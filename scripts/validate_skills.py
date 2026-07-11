#!/usr/bin/env python3
"""Validate the repository's Agent Skills without third-party dependencies."""

from __future__ import annotations

import ast
import json
import re
import sys
from pathlib import Path


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
FENCE_RE = re.compile(r"^```([A-Za-z0-9_+-]*)\s*$")
NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")


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


def main() -> int:
    errors: list[str] = []
    skills = sorted(ROOT.glob("litellm-*/SKILL.md"))
    if len(skills) != 7:
        errors.append(f"預期 7 個 skills，實際找到 {len(skills)} 個")

    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    for path in [ROOT / "README.md", *skills]:
        text = path.read_text(encoding="utf-8")
        validate_fences(path, text, errors)
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

    if errors:
        print("技能驗證失敗：", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"技能驗證通過：{len(skills)} 個 skills")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
