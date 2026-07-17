#!/usr/bin/env python3
"""Validate Agent Skills, documentation, fixtures, and checked-in examples."""

from __future__ import annotations

import ast
import json
import re
import sys
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
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
FENCE_RE = re.compile(r"^(```|~~~)([A-Za-z0-9_+-]*)\s*$")
LINK_RE = re.compile(r"(?<!!)\[[^\]]*\]\(([^)]+)\)")
NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
FRONTMATTER_FIELDS = {
    "name",
    "description",
    "license",
    "compatibility",
    "metadata",
    "allowed-tools",
}


def fail(errors: list[str], path: Path, message: str) -> None:
    errors.append(f"{path.relative_to(ROOT)}: {message}")


def parse_frontmatter(path: Path, text: str, errors: list[str]) -> dict[str, object]:
    lines = text.splitlines()
    if not lines or lines[0] != "---":
        fail(errors, path, "缺少 YAML frontmatter 起始分隔線")
        return {}
    try:
        end = lines.index("---", 1)
    except ValueError:
        fail(errors, path, "缺少 YAML frontmatter 結束分隔線")
        return {}

    try:
        data = yaml.safe_load("\n".join(lines[1:end]))
    except yaml.YAMLError as exc:
        fail(errors, path, f"YAML frontmatter 無法解析：{exc}")
        return {}
    if not isinstance(data, dict):
        fail(errors, path, "YAML frontmatter 必須是 mapping")
        return {}
    return data


def validate_fences(path: Path, text: str, errors: list[str]) -> None:
    open_fence: tuple[str, str, int, list[str]] | None = None
    for lineno, line in enumerate(text.splitlines(), 1):
        match = FENCE_RE.match(line)
        if open_fence is None:
            if match:
                open_fence = (match.group(1), match.group(2).lower(), lineno, [])
            continue

        marker, language, start, body = open_fence
        if not match or match.group(1) != marker or match.group(2):
            body.append(line)
            continue

        content = "\n".join(body)
        try:
            if language in {"python", "py"}:
                ast.parse(content)
            elif language == "json":
                json.loads(content)
            elif language in {"yaml", "yml"}:
                yaml.safe_load(content)
        except (SyntaxError, json.JSONDecodeError, yaml.YAMLError) as exc:
            fail(errors, path, f"第 {start} 行的 {language} code fence 無法解析：{exc}")
        open_fence = None
    if open_fence:
        fail(errors, path, f"第 {open_fence[2]} 行的 code fence 未關閉")


def validate_relative_links(path: Path, text: str, errors: list[str]) -> None:
    for lineno, line in enumerate(text.splitlines(), 1):
        for raw_target in LINK_RE.findall(line):
            target = raw_target.strip().split(maxsplit=1)[0].strip("<>")
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            relative_target = target.split("#", 1)[0]
            if relative_target and not (path.parent / relative_target).exists():
                fail(errors, path, f"第 {lineno} 行的相對連結不存在：{target}")


def validate_data_files(errors: list[str]) -> None:
    for path in sorted([*ROOT.rglob("*.yaml"), *ROOT.rglob("*.yml")]):
        if ".git" in path.parts:
            continue
        try:
            yaml.safe_load(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, yaml.YAMLError) as exc:
            fail(errors, path, f"YAML 無法解析：{exc}")

    for path in sorted(ROOT.rglob("*.json")):
        if ".git" in path.parts:
            continue
        try:
            json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            fail(errors, path, f"JSON 無法解析：{exc}")


def main() -> int:
    errors: list[str] = []
    skills = sorted(ROOT.glob("litellm-*/SKILL.md"))
    if len(skills) != 7:
        errors.append(f"預期 7 個 skills，實際找到 {len(skills)} 個")

    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    markdown_paths = sorted(
        path for path in ROOT.rglob("*.md") if ".git" not in path.parts
    )
    for path in markdown_paths:
        text = path.read_text(encoding="utf-8")
        validate_fences(path, text, errors)
        validate_relative_links(path, text, errors)
        for forbidden, replacement in FORBIDDEN_TEXT.items():
            if forbidden in text:
                fail(errors, path, f"包含禁用文字「{forbidden}」，應改為「{replacement}」")

    for path in skills:
        text = path.read_text(encoding="utf-8")
        metadata = parse_frontmatter(path, text, errors)
        name = metadata.get("name", "")
        description = metadata.get("description", "")
        unknown_fields = set(metadata) - FRONTMATTER_FIELDS
        if unknown_fields:
            fail(errors, path, f"frontmatter 包含未知欄位：{sorted(unknown_fields)}")
        if not isinstance(name, str) or not isinstance(description, str):
            fail(errors, path, "name 與 description 必須是字串")
            continue
        if name != path.parent.name:
            fail(errors, path, "name 必須與父目錄名稱一致")
        if not NAME_RE.fullmatch(name) or len(name) > 64:
            fail(errors, path, "name 不符合 Agent Skills 命名規格")
        if not description or len(description) > 1024 or "使用" not in description:
            fail(errors, path, "description 必須描述能力與使用時機")
        compatibility = metadata.get("compatibility")
        if compatibility is not None and (
            not isinstance(compatibility, str) or not 1 <= len(compatibility) <= 500
        ):
            fail(errors, path, "compatibility 必須是 1–500 字元的字串")
        if "metadata" in metadata and not isinstance(metadata["metadata"], dict):
            fail(errors, path, "metadata 必須是 mapping")
        if "allowed-tools" in metadata and not isinstance(metadata["allowed-tools"], str):
            fail(errors, path, "allowed-tools 必須是字串")
        for section in REQUIRED_SECTIONS:
            if section not in text:
                fail(errors, path, f"缺少必要章節標記：{section}")
        if f"`{name}`" not in readme:
            fail(errors, ROOT / "README.md", f"索引缺少 {name}")

    fixtures = ROOT / "tests" / "skill_trigger_cases.json"
    try:
        cases = json.loads(fixtures.read_text(encoding="utf-8"))
        names = {path.parent.name for path in skills}
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

    validate_data_files(errors)

    if errors:
        print("技能驗證失敗：", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"技能驗證通過：{len(skills)} 個 skills")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
