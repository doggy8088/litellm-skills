#!/usr/bin/env python3
"""Validate the repository's Agent Skills without third-party dependencies."""

from __future__ import annotations

import ast
import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote


ROOT = Path(__file__).resolve().parents[1]
EXPECTED_SKILLS = {
    "litellm-cost-governance",
    "litellm-guardrails-safety",
    "litellm-mcp-skills-gateway",
    "litellm-observability",
    "litellm-operations-runbook",
    "litellm-proxy-gateway",
    "litellm-routing-reliability",
    "litellm-sdk-basics",
}
REQUIRED_SECTIONS = {"# ", "## 工作流程", "## 安全底線", "## 驗收"}
FORBIDDEN_TEXT = {
    "基礎 of completion": "基礎的 completion",
    "自訂 of Python Hook": "自訂 Python Hook",
    "並 provide 測試": "並提供測試",
    "没有": "沒有",
    "示例": "範例",
    "質量": "品質",
    "文檔": "文件",
    "集群": "叢集",
}
FENCE_RE = re.compile(r"^```([A-Za-z0-9_+-]*)\s*$")
NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
MARKDOWN_LINK_RE = re.compile(r"\[[^\]]+\]\(([^)]+)\)")
TEXT_SUFFIXES = {".json", ".md", ".ps1", ".py", ".sh", ".txt", ".yaml", ".yml"}


def fail(errors: list[str], path: Path, message: str) -> None:
    errors.append(f"{path.relative_to(ROOT)}: {message}")


def parse_frontmatter(path: Path, text: str, errors: list[str]) -> dict[str, str]:
    lines = text.splitlines()
    if not lines or lines[0] != "---":
        fail(errors, path, "缺少 YAML frontmatter 起始分隔線")
        return {}
    try:
        end = lines.index("---", 1)
    except ValueError:
        fail(errors, path, "缺少 YAML frontmatter 結束分隔線")
        return {}

    data: dict[str, str] = {}
    for line in lines[1:end]:
        if not line.strip():
            continue
        if ":" not in line:
            fail(errors, path, f"無法解析 frontmatter 行：{line}")
            continue
        key, value = line.split(":", 1)
        data[key.strip()] = value.strip().strip('"').strip("'")
    return data


def validate_fences(path: Path, text: str, errors: list[str]) -> None:
    open_fence: tuple[str, int, list[str]] | None = None
    for lineno, line in enumerate(text.splitlines(), 1):
        match = FENCE_RE.match(line)
        if not match:
            if open_fence:
                open_fence[2].append(line)
            continue
        if open_fence is None:
            open_fence = (match.group(1).lower(), lineno, [])
            continue
        language, start, body = open_fence
        content = "\n".join(body)
        try:
            if language in {"python", "py"}:
                ast.parse(content)
            elif language == "json":
                json.loads(content)
            elif language in {"yaml", "yml"}:
                for offset, yaml_line in enumerate(body):
                    stripped = yaml_line.strip()
                    if "\t" in yaml_line:
                        raise ValueError(f"第 {start + offset + 1} 行含 tab")
                    if stripped and not stripped.startswith(("#", "-")) and ":" not in stripped:
                        raise ValueError(f"第 {start + offset + 1} 行缺少冒號")
        except (SyntaxError, json.JSONDecodeError, ValueError) as exc:
            fail(errors, path, f"第 {start} 行的 {language} code fence 無法解析：{exc}")
        open_fence = None
    if open_fence:
        fail(errors, path, f"第 {open_fence[1]} 行的 code fence 未關閉")


def validate_internal_links(path: Path, text: str, errors: list[str]) -> None:
    for raw_target in MARKDOWN_LINK_RE.findall(text):
        target = raw_target.strip().split(maxsplit=1)[0].strip("<>")
        if not target or target.startswith(("#", "http://", "https://", "mailto:")):
            continue
        target = unquote(target.split("#", 1)[0])
        resolved = (path.parent / target).resolve()
        try:
            resolved.relative_to(ROOT)
        except ValueError:
            fail(errors, path, f"內部連結超出 repository：{target}")
            continue
        if not resolved.exists():
            fail(errors, path, f"內部連結不存在：{target}")


def validate_agent_metadata(skill_dir: Path, name: str, errors: list[str]) -> None:
    path = skill_dir / "agents" / "openai.yaml"
    if not path.is_file():
        fail(errors, skill_dir / "SKILL.md", "缺少 agents/openai.yaml")
        return
    text = path.read_text(encoding="utf-8")
    required = ("interface:", "display_name:", "short_description:", "default_prompt:")
    for marker in required:
        if marker not in text:
            fail(errors, path, f"缺少欄位：{marker.rstrip(':')}")
    if f"${name}" not in text:
        fail(errors, path, f"default_prompt 必須明確引用 ${name}")


def repository_files() -> list[Path]:
    """Return tracked and non-ignored untracked files when Git is available."""
    try:
        result = subprocess.run(
            [
                "git",
                "ls-files",
                "--cached",
                "--others",
                "--exclude-standard",
                "-z",
            ],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=False,
        )
    except (OSError, subprocess.CalledProcessError):
        return [
            path
            for path in ROOT.rglob("*")
            if path.is_file() and ".git" not in path.parts
        ]

    paths: list[Path] = []
    for raw_path in result.stdout.split(b"\0"):
        if not raw_path:
            continue
        path = ROOT / raw_path.decode("utf-8")
        if path.is_file():
            paths.append(path)
    return paths


def validate_text_hygiene(paths: list[Path], errors: list[str]) -> None:
    for path in paths:
        if path.suffix.lower() not in TEXT_SUFFIXES and path.name != ".gitignore":
            continue
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeDecodeError:
            continue
        for lineno, line in enumerate(lines, 1):
            if line.endswith((" ", "\t")):
                fail(errors, path, f"第 {lineno} 行含行尾空白")


def validate_shell_modes(errors: list[str]) -> None:
    try:
        result = subprocess.run(
            ["git", "ls-files", "--stage", "-z"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=False,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        errors.append(f"無法讀取 Git file modes：{exc}")
        return
    for entry in result.stdout.split(b"\0"):
        if not entry or b"\t" not in entry:
            continue
        metadata, raw_path = entry.split(b"\t", 1)
        mode = metadata.split(maxsplit=1)[0].decode("ascii")
        relative = raw_path.decode("utf-8")
        if relative.endswith(".sh") and mode != "100755":
            fail(errors, ROOT / relative, f"Shell script mode 必須為 100755，目前為 {mode}")


def main() -> int:
    errors: list[str] = []
    repository_paths = repository_files()
    skills = sorted(ROOT.glob("litellm-*/SKILL.md"))
    names = {path.parent.name for path in skills}
    if names != EXPECTED_SKILLS:
        missing = sorted(EXPECTED_SKILLS - names)
        unexpected = sorted(names - EXPECTED_SKILLS)
        errors.append(f"skill allowlist 不一致；缺少={missing}，非預期={unexpected}")

    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    markdown_paths = [path for path in repository_paths if path.suffix.lower() == ".md"]
    for path in dict.fromkeys(markdown_paths):
        text = path.read_text(encoding="utf-8")
        validate_fences(path, text, errors)
        validate_internal_links(path, text, errors)
        for forbidden, replacement in FORBIDDEN_TEXT.items():
            if forbidden in text:
                fail(errors, path, f"包含禁用文字「{forbidden}」，應改為「{replacement}」")

    for path in skills:
        text = path.read_text(encoding="utf-8")
        metadata = parse_frontmatter(path, text, errors)
        name = metadata.get("name", "")
        description = metadata.get("description", "")
        if set(metadata) != {"name", "description"}:
            fail(errors, path, "frontmatter 僅允許 name 與 description")
        if name != path.parent.name:
            fail(errors, path, "name 必須與父目錄名稱一致")
        if not NAME_RE.fullmatch(name) or len(name) > 64:
            fail(errors, path, "name 不符合 Agent Skills 命名規格")
        if not description or len(description) > 1024 or "使用" not in description:
            fail(errors, path, "description 必須描述能力與使用時機")
        for section in REQUIRED_SECTIONS:
            if section not in text:
                fail(errors, path, f"缺少必要章節標記：{section}")
        if f"`{name}`" not in readme:
            fail(errors, ROOT / "README.md", f"索引缺少 {name}")
        validate_agent_metadata(path.parent, name, errors)

    fixtures = ROOT / "tests" / "skill_trigger_cases.json"
    try:
        cases = json.loads(fixtures.read_text(encoding="utf-8"))
        for case in cases:
            unknown = set(case["expected_skills"]) - names
            if unknown:
                fail(errors, fixtures, f"包含未知 skill：{sorted(unknown)}")
            excluded = set(case.get("excluded_skills", []))
            unknown_excluded = excluded - names
            if unknown_excluded:
                fail(errors, fixtures, f"包含未知排除 skill：{sorted(unknown_excluded)}")
            if set(case["expected_skills"]) & excluded:
                fail(errors, fixtures, "同一案例不可同時期待並排除同一 skill")
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as exc:
        fail(errors, fixtures, f"無法解析觸發測試資料：{exc}")

    capstone = ROOT / "curriculum" / "capstone.md"
    if not capstone.is_file() or "## 完成定義" not in capstone.read_text(encoding="utf-8"):
        fail(errors, capstone, "缺少跨技能整合實驗或完成定義")

    validate_text_hygiene(repository_paths, errors)
    validate_shell_modes(errors)

    if errors:
        print("技能驗證失敗：", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"技能驗證通過：{len(skills)} 個 skills")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
