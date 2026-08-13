import argparse
import json
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


ACCOUNT_ID = "a" * 32
ZONE_ID = "b" * 32
FAKE_API_TOKEN = "fake-public-token-for-local-tests-only-1234567890"
FAKE_TUNNEL_TOKEN = "fake-runtime-tunnel-token-for-local-tests-only-1234567890"
FANGDAI_TUNNEL_ID = "2d75ec14-e65b-45e2-8335-e54759514d73"


class State:
    def __init__(self, seed_fangdai: bool, fail_token_requests: int) -> None:
        self.lock = threading.Lock()
        self.retry_count = 0
        self.next_dns_id = 1
        self.fail_token_requests = fail_token_requests
        self.tunnels: dict[str, dict] = {}
        self.configurations: dict[str, dict] = {}
        self.dns_records: dict[str, dict] = {}
        self.access_applications: dict[str, dict] = {}
        self.access_policies: dict[str, list[dict]] = {}
        if seed_fangdai:
            self.tunnels[FANGDAI_TUNNEL_ID] = {
                "id": FANGDAI_TUNNEL_ID,
                "name": "wsl-fangdai",
                "status": "healthy",
                "connections": [{"id": "mock-connection"}],
            }
            self.configurations[FANGDAI_TUNNEL_ID] = {
                "config": {
                    "ingress": [
                        {"hostname": "fangdai.scuccs.me", "service": "http://app:8080"},
                        {"service": "http_status:404"},
                    ],
                    "warp-routing": {"enabled": False},
                }
            }
            self.dns_records["fangdai.scuccs.me"] = {
                "id": "dns-fangdai",
                "type": "CNAME",
                "name": "fangdai.scuccs.me",
                "content": f"{FANGDAI_TUNNEL_ID}.cfargotunnel.com",
                "proxied": True,
            }


class Handler(BaseHTTPRequestHandler):
    server_version = "CloudflareMock/2.0"

    def log_message(self, _format: str, *_args: object) -> None:
        return

    @property
    def state(self) -> State:
        return self.server.state  # type: ignore[attr-defined]

    def send_result(self, result: object, status: int = 200) -> None:
        payload = json.dumps({"success": status < 400, "result": result, "errors": []}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def send_error_result(self, status: int) -> None:
        payload = json.dumps(
            {
                "success": False,
                "result": None,
                "errors": [{"code": status, "message": "fake-public-token-for-local-tests-only-1234567890"}],
            }
        ).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def authorized(self) -> bool:
        return self.headers.get("Authorization") == f"Bearer {FAKE_API_TOKEN}"

    def parsed(self) -> tuple[str, dict[str, list[str]]]:
        parsed = urlparse(self.path)
        return parsed.path, parse_qs(parsed.query)

    def body(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(length) or b"{}")

    def do_GET(self) -> None:  # noqa: N802
        path, query = self.parsed()
        if path == "/health":
            self.send_result({"status": "healthy"})
            return
        if path.startswith("/client/v4/test/status/"):
            self.send_error_result(int(path.rsplit("/", 1)[1]))
            return
        if path == "/client/v4/test/retry":
            with self.state.lock:
                self.state.retry_count += 1
                attempt = self.state.retry_count
            if attempt < 3:
                self.send_error_result(429)
            else:
                self.send_result({"attempt": attempt})
            return
        if path == "/client/v4/test/timeout":
            time.sleep(2)
            self.send_result({"status": "late"})
            return
        if path == "/client/v4/test/drop":
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        if not self.authorized():
            self.send_error_result(401)
            return
        if path == "/client/v4/user/tokens/verify":
            self.send_result({"id": "token-id", "status": "active"})
            return
        if path == f"/client/v4/accounts/{ACCOUNT_ID}":
            self.send_result({"id": ACCOUNT_ID, "name": "测试账户"})
            return
        if path == "/client/v4/zones":
            if query.get("name") == ["scuccs.me"] and query.get("account.id") == [ACCOUNT_ID]:
                self.send_result([{"id": ZONE_ID, "name": "scuccs.me", "status": "active"}])
            else:
                self.send_result([])
            return
        if path == f"/client/v4/accounts/{ACCOUNT_ID}/cfd_tunnel":
            name = query.get("name", [""])[0]
            self.send_result([value for value in self.state.tunnels.values() if value["name"] == name])
            return
        tunnel_prefix = f"/client/v4/accounts/{ACCOUNT_ID}/cfd_tunnel/"
        if path.startswith(tunnel_prefix) and path.endswith("/configurations"):
            tunnel_id = path[len(tunnel_prefix) : -len("/configurations")]
            self.send_result(self.state.configurations.get(tunnel_id, {"config": {"ingress": []}}))
            return
        if path.startswith(tunnel_prefix) and path.endswith("/token"):
            with self.state.lock:
                if self.state.fail_token_requests > 0:
                    self.state.fail_token_requests -= 1
                    self.send_error_result(500)
                    return
            self.send_result(FAKE_TUNNEL_TOKEN)
            return
        if path == f"/client/v4/zones/{ZONE_ID}/dns_records":
            name = query.get("name", [""])[0]
            record = self.state.dns_records.get(name)
            self.send_result([record] if record else [])
            return
        if path == f"/client/v4/accounts/{ACCOUNT_ID}/access/apps":
            self.send_result(list(self.state.access_applications.values()))
            return
        access_prefix = f"/client/v4/accounts/{ACCOUNT_ID}/access/apps/"
        if path.startswith(access_prefix) and path.endswith("/policies"):
            application_id = path[len(access_prefix) : -len("/policies")]
            self.send_result(self.state.access_policies.get(application_id, []))
            return
        self.send_error_result(404)

    def do_POST(self) -> None:  # noqa: N802
        path, _query = self.parsed()
        if not self.authorized():
            self.send_error_result(401)
            return
        body = self.body()
        if path == f"/client/v4/accounts/{ACCOUNT_ID}/cfd_tunnel":
            tunnel_id = "11111111-2222-4333-8444-555555555555"
            tunnel = {"id": tunnel_id, "name": body["name"], "status": "inactive", "connections": []}
            self.state.tunnels[tunnel_id] = tunnel
            self.send_result(tunnel)
            return
        if path == f"/client/v4/zones/{ZONE_ID}/dns_records":
            record = dict(body)
            record["id"] = f"dns-{self.state.next_dns_id}"
            self.state.next_dns_id += 1
            self.state.dns_records[record["name"]] = record
            self.send_result(record)
            return
        if path == f"/client/v4/accounts/{ACCOUNT_ID}/access/apps":
            application = dict(body)
            application["id"] = "access-app-1"
            self.state.access_applications[application["id"]] = application
            self.send_result(application)
            return
        access_prefix = f"/client/v4/accounts/{ACCOUNT_ID}/access/apps/"
        if path.startswith(access_prefix) and path.endswith("/policies"):
            application_id = path[len(access_prefix) : -len("/policies")]
            policy = dict(body)
            policy["id"] = "access-policy-1"
            self.state.access_policies.setdefault(application_id, []).append(policy)
            self.send_result(policy)
            return
        self.send_error_result(404)

    def do_PUT(self) -> None:  # noqa: N802
        path, _query = self.parsed()
        if not self.authorized():
            self.send_error_result(401)
            return
        body = self.body()
        tunnel_prefix = f"/client/v4/accounts/{ACCOUNT_ID}/cfd_tunnel/"
        if path.startswith(tunnel_prefix) and path.endswith("/configurations"):
            tunnel_id = path[len(tunnel_prefix) : -len("/configurations")]
            self.state.configurations[tunnel_id] = body
            self.send_result(body)
            return
        dns_prefix = f"/client/v4/zones/{ZONE_ID}/dns_records/"
        if path.startswith(dns_prefix):
            record = dict(body)
            record["id"] = path[len(dns_prefix) :]
            self.state.dns_records[record["name"]] = record
            self.send_result(record)
            return
        self.send_error_result(404)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed-fangdai", action="store_true")
    parser.add_argument("--fail-token-requests", type=int, default=0)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.state = State(args.seed_fangdai, args.fail_token_requests)  # type: ignore[attr-defined]
    print(server.server_port, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
