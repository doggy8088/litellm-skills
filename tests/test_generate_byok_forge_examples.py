from __future__ import annotations

import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml


ROOT = Path(__file__).resolve().parents[1]
CATALOG_PATH = ROOT / "examples" / "litellm-byok-forge" / "catalog.json"


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

    def load_catalog(self):
        return json.loads(CATALOG_PATH.read_text(encoding="utf-8"))

    def render_yaml(self, relative_path: str):
        catalog = self.load_catalog()
        outputs = self.generator.render_outputs(catalog)
        return catalog, yaml.safe_load(outputs[Path(relative_path)])

    def assert_generated_config_contract(self, config) -> None:
        self.assertIs(config["litellm_settings"]["drop_params"], True)
        self.assertEqual(
            config["general_settings"]["master_key"],
            "os.environ/LITELLM_MASTER_KEY",
        )
        self.assertIsInstance(config["model_list"], list)
        self.assertTrue(config["model_list"])
        for item in config["model_list"]:
            self.assertIn("litellm_params", item)
            self.assertIsInstance(item["litellm_params"], dict)

    def assert_catalog_rejected(self, catalog, expected_path: str) -> None:
        with self.assertRaises(ValueError) as raised:
            self.generator.validate_catalog(catalog)
        self.assertIn(expected_path, str(raised.exception))

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
        catalog = self.load_catalog()
        catalog["providers"][0]["models"][0] = "injected\nmodel"

        with self.assertRaises(ValueError):
            self.generator.render_outputs(catalog)

    def test_generated_yaml_standard_provider_contract(self) -> None:
        _, config = self.render_yaml("providers/openai/gpt-5-5.yaml")

        self.assert_generated_config_contract(config)
        self.assertEqual(len(config["model_list"]), 1)
        entry = config["model_list"][0]
        self.assertEqual(entry["model_name"], "openai__gpt-5-5")
        self.assertEqual(entry["litellm_params"]["model"], "openai/gpt-5.5")
        self.assertEqual(
            entry["litellm_params"]["api_key"],
            "os.environ/OPENAI_API_KEY",
        )
        self.assertNotIn("api_base", entry["litellm_params"])
        self.assertNotIn("api_version", entry["litellm_params"])

    def test_generated_yaml_azure_provider_contract(self) -> None:
        _, config = self.render_yaml("providers/azure/gpt-5-5.yaml")

        self.assert_generated_config_contract(config)
        entry = config["model_list"][0]
        self.assertEqual(entry["model_name"], "azure__gpt-5-5")
        self.assertEqual(entry["litellm_params"]["model"], "azure/gpt-5.5")
        self.assertEqual(
            entry["litellm_params"]["api_key"],
            "os.environ/AZURE_API_KEY",
        )
        self.assertEqual(
            entry["litellm_params"]["api_base"],
            "https://your-resource.openai.azure.com",
        )
        self.assertEqual(
            entry["litellm_params"]["api_version"],
            "2025-04-01-preview",
        )

    def test_generated_yaml_keyless_local_provider_contract(self) -> None:
        _, config = self.render_yaml("providers/ollama/qwen3-coder-30b.yaml")

        self.assert_generated_config_contract(config)
        entry = config["model_list"][0]
        self.assertEqual(entry["model_name"], "ollama__qwen3-coder-30b")
        self.assertEqual(
            entry["litellm_params"]["model"],
            "ollama_chat/qwen3-coder:30b",
        )
        self.assertNotIn("api_key", entry["litellm_params"])
        self.assertEqual(
            entry["litellm_params"]["api_base"],
            "http://localhost:11434",
        )

    def test_generated_yaml_direct_cloud_provider_contract(self) -> None:
        _, config = self.render_yaml(
            "providers/ollama_cloud/deepseek-v3-1-671b.yaml"
        )

        self.assert_generated_config_contract(config)
        entry = config["model_list"][0]
        self.assertEqual(
            entry["model_name"],
            "ollama_cloud__deepseek-v3-1-671b",
        )
        self.assertEqual(
            entry["litellm_params"]["model"],
            "ollama_chat/deepseek-v3.1:671b",
        )
        self.assertEqual(
            entry["litellm_params"]["api_key"],
            "os.environ/OLLAMA_API_KEY",
        )
        self.assertEqual(
            entry["litellm_params"]["api_base"],
            "https://ollama.com",
        )

    def test_generated_yaml_combined_contract(self) -> None:
        catalog = self.load_catalog()
        outputs = self.generator.render_outputs(catalog)
        combined = yaml.safe_load(outputs[Path("all-models.yaml")])

        self.assert_generated_config_contract(combined)
        expected_count = sum(
            len(provider["models"]) for provider in catalog["providers"]
        )
        entries = combined["model_list"]
        aliases = [entry["model_name"] for entry in entries]
        self.assertEqual(len(entries), expected_count)
        self.assertEqual(len(aliases), len(set(aliases)))

        individual_aliases = set()
        for path, content in outputs.items():
            if path.parts and path.parts[0] == "providers":
                config = yaml.safe_load(content)
                individual_aliases.add(config["model_list"][0]["model_name"])
        self.assertEqual(individual_aliases, set(aliases))

    def test_validate_catalog_accepts_current_catalog(self) -> None:
        catalog = self.load_catalog()

        self.generator.validate_catalog(catalog)

        self.assertEqual(len(self.generator.render_outputs(catalog)), 115)

    def test_validate_catalog_rejects_invalid_root_shape(self) -> None:
        self.assert_catalog_rejected([], "catalog")

        cases = [
            ("missing source", lambda catalog: catalog.pop("source"), "source"),
            (
                "missing providers",
                lambda catalog: catalog.pop("providers"),
                "providers",
            ),
            (
                "unknown root field",
                lambda catalog: catalog.__setitem__("provider", []),
                "catalog.provider",
            ),
            (
                "non-string root field",
                lambda catalog: catalog.__setitem__(1, []),
                "catalog",
            ),
            (
                "empty providers",
                lambda catalog: catalog.__setitem__("providers", []),
                "providers",
            ),
            (
                "provider is not mapping",
                lambda catalog: catalog["providers"].__setitem__(0, "mistral"),
                "providers[0]",
            ),
        ]
        for label, mutate, expected_path in cases:
            with self.subTest(label=label):
                catalog = self.load_catalog()
                mutate(catalog)
                self.assert_catalog_rejected(catalog, expected_path)

    def test_validate_catalog_rejects_invalid_root_source(self) -> None:
        cases = [
            (
                "missing field",
                lambda source: source.pop("file"),
                "source.file",
            ),
            (
                "unknown field",
                lambda source: source.__setitem__("retrieved_at", "2026-07-12"),
                "source.retrieved_at",
            ),
            (
                "control character",
                lambda source: source.__setitem__("repository", "owner\trepo"),
                "source.repository",
            ),
            (
                "bad commit",
                lambda source: source.__setitem__("commit", "abc123"),
                "source.commit",
            ),
            (
                "url without host",
                lambda source: source.__setitem__("page", "https:///missing"),
                "source.page",
            ),
            (
                "bad extracted date",
                lambda source: source.__setitem__("extracted_at", "2026-02-30"),
                "source.extracted_at",
            ),
        ]
        for label, mutate, expected_path in cases:
            with self.subTest(label=label):
                catalog = self.load_catalog()
                mutate(catalog["source"])
                self.assert_catalog_rejected(catalog, expected_path)

    def test_validate_catalog_rejects_invalid_provider_identity(self) -> None:
        cases = [
            (
                "missing id",
                lambda provider: provider.pop("id"),
                "providers[0].id",
            ),
            (
                "path separator",
                lambda provider: provider.__setitem__("id", "bad/id"),
                "providers[0].id",
            ),
            (
                "name control character",
                lambda provider: provider.__setitem__("name", "Bad\nName"),
                "providers[0].name",
            ),
            (
                "bad prefix",
                lambda provider: provider.__setitem__("prefix", "Bad-Prefix"),
                "providers[0].prefix",
            ),
            (
                "unknown field",
                lambda provider: provider.__setitem__("need_base", True),
                "providers[0].need_base",
            ),
        ]
        for label, mutate, expected_path in cases:
            with self.subTest(label=label):
                catalog = self.load_catalog()
                mutate(catalog["providers"][0])
                self.assert_catalog_rejected(catalog, expected_path)

    def test_validate_catalog_rejects_non_boolean_flags(self) -> None:
        for flag in ("keyless", "needs_base", "needs_version"):
            for value in ("false", 1):
                with self.subTest(flag=flag, value=value):
                    catalog = self.load_catalog()
                    catalog["providers"][0][flag] = value
                    self.assert_catalog_rejected(
                        catalog,
                        f"providers[0].{flag}",
                    )

    def test_validate_catalog_rejects_invalid_environment_contract(self) -> None:
        cases = [
            (
                "lowercase env",
                lambda provider: provider.__setitem__("env", "api_key"),
                "providers[0].env",
            ),
            (
                "env control character",
                lambda provider: provider.__setitem__("env", "API_KEY\nNEXT"),
                "providers[0].env",
            ),
            (
                "missing keyed env",
                lambda provider: provider.pop("env"),
                "providers[0].env",
            ),
            (
                "nonempty keyless env",
                lambda provider: provider.__setitem__("env", "OLLAMA_API_KEY"),
                "providers[12].env",
            ),
        ]
        for label, mutate, expected_path in cases:
            with self.subTest(label=label):
                catalog = self.load_catalog()
                provider = (
                    catalog["providers"][12]
                    if label == "nonempty keyless env"
                    else catalog["providers"][0]
                )
                mutate(provider)
                self.assert_catalog_rejected(catalog, expected_path)

    def test_validate_catalog_rejects_invalid_base_contract(self) -> None:
        for label, value in (
            ("missing", None),
            ("bad scheme", "ftp://localhost:11434"),
            ("missing host", "http:///v1"),
        ):
            with self.subTest(label=label):
                catalog = self.load_catalog()
                provider = catalog["providers"][12]
                if value is None:
                    provider.pop("base_default")
                else:
                    provider["base_default"] = value
                self.assert_catalog_rejected(catalog, "providers[12].base_default")

    def test_validate_catalog_rejects_invalid_version_contract(self) -> None:
        for label, value in (
            ("missing", None),
            ("empty", ""),
            ("control character", "2025-04-01\npreview"),
        ):
            with self.subTest(label=label):
                catalog = self.load_catalog()
                provider = catalog["providers"][11]
                if value is None:
                    provider.pop("version_default")
                else:
                    provider["version_default"] = value
                self.assert_catalog_rejected(
                    catalog,
                    "providers[11].version_default",
                )

    def test_validate_catalog_rejects_invalid_models(self) -> None:
        cases = [
            (
                "not a list",
                lambda provider: provider.__setitem__("models", "model"),
                "providers[0].models",
            ),
            (
                "empty list",
                lambda provider: provider.__setitem__("models", []),
                "providers[0].models",
            ),
            (
                "invalid model",
                lambda provider: provider["models"].__setitem__(0, "bad|model"),
                "providers[0].models[0]",
            ),
            (
                "duplicate model",
                lambda provider: provider["models"].append(provider["models"][0]),
                "providers[0].models[4]",
            ),
            (
                "duplicate alias",
                lambda provider: provider.__setitem__(
                    "models", ["vendor/model", "vendor-model"]
                ),
                "providers[0].models[1]",
            ),
        ]
        for label, mutate, expected_path in cases:
            with self.subTest(label=label):
                catalog = self.load_catalog()
                mutate(catalog["providers"][0])
                self.assert_catalog_rejected(catalog, expected_path)

    def test_validate_catalog_rejects_duplicate_provider_id(self) -> None:
        catalog = self.load_catalog()
        catalog["providers"][1]["id"] = catalog["providers"][0]["id"]

        self.assert_catalog_rejected(catalog, "providers[1].id")

    def test_validate_catalog_rejects_invalid_provider_source(self) -> None:
        cases = [
            (
                "missing field",
                lambda source: source.pop("docs"),
                "providers[13].source.docs",
            ),
            (
                "unknown field",
                lambda source: source.__setitem__("date", "2026-07-12"),
                "providers[13].source.date",
            ),
            (
                "empty type",
                lambda source: source.__setitem__("type", ""),
                "providers[13].source.type",
            ),
            (
                "bad url",
                lambda source: source.__setitem__("url", "https:///tags"),
                "providers[13].source.url",
            ),
            (
                "bad docs",
                lambda source: source.__setitem__("docs", "file:///cloud"),
                "providers[13].source.docs",
            ),
            (
                "bad date",
                lambda source: source.__setitem__("retrieved_at", "2026-02-30"),
                "providers[13].source.retrieved_at",
            ),
        ]
        for label, mutate, expected_path in cases:
            with self.subTest(label=label):
                catalog = self.load_catalog()
                mutate(catalog["providers"][13]["source"])
                self.assert_catalog_rejected(catalog, expected_path)

    def test_main_validates_catalog_before_refresh(self) -> None:
        catalog = self.load_catalog()
        catalog["providers"][13]["id"] = "bad/id"
        with tempfile.TemporaryDirectory() as directory:
            catalog_path = Path(directory) / "catalog.json"
            catalog_path.write_text(json.dumps(catalog), encoding="utf-8")
            with (
                mock.patch.object(self.generator, "CATALOG_PATH", catalog_path),
                mock.patch.object(
                    self.generator,
                    "refresh_ollama_cloud_catalog",
                ) as refresh,
                mock.patch("sys.argv", ["generator", "--refresh-ollama-cloud"]),
            ):
                with self.assertRaises(ValueError):
                    self.generator.main()

        refresh.assert_not_called()

    def test_generated_catalog_counts_follow_in_memory_model_change(self) -> None:
        catalog = self.load_catalog()
        original_outputs = self.generator.render_outputs(catalog)
        original_model_count = sum(
            len(provider["models"]) for provider in catalog["providers"]
        )
        cloud_providers = [
            provider
            for provider in catalog["providers"]
            if provider["id"] in {"ollama_cloud", "ollama_cloud_local"}
        ]
        original_cloud_count = sum(
            len(provider["models"]) for provider in cloud_providers
        )
        direct_cloud = next(
            provider
            for provider in catalog["providers"]
            if provider["id"] == "ollama_cloud"
        )
        direct_cloud["models"].append("contract-test-model")

        outputs = self.generator.render_outputs(catalog)

        self.assertIn(
            f"{len(catalog['providers'])} 個 providers、{original_model_count + 1} 組",
            outputs[Path("model-catalog.md")],
        )
        self.assertIn(
            f"2 種 Ollama Cloud 存取方式、{original_cloud_count + 1} 個模型名稱",
            outputs[Path("ollama-cloud-models.md")],
        )
        self.assertEqual(len(outputs), len(original_outputs) + 1)
        self.assertIn(
            Path("providers/ollama_cloud/contract-test-model.yaml"),
            outputs,
        )

    def test_check_outputs_reports_missing_extra_and_changed_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            examples = Path(directory)
            stale_file = examples / "providers" / "old" / "nested" / "stale.yaml"
            stale_file.parent.mkdir(parents=True)
            stale_file.write_text(
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
        self.assertTrue(
            any(
                "providers/old/nested/stale.yaml" in error
                for error in errors
            )
        )
        self.assertTrue(any("生成內容不同步" in error for error in errors))

    def test_atomic_writer_replaces_outputs_and_removes_stale_provider(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            examples = Path(directory)
            stale_file = examples / "providers" / "old" / "nested" / "stale.yaml"
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
            self.assertFalse(stale_file.parent.parent.exists())

    def test_atomic_writer_preserves_non_yaml_beside_nested_stale_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            examples = Path(directory)
            stale_file = examples / "providers" / "old" / "nested" / "stale.yaml"
            stale_file.parent.mkdir(parents=True)
            stale_file.write_text("stale", encoding="utf-8")
            note_file = stale_file.parent / "keep.txt"
            note_file.write_text("keep", encoding="utf-8")
            outputs = {Path("all-models.yaml"): "new"}

            self.generator.write_outputs_atomically(outputs, examples=examples)

            self.assertFalse(stale_file.exists())
            self.assertEqual(note_file.read_text(encoding="utf-8"), "keep")
            self.assertTrue(note_file.parent.exists())
            self.assertTrue(note_file.parent.parent.exists())

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

    def assert_interrupt_rolls_back(self, interruption: BaseException) -> None:
        with tempfile.TemporaryDirectory() as directory:
            examples = Path(directory)
            all_models_file = examples / "all-models.yaml"
            all_models_file.write_text("old-models", encoding="utf-8")
            stale_file = examples / "providers" / "old" / "stale.yaml"
            stale_file.parent.mkdir(parents=True)
            stale_file.write_text("stale", encoding="utf-8")
            new_file = examples / "providers" / "new" / "model.yaml"
            outputs = {
                Path("all-models.yaml"): "new-models",
                Path("providers/new/model.yaml"): "new-model",
            }
            real_replace = self.generator.os.replace
            replacement_count = 0

            def interrupt_second_replace(source, target):
                nonlocal replacement_count
                replacement_count += 1
                if replacement_count == 2:
                    raise interruption
                return real_replace(source, target)

            with mock.patch.object(
                self.generator.os,
                "replace",
                side_effect=interrupt_second_replace,
            ):
                with self.assertRaises(type(interruption)) as raised:
                    self.generator.write_outputs_atomically(
                        outputs,
                        examples=examples,
                    )

            self.assertIs(raised.exception, interruption)
            self.assertEqual(
                all_models_file.read_text(encoding="utf-8"),
                "old-models",
            )
            self.assertEqual(stale_file.read_text(encoding="utf-8"), "stale")
            self.assertFalse(new_file.exists())
            self.assertFalse(new_file.parent.exists())

    def test_atomic_writer_rolls_back_after_keyboard_interrupt(self) -> None:
        self.assert_interrupt_rolls_back(KeyboardInterrupt("simulated interrupt"))

    def test_atomic_writer_rolls_back_after_system_exit(self) -> None:
        self.assert_interrupt_rolls_back(SystemExit(7))


if __name__ == "__main__":
    unittest.main()
