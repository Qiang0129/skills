import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
import shutil
from pathlib import Path
from unittest import mock


SCRIPT_DIRECTORY = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPT_DIRECTORY))

import scan_repository as scanner


class GithubUrlTests(unittest.TestCase):
    def test_normalizes_canonical_url(self):
        result = scanner.normalize_github_url("https://github.com/OpenAI/My_App.git")

        self.assertEqual(result["canonicalUrl"], "https://github.com/OpenAI/My_App")
        self.assertEqual(result["slug"], "my-app")

    def test_accepts_ssh_only_for_existing_remote(self):
        result = scanner.normalize_github_url("git@github.com:owner/private-repo.git", allow_ssh=True)

        self.assertEqual(result["canonicalUrl"], "https://github.com/owner/private-repo")

    def test_rejects_untrusted_or_ambiguous_urls(self):
        invalid_urls = [
            "http://github.com/owner/repo",
            "https://example.com/owner/repo",
            "https://token@github.com/owner/repo",
            "https://github.com/owner/repo/tree/main",
            "https://github.com/owner/../repo",
            "https://github.com/owner/repo?token=secret",
        ]

        for value in invalid_urls:
            with self.subTest(value=value), self.assertRaises(scanner.ScanError):
                scanner.normalize_github_url(value)


class ParserHelperTests(unittest.TestCase):
    def test_parses_environment_port_volume_and_requirement_variants(self):
        self.assertEqual(scanner.compose_environment_keys(["A=1", "B", "bad-key=2"]), {"A", "B"})
        self.assertEqual(scanner.compose_environment_keys(None), set())

        port = scanner.normalize_port("127.0.0.1:8080:80/udp")
        self.assertEqual(port, {"target": 80, "published": 8080, "hostIp": "127.0.0.1", "protocol": "udp"})
        self.assertEqual(scanner.normalize_port(9000)["target"], 9000)
        self.assertIsNone(scanner.normalize_port(object()))

        bind = scanner.normalize_volume("./data:/data:ro")
        named = scanner.normalize_volume("db-data:/var/lib/db")
        target_only = scanner.normalize_volume("/cache")
        self.assertEqual(bind["type"], "bind")
        self.assertTrue(bind["readOnly"])
        self.assertEqual(named["type"], "volume")
        self.assertIsNone(target_only["source"])
        self.assertIsNone(scanner.normalize_volume(123))

        self.assertEqual(scanner.package_name_from_requirement("requests>=2"), "requests")
        self.assertIsNone(scanner.package_name_from_requirement("git+https://github.com/example/demo"))
        self.assertIsNone(scanner.package_name_from_requirement("# comment"))

    def test_parses_pyproject_and_ignores_oversized_text(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pyproject = root / "pyproject.toml"
            pyproject.write_text(
                "[build-system]\n"
                "build-backend = 'setuptools.build_meta'\n"
                "[project]\n"
                "name = 'demo'\n"
                "dependencies = ['fastapi>=1', 'uvicorn']\n",
                encoding="utf-8",
            )
            parsed = scanner.parse_python_manifest(pyproject, root)
            self.assertEqual(parsed["packageName"], "demo")
            self.assertEqual(parsed["dependencies"], ["fastapi", "uvicorn"])

            oversized = root / "large.txt"
            oversized.write_bytes(b"x" * (scanner.MAX_TEXT_BYTES + 1))
            self.assertEqual(scanner.read_text_limited(oversized), "")

    def test_safe_git_handles_failure_and_timeout(self):
        with mock.patch("scan_repository.subprocess.run") as run_mock:
            run_mock.return_value = subprocess.CompletedProcess([], 1, stdout="", stderr="secret")
            self.assertIsNone(scanner.safe_git(Path("."), "rev-parse", "HEAD"))
            run_mock.side_effect = subprocess.TimeoutExpired("git", 10)
            self.assertIsNone(scanner.safe_git(Path("."), "rev-parse", "HEAD"))

    def test_load_compose_handles_tool_and_output_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            compose_path = Path(directory) / "compose.yml"
            compose_path.write_text("services: {}\n", encoding="utf-8")

            with mock.patch("scan_repository.subprocess.run", side_effect=FileNotFoundError):
                model, error = scanner.load_compose(compose_path)
                self.assertIsNone(model)
                self.assertIn("未找到", error)

            with mock.patch("scan_repository.subprocess.run", side_effect=subprocess.TimeoutExpired("docker", 30)):
                model, error = scanner.load_compose(compose_path)
                self.assertIsNone(model)
                self.assertIn("超时", error)

            with mock.patch(
                "scan_repository.subprocess.run",
                return_value=subprocess.CompletedProcess([], 0, stdout="not-json", stderr=""),
            ):
                model, error = scanner.load_compose(compose_path)
                self.assertIsNone(model)
                self.assertIn("无效 JSON", error)


class RepositoryInventoryTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("docker"), "需要 Docker Compose")
    def test_uses_real_compose_structured_parser(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            compose_path = root / "compose.yml"
            compose_path.write_text(
                "services:\n"
                "  web:\n"
                "    image: nginx:alpine\n"
                "    environment:\n"
                "      API_TOKEN: ${API_TOKEN}\n"
                "    expose:\n"
                "      - '80'\n"
                "    healthcheck:\n"
                "      test: [CMD, nginx, -t]\n"
                "    restart: unless-stopped\n"
                "    user: '101:101'\n"
                "    security_opt:\n"
                "      - no-new-privileges:true\n",
                encoding="utf-8",
            )
            (root / ".env").write_text("API_TOKEN=must-not-appear\n", encoding="utf-8")

            report = scanner.inspect_repository(root, "https://github.com/example/web", "main", "abc123")
            serialized = json.dumps(report, ensure_ascii=False)

        self.assertFalse(report["blockers"])
        self.assertIn("API_TOKEN", report["environmentKeys"])
        self.assertNotIn("must-not-appear", serialized)
        self.assertTrue(report["inventory"]["composeFiles"][0]["parsed"])

    def test_detects_monorepo_lfs_submodules_and_secret_keys_without_values(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "apps" / "web").mkdir(parents=True)
            (root / "apps" / "api").mkdir(parents=True)
            (root / "package.json").write_text(
                json.dumps(
                    {
                        "name": "demo",
                        "scripts": {"build": "vite build", "postinstall": "node setup.js"},
                        "dependencies": {"vite": "1.0.0"},
                    }
                ),
                encoding="utf-8",
            )
            (root / "apps" / "web" / "package.json").write_text('{"name":"web"}', encoding="utf-8")
            (root / "apps" / "api" / "requirements.txt").write_text("fastapi==1.0\n", encoding="utf-8")
            (root / ".env.example").write_text("API_TOKEN=do-not-output\nPUBLIC_URL=\n", encoding="utf-8")
            (root / ".env").write_text("REAL_PASSWORD=must-stay-hidden\n", encoding="utf-8")
            (root / ".gitattributes").write_text("*.bin filter=lfs diff=lfs merge=lfs -text\n", encoding="utf-8")
            (root / ".gitmodules").write_text('[submodule "demo"]\npath=vendor/demo\nurl=https://github.com/example/demo\n', encoding="utf-8")
            (root / "LICENSE").write_text("MIT\n", encoding="utf-8")
            (root / "Dockerfile").write_text("FROM alpine\nRUN curl https://example.com/install.sh | sh\nEXPOSE 8080\n", encoding="utf-8")

            report = scanner.inspect_repository(
                root,
                "https://github.com/example/demo",
                "main",
                "0123456789abcdef",
            )
            serialized = json.dumps(report, ensure_ascii=False)

            self.assertTrue(report["inventory"]["monorepoCandidate"])
            self.assertTrue(report["inventory"]["hasGitLfs"])
            self.assertTrue(report["inventory"]["hasSubmodules"])
            self.assertIn("API_TOKEN", report["environmentKeys"])
            self.assertIn("API_TOKEN", report["secretLikeKeys"])
            self.assertNotIn("REAL_PASSWORD", serialized)
            self.assertNotIn("do-not-output", serialized)
            finding_ids = {item["id"] for item in report["securityFindings"]}
            self.assertIn("package_lifecycle_scripts", finding_ids)
            self.assertIn("remote_script_execution", finding_ids)

    @mock.patch("scan_repository.subprocess.run")
    def test_structurally_detects_dangerous_compose_without_leaking_values(self, run_mock):
        model = {
            "services": {
                "db": {
                    "image": "postgres:16",
                    "privileged": True,
                    "network_mode": "host",
                    "environment": {"POSTGRES_PASSWORD": "super-secret-value"},
                    "ports": [{"target": 5432, "published": "5432", "host_ip": "0.0.0.0", "protocol": "tcp"}],
                    "volumes": [{"type": "bind", "source": "/var/run/docker.sock", "target": "/var/run/docker.sock"}],
                }
            },
            "volumes": {},
        }
        run_mock.return_value = subprocess.CompletedProcess([], 0, stdout=json.dumps(model), stderr="")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "compose.yml").write_text("services: {}\n", encoding="utf-8")
            report = scanner.inspect_repository(root, "https://github.com/example/demo", "main", "abc123")

        serialized = json.dumps(report, ensure_ascii=False)
        finding_ids = {item["id"] for item in report["securityFindings"]}
        self.assertTrue({"public_host_port", "docker_socket_mount", "privileged_container", "host_network"}.issubset(finding_ids))
        self.assertIn("PostgreSQL", {item.get("name") for item in report["externalDependencies"]})
        self.assertIn("POSTGRES_PASSWORD", report["environmentKeys"])
        self.assertNotIn("super-secret-value", serialized)
        self.assertTrue(report["feasibility"]["requiresExplicitApproval"])

    @mock.patch("scan_repository.subprocess.run")
    def test_blocks_published_udp(self, run_mock):
        model = {
            "services": {
                "game": {
                    "image": "example/game:1",
                    "ports": [{"target": 7777, "published": "7777", "host_ip": "127.0.0.1", "protocol": "udp"}],
                    "healthcheck": {"test": ["CMD", "true"]},
                    "restart": "unless-stopped",
                    "user": "1000:1000",
                    "security_opt": ["no-new-privileges:true"],
                }
            }
        }
        run_mock.return_value = subprocess.CompletedProcess([], 0, stdout=json.dumps(model), stderr="")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "compose.yaml").write_text("services: {}\n", encoding="utf-8")
            report = scanner.inspect_repository(root, "https://github.com/example/game", "main", "abc123")

        self.assertEqual(report["feasibility"]["status"], "blocked")
        self.assertIn("unsupported_public_protocol", {item["code"] for item in report["blockers"]})

    @mock.patch("scan_repository.subprocess.run")
    def test_compose_failure_redacts_stderr(self, run_mock):
        run_mock.return_value = subprocess.CompletedProcess([], 1, stdout="", stderr="PASSWORD=leaked-value")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "docker-compose.yml").write_text("services: broken\n", encoding="utf-8")
            report = scanner.inspect_repository(root, "https://github.com/example/demo", "main", "abc123")

        serialized = json.dumps(report, ensure_ascii=False)
        self.assertNotIn("leaked-value", serialized)
        self.assertIn("compose_parse_failed", {item["code"] for item in report["blockers"]})

    def test_reports_missing_deployment_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "index.html").write_text("<h1>demo</h1>", encoding="utf-8")
            report = scanner.inspect_repository(root, "https://github.com/example/demo", "main", "abc123")

        self.assertIn("deployment_manifest_missing", {item["code"] for item in report["blockers"]})


class CommandLineTests(unittest.TestCase):
    def test_validate_url_only_outputs_json(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            exit_code = scanner.main(["--validate-url-only", "--url", "https://github.com/example/demo"])

        self.assertEqual(exit_code, 0)
        self.assertEqual(json.loads(output.getvalue())["repository"]["slug"], "demo")

    def test_invalid_input_outputs_redacted_error(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            exit_code = scanner.main(["--validate-url-only", "--url", "https://example.com/demo/repo"])

        result = json.loads(output.getvalue())
        self.assertEqual(exit_code, 2)
        self.assertEqual(result["error"]["code"], "invalid_input")


if __name__ == "__main__":
    unittest.main()
