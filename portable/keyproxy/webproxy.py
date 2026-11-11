"""Web proxy for the dsh-lab VM (HTTP + HTTPS CONNECT).

The VM has no direct route to the internet; it reaches the web only through this proxy
on the VirtualBox host-only address. Goals:
  * any public site is reachable (TCP over HTTP/CONNECT);
  * the VM can never reach your LAN, the host's loopback services, or other private ranges
    (destinations are resolved here and checked before connecting);
  * every connection is logged;
  * fail-closed if the host's public (egress) IP changes after you confirmed it at start,
    e.g. when the VPN drops.
Stop this window and the VM loses internet at once.
"""
import asyncio
import ipaddress
import os
import re
import socket
import sys
import time
import urllib.request

import json


def _load_config():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "config.json")
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except OSError:
        return {}


CFG = _load_config()
# setup.ps1 picks the port (outside Windows' reserved/dynamic ranges) and the host-only address
BIND = (os.environ.get("WEBPROXY_BIND") or CFG.get("host_ip", "192.168.56.1"),
        int(os.environ.get("WEBPROXY_PORT") or CFG.get("web_port", 18128)))
ALLOWED_CLIENTS = ipaddress.ip_network(os.environ.get("WEBPROXY_SUBNET") or CFG.get("subnet", "192.168.56.0/24"), strict=False)
# "vpn": chain through UPSTREAM and fail closed when the egress IP changes; "direct": your real IP is used
MODE = os.environ.get("WEBPROXY_MODE") or CFG.get("mode", "vpn")
UPSTREAM = os.environ.get("WEBPROXY_UPSTREAM") or CFG.get("upstream", "")
DIRECT = (MODE == "direct") or not UPSTREAM
BLOCKED_PORTS = {25}  # outbound mail
MAX_CONNS = 64
LOG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "webproxy.log")
EXTRA_BLOCKED = [ipaddress.ip_network(n) for n in ("100.64.0.0/10", "198.18.0.0/15", "0.0.0.0/8")]

state = {"egress_ok": True, "egress_ip": None, "conns": 0}


def log(msg):
    line = time.strftime("%H:%M:%S ") + msg
    print(line, flush=True)
    with open(LOG_PATH, "a", encoding="utf-8") as f:
        f.write(time.strftime("%Y-%m-%d ") + line + "\n")



def public_ip():
    # what the outside world sees for traffic leaving through the upstream proxy
    # several lookup services: any one failing (or being slow through the VPN) must not look like an IP change
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({"https": "http://" + UPSTREAM}))
    last = None
    for url in ("https://api.ipify.org", "https://icanhazip.com", "https://checkip.amazonaws.com"):
        try:
            ip = opener.open(url, timeout=8).read().decode().strip()
            ipaddress.ip_address(ip)
            return ip
        except Exception as e:
            last = e
    raise last


def is_blocked(ip):
    a = ipaddress.ip_address(ip)
    if a.version == 6:
        if a.ipv4_mapped:
            a = a.ipv4_mapped
        else:
            return True  # no IPv6 through this proxy
    if (a.is_private or a.is_loopback or a.is_link_local or a.is_multicast
            or a.is_reserved or a.is_unspecified):
        return True
    return any(a in n for n in EXTRA_BLOCKED)


_HOST_RE = re.compile(r"(?=.{1,253}$)([A-Za-z0-9_-]{1,63}\.)+[A-Za-z0-9-]{2,63}\.?")
_NUMERIC_LABEL = re.compile(r"(0x[0-9a-f]*|[0-9]+)", re.I)


def valid_hostname(host):
    """Plain DNS names only. Rejects odd IPv4 spellings (2130706433, 0x7f.0.0.1, 127.1) that
    a downstream resolver might still turn into 127.0.0.1, and single-label names."""
    if not _HOST_RE.fullmatch(host):
        return False
    last = host.rstrip(".").rsplit(".", 1)[-1]
    return not _NUMERIC_LABEL.fullmatch(last)


async def precheck(host, port):
    """Refuse private/loopback/LAN destinations. IP literals are checked directly; hostnames are
    resolved here first. If local DNS cannot resolve a name (common for blocked foreign sites),
    the upstream resolves it remotely, from the VPN side, where your LAN is not reachable."""
    try:
        lit = ipaddress.ip_address(host.strip("[]"))
    except ValueError:
        lit = None
    if lit is not None:
        if is_blocked(str(lit)):
            raise PermissionError("destination is a private/blocked address")
        return
    if not valid_hostname(host):
        raise PermissionError("not a plain DNS name")
    try:
        infos = await asyncio.get_running_loop().getaddrinfo(host, port, family=socket.AF_INET, type=socket.SOCK_STREAM)
    except OSError:
        return
    if any(is_blocked(i[4][0]) for i in infos):
        raise PermissionError("destination resolves to a private/blocked address")


async def open_direct(host, port):
    """Real-IP mode: connect from this PC. The address is resolved once here and checked, then used,
    so a name cannot change to a private address between the check and the connection."""
    loop = asyncio.get_running_loop()
    try:
        ipaddress.ip_address(host.strip("[]"))
        addrs = [host.strip("[]")]
    except ValueError:
        infos = await loop.getaddrinfo(host, port, family=socket.AF_INET, type=socket.SOCK_STREAM)
        addrs = [i[4][0] for i in infos]
    addrs = [a for a in addrs if not is_blocked(a)]
    if not addrs:
        raise PermissionError("no public address for this name")
    return await asyncio.wait_for(asyncio.open_connection(addrs[0], port), 15)


async def open_via_upstream(host, port):
    if DIRECT:
        return await open_direct(host, port)
    uh, _, up = UPSTREAM.rpartition(":")
    sr, sw = await asyncio.wait_for(asyncio.open_connection(uh, int(up)), 10)
    sw.write(f"CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n\r\n".encode())
    await sw.drain()
    resp = await asyncio.wait_for(sr.readuntil(b"\r\n\r\n"), 25)
    if b" 200" not in resp.split(b"\r\n", 1)[0]:
        sw.close()
        raise ConnectionError("upstream refused: " + resp.split(b"\r\n", 1)[0].decode("latin-1"))
    return sr, sw


async def pipe(r, w):
    try:
        while True:
            data = await r.read(65536)
            if not data:
                break
            w.write(data)
            await w.drain()
    except (ConnectionError, asyncio.CancelledError, OSError):
        pass
    finally:
        try:
            w.close()
        except Exception:
            pass


async def reply(w, code, text):
    w.write(f"HTTP/1.1 {code} {text}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".encode())
    try:
        await w.drain()
    except Exception:
        pass
    w.close()


async def handle(cr, cw):
    peer = cw.get_extra_info("peername")[0]
    if ipaddress.ip_address(peer) not in ALLOWED_CLIENTS:
        log(f"{peer} refused (not host-only client)")
        cw.close()
        return
    if state["conns"] >= MAX_CONNS:
        return await reply(cw, 503, "Busy")
    state["conns"] += 1
    sw = None
    try:
        head = await asyncio.wait_for(cr.readuntil(b"\r\n\r\n"), 15)
        lines = head.decode("latin-1").split("\r\n")
        method, target, ver = lines[0].split(" ", 2)
        if not state["egress_ok"]:
            log(f"{method} {target} -> 503 (egress IP changed: fail-closed)")
            return await reply(cw, 503, "Egress IP changed")
        if method == "CONNECT":
            host, _, port = target.rpartition(":")
            port = int(port)
        else:
            u = urllib.parse.urlsplit(target)
            if not u.hostname:
                return await reply(cw, 400, "Bad Request")
            host, port = u.hostname, u.port or 80
        if port in BLOCKED_PORTS:
            log(f"{method} {host}:{port} -> 403 (port blocked)")
            return await reply(cw, 403, "Port blocked")
        try:
            await precheck(host, port)
        except PermissionError as e:
            log(f"{method} {host}:{port} -> 403 ({e})")
            return await reply(cw, 403, "Blocked destination")
        try:
            sr, sw = await open_via_upstream(host, port)
        except Exception as e:
            log(f"{method} {host}:{port} -> 502 ({type(e).__name__}: {e})")
            return await reply(cw, 502, "Bad Gateway")
        if method == "CONNECT":
            cw.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        else:
            path = urllib.parse.urlunsplit(("", "", u.path or "/", u.query, ""))
            hdrs = [l for l in lines[1:] if l and not l.lower().startswith(("proxy-", "connection:"))]
            sw.write((f"{method} {path} {ver}\r\n" + "\r\n".join(hdrs) + "\r\nConnection: close\r\n\r\n").encode("latin-1"))
        log(f"{method} {host}:{port} -> ok")
        await asyncio.gather(pipe(cr, sw), pipe(sr, cw))
    except (asyncio.IncompleteReadError, asyncio.TimeoutError, ValueError, ConnectionError):
        pass
    finally:
        state["conns"] -= 1
        for w in (cw, sw):
            try:
                if w:
                    w.close()
            except Exception:
                pass


async def watch_egress():
    fails = 0
    while True:
        await asyncio.sleep(15)
        try:
            ip = await asyncio.get_running_loop().run_in_executor(None, public_ip)
            fails = 0
        except Exception as e:
            # one failed lookup is usually a VPN hiccup; a *different* IP still blocks at once
            fails += 1
            log(f"egress check failed ({type(e).__name__}), {fails} in a row")
            if fails < 2:
                continue
            ip = None
        ok = ip == state["egress_ip"]
        if ok != state["egress_ok"]:
            log(f"EGRESS IP {'back to expected' if ok else 'CHANGED to ' + str(ip)} -> traffic {'allowed' if ok else 'BLOCKED'}")
        state["egress_ok"] = ok


async def main():
    srv = await asyncio.start_server(handle, *BIND)
    log(f"webproxy listening on {BIND[0]}:{BIND[1]}; mode {'direct (REAL IP)' if DIRECT else 'vpn'}; egress IP {state['egress_ip']}")
    if not DIRECT:
        asyncio.create_task(watch_egress())
    async with srv:
        await srv.serve_forever()


if __name__ == "__main__":
    import urllib.parse  # noqa: F401  (used above)
    here = os.path.dirname(os.path.abspath(__file__))
    if DIRECT:
        print("=" * 64)
        print("REAL-IP MODE: websites opened from the VM will see YOUR real public IP.")
        print("Still protected: the real API key never enters the VM, and the VM cannot")
        print("reach your LAN, this PC's local services, or private addresses.")
        print("=" * 64)
        ack = os.path.join(here, "direct_ack.txt")
        if os.environ.get("WEBPROXY_ACK") != "1" and not os.path.exists(ack):
            if input("To continue type I UNDERSTAND: ").strip().upper() != "I UNDERSTAND":
                sys.exit("Not confirmed. Nothing was started.")
            with open(ack, "w") as f:
                f.write("acknowledged")
        state["egress_ip"] = None
    else:
        ip = public_ip()
        print(f"Host public IP right now: {ip}")
        seen = os.path.join(here, "confirmed_ip.txt")
        last = open(seen).read().strip() if os.path.exists(seen) else ""
        if os.environ.get("WEBPROXY_CONFIRM") == ip or last == ip:
            print("Same IP you confirmed as your VPN's before; continuing.")
        else:
            if input("Is this your VPN's IP (NOT your home IP)? Type YES to continue: ").strip().upper() != "YES":
                sys.exit("Turn the VPN on, then start again.")
            with open(seen, "w") as f:
                f.write(ip)
        state["egress_ip"] = ip
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        log("stopped")
