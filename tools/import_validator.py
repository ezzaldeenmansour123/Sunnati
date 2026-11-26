#!/usr/bin/env python3
"""SUNNATI admin import validation (Phases 7-8) — reference implementation.

Validates a JSON or CSV document submitted to the admin panel BEFORE it
is stored in `admin_staging`. A document that fails validation is refused
outright (never staged, never published); a document that passes is
staged as `pending_review` — validation is NOT approval.

Rules (mirrored in lib/data/import_validator.dart — keep in sync):
  * File caps: at most 10 MiB, at most 10,000 records, a single string
    field at most 200,000 chars. A bigger file is refused, not truncated.
  * The document must be UTF-8 JSON (object with `kind` + `records`) or
    CSV (header row + data rows). `kind` is one of
    book | commentary | narrator | grade | source.
  * Every record must carry a non-empty `source`. A record without a
    source is unreviewable and is refused.
  * Required fields per kind (see REQUIRED_FIELDS). Unknown fields are
    refused (a typo must not silently become a new column).
  * Identifiers are strict: book `id` ^[a-z0-9][a-z0-9_-]{0,63}$,
    `hadith_key` ^[a-z0-9_]+:\\d+$.
  * Duplicate keys inside one file are refused (same kind + same
    identity key, compared on the Arabic-normalised form).
  * Suspicious content is refused, never executed or stored raw:
      - NUL bytes anywhere; non-string scalar where a string is required.
      - Path-like fields (`file`, `path`, `url` starting with `/`,
        containing `..`, a drive letter or a backslash).
      - Shell/command fragments in any string: `$(`, backtick, `;` + a
        command word is NOT blanket-refused (Arabic text legitimately
        contains `;`), but `$(`, backticks, `${`, newlines inside
        identifier fields, and leading `=`/`+`/`-`/`@` in CSV cells
        (spreadsheet-formula injection) are refused.
      - A `license` field that is empty when the kind needs one
        (book/source) — unlicensed content cannot be redistributed.
  * Validation never touches the production tables and never runs
    anything from the file: it only reads and checks.
"""
from __future__ import annotations

import csv
import io
import json
import re

MAX_FILE_BYTES = 10 * 1024 * 1024
MAX_RECORDS = 10_000
MAX_FIELD_CHARS = 200_000

KINDS = ("book", "commentary", "narrator", "grade", "source")

REQUIRED_FIELDS: dict[str, list[str]] = {
    "book": ["id", "name", "author", "source", "license"],
    "commentary": ["hadith_key", "text", "source"],
    "narrator": ["name", "source"],
    "grade": ["hadith_key", "grader", "grade", "source"],
    "source": ["name", "license"],
}

OPTIONAL_FIELDS: dict[str, list[str]] = {
    "book": ["short", "sort"],
    "commentary": ["title", "grade", "grader"],
    "narrator": ["kunya", "tier", "death_hijri", "status", "status_src",
                 "bio_src"],
    "grade": ["grade_raw", "grade_kind"],
    "source": ["type", "url", "notes"],
}

ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
HADITH_KEY_RE = re.compile(r"^[a-z0-9_]+:\d+$")
_DIACRITICS = "ًٌٍَُِّْٰٓـ"
_SHELL_FRAGMENTS = ("$(", "`", "${")


def normalize_arabic(text: str) -> str:
    """Mirror of lib/core/normalize.dart normalizeArabic (subset used
    for duplicate keys: diacritics + hamza/alef/teh unification)."""
    s = text
    for ch in _DIACRITICS:
        s = s.replace(ch, "")
    s = (s.replace("أ", "ا").replace("إ", "ا").replace("آ", "ا")
          .replace("ؤ", "و").replace("ئ", "ي").replace("ى", "ي")
          .replace("ة", "ه"))
    s = re.sub(r"[^\u0621-\u064a\u0660-\u0669\u06f0-\u06f90-9\s]", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def identity_key(kind: str, record: dict) -> str:
    if kind == "book":
        return f"book:{record.get('id', '')}"
    if kind in ("commentary", "grade"):
        return f"{kind}:{record.get('hadith_key', '')}"
    if kind == "narrator":
        return "narrator:" + normalize_arabic(str(record.get("name", "")))
    if kind == "source":
        return "source:" + normalize_arabic(str(record.get("name", "")))
    return f"{kind}:?"


def _check_string_field(errors: list[str], where: str, value: object,
                        *, allow_newlines: bool) -> None:
    if not isinstance(value, str):
        errors.append(f"{where}: must be a string")
        return
    if len(value) > MAX_FIELD_CHARS:
        errors.append(f"{where}: exceeds {MAX_FIELD_CHARS} characters")
    if "\x00" in value:
        errors.append(f"{where}: contains NUL byte")
    if not allow_newlines and ("\n" in value or "\r" in value):
        errors.append(f"{where}: newlines not allowed in this field")
    for frag in _SHELL_FRAGMENTS:
        if frag in value:
            errors.append(f"{where}: contains forbidden fragment {frag!r}")
            break


def _check_path_field(errors: list[str], where: str, value: object) -> None:
    if not isinstance(value, str):
        errors.append(f"{where}: must be a string")
        return
    if (value.startswith("/") or value.startswith("\\") or ".." in value
            or "\\" in value or re.match(r"^[A-Za-z]:", value)):
        errors.append(f"{where}: unsafe path {value!r}")


def validate_record(kind: str, record: dict, index: int) -> list[str]:
    """Validate one record. Returns its errors (empty = valid)."""
    errors: list[str] = []
    where = f"records[{index}]"
    if not isinstance(record, dict):
        return [f"{where}: not an object"]
    allowed = set(REQUIRED_FIELDS[kind]) | set(OPTIONAL_FIELDS[kind])
    for key in record:
        if key not in allowed:
            errors.append(f"{where}: unknown field {key!r}")
    for field in REQUIRED_FIELDS[kind]:
        value = record.get(field)
        if value is None or (isinstance(value, str) and not value.strip()):
            errors.append(f"{where}: missing required field {field!r}")
    for field, value in record.items():
        if field in ("text", "notes", "definition"):
            _check_string_field(errors, f"{where}.{field}", value,
                                allow_newlines=True)
        elif field in ("file", "path"):
            _check_path_field(errors, f"{where}.{field}", value)
        elif field == "url":
            _check_string_field(errors, f"{where}.{field}", value,
                                allow_newlines=False)
            if isinstance(value, str) and value and not (
                    value.startswith("http://")
                    or value.startswith("https://")):
                errors.append(f"{where}.url: must start with http(s)://")
        elif isinstance(value, str):
            _check_string_field(errors, f"{where}.{field}", value,
                                allow_newlines=False)
        elif isinstance(value, (int, float)) and not isinstance(value, bool):
            pass  # numeric fields (sort, death_hijri) are fine as-is
        elif value is not None:
            errors.append(f"{where}.{field}: unsupported value type")
    if kind == "book":
        book_id = record.get("id")
        if isinstance(book_id, str) and not ID_RE.match(book_id):
            errors.append(f"{where}.id: malformed book id {book_id!r}")
    if kind in ("commentary", "grade"):
        key = record.get("hadith_key")
        if isinstance(key, str) and not HADITH_KEY_RE.match(key):
            errors.append(f"{where}.hadith_key: malformed {key!r}")
    if kind == "narrator" and record.get("status"):
        if not record.get("status_src"):
            errors.append(
                f"{where}: a narrator status without status_src is refused")
    return errors


def validate_document(kind: str, records: list) -> dict:
    """Validate a parsed (kind, records) pair. Returns a report dict:
    {"ok": bool, "errors": [...], "warnings": [...], "record_count": n,
     "kind": kind}."""
    errors: list[str] = []
    warnings: list[str] = []
    if kind not in KINDS:
        return {"ok": False, "errors": [f"unknown kind {kind!r}"],
                "warnings": [], "record_count": 0, "kind": kind}
    if not isinstance(records, list):
        return {"ok": False, "errors": ["records must be a list"],
                "warnings": [], "record_count": 0, "kind": kind}
    if not records:
        errors.append("records is empty")
    if len(records) > MAX_RECORDS:
        errors.append(f"more than {MAX_RECORDS} records")
    seen: set[str] = set()
    for i, record in enumerate(records):
        errors.extend(validate_record(kind, record, i))
        if isinstance(record, dict):
            key = identity_key(kind, record)
            if key in seen:
                errors.append(f"records[{i}]: duplicate identity {key!r}")
            seen.add(key)
    return {"ok": not errors, "errors": errors, "warnings": warnings,
            "record_count": len(records), "kind": kind}


def validate_json_bytes(data: bytes) -> dict:
    """Validate a JSON import document (bytes)."""
    if len(data) > MAX_FILE_BYTES:
        return {"ok": False,
                "errors": [f"file exceeds {MAX_FILE_BYTES} bytes"],
                "warnings": [], "record_count": 0, "kind": ""}
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as e:
        return {"ok": False, "errors": [f"not valid UTF-8: {e}"],
                "warnings": [], "record_count": 0, "kind": ""}
    if "\x00" in text:
        return {"ok": False, "errors": ["document contains NUL byte"],
                "warnings": [], "record_count": 0, "kind": ""}
    try:
        doc = json.loads(text)
    except json.JSONDecodeError as e:
        return {"ok": False, "errors": [f"not valid JSON: {e}"],
                "warnings": [], "record_count": 0, "kind": ""}
    if not isinstance(doc, dict):
        return {"ok": False, "errors": ["document must be a JSON object"],
                "warnings": [], "record_count": 0, "kind": ""}
    if set(doc.keys()) - {"kind", "records", "source"}:
        return {"ok": False,
                "errors": [f"unknown top-level keys: "
                           f"{sorted(set(doc) - {'kind', 'records', 'source'})}"],
                "warnings": [], "record_count": 0, "kind": ""}
    return validate_document(doc.get("kind", ""), doc.get("records", []))


def validate_csv_text(text: str, kind: str) -> dict:
    """Validate a CSV import document (text). First row is the header;
    it must list exactly the allowed columns for `kind` (required +
    optional, any order, no extras)."""
    if len(text.encode("utf-8")) > MAX_FILE_BYTES:
        return {"ok": False,
                "errors": [f"file exceeds {MAX_FILE_BYTES} bytes"],
                "warnings": [], "record_count": 0, "kind": kind}
    if "\x00" in text:
        return {"ok": False, "errors": ["document contains NUL byte"],
                "warnings": [], "record_count": 0, "kind": kind}
    try:
        rows = list(csv.reader(io.StringIO(text)))
    except csv.Error as e:
        return {"ok": False, "errors": [f"not valid CSV: {e}"],
                "warnings": [], "record_count": 0, "kind": kind}
    if not rows:
        return {"ok": False, "errors": ["CSV is empty"],
                "warnings": [], "record_count": 0, "kind": kind}
    if kind not in KINDS:
        return {"ok": False, "errors": [f"unknown kind {kind!r}"],
                "warnings": [], "record_count": 0, "kind": kind}
    header = [h.strip() for h in rows[0]]
    allowed = set(REQUIRED_FIELDS[kind]) | set(OPTIONAL_FIELDS[kind])
    if set(header) - allowed:
        return {"ok": False,
                "errors": [f"unknown CSV columns: "
                           f"{sorted(set(header) - allowed)}"],
                "warnings": [], "record_count": 0, "kind": kind}
    if missing := [f for f in REQUIRED_FIELDS[kind] if f not in header]:
        return {"ok": False,
                "errors": [f"missing required CSV columns: {missing}"],
                "warnings": [], "record_count": 0, "kind": kind}
    errors: list[str] = []
    records: list[dict] = []
    for lineno, row in enumerate(rows[1:], start=2):
        if not row or all(not c.strip() for c in row):
            continue  # blank line
        if len(row) != len(header):
            errors.append(f"line {lineno}: {len(row)} cells, "
                          f"expected {len(header)}")
            continue
        for col, cell in zip(header, row):
            if cell[:1] in ("=", "+", "-", "@"):
                errors.append(
                    f"line {lineno}, column {col!r}: formula-like cell "
                    f"refused (starts with {cell[:1]!r})")
        records.append(dict(zip(header, row)))
    if errors:
        return {"ok": False, "errors": errors, "warnings": [],
                "record_count": len(records), "kind": kind}
    report = validate_document(kind, records)
    return report
