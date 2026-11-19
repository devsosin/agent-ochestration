#!/usr/bin/env python3
"""dockerproxy: Docker API proxy sidecar, one per project (compose service `docker`).

It holds the host Docker socket. The project's agent container gets only DOCKER_HOST=tcp://docker:2375, so
every Docker call goes through these rules: what the project creates is labelled agent-hub.project=<name>, and
only labelled objects can be used. Bind mounts stay inside PROJECT_DIR; privileged / host-namespace settings are
refused. Rules and reasons: docs/architecture.md (보안 경계). Tests: tests/dockerproxy_test.py. Python stdlib only.
"""
import http.client, json, os, re, socket, socketserver, sys, threading
from urllib.parse import parse_qsl, quote, urlencode, urlsplit

LABEL = "agent-hub.project"
PROJECT = os.environ.get("PROJECT_NAME", "")
PROJECT_DIR = os.path.realpath(os.environ.get("PROJECT_DIR", "/nonexistent"))
SOCK = os.environ.get("DOCKER_SOCK", "/var/run/docker.sock")
PORT = int(os.environ.get("PORT", "2375"))
MAX_JSON = 16 << 20
REF_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")             # container, volume, network, exec ids/names
IMAGE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_./:@-]*$")
NS_FIELDS = ("PidMode", "IpcMode", "UsernsMode", "UTSMode", "CgroupnsMode")
BUILTIN_NETWORKS = ("", "default", "bridge", "none")


class Deny(Exception):
    status = "403 Forbidden"


class NotFound(Deny):  # clients such as compose inspect first and create on 404
    status = "404 Not Found"


# --- JSON as Docker (Go) reads it: field names match case-insensitively ------------------------------------

def no_fold_dupes(pairs):
    seen = set()
    for k, _ in pairs:
        if k.casefold() in seen:  # Go keeps the last; a check reading the first would be bypassed
            raise Deny("duplicate JSON field %r" % k)
        seen.add(k.casefold())
    return dict(pairs)


def loads(data):
    try:
        return json.loads(data, object_pairs_hook=no_fold_dupes)
    except ValueError as e:
        raise Deny("invalid JSON: %s" % e)


def key(obj, name):  # the key Go would map to field `name` (casefold also covers Go's K/ſ folding)
    for k in obj or {}:
        if k.casefold() == name.casefold():
            return k
    return name


def g(obj, name):
    return (obj or {}).get(key(obj, name)) if isinstance(obj, dict) else None


def labelled(obj, labels):
    out = dict(labels or {})
    out[LABEL] = PROJECT
    return out


# --- ownership --------------------------------------------------------------------------------------------

def owned(obj):
    if not obj:
        return False
    labels = g(g(obj, "Config"), "Labels") if g(obj, "Config") is not None else g(obj, "Labels")
    return (labels or {}).get(LABEL) == PROJECT


def ref(r):
    if not isinstance(r, str) or not REF_RE.match(r):
        raise Deny("invalid name %r" % (r,))
    return r


def own(d, kind, r):  # -> the object's full id
    obj = d.get("/%s/%s" % (kind, ref(r)) + ("" if kind == "volumes" or kind == "networks" else "/json"))
    if obj is None:
        raise NotFound("No such %s: %s" % (kind[:-1], r))
    if not owned(obj):
        raise Deny("%s %s is not part of project %s" % (kind[:-1], r, PROJECT))
    return obj.get("Id") or obj.get("Name")


def own_container(d, r):
    return own(d, "containers", r)


def own_or_new_volume(d, name):
    v = d.get("/volumes/" + ref(name))
    if v is None:  # Docker would create it unlabelled; create it labelled first
        d.call("POST", "/volumes/create", {"Name": name, "Labels": labelled(None, None)})
    elif not owned(v):
        raise Deny("volume %s is not part of project %s" % (name, PROJECT))


def network(d, n):  # NetworkMode / EndpointsConfig value
    if n in BUILTIN_NETWORKS:
        return
    if n.lower() == "host":
        raise Deny("host networking is not allowed")
    if n.startswith("container:"):
        own_container(d, n.split(":", 1)[1])
    else:
        own(d, "networks", n)


def bind_source(src):
    real = os.path.realpath(src)
    # shortcut: a path checked here can still be swapped for a symlink before the daemon mounts it; closing that
    # race needs the daemon to mount by file descriptor, which Docker has no API for.
    if not src.startswith("/") or (real != PROJECT_DIR and not real.startswith(PROJECT_DIR + "/")):
        raise Deny("bind mount %s is outside the project folder %s" % (src, PROJECT_DIR))
    if real.endswith("docker.sock"):
        raise Deny("the Docker socket cannot be mounted")
    return real


def volume_driver(name, opts):
    if name not in (None, "", "local"):
        raise Deny("volume driver %s is not allowed" % name)
    if opts and g(opts, "type") != "tmpfs":  # local driver options can bind any host path (type=none,o=bind)
        raise Deny("volume driver options other than type=tmpfs are not allowed")


# --- request rules ----------------------------------------------------------------------------------------

def check_container(b, d):
    b = b if isinstance(b, dict) else {}
    h = g(b, "HostConfig") or {}
    for f in ("Privileged", "CapAdd", "Devices", "DeviceCgroupRules", "DeviceRequests", "CgroupParent"):
        if g(h, f):
            raise Deny("%s is not allowed" % f)
    for f in ("MaskedPaths", "ReadonlyPaths"):  # an empty list unmasks /proc and /sys
        if g(h, f) is not None:
            raise Deny("%s is not allowed" % f)
    for o in g(h, "SecurityOpt") or []:
        if o.replace("=", ":") not in ("no-new-privileges", "no-new-privileges:true"):
            raise Deny("security option %s is not allowed" % o)
    for f in NS_FIELDS:
        v = g(h, f) or ""
        if v.lower() == "host":
            raise Deny("%s=host is not allowed" % f)
        if v.startswith("container:"):
            own_container(d, v.split(":", 1)[1])
    if (g(h, "Runtime") or "runc") != "runc":
        raise Deny("runtime %s is not allowed" % g(h, "Runtime"))
    volume_driver(g(h, "VolumeDriver"), None)
    network(d, g(h, "NetworkMode") or "")
    for n in g(g(b, "NetworkingConfig"), "EndpointsConfig") or {}:
        network(d, n)
    for v in g(h, "VolumesFrom") or []:
        own_container(d, v.split(":")[0])
    binds = []
    for s in g(h, "Binds") or []:
        parts = s.split(":")
        if parts[0].startswith("/"):
            parts[0] = bind_source(parts[0])
        else:
            own_or_new_volume(d, parts[0])
        binds.append(":".join(parts))
    if binds:
        h[key(h, "Binds")] = binds
    for m in g(h, "Mounts") or []:
        t, src = (g(m, "Type") or "volume"), g(m, "Source")
        if t == "bind":
            m[key(m, "Source")] = bind_source(src or "")
        elif t == "volume":
            dc = g(g(m, "VolumeOptions"), "DriverConfig")
            volume_driver(g(dc, "Name"), g(dc, "Options"))
            if src:
                own_or_new_volume(d, src)
        elif t not in ("tmpfs", "image"):
            raise Deny("mount type %s is not allowed" % t)
    b[key(b, "Labels")] = labelled(b, g(b, "Labels"))
    return b


def check_exec(b):
    if g(b, "Privileged"):
        raise Deny("privileged exec is not allowed")
    return b


def check_volume(b):
    b = b if isinstance(b, dict) else {}
    volume_driver(g(b, "Driver"), g(b, "DriverOpts"))
    b[key(b, "Labels")] = labelled(b, g(b, "Labels"))
    return b


def check_network(b):
    b = b if isinstance(b, dict) else {}
    if g(b, "Driver") not in (None, "", "bridge"):
        raise Deny("network driver %s is not allowed" % g(b, "Driver"))
    if g(b, "ConfigOnly") or g(b, "ConfigFrom"):
        raise Deny("config networks are not allowed")
    b[key(b, "Labels")] = labelled(b, g(b, "Labels"))
    return b


def image_repo(r):  # "docker.io/library/agent-hub:base" -> "agent-hub"
    r = r.split("@")[0].lower()
    if ":" in r.rsplit("/", 1)[-1]:
        r = r.rsplit(":", 1)[0]
    for pre in ("docker.io/", "index.docker.io/", "library/"):
        if r.startswith(pre):
            r = r[len(pre):]
    return r


def check_image_target(d, r):
    """A tag a build or `docker tag` writes. Overwriting another project's (or the hub's) image would run this
    project's code in their containers, so only new names and this project's own images can be written."""
    if not IMAGE_RE.match(r or "") or ".." in r:
        raise Deny("invalid image name %r" % (r,))
    if image_repo(r) == "agent-hub":
        raise Deny("agent-hub images are reserved")
    img = d.get("/images/%s/json" % r)
    if img is not None and not owned(img):
        raise Deny("image %s exists and was not built by project %s" % (r, PROJECT))
    # shortcut: a name nobody has pulled yet (e.g. postgres:99) can be built here first and then used by another
    # project's compose; upgrade to per-project image namespaces if projects start sharing tag names.


def qget(q, k):
    return next((v for kk, v in q if kk == k), "")


def force_label(q):
    f = loads(qget(q, "filters") or "{}")
    if not isinstance(f, dict):
        raise Deny("invalid filters")
    labels = f.get("label") or {}
    if isinstance(labels, list):
        labels = dict((l, True) for l in labels)
    labels["%s=%s" % (LABEL, PROJECT)] = True  # label filters are ANDed
    f["label"] = labels
    return [(k, v) for k, v in q if k != "filters"] + [("filters", json.dumps(f))]


def check_build(q, d):
    for k, v in q:
        if k == "t":
            check_image_target(d, v)
        elif k == "networkmode" and v not in BUILTIN_NETWORKS:
            raise Deny("build network mode %s is not allowed" % v)
        elif k == "version" and v == "2":
            raise Deny("BuildKit is not available through the project proxy (DOCKER_BUILDKIT=0)")
    labels = labelled(None, loads(qget(q, "labels") or "{}"))
    return [(k, v) for k, v in q if k != "labels"] + [("labels", json.dumps(labels))]


def route(method, p, q, body, d):
    """Decides one request. Returns (path, query, body) to forward, possibly rewritten; raises Deny."""
    s = p.strip("/").split("/")
    head, n = s[0], len(s)
    get, post, delete = method in ("GET", "HEAD"), method == "POST", method == "DELETE"
    if p in ("/_ping", "/version", "/info") and get:
        return p, q, body
    if p == "/events" and get:
        return p, force_label(q), body
    if head == "containers":
        if p == "/containers/json" and get:
            return p, force_label(q), body
        if p == "/containers/create" and post:
            return p, q, check_container(body, d)
        if n >= 2 and s[1] not in ("json", "create", "prune") and (n > 2 or delete):
            cid = own_container(d, s[1])
            if n == 3 and s[2] == "exec" and post:
                body = check_exec(body)
            return "/".join(["", "containers", cid] + s[2:]), q, body
    elif head == "exec" and n == 3 and s[2] in ("start", "resize", "json"):
        e = d.get("/exec/%s/json" % ref(s[1]))
        if e is None:
            raise NotFound("No such exec instance: %s" % s[1])
        own_container(d, e.get("ContainerID"))
        return p, q, body
    elif head == "images":
        if p in ("/images/json", "/images/search", "/images/get") and get:
            return p, q, body
        if p == "/images/create" and post:
            if qget(q, "fromSrc"):
                raise Deny("image import is not allowed")
            if image_repo(qget(q, "fromImage")) == "agent-hub":
                raise Deny("agent-hub images are reserved")
            return p, q, body
        if n >= 3 and s[-1] in ("json", "history", "get") and get or n >= 3 and s[-1] == "push" and post:
            return p, q, body
        if n >= 3 and s[-1] == "tag" and post:
            check_image_target(d, "%s:%s" % (qget(q, "repo"), qget(q, "tag") or "latest"))
            return p, q, body
    elif p == "/build" and post:
        return p, check_build(q, d), body
    elif head == "volumes":
        if p == "/volumes" and get:
            return p, force_label(q), body
        if p == "/volumes/create" and post:
            return p, q, check_volume(body)
        if n == 2 and s[1] != "prune" and (get or delete):
            own(d, "volumes", s[1])
            return p, q, body
    elif head == "networks":
        if p == "/networks" and get:
            return p, force_label(q), body
        if p == "/networks/create" and post:
            return p, q, check_network(body)
        if n == 2 and s[1] != "prune" and (get or delete):
            return "/networks/" + own(d, "networks", s[1]), q, body
        if n == 3 and post and s[2] in ("connect", "disconnect"):
            nid = own(d, "networks", s[1])
            own_container(d, g(body, "Container"))
            return "/networks/%s/%s" % (nid, s[2]), q, body
    elif head == "distribution" and get:
        return p, q, body
    raise Deny("%s %s is not allowed through the project proxy" % (method, p))


# --- daemon access ----------------------------------------------------------------------------------------

class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=60)
        self.unix_path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self.unix_path)


class Daemon:
    """The lookups the rules make; tests replace it."""

    def call(self, method, path, body=None):  # -> JSON, or None for 404
        c = UnixHTTPConnection(SOCK)
        try:
            data = None if body is None else json.dumps(body)
            c.request(method, quote(path, safe="/:@"), data, {"Content-Type": "application/json"} if data else {})
            r = c.getresponse()
            out = r.read()
        finally:
            c.close()
        if r.status == 404:
            return None
        if r.status >= 400:
            raise Deny("docker %s %s: %s" % (method, path, out[:300].decode("utf-8", "replace")))
        return json.loads(out) if out else {}

    def get(self, path):
        return self.call("GET", path)


# --- HTTP plumbing ----------------------------------------------------------------------------------------

def body_pieces(rfile, hdr):  # the request body, de-chunked
    if "chunked" in hdr.get("transfer-encoding", "").lower():
        while True:
            size = int(rfile.readline(1024).split(b";")[0].strip() or b"0", 16)
            if size == 0:
                while rfile.readline(65537) not in (b"\r\n", b"\n", b""):
                    pass
                return
            while size > 0:
                b = rfile.read(min(size, 65536))
                if not b:
                    return
                size -= len(b)
                yield b
            rfile.readline(1024)
    else:
        n = int(hdr.get("content-length") or 0)
        while n > 0:
            b = rfile.read(min(n, 65536))
            if not b:
                return
            n -= len(b)
            yield b


def deny_response(msg, status=Deny.status):
    body = json.dumps({"message": "agent-hub docker proxy: " + msg}).encode()
    return (b"HTTP/1.1 " + status.encode() + b"\r\nContent-Type: application/json\r\nConnection: close\r\n"
            b"Content-Length: %d\r\n\r\n" % len(body)) + body


def pump(src, dst):  # copies until EOF, then half-closes dst
    try:
        while True:
            b = src.read1(65536) if hasattr(src, "read1") else src.recv(65536)
            if not b:
                break
            dst.sendall(b)
    except OSError:
        pass
    try:
        dst.shutdown(socket.SHUT_WR)
    except OSError:
        pass


class Handler(socketserver.BaseRequestHandler):
    daemon = Daemon()

    def handle(self):
        client = self.request
        rfile = client.makefile("rb")
        method = target = "?"
        try:
            line = rfile.readline(65537).decode("latin-1")
            if not line.strip():
                return
            method, target, _ = line.split(" ", 2)
            headers = []
            while True:
                h = rfile.readline(65537).decode("latin-1")
                if h in ("\r\n", "\n", ""):
                    break
                k, _, v = h.partition(":")
                headers.append((k.strip(), v.strip()))
                if len(headers) > 200:
                    raise Deny("too many headers")
            hdr = dict((k.lower(), v) for k, v in headers)
            u = urlsplit(target)
            m = re.match(r"^(/v[0-9.]+)?(/[^%]*)$", u.path)  # no percent-encoding: the daemon decodes paths
            if not m or any(seg in (".", "..") for seg in m.group(2).split("/")) or "//" in m.group(2):
                raise Deny("invalid path %s" % u.path)
            prefix, p = m.group(1) or "", m.group(2)
            q = parse_qsl(u.query, keep_blank_values=True)
            body, is_json = None, hdr.get("content-type", "").startswith("application/json")
            if is_json:
                data = b""
                for piece in body_pieces(rfile, hdr):
                    data += piece
                    if len(data) > MAX_JSON:
                        raise Deny("request body too large")
                body = loads(data) if data.strip() else None
            p, q, body = route(method, p, q, body, self.daemon)
        except Deny as e:
            print("deny %s %s: %s" % (method, target, e), file=sys.stderr, flush=True)
            client.sendall(deny_response(str(e), e.status))
            return
        except (ValueError, OSError) as e:
            client.sendall(deny_response("bad request: %s" % e))
            return

        up = socket.socket(socket.AF_UNIX)
        try:
            up.connect(SOCK)
            upgrade = "upgrade" in hdr
            # `close` makes the daemon end the connection after one response, so nothing after it is parsed
            # as a second, unchecked request. Hijacked streams (attach, exec) are raw after the upgrade.
            out = ["%s %s%s%s HTTP/1.1" % (method, prefix, p, "?" + urlencode(q) if q else ""),
                   "Connection: %s" % ("Upgrade, close" if upgrade else "close")]
            drop = {"connection", "keep-alive", "proxy-connection"}
            if is_json:
                drop |= {"content-length", "transfer-encoding"}
            out += ["%s: %s" % (k, v) for k, v in headers if k.lower() not in drop]
            if is_json:
                data = json.dumps(body).encode() if body is not None else b""
                out.append("Content-Length: %d" % len(data))
                up.sendall(("\r\n".join(out) + "\r\n\r\n").encode("latin-1") + data)
            else:
                up.sendall(("\r\n".join(out) + "\r\n\r\n").encode("latin-1"))
                chunked = "chunked" in hdr.get("transfer-encoding", "").lower()
                for piece in body_pieces(rfile, hdr):
                    up.sendall(b"%x\r\n%s\r\n" % (len(piece), piece) if chunked else piece)
                if chunked:
                    up.sendall(b"0\r\n\r\n")
            stream = upgrade or p.endswith("/attach") or (p.startswith("/exec/") and p.endswith("/start"))
            if stream:
                threading.Thread(target=pump, args=(rfile, up), daemon=True).start()
            pump(up, client)
        except OSError as e:
            print("error %s %s: %s" % (method, p, e), file=sys.stderr, flush=True)
        finally:
            up.close()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    if not PROJECT or not os.path.isdir(PROJECT_DIR):
        sys.exit("dockerproxy: PROJECT_NAME and an existing PROJECT_DIR are required")
    print("dockerproxy for %s (%s) on :%d" % (PROJECT, PROJECT_DIR, PORT), file=sys.stderr, flush=True)
    Server(("0.0.0.0", PORT), Handler).serve_forever()
