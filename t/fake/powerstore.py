#!/usr/bin/env python3
"""A fake PowerStore, over real HTTPS, that REFUSES what the real one refuses.

This exists because the unit tests stub the API client entirely, which proves
the decision logic and says nothing about whether the requests are ones a
PowerStore would answer. Driving the real client over a real socket is the
only thing that has ever settled an argument with a customer's measurement.

It covers only as much as the host-group work needs. The REFUSALS are the
point: a fixture that accepts anything restates the assumption under test,
which is how a logout that had never worked was confirmed for five releases
(lesson 79). What this one enforces, and why each matters:

  - a host belongs to AT MOST ONE host group. add_host_ids naming a host that
    already has one is refused 422. This is the property the whole host-group
    design rests on, and without it the fixture would happily let the plugin
    do the one thing it must never do.
  - add_host_ids and remove_host_ids are mutually exclusive in a single PATCH,
    as Dell's own client builds them, so a move cannot be atomic here either.
  - GET /host_group/<unknown> answers 404, not an empty object: absent and
    "could not ask" have to stay distinguishable (rule 21a).
  - every non-GET requires the DELL-EMC-TOKEN header.
  - attach and detach name a host OR a host group, never both. The real array
    answers a body carrying both with HTTP 500 'Volume internal error'
    (0xE0A080010052), which reads as an array fault rather than a bad request,
    and that is what hid issue #11 for thirteen releases. This one answers 500
    too, deliberately, so the fixture cannot make the client look correct.

Usage:

    openssl req -x509 -newkey rsa:2048 -keyout /tmp/fake.pem -out /tmp/fake.pem \
        -days 2 -nodes -subj "/CN=127.0.0.1"
    python3 t/fake/powerstore.py 18443 clean   /tmp/fake.pem   # host in no group
    python3 t/fake/powerstore.py 18443 foreign /tmp/fake.pem   # host in someone else's

then point a storage at --dell-portal 127.0.0.1:18443 --dell-ssl-verify 0.
On SIGTERM it prints the hosts and groups it ended up with, which is what you
assert against. Not a Dell product and not a simulation of storage behaviour:
it proves what the plugin SENDS and how it reacts to a refusal, nothing more.
"""
import json, ssl, sys, uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

TOKEN = "tok-fake-123"
HOSTS = {}          # id -> {id,name,host_group_id}
GROUPS = {}         # id -> {id,name,description}
LOG = []

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("DELL-EMC-TOKEN", TOKEN)
        self.end_headers()
        self.wfile.write(body)

    def _err(self, code, msg):
        LOG.append(("REFUSED", msg))
        self._send(code, {"messages": [{"code": "0xE0", "severity": "Error",
                                        "message_l10n": msg}]})

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def _auth_ok(self):
        return self.headers.get("DELL-EMC-TOKEN") == TOKEN

    def do_GET(self):
        u = urlparse(self.path); p = u.path; q = parse_qs(u.query)
        LOG.append(("GET", p))
        if p.endswith("/login_session"):
            return self._send(200, [])
        if p.endswith("/host"):
            name = (q.get("name", [""])[0] or "").replace("eq.", "")
            return self._send(200, [h for h in HOSTS.values() if h["name"] == name])
        if p.endswith("/host_group"):
            name = (q.get("name", [""])[0] or "").replace("eq.", "")
            return self._send(200, [g for g in GROUPS.values() if g["name"] == name])
        if "/host_group/" in p:
            gid = p.rsplit("/", 1)[-1]
            if gid not in GROUPS:
                return self._err(404, "not found")     # ABSENT, not empty
            return self._send(200, GROUPS[gid])
        return self._send(200, [])

    def do_POST(self):
        p = urlparse(self.path).path
        if not self._auth_ok():
            return self._err(401, "missing DELL-EMC-TOKEN")
        b = self._body(); LOG.append(("POST", p, b))
        if p.endswith("/attach") or p.endswith("/detach"):
            if b.get("host_id") and b.get("host_group_id"):
                # As the array does: a 500, not a helpful 422.
                return self._err(500, "Volume internal error. Contact your"
                                      " support provider. (0xE0A080010052)")
            if not b.get("host_id") and not b.get("host_group_id"):
                return self._err(422, "either host_id or host_group_id is required")
            LOG.append(("MAPPED", p, b))
            return self._send(204, {})
        if p.endswith("/host_group"):
            if any(g["name"] == b.get("name") for g in GROUPS.values()):
                return self._err(422, "a host group with that name exists")
            gid = "hg-" + uuid.uuid4().hex[:6]
            GROUPS[gid] = {"id": gid, "name": b["name"],
                           "description": b.get("description", "")}
            for hid in b.get("host_ids", []):
                if HOSTS.get(hid, {}).get("host_group_id"):
                    return self._err(422, "host already in a host group")
                HOSTS[hid]["host_group_id"] = gid
            return self._send(201, {"id": gid})
        return self._send(200, {})

    def do_PATCH(self):
        p = urlparse(self.path).path
        if not self._auth_ok():
            return self._err(401, "missing DELL-EMC-TOKEN")
        b = self._body(); LOG.append(("PATCH", p, b))
        if "/host_group/" in p:
            gid = p.rsplit("/", 1)[-1]
            if gid not in GROUPS:
                return self._err(404, "not found")
            if "add_host_ids" in b and "remove_host_ids" in b:
                return self._err(422, "add and remove are mutually exclusive")
            for hid in b.get("add_host_ids", []):
                cur = HOSTS.get(hid, {}).get("host_group_id")
                if cur and cur != gid:
                    # THE refusal that matters.
                    return self._err(422, "host is already in host group " + cur)
                HOSTS[hid]["host_group_id"] = gid
            for hid in b.get("remove_host_ids", []):
                HOSTS[hid]["host_group_id"] = None
            return self._send(200, {})
        return self._send(200, {})

if __name__ == "__main__":
    port = int(sys.argv[1])
    HOSTS["h-1"] = {"id": "h-1", "name": "pve-cluster1-pc-pve1", "host_group_id": None}
    HOSTS["h-2"] = {"id": "h-2", "name": "pve-cluster1-node2", "host_group_id": None}
    if len(sys.argv) > 2 and sys.argv[2] == "foreign":
        GROUPS["hg-theirs"] = {"id": "hg-theirs", "name": "vmware-cluster",
                               "description": "ESXi hosts"}
        HOSTS["h-1"]["host_group_id"] = "hg-theirs"
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(sys.argv[3] if len(sys.argv) > 3 else "/tmp/fake.pem")
    srv = HTTPServer(("127.0.0.1", port), H)
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    import atexit, signal
    def dump(*a):
        print(json.dumps({"hosts": HOSTS, "groups": GROUPS}, indent=1))
        sys.exit(0)
    signal.signal(signal.SIGTERM, dump)
    srv.serve_forever()
