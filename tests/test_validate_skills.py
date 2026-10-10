from __future__ import annotations

import importlib.util
import unittest
from tempfile import TemporaryDirectory
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


    def test_validate_data_files_accepts_empty_and_scalar_documents(self) -> None:
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "empty.yaml").write_text("", encoding="utf-8")
            (root / "scalar.yml").write_text("plain text\n", encoding="utf-8")
            (root / "array.json").write_text("[]", encoding="utf-8")
            (root / "scalar.json").write_text("null", encoding="utf-8")
            errors: list[str] = []
            original_root = self.validator.ROOT
            self.validator.ROOT = root
            try:
                self.validator.validate_data_files(errors)
            finally:
                self.validator.ROOT = original_root

        self.assertEqual(errors, [])

    def test_validate_data_files_reports_invalid_yaml_and_json_and_skips_git(self) -> None:
        with TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "invalid.yaml").write_text("key: [unterminated", encoding="utf-8")
            (root / "invalid.json").write_text("{not-json}", encoding="utf-8")
            git_directory = root / ".git"
            git_directory.mkdir()
            (git_directory / "ignored.yml").write_text("key: [unterminated", encoding="utf-8")
            errors: list[str] = []
            original_root = self.validator.ROOT
            self.validator.ROOT = root
            try:
                self.validator.validate_data_files(errors)
            finally:
                self.validator.ROOT = original_root

        self.assertEqual(len(errors), 2)
        self.assertTrue(any("invalid.yaml" in error and "YAML 無法解析" in error for error in errors))
        self.assertTrue(any("invalid.json" in error and "JSON 無法解析" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
