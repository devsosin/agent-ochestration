#!/usr/bin/env python3
"""imagegen: MCP server (streamable HTTP, JSON responses) that generates images with the host's Codex CLI.

Runs on the Mac mini host (`proj imagegen run`), so the ChatGPT login stays in the host's ~/.codex and never
enters project containers. Codex runs read-only with its shell tools disabled: a prompt can only make an image.
Containers call http://host.docker.internal:<port>/mcp and download the result from /files/<id>.<ext>.
Python 3.9 stdlib only (macOS /usr/bin/python3).
"""
import json, os, re, shutil, subprocess, sys, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("IMAGEGEN_PORT", "7801"))
BIND = os.environ.get("IMAGEGEN_BIND", "127.0.0.1")
OUT_DIR = os.environ.get("IMAGEGEN_DIR", os.path.expanduser("~/.agent-hub/imagegen"))
PUBLIC_URL = os.environ.get("IMAGEGEN_PUBLIC_URL", "http://host.docker.internal:%d" % PORT)
CODEX = os.environ.get("CODEX_BIN", "codex")
CODEX_HOME = os.environ.get("CODEX_HOME", os.path.expanduser("~/.codex"))
TIMEOUT = int(os.environ.get("IMAGEGEN_TIMEOUT", "300"))
KEEP_SECONDS = 24 * 3600
FILE_RE = re.compile(r"^[0-9a-f]{32}\.(png|jpg|jpeg|webp)$")
# Everything except image generation is turned off; read-only sandbox on top.
CODEX_ARGS = ["exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
              "-s", "read-only"] + sum((["--disable", f] for f in (
                  "shell_tool", "unified_exec", "apps", "plugins", "multi_agent", "browser_use", "computer_use",
                  "skill_search", "tool_suggest")), [])
TOOL = {
    "name": "generate_image",
    "description": "Generate one raster image (PNG) from a text description, using GPT image generation. "
                   "Takes 20-60 s. Returns a URL; download it into the project with curl, e.g. "
                   "`curl -fsS -o assets/logo.png <url>`. Describe subject, style, background, and aspect ratio.",
    "inputSchema": {"type": "object", "required": ["prompt"],
                    "properties": {"prompt": {"type": "string", "description": "What to draw, in detail"}}},
}
lock = threading.Lock()  # one generation at a time: it spends the ChatGPT plan's quota


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, file=sys.stderr, flush=True)


def prune():
    now = time.time()
    for name in os.listdir(OUT_DIR):
        p = os.path.join(OUT_DIR, name)
        if FILE_RE.match(name) and now - os.path.getmtime(p) > KEEP_SECONDS:
            os.remove(p)


def generate(prompt):
    """Returns (file name, None) or (None, error)."""
    task = ("Use your image generation tool exactly once to create the image described below. "
            "Do not run commands or read files. When the image is generated, reply with: done\n\n"
            "Image description:\n" + prompt)
    with lock:
        try:
            r = subprocess.run([CODEX] + CODEX_ARGS + [task], stdin=subprocess.DEVNULL, capture_output=True,
                               text=True, timeout=TIMEOUT, cwd=OUT_DIR, env=dict(os.environ, CODEX_HOME=CODEX_HOME))
        except subprocess.TimeoutExpired:
            return None, "codex timed out after %ds" % TIMEOUT
        except OSError as e:
            return None, "cannot run codex: %s" % e
    thread, last = None, ""
    for line in r.stdout.splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("type") == "thread.started":
            thread = ev.get("thread_id")
        item = ev.get("item") or {}
        if item.get("type") == "agent_message":
            last = item.get("text", "")
        if ev.get("type") in ("error", "turn.failed"):
            last = json.dumps(ev)[:500]
    src_dir = os.path.join(CODEX_HOME, "generated_images", thread or "-")
    files = sorted((os.path.join(src_dir, f) for f in os.listdir(src_dir)), key=os.path.getmtime) \
        if thread and os.path.isdir(src_dir) else []
    if not files:
        err = last or r.stderr.strip()[-500:] or "exit %d" % r.returncode
        return None, "no image produced: " + err
    ext = os.path.splitext(files[-1])[1].lstrip(".").lower() or "png"
    name = "%s.%s" % (uuid.uuid4().hex, ext)
    shutil.move(files[-1], os.path.join(OUT_DIR, name))
    shutil.rmtree(src_dir, ignore_errors=True)
    return name, None


def rpc(msg):
    """Handles one JSON-RPC message; None for notifications."""
    mid, method, params = msg.get("id"), msg.get("method"), msg.get("params") or {}
    if mid is None:
        return None
    if method == "initialize":
        result = {"protocolVersion": params.get("protocolVersion", "2025-06-18"),
                  "capabilities": {"tools": {}}, "serverInfo": {"name": "imagegen", "version": "1"}}
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": [TOOL]}
    elif method == "tools/call":
        prompt = ((params.get("arguments") or {}).get("prompt") or "").strip()
        if params.get("name") != TOOL["name"] or not prompt:
            result = {"isError": True, "content": [{"type": "text", "text": "usage: generate_image(prompt)"}]}
        else:
            t0 = time.time()
            name, err = generate(prompt)
            log("generate %s in %.0fs: %s" % ("ok" if name else "FAILED", time.time() - t0, name or err))
            text = ("Image ready (kept 24 h): %s/files/%s\nSave it with: curl -fsS -o <path in your project> %s/files/%s"
                    % (PUBLIC_URL, name, PUBLIC_URL, name)) if name else err
            result = {"isError": not name, "content": [{"type": "text", "text": text}]}
    else:
        return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "method not found: %s" % method}}
    return {"jsonrpc": "2.0", "id": mid, "result": result}


class Handler(BaseHTTPRequestHandler):
    def send(self, code, body=b"", ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/mcp":
            return self.send(404)
        try:
            msg = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)))
        except ValueError:
            return self.send(400, b'{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse error"}}')
        out = [r for r in map(rpc, msg if isinstance(msg, list) else [msg]) if r]
        if not out:
            return self.send(202)
        self.send(200, json.dumps(out if isinstance(msg, list) else out[0]).encode())

    def do_GET(self):
        if self.path == "/health":
            return self.send(200, b"ok", "text/plain")
        if self.path == "/mcp":  # no server-initiated stream
            return self.send(405)
        name = self.path[len("/files/"):] if self.path.startswith("/files/") else ""
        if not FILE_RE.match(name) or not os.path.isfile(os.path.join(OUT_DIR, name)):
            return self.send(404)
        with open(os.path.join(OUT_DIR, name), "rb") as f:
            ext = name.rsplit(".", 1)[1]
            self.send(200, f.read(), "image/" + ("jpeg" if ext == "jpg" else ext))

    def do_DELETE(self):  # session end; there is no session state
        self.send(200 if self.path == "/mcp" else 404)

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    os.makedirs(OUT_DIR, exist_ok=True)
    prune()
    threading.Thread(target=lambda: [time.sleep(3600) or prune() for _ in iter(int, 1)], daemon=True).start()
    log("imagegen on %s:%d (codex %s, CODEX_HOME %s)" % (BIND, PORT, CODEX, CODEX_HOME))
    ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()
