#!/usr/bin/env python3
"""SUNNATI download-package format (Phase 7) — reference implementation.

A downloadable extended-library package is a directory:

    <library_id>-<version>/
      manifest.json        # this spec, format version 1
      <library_id>.db      # SQLite library fragment (tables per SCHEMA)
      LICENSE.txt          # verbatim licence text of the source

`manifest.json` fields (all required unless noted):

    format          "sunnati-package" (constant)
    format_version  1
    library_id      stable id, ^[a-z0-9][a-z0-9_-]{0,63}$
    name            Arabic display name
    version         e.g. "1.0.0"
    source          source name, e.g. "quranlab/hadith" — never empty
    license         licence identifier, e.g. "ODbL-1.0" — never empty
    license_url     (optional) canonical licence URL
    files           list of {"path", "sha256", "size_bytes"}; every file
                    listed must be present in the package and vice versa
    total_bytes     sum of files[].size_bytes
    created_at      ISO-8601 UTC timestamp
    min_app_version (optional) e.g. "1.0.0"

Rules (mirrored in lib/core/package_manifest.dart — keep in sync):
  * SHA-256 is 64 lowercase hex chars; the installer refuses a package
    whose manifest hash, file hash or total size disagrees.
  * `path` entries are relative, use `/`, never start with `/`, never
    contain `..`, a drive (`C:`) or a backslash — a package must not be
    able to write outside its own directory (path-traversal guard).
  * Allowed file extensions: `.db`, `.json`, `.txt`, `.md`.
  * No package is ever created for an extended library whose data has
    not been imported and verified (see lib/core/extended_library.dart):
    this module validates a manifest; it does not invent one.
"""
from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

FORMAT = "sunnati-package"
FORMAT_VERSION = 1
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
LIBRARY_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")
ALLOWED_EXTENSIONS = {".db", ".json", ".txt", ".md"}
MAX_TOTAL_BYTES = 2 * 1024 * 1024 * 1024  # 2 GiB — a package bigger than
# this is refused; it must be split or flagged to the owner first.


def is_safe_package_path(path: str) -> bool:
    """True iff `path` is a safe relative path inside the package."""
    if not path or path.startswith("/") or path.startswith("\\"):
        return False
    if "\\" in path or "\x00" in path:
        return False
    if re.search(r"^[A-Za-z]:", path):
        return False
    parts = path.split("/")
    if any(p in ("", ".", "..") for p in parts):
        return False
    if Path(path).suffix.lower() not in ALLOWED_EXTENSIONS:
        return False
    return True


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def validate_manifest(manifest: dict) -> list[str]:
    """Return the list of validation errors (empty = valid)."""
    errors: list[str] = []
    if not isinstance(manifest, dict):
        return ["manifest is not a JSON object"]
    if manifest.get("format") != FORMAT:
        errors.append(f"format must be '{FORMAT}'")
    if manifest.get("format_version") != FORMAT_VERSION:
        errors.append(f"format_version must be {FORMAT_VERSION}")
    lib_id = manifest.get("library_id")
    if not isinstance(lib_id, str) or not LIBRARY_ID_RE.match(lib_id):
        errors.append("library_id is missing or malformed")
    if not isinstance(manifest.get("name"), str) or not manifest["name"].strip():
        errors.append("name is missing or empty")
    version = manifest.get("version")
    if not isinstance(version, str) or not VERSION_RE.match(version):
        errors.append("version must be semantic (x.y.z)")
    if not isinstance(manifest.get("source"), str) or not manifest["source"].strip():
        errors.append("source is missing or empty")
    if not isinstance(manifest.get("license"), str) or not manifest["license"].strip():
        errors.append("license is missing or empty")
    files = manifest.get("files")
    if not isinstance(files, list) or not files:
        errors.append("files must be a non-empty list")
        return errors
    total = 0
    seen: set[str] = set()
    for entry in files:
        if not isinstance(entry, dict):
            errors.append("files[] entry is not an object")
            continue
        path = entry.get("path")
        if not isinstance(path, str) or not is_safe_package_path(path):
            errors.append(f"unsafe file path: {path!r}")
            continue
        if path in seen:
            errors.append(f"duplicate file path: {path!r}")
        seen.add(path)
        sha = entry.get("sha256")
        if not isinstance(sha, str) or not SHA256_RE.match(sha):
            errors.append(f"bad sha256 for {path!r}")
        size = entry.get("size_bytes")
        if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
            errors.append(f"bad size_bytes for {path!r}")
        else:
            total += size
    declared = manifest.get("total_bytes")
    if not isinstance(declared, int) or isinstance(declared, bool) or declared <= 0:
        errors.append("total_bytes is missing or not a positive integer")
    elif declared != total:
        errors.append(
            f"total_bytes ({declared}) != sum of files ({total})")
    if total > MAX_TOTAL_BYTES:
        errors.append(f"total_bytes exceeds the {MAX_TOTAL_BYTES} cap")
    created = manifest.get("created_at")
    if not isinstance(created, str) or not created.strip():
        errors.append("created_at is missing or empty")
    return errors


def build_manifest(*, library_id: str, name: str, version: str,
                   source: str, license_id: str, files: list[dict],
                   created_at: str, license_url: str = "",
                   min_app_version: str = "") -> dict:
    """Build a manifest dict from verified file entries.

    Callers must have computed each entry's sha256/size from the real
    file first (see build_package.py); this function only assembles and
    validates — it raises ValueError on any validation error.
    """
    manifest: dict = {
        "format": FORMAT,
        "format_version": FORMAT_VERSION,
        "library_id": library_id,
        "name": name,
        "version": version,
        "source": source,
        "license": license_id,
        "files": files,
        "total_bytes": sum(f["size_bytes"] for f in files),
        "created_at": created_at,
    }
    if license_url:
        manifest["license_url"] = license_url
    if min_app_version:
        manifest["min_app_version"] = min_app_version
    errors = validate_manifest(manifest)
    if errors:
        raise ValueError("; ".join(errors))
    return manifest


def load_manifest(path: Path) -> tuple[dict | None, list[str]]:
    """Load + validate a manifest file. Returns (manifest, errors)."""
    try:
        raw = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as e:
        return None, [f"cannot read manifest: {e}"]
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        return None, [f"manifest is not valid JSON: {e}"]
    errors = validate_manifest(data)
    if errors:
        return None, errors
    return data, []


def verify_package_files(package_dir: Path, manifest: dict) -> list[str]:
    """Check every listed file exists in `package_dir` with matching
    size + SHA-256, and that no unlisted payload file is present."""
    errors: list[str] = []
    listed = {f["path"] for f in manifest.get("files", [])}
    for entry in manifest.get("files", []):
        fpath = package_dir / entry["path"]
        if not fpath.is_file():
            errors.append(f"missing file: {entry['path']}")
            continue
        actual_size = fpath.stat().st_size
        if actual_size != entry["size_bytes"]:
            errors.append(
                f"size mismatch for {entry['path']}: manifest "
                f"{entry['size_bytes']}, actual {actual_size}")
            continue
        actual_sha = sha256_file(fpath)
        if actual_sha != entry["sha256"]:
            errors.append(f"sha256 mismatch for {entry['path']}")
    for found in sorted(package_dir.rglob("*")):
        if not found.is_file():
            continue
        rel = found.relative_to(package_dir).as_posix()
        if rel == "manifest.json":
            continue
        if rel not in listed:
            errors.append(f"unlisted file in package: {rel}")
    return errors
