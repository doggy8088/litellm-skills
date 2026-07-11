from __future__ import annotations

import csv
import hashlib
import importlib.util
import io
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VALIDATOR_PATH = (
    ROOT
    / "litellm-operations-runbook"
    / "scripts"
    / "spendlogs"
    / "validate-spendlogs-archive.py"
)


def load_validator():
    spec = importlib.util.spec_from_file_location("spendlogs_archive_validator_test", VALIDATOR_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("無法載入 SpendLogs archive validator")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


VALIDATOR = load_validator()


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def csv_bytes(rows: list[list[str]]) -> bytes:
    output = io.StringIO(newline="")
    writer = csv.writer(output, lineterminator="\n")
    writer.writerows(rows)
    return output.getvalue().encode("utf-8")


def add_bytes(tar: tarfile.TarFile, name: str, data: bytes) -> None:
    member = tarfile.TarInfo(name)
    member.mode = 0o600
    member.size = len(data)
    tar.addfile(member, io.BytesIO(data))


def build_archive(
    path: Path,
    *,
    data_request_id: str = "req-1",
    start_time: str = "2026-06-15 12:00:00+00",
    extra_member: tarfile.TarInfo | None = None,
) -> None:
    data_row = ["" for _ in VALIDATOR.SPENDLOG_COLUMNS]
    data_row[0] = data_request_id
    data_row[VALIDATOR.START_TIME_INDEX] = start_time
    data = csv_bytes([VALIDATOR.SPENDLOG_COLUMNS, data_row])
    request_ids = csv_bytes([["request_id"], ["req-1"]])
    schema = b'CREATE TABLE public."LiteLLM_SpendLogs" ();\n'
    manifest = "\n".join(
        (
            "archive_format=litellm_spendlogs_month_v2",
            "table_schema=public",
            "table_name=LiteLLM_SpendLogs",
            "month=2026-06",
            "range_start=2026-06-01T00:00:00Z",
            "range_end=2026-07-01T00:00:00Z",
            "timezone_basis=UTC",
            "row_count=1",
            "exported_at_utc=2026-07-12T00:00:00Z",
            "source_database=test",
            "data_file=data/LiteLLM_SpendLogs.csv",
            f"data_sha256={sha256(data)}",
            "request_ids_file=data/request_ids.csv",
            f"request_ids_sha256={sha256(request_ids)}",
            "schema_file=schema/LiteLLM_SpendLogs.schema.sql",
            f"schema_sha256={sha256(schema)}",
            "",
        )
    ).encode("utf-8")

    with tarfile.open(path, "w:gz") as tar:
        for name in ("data", "schema"):
            directory = tarfile.TarInfo(name)
            directory.type = tarfile.DIRTYPE
            directory.mode = 0o700
            tar.addfile(directory)
        add_bytes(tar, "manifest.env", manifest)
        add_bytes(tar, "data/LiteLLM_SpendLogs.csv", data)
        add_bytes(tar, "data/request_ids.csv", request_ids)
        add_bytes(tar, "schema/LiteLLM_SpendLogs.schema.sql", schema)
        if extra_member is not None:
            tar.addfile(extra_member)


class SpendLogsArchiveValidatorTests(unittest.TestCase):
    def validate(self, archive: Path, destination: Path) -> None:
        VALIDATOR.safe_extract(archive, destination)
        manifest = VALIDATOR.parse_manifest(destination / "manifest.env")
        count = VALIDATOR.validate_manifest(manifest)
        VALIDATOR.validate_checksums(destination, manifest)
        VALIDATOR.validate_request_ids(destination, manifest, count)

    def test_valid_archive_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive = root / "valid.tar.gz"
            build_archive(archive)
            self.validate(archive, root / "extracted")

    def test_rejects_parent_path_member_before_extraction(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive = root / "traversal.tar.gz"
            unsafe = tarfile.TarInfo("../escape")
            unsafe.size = 0
            build_archive(archive, extra_member=unsafe)
            with self.assertRaises(VALIDATOR.ValidationError):
                VALIDATOR.safe_extract(archive, root / "extracted")
            self.assertFalse((root / "escape").exists())

    def test_rejects_symbolic_link_member(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive = root / "link.tar.gz"
            link = tarfile.TarInfo("unexpected-link")
            link.type = tarfile.SYMTYPE
            link.linkname = "manifest.env"
            build_archive(archive, extra_member=link)
            with self.assertRaises(VALIDATOR.ValidationError):
                VALIDATOR.safe_extract(archive, root / "extracted")

    def test_rejects_request_id_set_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive = root / "mismatch.tar.gz"
            build_archive(archive, data_request_id="req-2")
            destination = root / "extracted"
            VALIDATOR.safe_extract(archive, destination)
            manifest = VALIDATOR.parse_manifest(destination / "manifest.env")
            count = VALIDATOR.validate_manifest(manifest)
            VALIDATOR.validate_checksums(destination, manifest)
            with self.assertRaises(VALIDATOR.ValidationError):
                VALIDATOR.validate_request_ids(destination, manifest, count)

    def test_rejects_start_time_outside_manifest_month(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive = root / "wrong-month.tar.gz"
            build_archive(archive, start_time="2026-07-01T00:00:00Z")
            destination = root / "extracted"
            VALIDATOR.safe_extract(archive, destination)
            manifest = VALIDATOR.parse_manifest(destination / "manifest.env")
            count = VALIDATOR.validate_manifest(manifest)
            VALIDATOR.validate_checksums(destination, manifest)
            with self.assertRaises(VALIDATOR.ValidationError):
                VALIDATOR.validate_request_ids(destination, manifest, count)

    def test_rejects_member_over_configured_size_limit(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            archive = root / "oversize.tar.gz"
            build_archive(archive)
            with self.assertRaises(VALIDATOR.ValidationError):
                VALIDATOR.safe_extract(
                    archive,
                    root / "extracted",
                    max_member_bytes=1,
                    max_total_bytes=1,
                )


if __name__ == "__main__":
    unittest.main()
