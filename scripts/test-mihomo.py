"""Exercise the packaged supervisor and real Mihomo using loopback services."""
import http.client
import json
import os
from pathlib import Path
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
from urllib.request import build_opener, ProxyHandler, Request

ROOT = Path(__file__).resolve().parents[1]
LOCAL = build_opener(ProxyHandler({}))

class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True

class Endpoint(socketserver.StreamRequestHandler):
    def handle(self):
        line = self.rfile.readline(8192)
        if not line:
            return
        while self.rfile.readline(8192) not in (b"\r\n", b""):
            pass
        if line.startswith(b"CONNECT "):
            self.wfile.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            self.handle()
            return
        data = self.server.label
        self.wfile.write(b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: %d\r\n\r\n" % len(data) + data)

def server(label):
    srv = Server(("127.0.0.1", 0), Endpoint)
    srv.label = label
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv

def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]

def get(port, url):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=8)
    try:
        conn.request("GET", url)
        res = conn.getresponse()
        return res.status, res.read()
    finally:
        conn.close()

def tunnel(port, target):
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    s.sendall(f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n".encode())
    reply = http.client.HTTPResponse(s)
    reply.begin()
    assert reply.status == 200
    reply.close()
    return s

def verify_cut(phone_tunnel, direct_tunnel):
    with phone_tunnel, direct_tunnel:
        try:
            assert phone_tunnel.recv(1) == b""
        except ConnectionResetError:
            pass
        direct_tunnel.sendall(b"GET / HTTP/1.1\r\nHost: enterprise\r\n\r\n")
        reply = http.client.HTTPResponse(direct_tunnel)
        reply.begin()
        assert reply.read() == b"enterprise"

def test(binary, tmp):
    phone, enterprise = server(b"phone"), server(b"enterprise")
    proxy, pac = free_port(), free_port()
    config = json.loads((ROOT / "src/default.json").read_text())
    config["listen_addr"] = f"127.0.0.1:{proxy}"
    config["pac_port"] = pac
    config["hotspot"].update(mode="always", interface="Loopback Pseudo-Interface 1" if os.name=="nt" else "lo0", proxy_host="127.0.0.1", proxy_port=phone.server_address[1])
    config["domains"].append(dict(pattern="*.official.invalid", hotspot=True))
    rules = tmp / "mihomo/rules"
    rules.mkdir(parents=True)
    (rules/"sample").write_text("payload:\n  - +.subscribed.invalid\n")
    config["rule_providers"] = [dict(name="sample", behavior="domain", format="yaml", url="https://rules.invalid/sample")]
    path = tmp / "config.json"
    path.write_text(json.dumps(config))
    proc = subprocess.Popen([binary,"daemon","--config",str(path)])
    def wait_state(active):
        deadline = time.monotonic() + 40
        last = None
        while time.monotonic() < deadline:
            assert proc.poll() is None, proc.returncode
            try:
                last = json.loads((tmp/"runtime.json").read_text(encoding="utf-8"))["hotspot"]
                if last["active"] is active:
                    return
            except (FileNotFoundError, PermissionError):
                pass
            time.sleep(.2)
        raise AssertionError(last)
    try:
        wait_state(True)
        assert b"PROXY 127.0.0.1:" in get(pac, "/proxy.pac")[1]
        assert get(proxy,"http://service.official.invalid/")[1] == b"phone"
        assert get(proxy,"http://service.subscribed.invalid/")[1] == b"phone"
        internal = f"http://127.0.0.1:{enterprise.server_address[1]}/corp"
        assert get(proxy,internal)[1] == b"enterprise"
        assert get(7898,internal)[1] == b"enterprise"
        phone_tunnel = tunnel(proxy, "service.official.invalid:443")
        direct_tunnel = tunnel(proxy, f"127.0.0.1:{enterprise.server_address[1]}")
        subprocess.run([binary,"hotspot","off","--config",str(path)],check=True)
        wait_state(False)
        verify_cut(phone_tunnel, direct_tunnel)
        assert get(proxy,internal)[1] == b"enterprise"
        subprocess.run([binary,"hotspot","auto","--config",str(path)],check=True)
        config["hotspot"]["mode"]="always"
        path.write_text(json.dumps(config))
        wait_state(True)
        phone_tunnel = tunnel(proxy, "service.official.invalid:443")
        direct_tunnel = tunnel(proxy, f"127.0.0.1:{enterprise.server_address[1]}")
        phone.shutdown()
        phone.server_close()
        wait_state(False)
        verify_cut(phone_tunnel, direct_tunnel)
        settings=json.loads((tmp/"mihomo/config.yaml").read_text())
        url="http://"+settings["external-controller"]+"/proxies/SELECTED"
        req=Request(url,headers={"Authorization":"Bearer "+settings["secret"]})
        assert json.load(LOCAL.open(req,timeout=3))["now"]=="DIRECT"
        assert get(proxy,internal)[1]==b"enterprise"
        events = [json.loads(line) for line in (tmp/"routing.jsonl").read_text().splitlines()]
        for trigger in ["manual_off","phone_unavailable"]:
            assert any(e["event"] == trigger and e["egress"] == "system_direct" and e["closed_phone_connections"] >= 1 for e in events), events
        print("PASS: PAC, selected destination, corporate direct, legacy port, manual off, phone loss -> DIRECT")
    finally:
        if os.name=="nt":
            subprocess.run(["taskkill","/F","/T","/PID",str(proc.pid)],capture_output=True)
        else:
            proc.terminate()
        proc.wait(timeout=10)
        phone.shutdown();phone.server_close();enterprise.shutdown();enterprise.server_close()

if __name__=="__main__":
    binary=str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory() as directory:
        test(binary,Path(directory))

