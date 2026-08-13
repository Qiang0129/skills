#!/usr/bin/env python3
"""以只读方式扫描 GitHub 仓库的部署能力与高风险配置。"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import urlsplit

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python 3.11 之前的兼容提示
    tomllib = None


SCHEMA_VERSION = "1.0"
MAX_TEXT_BYTES = 1024 * 1024
IGNORED_DIRECTORIES = {
    ".git",
    ".hg",
    ".svn",
    ".idea",
    ".vscode",
    "node_modules",
    "vendor",
    "dist",
    "build",
    "target",
    ".next",
    ".nuxt",
    ".venv",
    "venv",
    "__pycache__",
}
COMPOSE_NAMES = {
    "compose.yml",
    "compose.yaml",
    "docker-compose.yml",
    "docker-compose.yaml",
}
MANIFEST_NAMES = {
    "package.json": "node",
    "pyproject.toml": "python",
    "requirements.txt": "python",
    "pipfile": "python",
    "poetry.lock": "python",
    "go.mod": "go",
    "cargo.toml": "rust",
    "pom.xml": "java",
    "build.gradle": "java",
    "build.gradle.kts": "java",
    "gemfile": "ruby",
    "composer.json": "php",
}
DATABASE_PORTS = {3306, 5432, 6379, 27017, 27018, 9200, 9300, 11211}
DATABASE_IMAGES = {
    "postgres": "PostgreSQL",
    "mysql": "MySQL",
    "mariadb": "MariaDB",
    "redis": "Redis",
    "mongo": "MongoDB",
    "elasticsearch": "Elasticsearch",
    "opensearchproject/opensearch": "OpenSearch",
    "memcached": "Memcached",
}
SENSITIVE_BIND_PREFIXES = ("/etc", "/root", "/proc", "/sys", "/var/run")
ENV_KEY_PATTERN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
GITHUB_COMPONENT_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+$")


class ScanError(Exception):
    """表示可以安全返回给用户的扫描错误。"""


def normalize_slug(value: str, max_length: int = 63) -> str:
    slug = re.sub(r"[^a-z0-9-]+", "-", value.lower())
    slug = re.sub(r"-+", "-", slug).strip("-")[:max_length].rstrip("-")
    if not slug:
        raise ScanError("仓库名无法转换为有效的 DNS 标签。")
    return slug


def normalize_github_url(value: str, allow_ssh: bool = False) -> dict[str, str]:
    raw = value.strip()
    owner = ""
    repository = ""

    if allow_ssh and raw.startswith("git@github.com:"):
        path = raw.removeprefix("git@github.com:")
        parts = path.removesuffix(".git").split("/")
        if len(parts) == 2:
            owner, repository = parts
    else:
        parsed = urlsplit(raw)
        if parsed.scheme.lower() != "https":
            raise ScanError("GitHub 仓库链接必须使用 HTTPS。")
        if parsed.username or parsed.password or parsed.port:
            raise ScanError("GitHub 仓库链接不能包含凭据或自定义端口。")
        if (parsed.hostname or "").lower() != "github.com":
            raise ScanError("只允许 github.com 仓库链接。")
        if parsed.query or parsed.fragment:
            raise ScanError("GitHub 仓库链接不能包含查询参数或片段。")
        parts = [part for part in parsed.path.split("/") if part]
        if len(parts) != 2:
            raise ScanError("请提供仓库首页链接，格式为 https://github.com/所有者/仓库。")
        owner, repository = parts
        repository = repository.removesuffix(".git")

    if (
        not owner
        or not repository
        or owner in {".", ".."}
        or repository in {".", ".."}
        or not GITHUB_COMPONENT_PATTERN.fullmatch(owner)
        or not GITHUB_COMPONENT_PATTERN.fullmatch(repository)
    ):
        raise ScanError("GitHub 仓库所有者或仓库名不合法。")

    return {
        "owner": owner,
        "name": repository,
        "slug": normalize_slug(repository),
        "canonicalUrl": f"https://github.com/{owner}/{repository}",
    }


def read_text_limited(path: Path) -> str:
    try:
        if path.stat().st_size > MAX_TEXT_BYTES:
            return ""
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def walk_repository(root: Path) -> list[Path]:
    files: list[Path] = []
    for current_root, directories, filenames in os.walk(root, followlinks=False):
        directories[:] = sorted(
            directory
            for directory in directories
            if directory.lower() not in IGNORED_DIRECTORIES
            and not (Path(current_root) / directory).is_symlink()
        )
        for filename in sorted(filenames):
            path = Path(current_root) / filename
            if not path.is_symlink():
                files.append(path)
    return files


def relative_path(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()


def parse_env_keys(text: str) -> set[str]:
    keys: set[str] = set()
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        stripped = re.sub(r"^export\s+", "", stripped)
        key = stripped.split("=", 1)[0].strip()
        if ENV_KEY_PATTERN.fullmatch(key):
            keys.add(key)
    return keys


def package_name_from_requirement(value: str) -> str | None:
    stripped = value.strip()
    if not stripped or stripped.startswith(("#", "-", "http://", "https://", "git+")):
        return None
    match = re.match(r"([A-Za-z0-9_.-]+)", stripped)
    return match.group(1) if match else None


def safe_git(root: Path, *arguments: str) -> str | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(root), *arguments],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip() or None


def compose_environment_keys(value: Any) -> set[str]:
    if isinstance(value, dict):
        return {str(key) for key in value if ENV_KEY_PATTERN.fullmatch(str(key))}
    if isinstance(value, list):
        result: set[str] = set()
        for item in value:
            key = str(item).split("=", 1)[0]
            if ENV_KEY_PATTERN.fullmatch(key):
                result.add(key)
        return result
    return set()


def normalize_port(value: Any) -> dict[str, Any] | None:
    if isinstance(value, dict):
        target = value.get("target")
        published = value.get("published")
        return {
            "target": int(target) if str(target).isdigit() else target,
            "published": int(published) if str(published).isdigit() else published,
            "hostIp": value.get("host_ip"),
            "protocol": str(value.get("protocol") or "tcp").lower(),
        }
    if isinstance(value, (str, int)):
        text = str(value)
        protocol = "udp" if text.lower().endswith("/udp") else "tcp"
        text = re.sub(r"/(tcp|udp)$", "", text, flags=re.IGNORECASE)
        parts = text.split(":")
        target_text = parts[-1]
        published_text = parts[-2] if len(parts) >= 2 else None
        host_ip = ":".join(parts[:-2]) if len(parts) >= 3 else None
        return {
            "target": int(target_text) if target_text.isdigit() else target_text,
            "published": int(published_text) if published_text and published_text.isdigit() else published_text,
            "hostIp": host_ip,
            "protocol": protocol,
        }
    return None


def normalize_volume(value: Any) -> dict[str, Any] | None:
    if isinstance(value, dict):
        return {
            "type": value.get("type"),
            "source": value.get("source"),
            "target": value.get("target"),
            "readOnly": bool(value.get("read_only")),
        }
    if isinstance(value, str):
        parts = value.split(":")
        if len(parts) < 2:
            return {"type": "volume", "source": None, "target": value, "readOnly": False}
        source, target = parts[0], parts[1]
        return {
            "type": "bind" if source.startswith(("/", ".", "~")) or re.match(r"^[A-Za-z]:", source) else "volume",
            "source": source,
            "target": target,
            "readOnly": len(parts) > 2 and "ro" in parts[2].split(","),
        }
    return None


def add_finding(
    findings: list[dict[str, Any]],
    finding_id: str,
    severity: str,
    message: str,
    *,
    service: str | None = None,
    file: str | None = None,
    evidence: str | None = None,
) -> None:
    item = {
        "id": finding_id,
        "severity": severity,
        "message": message,
        "requiresExplicitApproval": severity in {"high", "critical"},
    }
    if service:
        item["service"] = service
    if file:
        item["file"] = file
    if evidence:
        item["evidence"] = evidence
    identity = (finding_id, service, file, evidence)
    if not any((entry.get("id"), entry.get("service"), entry.get("file"), entry.get("evidence")) == identity for entry in findings):
        findings.append(item)


def inspect_dockerfile(
    path: Path,
    root: Path,
    ports: list[dict[str, Any]],
    findings: list[dict[str, Any]],
    recommendations: set[str],
) -> dict[str, Any]:
    text = read_text_limited(path)
    rel = relative_path(path, root)
    users = re.findall(r"(?im)^\s*USER\s+([^\s#]+)", text)
    has_healthcheck = bool(re.search(r"(?im)^\s*HEALTHCHECK\s+", text))
    exposed_ports: list[dict[str, Any]] = []

    for match in re.finditer(r"(?im)^\s*EXPOSE\s+(.+)$", text):
        for token in match.group(1).split():
            port = normalize_port(token)
            if port:
                port.update({"service": None, "source": rel, "published": None})
                exposed_ports.append(port)
                ports.append(port)

    if not users or users[-1].lower() in {"root", "0"}:
        add_finding(findings, "container_runs_as_root", "medium", "Dockerfile 未声明最终非 root 用户。", file=rel)
    if not has_healthcheck:
        recommendations.add(f"为 {rel} 增加可验证的健康检查。")

    for line_number, line in enumerate(text.splitlines(), start=1):
        if re.search(r"(?i)^\s*(RUN|ADD).*\b(curl|wget|https?://).*(\|\s*(sh|bash)|ADD\s+https?://)", line):
            add_finding(
                findings,
                "remote_script_execution",
                "high",
                "构建过程包含远程脚本或远程 ADD，需要人工审查来源与校验机制。",
                file=rel,
                evidence=f"第 {line_number} 行",
            )

    return {
        "path": rel,
        "finalUser": users[-1] if users else None,
        "healthcheck": has_healthcheck,
        "exposedPorts": exposed_ports,
    }


def compose_command(path: Path) -> list[str]:
    return [
        "docker",
        "compose",
        "--env-file",
        os.devnull,
        "-f",
        path.name,
        "config",
        "--format",
        "json",
        "--no-interpolate",
        "--no-env-resolution",
        "--no-path-resolution",
    ]


def load_compose(path: Path) -> tuple[dict[str, Any] | None, str | None]:
    try:
        result = subprocess.run(
            compose_command(path),
            cwd=path.parent,
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
            env={key: value for key, value in os.environ.items() if key in {"PATH", "HOME", "USER", "DOCKER_HOST", "SYSTEMROOT"}},
        )
    except FileNotFoundError:
        return None, "未找到 Docker Compose，无法进行结构化解析。"
    except subprocess.TimeoutExpired:
        return None, "Docker Compose 结构化解析超时。"

    if result.returncode != 0:
        return None, f"Docker Compose 结构化解析失败（退出码 {result.returncode}）。"
    try:
        return json.loads(result.stdout), None
    except json.JSONDecodeError:
        return None, "Docker Compose 返回了无效 JSON。"


def inspect_compose(
    path: Path,
    root: Path,
    findings: list[dict[str, Any]],
    blockers: list[dict[str, str]],
    recommendations: set[str],
) -> tuple[dict[str, Any], set[str], list[dict[str, Any]], list[dict[str, str]]]:
    rel = relative_path(path, root)
    model, error = load_compose(path)
    if error or not isinstance(model, dict):
        blockers.append({"code": "compose_parse_failed", "message": f"{rel}：{error or '无法解析 Compose。'}"})
        return {"path": rel, "parsed": False, "services": []}, set(), [], []

    environment_keys: set[str] = set()
    ports: list[dict[str, Any]] = []
    persistence: list[dict[str, str]] = []
    dependencies: list[dict[str, str]] = []
    service_reports: list[dict[str, Any]] = []

    for service_name, service in sorted((model.get("services") or {}).items()):
        if not isinstance(service, dict):
            continue
        service_env_keys = compose_environment_keys(service.get("environment"))
        environment_keys.update(service_env_keys)
        service_ports: list[dict[str, Any]] = []
        service_volumes: list[dict[str, Any]] = []

        for port_value in service.get("ports") or []:
            port = normalize_port(port_value)
            if not port:
                continue
            port.update({"service": service_name, "source": rel})
            ports.append(port)
            service_ports.append(port)

            published = port.get("published")
            target = port.get("target")
            host_ip = str(port.get("hostIp") or "")
            if published and host_ip not in {"127.0.0.1", "::1", "localhost"}:
                severity = "critical" if target in DATABASE_PORTS else "high"
                message = "数据库或缓存端口直接发布到宿主机。" if target in DATABASE_PORTS else "服务端口未限制为 127.0.0.1。"
                add_finding(findings, "public_host_port", severity, message, service=service_name, file=rel, evidence=f"端口 {published}:{target}")
            if published and port.get("protocol") == "udp":
                blockers.append({"code": "unsupported_public_protocol", "message": f"{service_name} 发布 UDP 端口 {published}，首版 Cloudflare 流程不支持。"})

        for expose_value in service.get("expose") or []:
            port = normalize_port(expose_value)
            if port:
                port.update({"service": service_name, "source": rel, "published": None})
                ports.append(port)
                service_ports.append(port)

        for volume_value in service.get("volumes") or []:
            volume = normalize_volume(volume_value)
            if not volume:
                continue
            service_volumes.append(volume)
            source = str(volume.get("source") or "")
            target = str(volume.get("target") or "")
            if volume.get("type") == "volume":
                persistence.append({"service": service_name, "type": "named-volume", "source": source, "target": target})
            elif source:
                persistence.append({"service": service_name, "type": "bind", "source": source, "target": target})
            normalized_source = source.replace("\\", "/").lower()
            if "docker.sock" in normalized_source or "docker.sock" in target.lower():
                add_finding(findings, "docker_socket_mount", "critical", "服务挂载 Docker Socket，等同于高主机权限。", service=service_name, file=rel)
            elif normalized_source == "/":
                add_finding(findings, "root_filesystem_mount", "critical", "服务挂载宿主根文件系统。", service=service_name, file=rel)
            elif any(normalized_source == prefix or normalized_source.startswith(prefix + "/") for prefix in SENSITIVE_BIND_PREFIXES):
                add_finding(findings, "sensitive_host_mount", "high", "服务挂载宿主敏感目录。", service=service_name, file=rel, evidence=source)

        if service.get("privileged"):
            add_finding(findings, "privileged_container", "critical", "服务启用了 privileged。", service=service_name, file=rel)
        if str(service.get("network_mode") or "").lower() == "host":
            add_finding(findings, "host_network", "critical", "服务使用 host 网络。", service=service_name, file=rel)
        if str(service.get("pid") or "").lower() == "host" or str(service.get("ipc") or "").lower() == "host":
            add_finding(findings, "host_namespace", "high", "服务共享宿主 PID 或 IPC 命名空间。", service=service_name, file=rel)
        if service.get("devices"):
            add_finding(findings, "host_devices", "high", "服务直接访问宿主设备。", service=service_name, file=rel)
        if service.get("cap_add"):
            add_finding(findings, "added_capabilities", "high", "服务增加了 Linux capabilities。", service=service_name, file=rel)

        user = str(service.get("user") or "")
        if not user or user.lower() in {"root", "0", "0:0"}:
            add_finding(findings, "container_runs_as_root", "medium", "服务未声明非 root 用户。", service=service_name, file=rel)
        if not service.get("healthcheck"):
            recommendations.add(f"为 Compose 服务 {service_name} 增加健康检查。")
        if not service.get("restart"):
            recommendations.add(f"为 Compose 服务 {service_name} 设置 restart: unless-stopped。")
        security_options = {str(item).lower() for item in service.get("security_opt") or []}
        if "no-new-privileges:true" not in security_options:
            recommendations.add(f"为 Compose 服务 {service_name} 增加 no-new-privileges:true。")

        image = str(service.get("image") or "")
        image_base = image.split(":", 1)[0].split("@", 1)[0].lower()
        for prefix, display_name in DATABASE_IMAGES.items():
            if image_base == prefix or image_base.endswith("/" + prefix):
                dependencies.append({"type": "stateful-service", "name": display_name, "service": service_name})
                break

        service_reports.append(
            {
                "name": service_name,
                "image": image or None,
                "hasBuild": bool(service.get("build")),
                "environmentKeys": sorted(service_env_keys),
                "secretNames": sorted(str(item.get("source") or item) if isinstance(item, dict) else str(item) for item in service.get("secrets") or []),
                "ports": service_ports,
                "volumes": service_volumes,
                "healthcheck": bool(service.get("healthcheck")),
                "restart": service.get("restart"),
                "user": user or None,
            }
        )

    return (
        {"path": rel, "parsed": True, "services": service_reports},
        environment_keys,
        ports,
        dependencies + persistence,
    )


def parse_package_json(path: Path, root: Path, findings: list[dict[str, Any]]) -> dict[str, Any]:
    rel = relative_path(path, root)
    try:
        data = json.loads(read_text_limited(path))
    except json.JSONDecodeError:
        return {"path": rel, "type": "node", "parsed": False}

    dependencies = sorted(set((data.get("dependencies") or {}).keys()) | set((data.get("devDependencies") or {}).keys()))
    script_names = sorted((data.get("scripts") or {}).keys())
    lifecycle_scripts = sorted(set(script_names) & {"preinstall", "install", "postinstall", "prepare"})
    if lifecycle_scripts:
        add_finding(
            findings,
            "package_lifecycle_scripts",
            "high",
            "Node 包含安装生命周期脚本，构建前需要审查。",
            file=rel,
            evidence=", ".join(lifecycle_scripts),
        )
    return {
        "path": rel,
        "type": "node",
        "parsed": True,
        "packageName": data.get("name"),
        "scriptNames": script_names,
        "engines": data.get("engines") or {},
        "dependencies": dependencies,
    }


def parse_python_manifest(path: Path, root: Path) -> dict[str, Any]:
    rel = relative_path(path, root)
    if path.name.lower() == "requirements.txt":
        dependencies = sorted(
            value
            for value in (package_name_from_requirement(line) for line in read_text_limited(path).splitlines())
            if value
        )
        return {"path": rel, "type": "python", "parsed": True, "dependencies": dependencies}
    if path.name.lower() == "pyproject.toml":
        try:
            text = read_text_limited(path)
            if tomllib:
                data = tomllib.loads(text)
            else:
                # Python 3.10 没有 tomllib 时仅解析部署扫描所需的安全基础字段；
                # 不执行 TOML 内容，也不试图替代完整 TOML 解析器。
                project_match = re.search(r"(?ms)^\s*\[project\]\s*(.*?)(?=^\s*\[|\Z)", text)
                project_text = project_match.group(1) if project_match else ""
                name_match = re.search(r"(?m)^\s*name\s*=\s*['\"]([^'\"]+)['\"]", project_text)
                dependency_match = re.search(r"(?ms)^\s*dependencies\s*=\s*\[(.*?)\]", project_text)
                dependency_text = dependency_match.group(1) if dependency_match else ""
                data = {
                    "project": {
                        "name": name_match.group(1) if name_match else None,
                        "dependencies": re.findall(r"['\"]([^'\"]+)['\"]", dependency_text),
                    },
                    "build-system": {},
                }
            project = data.get("project") or {}
            dependencies = [package_name_from_requirement(item) for item in project.get("dependencies") or []]
            return {
                "path": rel,
                "type": "python",
                "parsed": True,
                "packageName": project.get("name"),
                "dependencies": sorted(value for value in dependencies if value),
                "buildBackend": (data.get("build-system") or {}).get("build-backend"),
            }
        except (OSError, ValueError):
            pass
    return {"path": rel, "type": "python", "parsed": False}


def inspect_repository(
    root: Path,
    repository_url: str | None,
    requested_ref: str | None,
    requested_commit: str | None,
) -> dict[str, Any]:
    if not root.is_dir():
        raise ScanError("仓库目录不存在或不是目录。")

    files = walk_repository(root)
    findings: list[dict[str, Any]] = []
    blockers: list[dict[str, str]] = []
    recommendations: set[str] = set()
    manifests: list[dict[str, Any]] = []
    compose_reports: list[dict[str, Any]] = []
    dockerfiles: list[dict[str, Any]] = []
    environment_keys: set[str] = set()
    ports: list[dict[str, Any]] = []
    dependencies: list[dict[str, str]] = []
    persistence: list[dict[str, str]] = []
    licenses: list[str] = []
    package_roots: set[str] = set()
    has_lfs = False
    has_submodules = False

    remote = repository_url or safe_git(root, "remote", "get-url", "origin")
    repository = normalize_github_url(remote, allow_ssh=repository_url is None) if remote else None
    commit = requested_commit or safe_git(root, "rev-parse", "HEAD")
    branch = requested_ref or safe_git(root, "branch", "--show-current")

    for path in files:
        rel = relative_path(path, root)
        lower_name = path.name.lower()

        if lower_name.startswith(("license", "copying")):
            licenses.append(rel)
        if lower_name == ".gitmodules":
            has_submodules = True
        if lower_name == ".gitattributes" and "filter=lfs" in read_text_limited(path).lower():
            has_lfs = True
        if lower_name in {".env.example", ".env.sample", ".env.template", "example.env"}:
            environment_keys.update(parse_env_keys(read_text_limited(path)))
        if lower_name in COMPOSE_NAMES:
            report, compose_env_keys, compose_ports, compose_items = inspect_compose(path, root, findings, blockers, recommendations)
            compose_reports.append(report)
            environment_keys.update(compose_env_keys)
            ports.extend(compose_ports)
            for item in compose_items:
                if item.get("type") in {"named-volume", "bind"}:
                    persistence.append(item)
                else:
                    dependencies.append(item)
        if lower_name == "dockerfile" or lower_name.startswith("dockerfile."):
            dockerfiles.append(inspect_dockerfile(path, root, ports, findings, recommendations))
        if lower_name in MANIFEST_NAMES:
            package_roots.add(str(Path(rel).parent))
            if lower_name == "package.json":
                manifests.append(parse_package_json(path, root, findings))
            elif lower_name in {"requirements.txt", "pyproject.toml"}:
                manifests.append(parse_python_manifest(path, root))
            else:
                manifests.append({"path": rel, "type": MANIFEST_NAMES[lower_name], "parsed": False})
        if lower_name in {"install.sh", "setup.sh", "bootstrap.sh"}:
            add_finding(findings, "installation_script_present", "medium", "仓库包含安装脚本，执行前需要人工审查。", file=rel)

    if not compose_reports and not dockerfiles and not manifests:
        blockers.append({"code": "deployment_manifest_missing", "message": "未发现 Docker、Compose 或常见语言项目清单。"})
    if has_lfs:
        recommendations.add("部署前确认 Git LFS 对象完整，分析阶段保持跳过 smudge。")
    if has_submodules:
        recommendations.add("逐个审查并固定 Git 子模块提交后再初始化。")
    if len({root_name for root_name in package_roots if root_name != "."}) > 1:
        recommendations.add("检测到多个项目根目录；在计划模式中逐个确认需要发布的应用入口。")
    if not licenses:
        recommendations.add("未检测到许可证文件，公开部署前确认使用与分发权限。")

    oauth_keys = sorted(
        key
        for key in environment_keys
        if any(marker in key.upper() for marker in ("OAUTH", "CLIENT_ID", "CLIENT_SECRET", "CALLBACK", "REDIRECT_URI"))
    )
    secret_like_keys = sorted(
        key
        for key in environment_keys
        if any(marker in key.upper() for marker in ("SECRET", "PASSWORD", "TOKEN", "PRIVATE_KEY", "API_KEY"))
    )
    if oauth_keys:
        recommendations.add("在域名确定后逐项确认 OAuth 回调地址与受信任代理配置。")
    if secret_like_keys:
        recommendations.add("只创建密钥键名模板；让用户通过本机安全输入填充值并仅验证键是否存在。")

    severity_rank = {"low": 1, "medium": 2, "high": 3, "critical": 4}
    findings.sort(key=lambda item: (-severity_rank.get(str(item.get("severity")), 0), str(item.get("file") or ""), str(item.get("service") or ""), str(item.get("id") or "")))
    highest_severity = max((severity_rank.get(item["severity"], 0) for item in findings), default=0)
    status = "blocked" if blockers else "conditional" if highest_severity >= 2 or recommendations else "ready"

    return {
        "schemaVersion": SCHEMA_VERSION,
        "repository": {
            "canonicalUrl": repository["canonicalUrl"] if repository else None,
            "owner": repository["owner"] if repository else None,
            "name": repository["name"] if repository else root.name,
            "slug": repository["slug"] if repository else normalize_slug(root.name),
            "ref": branch,
            "commit": commit,
        },
        "feasibility": {
            "status": status,
            "requiresExplicitApproval": any(item["requiresExplicitApproval"] for item in findings),
        },
        "inventory": {
            "fileCount": len(files),
            "manifests": manifests,
            "composeFiles": compose_reports,
            "dockerfiles": dockerfiles,
            "licenses": sorted(licenses),
            "hasGitLfs": has_lfs,
            "hasSubmodules": has_submodules,
            "monorepoCandidate": len({value for value in package_roots if value != "."}) > 1,
        },
        "ports": sorted(ports, key=lambda item: (str(item.get("service") or ""), str(item.get("target") or ""), str(item.get("published") or ""))),
        "environmentKeys": sorted(environment_keys),
        "secretLikeKeys": secret_like_keys,
        "oauthKeys": oauth_keys,
        "persistence": persistence,
        "externalDependencies": dependencies,
        "securityFindings": findings,
        "blockers": blockers,
        "recommendations": sorted(recommendations),
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="只读扫描 GitHub 仓库的 WSL 容器部署可行性。")
    parser.add_argument("path", nargs="?", help="待扫描的本地仓库或安全解包目录")
    parser.add_argument("--url", help="原始 GitHub 仓库 URL")
    parser.add_argument("--ref", help="分析的分支或标签")
    parser.add_argument("--commit", help="固定的提交 SHA")
    parser.add_argument("--validate-url-only", action="store_true", help="只验证并规范化 GitHub URL")
    parser.add_argument("--pretty", action="store_true", help="格式化 JSON 输出")
    return parser


def emit_json(data: dict[str, Any], pretty: bool) -> None:
    json.dump(data, sys.stdout, ensure_ascii=False, indent=2 if pretty else None, sort_keys=False)
    sys.stdout.write("\n")


def main(argv: Iterable[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.validate_url_only:
            if not args.url:
                raise ScanError("--validate-url-only 必须同时提供 --url。")
            emit_json({"schemaVersion": SCHEMA_VERSION, "repository": normalize_github_url(args.url)}, args.pretty)
            return 0
        if not args.path:
            raise ScanError("必须提供待扫描目录。")
        report = inspect_repository(Path(args.path).resolve(), args.url, args.ref, args.commit)
        emit_json(report, args.pretty)
        return 2 if report["blockers"] else 0
    except ScanError as error:
        emit_json({"schemaVersion": SCHEMA_VERSION, "error": {"code": "invalid_input", "message": str(error)}}, args.pretty)
        return 2
    except Exception:
        # 不回显异常细节，避免把路径、配置值或第三方工具输出带入日志。
        emit_json({"schemaVersion": SCHEMA_VERSION, "error": {"code": "scan_failed", "message": "仓库扫描失败；请在不输出密钥值的前提下检查本地日志。"}}, args.pretty)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
