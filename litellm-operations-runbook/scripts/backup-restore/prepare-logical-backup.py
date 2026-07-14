#!/usr/bin/env python3
"""Safely validate and extract one logical PostgreSQL member from a ZIP."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import zipfile


SHA256_RE = re.compile(r"[0-9a-fA-F]{64}")
MAX_ZIP_MEMBERS = 64
MAX_CHECKSUM_BYTES = 1024 * 1024


class ValidationError(RuntimeError):
    """Logical backup validation failed."""


def normalized_name(info: zipfile.ZipInfo) -> str:
    raw_name = info.filename
    path = PurePosixPath(raw_name)
    if (
        path.is_absolute()
        or raw_name.startswith(("/", "\\"))
        or "\\" in raw_name
        or any(part in {"", ".", ".."} for part in path.parts)
        or any(ord(character) < 32 for character in raw_name)
    ):
        raise ValidationError(f"ZIP contains an unsafe member path: {raw_name!r}")
    return raw_name.rstrip("/") if info.is_dir() else raw_name


def is_regular_file(info: zipfile.ZipInfo) -> bool:
    mode = (info.external_attr >> 16) & 0xFFFF
    if mode and stat.S_ISLNK(mode):
        return False
    file_type = stat.S_IFMT(mode)
    return not info.is_dir() and file_type in (0, stat.S_IFREG)


def parse_expected_checksum(contents: bytes, member_name: str) -> str:
    try:
        text = contents.decode("utf-8")
    except UnicodeError as exc:
        raise ValidationError("SHA256SUMS must be UTF-8 text") from exc

    accepted_names = {member_name, PurePosixPath(member_name).name, f"./{member_name}"}
    matches: list[str] = []
    for line in text.splitlines():
        fields = line.split(maxsplit=1)
        if len(fields) != 2 or not SHA256_RE.fullmatch(fields[0]):
            continue
        recorded_name = fields[1].removeprefix("*")
        if recorded_name in accepted_names:
            matches.append(fields[0].lower())
    if len(matches) != 1:
        raise ValidationError("SHA256SUMS must contain exactly one checksum for the logical backup member")
    return matches[0]


def prepare_zip(
    archive: Path,
    destination: Path,
    *,
    max_member_bytes: int,
    max_total_bytes: int,
) -> tuple[str, Path]:
    if max_member_bytes <= 0 or max_total_bytes <= 0:
        raise ValidationError("ZIP extraction limits must be positive")

    destination.mkdir(mode=0o700, parents=True, exist_ok=False)
    try:
        with zipfile.ZipFile(archive) as source_zip:
            infos = source_zip.infolist()
            if len(infos) > MAX_ZIP_MEMBERS:
                raise ValidationError(f"ZIP contains more than {MAX_ZIP_MEMBERS} members")

            seen: set[str] = set()
            logical_members: list[tuple[str, zipfile.ZipInfo]] = []
            checksum_members: list[zipfile.ZipInfo] = []
            total_size = 0
            for info in infos:
                name = normalized_name(info)
                if name in seen:
                    raise ValidationError(f"ZIP contains a duplicate member: {name!r}")
                seen.add(name)
                if info.is_dir():
                    continue
                if not is_regular_file(info):
                    raise ValidationError(f"ZIP member must be a regular file: {name!r}")
                if info.file_size < 0 or info.file_size > max_member_bytes:
                    raise ValidationError(f"ZIP member exceeds the configured size limit: {name!r}")
                total_size += info.file_size
                if total_size > max_total_bytes:
                    raise ValidationError("ZIP members exceed the configured total-size limit")
                if name.lower().endswith((".dump", ".sql")):
                    logical_members.append((name, info))
                if PurePosixPath(name).name == "SHA256SUMS":
                    checksum_members.append(info)

            if len(logical_members) != 1:
                raise ValidationError("ZIP must contain exactly one .dump or .sql member")
            if len(checksum_members) != 1:
                raise ValidationError("ZIP must contain exactly one SHA256SUMS member")

            member_name, logical_info = logical_members[0]
            checksum_info = checksum_members[0]
            if checksum_info.file_size > MAX_CHECKSUM_BYTES:
                raise ValidationError("SHA256SUMS exceeds its safety limit")
            expected = parse_expected_checksum(source_zip.read(checksum_info), member_name)

            kind = "dump" if member_name.lower().endswith(".dump") else "sql"
            output_path = destination / f"restore.{kind}"
            digest = hashlib.sha256()
            copied = 0
            with source_zip.open(logical_info) as source, output_path.open("xb") as output:
                while True:
                    chunk = source.read(1024 * 1024)
                    if not chunk:
                        break
                    copied += len(chunk)
                    if copied > max_member_bytes:
                        raise ValidationError("logical backup member exceeded its declared safety limit")
                    digest.update(chunk)
                    output.write(chunk)
            output_path.chmod(0o600)
            if copied != logical_info.file_size:
                raise ValidationError("logical backup member size did not match the ZIP metadata")
            if digest.hexdigest() != expected:
                raise ValidationError("logical backup member checksum verification failed")
            return kind, output_path
    except (OSError, RuntimeError, zipfile.BadZipFile, zipfile.LargeZipFile) as exc:
        if isinstance(exc, ValidationError):
            raise
        raise ValidationError(f"could not validate logical backup ZIP: {exc}") from exc


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--max-member-bytes", type=int, required=True)
    parser.add_argument("--max-total-bytes", type=int, required=True)
    args = parser.parse_args()

    os.umask(0o077)
    if not args.archive.is_file():
        raise ValidationError(f"archive file not found: {args.archive}")
    kind, path = prepare_zip(
        args.archive,
        args.destination,
        max_member_bytes=args.max_member_bytes,
        max_total_bytes=args.max_total_bytes,
    )
    print(f"prepared_kind={kind}")
    print(f"prepared_file={path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValidationError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
