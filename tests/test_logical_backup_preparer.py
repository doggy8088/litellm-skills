from __future__ import annotations

import hashlib
import importlib.util
import tempfile
import unittest
from pathlib import Path
import zipfile


ROOT = Path(__file__).resolve().parents[1]
PREPARER_PATH = (
    ROOT
    / "litellm-operations-runbook"
    / "scripts"
    / "backup-restore"
    / "prepare-logical-backup.py"
)


def load_preparer():
    spec = importlib.util.spec_from_file_location("logical_backup_preparer_test", PREPARER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("無法載入 logical backup preparer")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


PREPARER = load_preparer()


def build_zip(path: Path, *, member_name: str = "database.dump", payload: bytes = b"dump") -> None:
    digest = hashlib.sha256(payload).hexdigest()
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(member_name, payload)
        archive.writestr("SHA256SUMS", f"{digest}  {member_name}\n")
        archive.writestr("manifest.txt", "backup_format=litellm-logical-v1\n")


class LogicalBackupPreparerTests(unittest.TestCase):
    def test_prepares_verified_dump(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive = root / "backup.zip"
            build_zip(archive)
            kind, prepared = PREPARER.prepare_zip(
                archive,
                root / "prepared",
                max_member_bytes=1024,
                max_total_bytes=4096,
            )
            self.assertEqual(kind, "dump")
            self.assertEqual(prepared.read_bytes(), b"dump")

    def test_rejects_traversal_member(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive = root / "backup.zip"
            build_zip(archive, member_name="../database.dump")
            with self.assertRaises(PREPARER.ValidationError):
                PREPARER.prepare_zip(
                    archive,
                    root / "prepared",
                    max_member_bytes=1024,
                    max_total_bytes=4096,
                )

    def test_rejects_member_over_limit(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive = root / "backup.zip"
            build_zip(archive, payload=b"too-large")
            with self.assertRaises(PREPARER.ValidationError):
                PREPARER.prepare_zip(
                    archive,
                    root / "prepared",
                    max_member_bytes=4,
                    max_total_bytes=4096,
                )


if __name__ == "__main__":
    unittest.main()
