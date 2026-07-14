from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def load_validator():
    path = ROOT / "scripts" / "validate_skills.py"
    spec = importlib.util.spec_from_file_location("validate_skills", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"無法載入 {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ValidatorUnitTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.validator = load_validator()

    def test_parse_frontmatter_reads_name_and_description(self) -> None:
        errors: list[str] = []
        path = self.validator.ROOT / "example-skill" / "SKILL.md"
        metadata = self.validator.parse_frontmatter(
            path,
            "---\nname: example-skill\ndescription: 使用此技能處理範例\n---\n",
            errors,
        )

        self.assertEqual(metadata["name"], "example-skill")
        self.assertEqual(metadata["description"], "使用此技能處理範例")
        self.assertEqual(errors, [])

    def test_parse_frontmatter_accepts_spec_optional_fields(self) -> None:
        errors: list[str] = []
        path = self.validator.ROOT / "example-skill" / "SKILL.md"
        metadata = self.validator.parse_frontmatter(
            path,
            (
                "---\n"
                "name: example-skill\n"
                "description: >\n"
                "  使用此技能處理範例\n"
                "license: MIT\n"
                "compatibility: Requires Python 3.12\n"
                "metadata:\n"
                "  version: '1.0'\n"
                "allowed-tools: Read Bash(git:*)\n"
                "---\n"
            ),
            errors,
        )

        self.assertEqual(metadata["license"], "MIT")
        self.assertEqual(metadata["metadata"], {"version": "1.0"})
        self.assertEqual(errors, [])

    def test_validate_fences_accepts_valid_python(self) -> None:
        errors: list[str] = []
        path = self.validator.ROOT / "example.md"
        self.validator.validate_fences(
            path,
            "```python\nprint('ok')\n```\n",
            errors,
        )
        self.assertEqual(errors, [])

    def test_validate_fences_rejects_invalid_json(self) -> None:
        errors: list[str] = []
        path = self.validator.ROOT / "example.md"
        self.validator.validate_fences(
            path,
            "```json\n{not-json}\n```\n",
            errors,
        )
        self.assertEqual(len(errors), 1)

    def test_validate_fences_reports_unclosed_fence(self) -> None:
        errors: list[str] = []
        path = self.validator.ROOT / "example.md"
        self.validator.validate_fences(
            path,
            "```python\nprint('ok')\n",
            errors,
        )
        self.assertEqual(len(errors), 1)

    def test_validate_fences_accepts_tilde_yaml(self) -> None:
        errors: list[str] = []
        path = self.validator.ROOT / "example.md"
        self.validator.validate_fences(
            path,
            "~~~yaml\nmodel_list:\n  - model_name: test\n~~~\n",
            errors,
        )
        self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()
