from __future__ import annotations

import re
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
KEY_MANAGER = ROOT / "litellm-cost-governance" / "scripts" / "key-manager"
BACKUP = ROOT / "litellm-operations-runbook" / "scripts" / "backup-restore"
SPENDLOGS = ROOT / "litellm-operations-runbook" / "scripts" / "spendlogs"


def shell_function(script: str, name: str) -> str:
    start = script.index(f"{name}() {{")
    end = script.index("\n}\n", start)
    return script[start:end]


def git_visible_files() -> list[Path]:
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
    return [
        ROOT / raw_path.decode("utf-8")
        for raw_path in result.stdout.split(b"\0")
        if raw_path and (ROOT / raw_path.decode("utf-8")).is_file()
    ]


class RepositorySafetyTests(unittest.TestCase):
    def test_retired_high_risk_helpers_are_absent(self) -> None:
        self.assertFalse(KEY_MANAGER.exists(), "repo 不應提供自製 key-manager admin client")
        retired = (
            KEY_MANAGER / "BatchRecreateKey.ps1",
            KEY_MANAGER / "UpdateKeyInfo.ps1",
            KEY_MANAGER / "UpdateKeyList.ps1",
            KEY_MANAGER / "key-manager.ps1",
            KEY_MANAGER / "usage_webapp",
            BACKUP / "Upload-AzureBlobWithSas.ps1",
        )
        for path in retired:
            self.assertFalse(path.exists(), f"高風險 helper 不應存在：{path}")

    def test_no_high_confidence_secret_literal_is_committed(self) -> None:
        patterns = {
            "provider key": re.compile(r"\bsk-[A-Za-z0-9_-]{20,}"),
            "bearer token": re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~-]{24,}"),
            "SAS signature": re.compile(r"(?i)[?&]sig=[A-Za-z0-9%/+_-]{16,}"),
            "Azure account key": re.compile(r"(?i)AccountKey=[A-Za-z0-9+/=]{20,}"),
        }
        documented_placeholders = {
            "sk-local-change-this-value",
            "sk-provider-key-goes-here",
        }
        text_suffixes = {".json", ".md", ".ps1", ".py", ".sh", ".txt", ".yaml", ".yml"}
        for path in git_visible_files():
            if path.suffix.lower() not in text_suffixes and path.name not in {".env.example", ".gitignore"}:
                continue
            text = path.read_text(encoding="utf-8", errors="ignore")
            for label, pattern in patterns.items():
                findings = {
                    match.group(0)
                    for match in pattern.finditer(text)
                    if match.group(0) not in documented_placeholders
                }
                self.assertFalse(findings, f"{path} 含疑似 {label}: {sorted(findings)}")

    def test_backup_archive_does_not_include_dotenv(self) -> None:
        script = (BACKUP / "daily-backup.sh").read_text(encoding="utf-8")
        dangerous = (
            r"(?:zip|tar)[^\n]*\$\{?ENV_FILE\}?",
            r"(?:FILES_TO_(?:ZIP|ARCHIVE)|CONFIGS)[^\n]*\$\{?ENV_FILE\}?",
        )
        for pattern in dangerous:
            self.assertIsNone(re.search(pattern, script), "daily backup 不得封存 .env")
        self.assertIn("umask 077", script)
        self.assertIn("LITELLM_AGE_RECIPIENT", script)
        self.assertIn(".zip.age", script)

    def test_azure_upload_requires_https_and_does_not_log_sas(self) -> None:
        script = (BACKUP / "upload-backup.sh").read_text(encoding="utf-8")
        self.assertNotIn("http://", script)
        self.assertRegex(script, r"https://")
        for pattern in (
            r"(?:echo|printf|log).*SAS_(?:URL|QUERY)",
            r"(?:echo|printf|log).*FULL_BLOB_SAS_URI",
        ):
            self.assertIsNone(re.search(pattern, script, re.IGNORECASE), "不得輸出 SAS query")

    def test_restore_has_no_physical_wal_path_or_known_password(self) -> None:
        script = (BACKUP / "restore-backup.sh").read_text(encoding="utf-8")
        self.assertNotIn("litellm_password_change_me", script)
        self.assertNotIn("recovery.signal", script)
        self.assertNotIn("restore_command", script)
        self.assertIn("127.0.0.1", script)
        self.assertIn("LITELLM_AGE_IDENTITY_FILE", script)
        self.assertIn("required detached checksum", script)
        self.assertIn("litellm.restore.run", script)

    def test_destructive_spendlog_commands_require_execution_guards(self) -> None:
        delete_script = (SPENDLOGS / "delete-spendlogs-month.sh").read_text(encoding="utf-8")
        self.assertIn("--execute", delete_script)
        self.assertIn("--expect-count", delete_script)
        self.assertIn("--force-current-month", delete_script)
        for function_name in ("delete_archived_rows", "delete_retention_rows"):
            function = shell_function(delete_script, function_name)
            self.assertIn("BEGIN ISOLATION LEVEL SERIALIZABLE", function)
            self.assertIn('LOCK TABLE public."LiteLLM_SpendLogs"', function)
            self.assertIn('target."startTime" >=', function)
            self.assertIn("remaining_count", function)

        export_script = (SPENDLOGS / "export-spendlogs-month.sh").read_text(encoding="utf-8")
        self.assertIn("--expect-count", export_script)
        self.assertIn("--age-recipient", export_script)
        self.assertIn(".tar.gz.age", export_script)

    def test_spendlog_shell_column_lists_preserve_request_duration(self) -> None:
        for script_name in (
            "export-spendlogs-month.sh",
            "import-spendlogs-month.sh",
        ):
            script = (SPENDLOGS / script_name).read_text(encoding="utf-8")
            match = re.search(r"SPENDLOG_COLUMNS=\(\n(?P<body>.*?)\n\)", script, re.DOTALL)
            self.assertIsNotNone(match, f"找不到 {script_name} 的 SPENDLOG_COLUMNS")
            columns = [line.strip() for line in match.group("body").splitlines()]
            end_time_index = columns.index("endTime")
            self.assertEqual(columns[end_time_index + 1], "request_duration_ms")
            self.assertEqual(columns[end_time_index + 2], "completionStartTime")

    def test_shell_scripts_avoid_reviewed_gnu_only_options(self) -> None:
        for path in ROOT.rglob("*.sh"):
            script = path.read_text(encoding="utf-8")
            self.assertIsNone(
                re.search(r"\bdate[^\n]*\s-d(?:\s|$)", script),
                f"{path} 不得使用 GNU date -d",
            )
            self.assertNotIn("realpath -m", script, f"{path} 不得使用 GNU realpath -m")
            self.assertIsNone(
                re.search(r"\bsed\b[^\n]*/[A-Za-z]*I[A-Za-z]*['\"]", script),
                f"{path} 不得使用 GNU sed I modifier",
            )

        daily_backup = (BACKUP / "daily-backup.sh").read_text(encoding="utf-8")
        redaction = re.search(
            r"sed -E 's/(?P<pattern>.+?)/\\1=<redacted>/g'",
            daily_backup,
        )
        self.assertIsNotNone(redaction, "找不到可攜式錯誤訊息遮蔽規則")
        python_pattern = redaction.group("pattern").replace("[^[:space:]]+", r"\S+")
        redact = re.compile(python_pattern)
        for secret_name in ("password", "PASSWORD", "Password", "ToKeN"):
            self.assertEqual(
                redact.sub(r"\1=<redacted>", f"error {secret_name}=sensitive"),
                f"error {secret_name}=<redacted>",
            )

    def test_custom_hook_cannot_rewrite_model_or_register_pricing(self) -> None:
        path = (
            ROOT
            / "litellm-guardrails-safety"
            / "scripts"
            / "custom_hooks"
            / "proxy_policy_hook.py"
        )
        text = path.read_text(encoding="utf-8")
        self.assertNotIn("register_model", text)
        self.assertNotIn('data["model"] =', text)
        self.assertNotIn("LITELLM_MODEL_ALIAS_MAP_JSON", text)


if __name__ == "__main__":
    unittest.main()
