from __future__ import annotations

import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]


def load_generator():
    path = ROOT / "scripts" / "generate_byok_forge_examples.py"
    spec = importlib.util.spec_from_file_location("generate_byok_forge_examples", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"無法載入 {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class GeneratorUnitTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.generator = load_generator()

    def test_slug_normalizes_provider_model_names(self) -> None:
        self.assertEqual(
            self.generator.slug("Qwen/Qwen3-Coder:30B"),
            "qwen-qwen3-coder-30b",
        )

    def test_slug_rejects_value_without_filename_characters(self) -> None:
        with self.assertRaises(ValueError):
            self.generator.slug("///")

    def test_validate_model_name_accepts_supported_provider_formats(self) -> None:
        names = [
            "Qwen/Qwen3-Coder:30B",
            "gpt-oss:120b-cloud",
            "vendor/model.v2+preview@2026",
        ]
        for name in names:
            with self.subTest(name=name):
                self.assertEqual(self.generator.validate_model_name(name), name)

    def test_validate_model_name_rejects_unsafe_or_non_string_values(self) -> None:
        invalid_names = [
            123,
            "bad|name",
            "bad\nname",
            "`bad`",
            "x" * 201,
        ]
        for name in invalid_names:
            with self.subTest(name=name):
                with self.assertRaises(ValueError):
                    self.generator.validate_model_name(name)

    def test_markdown_table_code_escapes_structural_characters(self) -> None:
        self.assertEqual(
            self.generator.markdown_table_code("<bad>|`name`\nnext"),
            "<code>&lt;bad&gt;&#124;`name` next</code>",
        )

    def test_model_alias_includes_provider_id(self) -> None:
        provider = {"id": "openrouter"}
        self.assertEqual(
            self.generator.model_alias(provider, "vendor/model"),
            "openrouter__vendor-model",
        )

    def test_refresh_ollama_cloud_catalog_uses_mocked_network(self) -> None:
        catalog = {
            "providers": [
                {
                    "id": "ollama_cloud",
                    "models": ["old-model"],
                }
            ]
        }
        payload = io.BytesIO(
            json.dumps(
                {
                    "models": [
                        {"name": "zeta"},
                        {"model": "alpha"},
                        {"name": "alpha"},
                    ]
                }
            ).encode("utf-8")
        )

        with mock.patch.object(
            self.generator.urllib.request,
            "urlopen",
            return_value=payload,
        ) as urlopen:
            count = self.generator.refresh_ollama_cloud_catalog(catalog)

        self.assertEqual(count, 2)
        self.assertEqual(catalog["providers"][0]["models"], ["alpha", "zeta"])
        urlopen.assert_called_once()

    def test_refresh_rejects_empty_model_response(self) -> None:
        catalog = {"providers": [{"id": "ollama_cloud", "models": []}]}
        payload = io.BytesIO(json.dumps({"models": []}).encode("utf-8"))

        with mock.patch.object(
            self.generator.urllib.request,
            "urlopen",
            return_value=payload,
        ):
            with self.assertRaises(ValueError):
                self.generator.refresh_ollama_cloud_catalog(catalog)

    def test_refresh_rejects_unsafe_remote_model_without_mutating_catalog(self) -> None:
        catalog = {
            "providers": [
                {
                    "id": "ollama_cloud",
                    "models": ["old-model"],
                }
            ]
        }
        payload = io.BytesIO(
            json.dumps(
                {
                    "models": [
                        {"name": "valid-model"},
                        {"name": "injected|model"},
                    ]
                }
            ).encode("utf-8")
        )

        with mock.patch.object(
            self.generator.urllib.request,
            "urlopen",
            return_value=payload,
        ):
            with self.assertRaises(ValueError):
                self.generator.refresh_ollama_cloud_catalog(catalog)

        self.assertEqual(catalog["providers"][0]["models"], ["old-model"])

    def test_render_rejects_unsafe_checked_in_model_name(self) -> None:
        catalog = json.loads(
            (ROOT / "examples" / "litellm-byok-forge" / "catalog.json").read_text(
                encoding="utf-8"
            )
        )
        catalog["providers"][0]["models"][0] = "injected\nmodel"

        with self.assertRaises(ValueError):
            self.generator.render_outputs(catalog)

    def test_check_outputs_reports_missing_extra_and_changed_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            examples = Path(directory)
            (examples / "providers" / "old").mkdir(parents=True)
            (examples / "providers" / "old" / "stale.yaml").write_text(
                "stale",
                encoding="utf-8",
            )
            (examples / "all-models.yaml").write_text("old", encoding="utf-8")
            outputs = {
                Path("providers/new/model.yaml"): "model",
                Path("all-models.yaml"): "new",
            }

            with mock.patch.object(self.generator, "EXAMPLES", examples):
                errors = self.generator.check_outputs(outputs)

        self.assertTrue(any("缺少生成檔" in error for error in errors))
        self.assertTrue(any("多餘生成檔" in error for error in errors))
        self.assertTrue(any("生成內容不同步" in error for error in errors))

    def test_atomic_writer_replaces_outputs_and_removes_stale_provider(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            examples = Path(directory)
            stale_file = examples / "providers" / "old" / "stale.yaml"
            stale_file.parent.mkdir(parents=True)
            stale_file.write_text("stale", encoding="utf-8")
            (examples / "all-models.yaml").write_text("old", encoding="utf-8")
            outputs = {
                Path("providers/new/model.yaml"): "model",
                Path("all-models.yaml"): "new",
            }

            self.generator.write_outputs_atomically(outputs, examples=examples)

            self.assertEqual(
                (examples / "providers" / "new" / "model.yaml").read_text(
                    encoding="utf-8"
                ),
                "model",
            )
            self.assertEqual(
                (examples / "all-models.yaml").read_text(encoding="utf-8"),
                "new",
            )
            self.assertFalse(stale_file.exists())
            self.assertFalse(stale_file.parent.exists())

    def test_atomic_writer_rolls_back_every_output_after_replace_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            examples = Path(directory)
            env_file = examples / ".env.example"
            all_models_file = examples / "all-models.yaml"
            env_file.write_text("old-env", encoding="utf-8")
            all_models_file.write_text("old-models", encoding="utf-8")
            outputs = {
                Path(".env.example"): "new-env",
                Path("all-models.yaml"): "new-models",
            }
            real_replace = self.generator.os.replace
            replacement_count = 0

            def fail_second_replace(source, target):
                nonlocal replacement_count
                replacement_count += 1
                if replacement_count == 2:
                    raise OSError("simulated replace failure")
                return real_replace(source, target)

            with mock.patch.object(
                self.generator.os,
                "replace",
                side_effect=fail_second_replace,
            ):
                with self.assertRaises(OSError):
                    self.generator.write_outputs_atomically(
                        outputs,
                        examples=examples,
                    )

            self.assertEqual(env_file.read_text(encoding="utf-8"), "old-env")
            self.assertEqual(
                all_models_file.read_text(encoding="utf-8"),
                "old-models",
            )


if __name__ == "__main__":
    unittest.main()
