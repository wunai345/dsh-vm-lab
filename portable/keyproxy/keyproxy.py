"""Key-injecting proxy for the dsh-lab VM.

The VM's dsh points its API base URL at http://<host-only address>:<key_port>/anthropic (this PC's VirtualBox host-only address)
and uses the dummy key below. This proxy swaps in the real
DeepSeek key, so the real key never exists inside the VM.

- Binds the VirtualBox host-only address only (not the LAN, not loopback).
- Real key is typed at a hidden prompt and kept in memory only.
- Allowlist of API paths, request caps, no bodies or keys in logs.
- Stop it (Ctrl+C or close the window) and the VM loses model access at once.
"""
import getpass
import http.client
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = "api.deepseek.com"
DUMMY_KEY = "lab-dummy-key"
# Host-only adapter address and port come from ../config.json (written by setup.ps1).
import json


def _load_config():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "config.json")
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except OSError:
        return {}


CFG = _load_config()
BIND = (os.environ.get("KEYPROXY_BIND") or CFG.get("host_ip", "192.168.56.1"),
        int(os.environ.get("KEYPROXY_PORT") or CFG.get("key_port", 8787)))
ALLOWED = {
    ("POST", "/chat/completions"),
    ("POST", "/v1/chat/completions"),
    ("GET", "/models"),
    ("GET", "/v1/models"),
    # dsh talks the Anthropic Messages protocol (default base: https://api.deepseek.com/anthropic)
    ("POST", "/anthropic/v1/messages"),
    ("POST", "/anthropic/v1/messages/count_tokens"),
}
PASS_HEADERS = ("anthropic-version", "anthropic-beta")
MAX_TOTAL = int(os.environ.get("KEYPROXY_MAX_TOTAL", "2000"))
MAX_PER_MIN = int(os.environ.get("KEYPROXY_MAX_PER_MIN", "30"))
LOG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "proxy.log")
HOP = {"connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade",
       "proxy-authenticate", "proxy-authorization"}

def read_key():
    """Hidden key entry that echoes one * per character, so you can see a paste landed."""
    if os.name != "nt":
        return getpass.getpass("DeepSeek key (hidden, kept in memory only): ").strip()
    import msvcrt
    print("DeepSeek key (kept in memory only). Paste with right-click, then press Enter. You will see * for each character.")
    for attempt in range(3):
        sys.stdout.write("key> ")
        sys.stdout.flush()
        chars = []
        while True:
            ch = msvcrt.getwch()
            if ch in ("\r", "\n"):
                break
            if ch == "\x03":
                raise KeyboardInterrupt
            if ch in ("\x00", "\xe0"):
                msvcrt.getwch()  # swallow the second code of a special key
            elif ch == "\b":
                if chars:
                    chars.pop()
                    sys.stdout.write("\b \b")
            else:
                chars.append(ch)
                sys.stdout.write("*")
            sys.stdout.flush()
        print()
        key = "".join(chars).strip()
        if key:
            print(f"Got {len(key)} characters.")
            return key
        print("Nothing received. Click this window, then paste again (right-click), then Enter.")
    return ""


REAL_KEY = os.environ.get("KEYPROXY_KEY") or read_key()
if not REAL_KEY:
    sys.exit("No key given.")

lock = threading.Lock()
total = 0
recent = []


def log(msg):
    line = time.strftime("%H:%M:%S ") + msg
    print(line, flush=True)
    with open(LOG_PATH, "a", encoding="utf-8") as f:
        f.write(time.strftime("%Y-%m-%d ") + line + "\n")


def allow_request():
    global total
    now = time.time()
    with lock:
        recent[:] = [t for t in recent if now - t < 60]
        if total >= MAX_TOTAL:
            return "total cap reached"
        if len(recent) >= MAX_PER_MIN:
            return "per-minute cap reached"
        total += 1
        recent.append(now)
    return None


class Handler(BaseHTTPRequestHandler):
    server_version = "keyproxy"

    def log_message(self, *a):
        pass

    def deny(self, code, why):
        body = ('{"error":"%s"}' % why).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        log(f"{self.command} {self.path} -> {code} ({why})")

    def handle_any(self):
        path = self.path.split("?")[0]
        sent = self.headers.get("x-api-key") or self.headers.get("Authorization", "").removeprefix("Bearer ")
        if sent != DUMMY_KEY:
            return self.deny(401, "bad dummy key")
        if (self.command, path) not in ALLOWED:
            return self.deny(403, "path not allowed")
        why = allow_request()
        if why:
            return self.deny(429, why)
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else None
        headers = {
            "Authorization": "Bearer " + REAL_KEY,
            "x-api-key": REAL_KEY,
            "Accept-Encoding": "identity",
            "Content-Type": self.headers.get("Content-Type", "application/json"),
        }
        for h in ("Accept",) + PASS_HEADERS:
            if self.headers.get(h):
                headers[h] = self.headers[h]
        try:
            conn = http.client.HTTPSConnection(UPSTREAM, timeout=300)
            conn.request(self.command, self.path, body=body, headers=headers)
            resp = conn.getresponse()
        except Exception as e:
            return self.deny(502, "upstream error: " + type(e).__name__)
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() not in HOP:
                self.send_header(k, v)
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            while True:
                chunk = resp.read1(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            conn.close()
        log(f"{self.command} {path} -> {resp.status} (#{total})")

    do_GET = handle_any
    do_POST = handle_any


if __name__ == "__main__":
    srv = ThreadingHTTPServer(BIND, Handler)
    log(f"keyproxy listening on {BIND[0]}:{BIND[1]}; caps: {MAX_TOTAL} total, {MAX_PER_MIN}/min")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        log("stopped")
