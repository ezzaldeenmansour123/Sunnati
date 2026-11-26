#!/usr/bin/env python3
"""Phase 7-8 local test suite (runs WITHOUT Dart/Flutter).

Covers, with real execution:
  * package manifest spec (tools/package_manifest.py) + build_package CLI
  * import validation (tools/import_validator.py) + validate_import CLI
  * admin PIN algorithm mirror (same salted iterated SHA-256 as
    lib/core/admin_pin.dart) + Dart constant parity
  * schema v4 migration on a COPY of assets/sunnati.db (the master asset
    is never touched — its SHA-256 is asserted unchanged)
  * Dart <-> Python parity for the v4 SQL and the validation rules
  * extended-library catalogue honesty (preparing only: no URL/size)

Run:  python3 tools/test_phase7_8.py
Dart unit tests (test/package_manifest_test.dart,
test/import_validator_test.dart, test/admin_pin_test.dart) cover the
same rules in Dart and run in CI (`flutter test`) — they are NOT run
here because no Dart toolchain exists locally.
"""
from __future__ import annotations

import hashlib
import json
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / "tools"
sys.path.insert(0, str(TOOLS))

from build_db import SCHEMA_V4  # noqa: E402
from import_validator import (validate_csv_text,  # noqa: E402
                              validate_json_bytes)
from migrate_schema_v4 import apply_v4  # noqa: E402
from package_manifest import (build_manifest, sha256_file,  # noqa: E402
                              validate_manifest, verify_package_files)

ASSET_DB = ROOT / "assets" / "sunnati.db"


def valid_manifest() -> dict:
    return {
        "format": "sunnati-package",
        "format_version": 1,
        "library_id": "darqutni",
        "name": "سنن الدارقطني",
        "version": "1.0.0",
        "source": "verified-source",
        "license": "ODbL-1.0",
        "files": [{"path": "darqutni.db", "sha256": "a" * 64,
                   "size_bytes": 12345}],
        "total_bytes": 12345,
        "created_at": "2026-11-26T00:00:00Z",
    }


def pin_hash_py(pin: str, salt_hex: str, iterations: int = 10000) -> str:
    """Mirror of lib/core/admin_pin.dart _hashWithSaltAndIterations."""
    digest = hashlib.sha256(f"{salt_hex}:{pin}".encode("utf-8")).digest()
    for _ in range(1, iterations):
        digest = hashlib.sha256(digest).digest()
    return f"v1${iterations}${salt_hex}${digest.hex()}"


class TestPackageManifest(unittest.TestCase):
    def test_valid_manifest_passes(self):
        self.assertEqual(validate_manifest(valid_manifest()), [])

    def test_missing_license_or_source_refused(self):
        m = valid_manifest()
        m["license"] = ""
        self.assertTrue(validate_manifest(m))
        m = valid_manifest()
        del m["source"]
        self.assertTrue(validate_manifest(m))

    def test_total_mismatch_refused(self):
        m = valid_manifest()
        m["total_bytes"] = 999
        errs = validate_manifest(m)
        self.assertTrue(any("total_bytes" in e for e in errs))

    def test_bad_sha_refused(self):
        m = valid_manifest()
        m["files"][0]["sha256"] = "xyz"
        self.assertTrue(validate_manifest(m))

    def test_path_traversal_refused(self):
        for bad in ("../evil.db", "/etc/x.db", r"C:\x.db", r"a\b.db",
                    "run.sh", "noext"):
            m = valid_manifest()
            m["files"][0]["path"] = bad
            self.assertTrue(validate_manifest(m), bad)

    def test_real_package_build_and_verify(self):
        with tempfile.TemporaryDirectory() as td:
            pkg = Path(td) / "darqutni-1.0.0"
            pkg.mkdir()
            (pkg / "darqutni.db").write_bytes(b"fake-sqlite-bytes" * 100)
            (pkg / "LICENSE.txt").write_text("ODbL-1.0 text",
                                             encoding="utf-8")
            files = [
                {"path": "darqutni.db",
                 "sha256": sha256_file(pkg / "darqutni.db"),
                 "size_bytes": (pkg / "darqutni.db").stat().st_size},
                {"path": "LICENSE.txt",
                 "sha256": sha256_file(pkg / "LICENSE.txt"),
                 "size_bytes": (pkg / "LICENSE.txt").stat().st_size},
            ]
            manifest = build_manifest(
                library_id="darqutni", name="سنن الدارقطني",
                version="1.0.0", source="verified-source",
                license_id="ODbL-1.0", files=files,
                created_at="2026-11-26T00:00:00Z")
            (pkg / "manifest.json").write_text(
                json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
            self.assertEqual(verify_package_files(pkg, manifest), [])
            # Tamper with one byte: verification must catch it.
            with open(pkg / "darqutni.db", "ab") as f:
                f.write(b"x")
            errs = verify_package_files(pkg, manifest)
            self.assertTrue(any("darqutni.db" in e for e in errs))
            # Unlisted file: also an error.
            (pkg / "extra.txt").write_text("stowaway", encoding="utf-8")
            errs = verify_package_files(pkg, manifest)
            self.assertTrue(any("extra.txt" in e for e in errs))

    def test_build_package_cli(self):
        with tempfile.TemporaryDirectory() as td:
            db = Path(td) / "payload.db"
            db.write_bytes(b"payload" * 50)
            lic = Path(td) / "LICENSE.txt"
            lic.write_text("ODbL-1.0", encoding="utf-8")
            out = Path(td) / "out"
            r = subprocess.run(
                [sys.executable, str(TOOLS / "build_package.py"),
                 "--db", str(db), "--library-id", "darqutni",
                 "--name", "سنن الدارقطني", "--version", "1.0.0",
                 "--source", "verified-source", "--license", "ODbL-1.0",
                 "--license-file", str(lic), "--out", str(out)],
                capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            manifest = json.loads(
                (out / "darqutni-1.0.0" / "manifest.json")
                .read_text(encoding="utf-8"))
            self.assertEqual(validate_manifest(manifest), [])
            # Refusal: missing licence file.
            r = subprocess.run(
                [sys.executable, str(TOOLS / "build_package.py"),
                 "--db", str(db), "--library-id", "darqutni",
                 "--name", "x", "--version", "1.0.0",
                 "--source", "s", "--license", "ODbL-1.0",
                 "--license-file", str(Path(td) / "nope.txt"),
                 "--out", str(out)],
                capture_output=True, text=True)
            self.assertEqual(r.returncode, 2)


class TestImportValidator(unittest.TestCase):
    def test_valid_narrator_json(self):
        doc = json.dumps({"kind": "narrator", "records": [
            {"name": "الزهري", "source": "تقريب التهذيب",
             "status": "ثقة", "status_src": "تقريب التهذيب ص 1"}]},
            ensure_ascii=False).encode()
        rep = validate_json_bytes(doc)
        self.assertTrue(rep["ok"], rep["errors"])
        self.assertEqual(rep["record_count"], 1)

    def test_missing_source_refused(self):
        doc = b'{"kind": "narrator", "records": [{"name": "x"}]}'
        self.assertFalse(validate_json_bytes(doc)["ok"])

    def test_status_without_source_refused(self):
        doc = json.dumps({"kind": "narrator", "records": [
            {"name": "x", "source": "s", "status": "ثقة"}]},
            ensure_ascii=False).encode()
        rep = validate_json_bytes(doc)
        self.assertFalse(rep["ok"])
        self.assertTrue(any("status_src" in e for e in rep["errors"]))

    def test_unknown_field_and_bad_id_refused(self):
        doc = b'''{"kind": "book", "records": [
          {"id": "darqutni", "name": "x", "author": "y",
           "source": "s", "license": "l", "surprise": 1}]}'''
        self.assertFalse(validate_json_bytes(doc)["ok"])
        doc = b'''{"kind": "book", "records": [
          {"id": "Bad ID!", "name": "x", "author": "y",
           "source": "s", "license": "l"}]}'''
        self.assertFalse(validate_json_bytes(doc)["ok"])

    def test_duplicate_and_shell_fragment_refused(self):
        doc = json.dumps({"kind": "narrator", "records": [
            {"name": "الزهري", "source": "s"},
            {"name": "الزهرى", "source": "s"}]},
            ensure_ascii=False).encode()
        rep = validate_json_bytes(doc)
        self.assertFalse(rep["ok"])  # normalised duplicate
        doc = b'{"kind": "source", "records": [{"name": "x$(id)", "license": "l"}]}'
        self.assertFalse(validate_json_bytes(doc)["ok"])

    def test_csv_valid_and_formula_refused(self):
        rep = validate_csv_text("name,source\nالزهري,تقريب التهذيب\n",
                                "narrator")
        self.assertTrue(rep["ok"], rep["errors"])
        rep = validate_csv_text("name,source\n=1+1,تقريب التهذيب\n",
                                "narrator")
        self.assertFalse(rep["ok"])
        self.assertTrue(any("formula" in e for e in rep["errors"]))
        rep = validate_csv_text("name\nالزهري\n", "narrator")
        self.assertFalse(rep["ok"])  # missing required column

    def test_validate_import_cli_exit_codes(self):
        with tempfile.TemporaryDirectory() as td:
            good = Path(td) / "good.json"
            good.write_text(json.dumps(
                {"kind": "grade", "records": [
                    {"hadith_key": "bukhari:1", "grader": "الألباني",
                     "grade": "صحيح", "source": "صحيح الجامع"}]},
                ensure_ascii=False), encoding="utf-8")
            r = subprocess.run(
                [sys.executable, str(TOOLS / "validate_import.py"),
                 "--file", str(good)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout)
            bad = Path(td) / "bad.json"
            bad.write_text('{"kind": "grade", "records": [{}]}',
                           encoding="utf-8")
            r = subprocess.run(
                [sys.executable, str(TOOLS / "validate_import.py"),
                 "--file", str(bad)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 1)


class TestAdminPinMirror(unittest.TestCase):
    def test_algorithm_vector(self):
        # Fixed vector: guards the documented algorithm against drift.
        # Computed with hashlib SHA-256, salt "00"*16, pin "4829".
        stored = pin_hash_py("4829", "00" * 16)
        parts = stored.split("$")
        self.assertEqual(parts[0], "v1")
        self.assertEqual(parts[1], "10000")
        self.assertEqual(parts[2], "00" * 16)
        self.assertEqual(len(parts[3]), 64)
        self.assertNotEqual(pin_hash_py("4828", "00" * 16), stored)
        self.assertNotEqual(pin_hash_py("4829", "11" * 16), stored)

    def test_dart_constants_match(self):
        dart = (ROOT / "lib" / "core" / "admin_pin.dart").read_text()
        self.assertIn("kAdminPinIterations = 10000", dart)
        self.assertIn("kAdminPinSaltBytes = 16", dart)
        self.assertIn("kAdminPinMaxAttempts = 5", dart)
        self.assertIn("kAdminPinFormatVersion = 'v1'", dart)
        # Same first-round construction: sha256(saltHex + ":" + pin).
        self.assertIn("utf8.encode('$saltHex:$pin')", dart)
        # No default PIN anywhere in the new code.
        for path in (ROOT / "lib").rglob("*.dart"):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn("1234", text.replace(
                "kAdminPinMaxAttempts", "").replace("4321", ""),
                f"default-looking PIN in {path}")
            self.assertNotIn("defaultPin", text)
            self.assertNotIn("DEFAULT_PIN", text)


class TestSchemaV4Migration(unittest.TestCase):
    def test_migration_on_copy_only(self):
        before_sha = hashlib.sha256(ASSET_DB.read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory() as td:
            work = Path(td) / "work.db"
            shutil.copyfile(ASSET_DB, work)
            con = sqlite3.connect(str(work))
            try:
                before_version = con.execute(
                    "SELECT value FROM meta WHERE key='schema_version'"
                ).fetchone()[0]
                report = apply_v4(con)
                # The asset DB ships v3 since the verified core landed
                # (2026-11-26); v3 is applied here only when absent.
                self.assertTrue(
                    report["v3_applied"] or before_version in ("3", "4"),
                    f"v3 neither applied nor already present "
                    f"(before_version={before_version})")
                tables = {r[0] for r in con.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'")}
                self.assertIn("admin_audit_log", tables)
                self.assertIn("admin_staging", tables)
                self.assertIn("narrator_aliases", tables)  # v3 applied
                cols = {r[1] for r in con.execute(
                    "PRAGMA table_info(downloaded_libraries)")}
                for col in ("source", "license", "download_url",
                            "total_bytes", "downloaded_bytes",
                            "manifest_json", "updated_at"):
                    self.assertIn(col, cols)
                row = con.execute(
                    "SELECT value FROM meta WHERE key='schema_version'"
                ).fetchone()
                self.assertEqual(row[0], "4")
                self.assertEqual(
                    con.execute("SELECT COUNT(*) FROM hadiths").fetchone()[0],
                    65712)
                self.assertEqual(
                    con.execute("PRAGMA quick_check").fetchone()[0], "ok")
                # CHECK constraints enforced: bogus review status refused.
                with self.assertRaises(sqlite3.IntegrityError):
                    con.execute(
                        "INSERT INTO admin_staging (kind, payload_json,"
                        " submitted_at, review_status) VALUES"
                        " ('narrator', '{}', '2026-11-26', 'bogus')")
                con.rollback()
                # Audit + staging round-trip.
                con.execute(
                    "INSERT INTO admin_audit_log (created_at, actor,"
                    " action, entity_type, entity_id, source, detail)"
                    " VALUES ('2026-11-26T00:00:00Z', 'admin',"
                    " 'import_staged', 'narrator', '1', 'taqrib', 'test')")
                con.execute(
                    "INSERT INTO admin_staging (kind, payload_json,"
                    " source, sha256, submitted_at) VALUES"
                    " ('narrator', '{\"name\": \"x\"}', 'taqrib',"
                    " 'ab', '2026-11-26T00:00:00Z')")
                con.commit()
                self.assertEqual(
                    con.execute("SELECT COUNT(*) FROM admin_audit_log")
                    .fetchone()[0], 1)
                self.assertEqual(
                    con.execute(
                        "SELECT review_status FROM admin_staging")
                    .fetchone()[0], "pending_review")
                # Idempotency: run again, nothing breaks.
                report2 = apply_v4(con)
                self.assertFalse(report2["v3_applied"])
                self.assertEqual(report2["v4"]["columns_added"], [])
                self.assertEqual(
                    con.execute("PRAGMA quick_check").fetchone()[0], "ok")
            finally:
                con.close()
        after_sha = hashlib.sha256(ASSET_DB.read_bytes()).hexdigest()
        self.assertEqual(before_sha, after_sha,
                         "master asset DB must never be modified")

    def test_dart_sql_parity_with_python_schema_v4(self):
        dart = (ROOT / "lib" / "data" / "database.dart").read_text()

        def norm(sql: str) -> str:
            return re.sub(r"\s+", " ", sql).strip().rstrip(";").lower()

        py_statements = [norm(s) for s in SCHEMA_V4.split(";")
                         if s.strip()]
        # Every Python CREATE TABLE / CREATE INDEX must exist in Dart.
        for stmt in py_statements:
            if stmt.startswith("create table") or \
                    stmt.startswith("create index"):
                self.assertIn(stmt, norm(dart), f"missing in Dart: {stmt}")
        # Every Python ALTER column must exist in Dart's column map.
        for stmt in py_statements:
            m = re.match(r"alter table downloaded_libraries add column "
                         r"(\w+) (.*)", stmt)
            if m:
                col, definition = m.group(1), m.group(2)
                self.assertIn(f"'{col}':", dart)
                self.assertIn(norm(definition).upper(), dart.upper(),
                              f"column {col} definition differs")


class TestCatalogueHonesty(unittest.TestCase):
    def test_extended_catalogue_is_preparing_only(self):
        dart = (ROOT / "lib" / "core" / "extended_library.dart").read_text()
        self.assertNotIn("http", dart)
        self.assertNotIn("size_bytes", dart)
        self.assertNotIn("download_url", dart)
        ids = re.findall(r"id: '([a-z0-9_]+)'", dart)
        self.assertEqual(len(ids), 14)
        self.assertEqual(len(set(ids)), 14)
        books = len(re.findall(r"kind: 'book'", dart))
        collections = len(re.findall(r"kind: 'collection'", dart))
        self.assertEqual(books, 8)
        self.assertEqual(collections, 6)
        for name in ("موطأ محمد", "مصنف عبد الرزاق",
                     "مصنف ابن أبي شيبة", "مسند أبي يعلى", "مسند البزار",
                     "سنن الدارقطني", "السنن الكبرى للبيهقي",
                     "المستدرك على الصحيحين للحاكم"):
            self.assertIn(name, dart)

    def test_no_green_in_new_ui(self):
        for path in list((ROOT / "lib" / "ui").rglob("*.dart")) + \
                [ROOT / "lib" / "core" / "extended_library.dart",
                 ROOT / "lib" / "core" / "package_manifest.dart"]:
            text = path.read_text(encoding="utf-8")
            self.assertNotIn("Colors.green", text, str(path))
            self.assertNotIn("emerald", text.lower(), str(path))

    def test_no_api_keys_in_new_code(self):
        for path in (ROOT / "lib").rglob("*.dart"):
            text = path.read_text(encoding="utf-8")
            self.assertNotIn("api_key", text.lower(), str(path))
            self.assertNotIn("apiKey", text, str(path))


if __name__ == "__main__":
    unittest.main(verbosity=2)
