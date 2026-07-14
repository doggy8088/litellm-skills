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


if __name__ == "__main__":
    unittest.main()
