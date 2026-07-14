#!/usr/bin/env python3
"""Safely extract and validate a LiteLLM SpendLogs monthly archive."""

from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
import hashlib
import hmac
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sqlite3
import sys
import tarfile
import tempfile


ARCHIVE_FORMAT = "litellm_spendlogs_month_v3"
EXPECTED_MEMBERS = {
    "manifest.env": "file",
    "data": "dir",
    "data/LiteLLM_SpendLogs.csv": "file",
    "data/request_ids.csv": "file",
    "schema": "dir",
    "schema/LiteLLM_SpendLogs.schema.sql": "file",
}
EXPECTED_PATHS = {
    "data_file": "data/LiteLLM_SpendLogs.csv",
    "request_ids_file": "data/request_ids.csv",
    "schema_file": "schema/LiteLLM_SpendLogs.schema.sql",
}
SPENDLOG_COLUMNS = [
    "request_id",
    "call_type",
    "api_key",
    "spend",
    "total_tokens",
    "prompt_tokens",
    "completion_tokens",
    "startTime",
    "endTime",
    "request_duration_ms",
    "completionStartTime",
    "model",
    "model_id",
    "model_group",
    "custom_llm_provider",
    "api_base",
    "user",
    "metadata",
    "cache_hit",
    "cache_key",
    "request_tags",
    "team_id",
    "end_user",
    "requester_ip_address",
    "messages",
    "response",
    "proxy_server_request",
    "session_id",
    "status",
    "mcp_namespaced_tool_name",
    "organization_id",
    "agent_id",
]
REQUIRED_MANIFEST_KEYS = {
    "archive_format",
    "table_schema",
    "table_name",
    "month",
    "range_start",
    "range_end",
    "timezone_basis",
    "row_count",
    "exported_at_utc",
    "source_database",
    "data_file",
    "data_sha256",
    "request_ids_file",
    "request_ids_sha256",
    "schema_file",
    "schema_sha256",
}
SHA256_RE = re.compile(r"[0-9a-f]{64}")
MONTH_RE = re.compile(r"[0-9]{4}-(0[1-9]|1[0-2])")
MANIFEST_KEY_RE = re.compile(r"[a-z][a-z0-9_]*")
DEFAULT_MAX_MEMBER_BYTES = 8 * 1024 * 1024 * 1024
DEFAULT_MAX_TOTAL_BYTES = 12 * 1024 * 1024 * 1024
START_TIME_INDEX = SPENDLOG_COLUMNS.index("startTime")


class ValidationError(RuntimeError):
    """Archive validation failed."""


def normalized_member_name(member: tarfile.TarInfo) -> str:
    raw_name = member.name
    path = PurePosixPath(raw_name)
    if path.is_absolute() or raw_name.startswith(("/", "\\")):
        raise ValidationError(f"archive contains an absolute path: {raw_name!r}")
    if "\\" in raw_name or any(part in {"", ".", ".."} for part in path.parts):
        raise ValidationError(f"archive contains an unsafe path: {raw_name!r}")
    return raw_name.rstrip("/") if member.isdir() else raw_name


def safe_extract(
    archive: Path,
    destination: Path,
    *,
    max_member_bytes: int = DEFAULT_MAX_MEMBER_BYTES,
    max_total_bytes: int = DEFAULT_MAX_TOTAL_BYTES,
) -> None:
    if max_member_bytes <= 0 or max_total_bytes <= 0:
        raise ValidationError("archive extraction limits must be positive")
    if max_total_bytes < max_member_bytes:
        raise ValidationError("total-size limit must be at least the member-size limit")
    destination.mkdir(mode=0o700, parents=True, exist_ok=False)
    seen: set[str] = set()

    try:
        with tarfile.open(archive, mode="r:gz") as tar:
            members = tar.getmembers()
            member_by_name: dict[str, tarfile.TarInfo] = {}
            total_file_size = 0
            for member in members:
                name = normalized_member_name(member)
                if member.issym() or member.islnk():
                    raise ValidationError(f"archive links are not allowed: {name!r}")
                if name in seen:
                    raise ValidationError(f"archive contains a duplicate member: {name!r}")
                seen.add(name)
                member_by_name[name] = member
                expected_type = EXPECTED_MEMBERS.get(name)
                if expected_type is None:
                    raise ValidationError(f"archive contains an unexpected member: {name!r}")
                if expected_type == "file" and not member.isfile():
                    raise ValidationError(f"archive member must be a regular file: {name!r}")
                if expected_type == "dir" and not member.isdir():
                    raise ValidationError(f"archive member must be a directory: {name!r}")
                if member.isfile():
                    if member.size < 0 or member.size > max_member_bytes:
                        raise ValidationError(
                            f"archive member exceeds the configured size limit: {name!r}"
                        )
                    total_file_size += member.size
                    if total_file_size > max_total_bytes:
                        raise ValidationError(
                            "archive members exceed the configured total-size limit"
                        )

            missing = set(EXPECTED_MEMBERS) - seen
            if missing:
                raise ValidationError(
                    "archive is missing required members: " + ", ".join(sorted(missing))
                )

            for name in ("data", "schema"):
                target = destination / name
                target.mkdir(mode=0o700, parents=False, exist_ok=False)

            for name in (
                "manifest.env",
                "data/LiteLLM_SpendLogs.csv",
                "data/request_ids.csv",
                "schema/LiteLLM_SpendLogs.schema.sql",
            ):
                member = member_by_name[name]
                target = destination.joinpath(*PurePosixPath(name).parts)
                source = tar.extractfile(member)
                if source is None:
                    raise ValidationError(f"could not read archive member: {name!r}")
                with source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(0o600)
    except (tarfile.TarError, OSError) as exc:
        raise ValidationError(f"could not safely extract archive: {exc}") from exc


def parse_manifest(path: Path) -> dict[str, str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise ValidationError(f"could not read manifest.env: {exc}") from exc

    values: dict[str, str] = {}
    for line_number, line in enumerate(lines, start=1):
        if not line or "=" not in line:
            raise ValidationError(f"invalid manifest line {line_number}")
        key, value = line.split("=", 1)
        if not MANIFEST_KEY_RE.fullmatch(key):
            raise ValidationError(f"invalid manifest key on line {line_number}: {key!r}")
        if key in values:
            raise ValidationError(f"duplicate manifest key: {key}")
        if "\x00" in value or "\r" in value or "\n" in value:
            raise ValidationError(f"invalid manifest value for {key}")
        values[key] = value

    missing = REQUIRED_MANIFEST_KEYS - values.keys()
    if missing:
        raise ValidationError(
            "manifest is missing required keys: " + ", ".join(sorted(missing))
        )
    return values


def validate_manifest(values: dict[str, str]) -> int:
    if values["archive_format"] != ARCHIVE_FORMAT:
        raise ValidationError(
            f"unsupported archive_format: {values['archive_format']!r}; expected {ARCHIVE_FORMAT!r}"
        )
    if values["table_schema"] != "public" or values["table_name"] != "LiteLLM_SpendLogs":
        raise ValidationError("manifest identifies an unexpected database table")
    if values["timezone_basis"] != "UTC":
        raise ValidationError("manifest timezone_basis must be UTC")
    if not MONTH_RE.fullmatch(values["month"]):
        raise ValidationError("manifest month must use YYYY-MM")
    year, month = (int(part) for part in values["month"].split("-"))
    next_year, next_month = (year + 1, 1) if month == 12 else (year, month + 1)
    expected_start = f"{year:04d}-{month:02d}-01T00:00:00Z"
    expected_end = f"{next_year:04d}-{next_month:02d}-01T00:00:00Z"
    if values["range_start"] != expected_start or values["range_end"] != expected_end:
        raise ValidationError("manifest range must exactly match the declared UTC month")
    try:
        exported_at = datetime.strptime(values["exported_at_utc"], "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as exc:
        raise ValidationError("manifest exported_at_utc must use YYYY-MM-DDTHH:MM:SSZ") from exc
    if exported_at.replace(tzinfo=timezone.utc).utcoffset() is None:
        raise ValidationError("manifest exported_at_utc must be UTC")
    if not values["row_count"].isdigit():
        raise ValidationError("manifest row_count must be a non-negative integer")
    for key, expected_path in EXPECTED_PATHS.items():
        if values[key] != expected_path:
            raise ValidationError(f"manifest {key} must be {expected_path!r}")
    for key in ("data_sha256", "request_ids_sha256", "schema_sha256"):
        if not SHA256_RE.fullmatch(values[key]):
            raise ValidationError(f"manifest {key} must be a lowercase SHA-256 digest")
    return int(values["row_count"])


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_checksums(root: Path, values: dict[str, str]) -> None:
    for path_key, digest_key in (
        ("data_file", "data_sha256"),
        ("request_ids_file", "request_ids_sha256"),
        ("schema_file", "schema_sha256"),
    ):
        path = root.joinpath(*PurePosixPath(values[path_key]).parts)
        actual = sha256(path)
        if not hmac.compare_digest(actual, values[digest_key]):
            raise ValidationError(
                f"{path_key} checksum mismatch: expected={values[digest_key]}, actual={actual}"
            )


def maximize_csv_field_size() -> None:
    limit = sys.maxsize
    while True:
        try:
            csv.field_size_limit(limit)
            return
        except OverflowError:
            limit //= 10


def parse_start_time(value: str, *, line_number: int) -> datetime:
    if not value:
        raise ValidationError(f"SpendLogs startTime is empty at row {line_number}")
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as exc:
        raise ValidationError(
            f"SpendLogs startTime is invalid at row {line_number}: {value!r}"
        ) from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def validate_request_ids(root: Path, values: dict[str, str], expected_count: int) -> None:
    maximize_csv_field_size()
    data_path = root / EXPECTED_PATHS["data_file"]
    request_ids_path = root / EXPECTED_PATHS["request_ids_file"]
    database_file = tempfile.NamedTemporaryFile(
        prefix="spendlogs-request-ids-", suffix=".sqlite3", delete=False
    )
    database_path = Path(database_file.name)
    database_file.close()
    range_start = datetime.strptime(values["range_start"], "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=timezone.utc
    )
    range_end = datetime.strptime(values["range_end"], "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=timezone.utc
    )
    database: sqlite3.Connection | None = None

    try:
        database = sqlite3.connect(database_path)
        with database:
            database.execute(
                "CREATE TABLE request_ids (request_id TEXT PRIMARY KEY, seen_in_data INTEGER NOT NULL DEFAULT 0)"
            )
            request_id_count = 0
            with request_ids_path.open("r", encoding="utf-8", newline="") as source:
                rows = csv.reader(source)
                header = next(rows, None)
                if header != ["request_id"]:
                    raise ValidationError("request_ids.csv must have exactly one request_id column")
                for line_number, row in enumerate(rows, start=2):
                    if len(row) != 1 or not row[0]:
                        raise ValidationError(f"invalid request_ids.csv row {line_number}")
                    try:
                        database.execute("INSERT INTO request_ids(request_id) VALUES (?)", (row[0],))
                    except sqlite3.IntegrityError as exc:
                        raise ValidationError(
                            f"duplicate request_id in request_ids.csv at row {line_number}"
                        ) from exc
                    request_id_count += 1

            if request_id_count != expected_count:
                raise ValidationError(
                    f"request_ids.csv row count mismatch: expected={expected_count}, actual={request_id_count}"
                )

            data_count = 0
            with data_path.open("r", encoding="utf-8", newline="") as source:
                rows = csv.reader(source)
                header = next(rows, None)
                if header != SPENDLOG_COLUMNS:
                    raise ValidationError("SpendLogs data CSV columns or column order are invalid")
                for line_number, row in enumerate(rows, start=2):
                    if len(row) != len(SPENDLOG_COLUMNS) or not row[0]:
                        raise ValidationError(f"invalid SpendLogs data row {line_number}")
                    start_time = parse_start_time(row[START_TIME_INDEX], line_number=line_number)
                    if not range_start <= start_time < range_end:
                        raise ValidationError(
                            f"SpendLogs startTime falls outside the manifest UTC month at row {line_number}"
                        )
                    updated = database.execute(
                        "UPDATE request_ids SET seen_in_data = 1 "
                        "WHERE request_id = ? AND seen_in_data = 0",
                        (row[0],),
                    ).rowcount
                    if updated != 1:
                        raise ValidationError(
                            f"SpendLogs data request_id is missing from request_ids.csv or duplicated at row {line_number}"
                        )
                    data_count += 1

            if data_count != expected_count:
                raise ValidationError(
                    f"SpendLogs data row count mismatch: expected={expected_count}, actual={data_count}"
                )
            missing_from_data = database.execute(
                "SELECT COUNT(*) FROM request_ids WHERE seen_in_data = 0"
            ).fetchone()[0]
            if missing_from_data:
                raise ValidationError(
                    f"request_ids.csv contains {missing_from_data} IDs missing from the data CSV"
                )
    except (OSError, UnicodeError, csv.Error, sqlite3.Error) as exc:
        raise ValidationError(f"could not validate archive CSV files: {exc}") from exc
    finally:
        if database is not None:
            database.close()
        database_path.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument(
        "--max-member-bytes", type=int, default=DEFAULT_MAX_MEMBER_BYTES
    )
    parser.add_argument(
        "--max-total-bytes", type=int, default=DEFAULT_MAX_TOTAL_BYTES
    )
    args = parser.parse_args()

    os.umask(0o077)
    if not args.archive.is_file():
        raise ValidationError(f"archive file not found: {args.archive}")
    safe_extract(
        args.archive,
        args.destination,
        max_member_bytes=args.max_member_bytes,
        max_total_bytes=args.max_total_bytes,
    )
    manifest = parse_manifest(args.destination / "manifest.env")
    expected_count = validate_manifest(manifest)
    validate_checksums(args.destination, manifest)
    validate_request_ids(args.destination, manifest, expected_count)
    print(f"archive_format={manifest['archive_format']}")
    print(f"month={manifest['month']}")
    print(f"row_count={expected_count}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
