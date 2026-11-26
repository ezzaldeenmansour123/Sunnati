#!/usr/bin/env python3
"""Build a SUNNATI download package (admin desktop tool, Phase 7).

Creates <out>/<library_id>-<version>/ with manifest.json + the payload
SQLite file + LICENSE.txt, computing SHA-256 from the real files.

Refuses to build when any of these is missing: the payload file, the
licence text file, --source, --license. A package is never built for
unverified data — the caller (admin) asserts the payload was imported
and reviewed; the tool records the assertion in the manifest's
`created_at` and in the printed report, and the app re-verifies every
hash before installing.

Usage:
    python3 tools/build_package.py --db payload.db --library-id darqutni \\
        --name "سنن الدارقطني" --version 1.0.0 \\
        --source "verified-source-name" --license "ODbL-1.0" \\
        --license-file LICENSE.txt --out packages/
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from package_manifest import (build_manifest, sha256_file,  # noqa: E402
                              verify_package_files)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--db", required=True, help="payload SQLite file")
    ap.add_argument("--library-id", required=True)
    ap.add_argument("--name", required=True, help="Arabic display name")
    ap.add_argument("--version", required=True, help="semantic x.y.z")
    ap.add_argument("--source", required=True, help="source name")
    ap.add_argument("--license", required=True, help="licence identifier")
    ap.add_argument("--license-file", required=True,
                    help="verbatim licence text file")
    ap.add_argument("--license-url", default="")
    ap.add_argument("--out", required=True, help="output directory")
    args = ap.parse_args()

    db = Path(args.db)
    lic = Path(args.license_file)
    for path, label in ((db, "payload DB"), (lic, "licence file")):
        if not path.is_file():
            print(f"refused: {label} not found: {path}", file=sys.stderr)
            return 2
    if not args.source.strip() or not args.license.strip():
        print("refused: --source and --license are mandatory",
              file=sys.stderr)
        return 2

    out_dir = Path(args.out) / f"{args.library_id}-{args.version}"
    out_dir.mkdir(parents=True, exist_ok=True)
    db_name = f"{args.library_id}.db"
    shutil.copyfile(db, out_dir / db_name)
    shutil.copyfile(lic, out_dir / "LICENSE.txt")
    created_at = datetime.now(timezone.utc).isoformat()
    files = [
        {"path": db_name,
         "sha256": sha256_file(out_dir / db_name),
         "size_bytes": (out_dir / db_name).stat().st_size},
        {"path": "LICENSE.txt",
         "sha256": sha256_file(out_dir / "LICENSE.txt"),
         "size_bytes": (out_dir / "LICENSE.txt").stat().st_size},
    ]
    try:
        manifest = build_manifest(
            library_id=args.library_id, name=args.name,
            version=args.version, source=args.source,
            license_id=args.license, files=files, created_at=created_at,
            license_url=args.license_url)
    except ValueError as e:
        print(f"refused: {e}", file=sys.stderr)
        return 2
    (out_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2),
        encoding="utf-8")
    errors = verify_package_files(out_dir, manifest)
    if errors:
        print(f"verification failed: {errors}", file=sys.stderr)
        return 1
    print(f"package built: {out_dir}")
    print(f"  library: {args.library_id} {args.version} "
          f"({manifest['total_bytes']} bytes)")
    print(f"  source: {args.source} | license: {args.license}")
    print("  verified: all file hashes match the manifest")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
