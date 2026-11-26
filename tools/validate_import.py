#!/usr/bin/env python3
"""Validate a SUNNATI admin import file (JSON or CSV) — desktop tool.

Prints the validation report and exits non-zero when the file is
refused. This is the same rule set the in-app admin panel enforces
(see tools/import_validator.py and lib/data/import_validator.dart).

Usage:
    python3 tools/validate_import.py --file import.json
    python3 tools/validate_import.py --file import.csv --kind narrator
    (JSON carries its own `kind`; CSV needs --kind.)
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from import_validator import validate_csv_text, validate_json_bytes  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--file", required=True)
    ap.add_argument("--kind", default="",
                    help="required for CSV; ignored for JSON")
    args = ap.parse_args()
    path = Path(args.file)
    if not path.is_file():
        print(f"not found: {path}", file=sys.stderr)
        return 2
    data = path.read_bytes()
    if path.suffix.lower() == ".json":
        report = validate_json_bytes(data)
    elif path.suffix.lower() == ".csv":
        if not args.kind:
            print("CSV needs --kind (book|commentary|narrator|grade|source)",
                  file=sys.stderr)
            return 2
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError as e:
            print(f"not valid UTF-8: {e}", file=sys.stderr)
            return 1
        report = validate_csv_text(text, args.kind)
    else:
        print("only .json and .csv are accepted", file=sys.stderr)
        return 2
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
