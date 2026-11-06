"""Fail-closed audit that Source regression does not modify its input tree.

The Candidate builder binds an exact prepared-source fingerprint.  Tests may
create transient bytecode caches, but after those are removed the actual Source
files must be byte-for-byte identical to the pre-test snapshot.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def eligible(path: Path, root: Path) -> bool:
    rel = path.relative_to(root)
    if "__pycache__" in rel.parts:
        return False
    if path.suffix.lower() in {".pyc", ".pyo"}:
        return False
    return path.is_file()


def snapshot(root: Path) -> dict:
    root = root.resolve()
    files = {}
    for path in sorted(root.rglob("*"), key=lambda p: p.as_posix().casefold()):
        if not eligible(path, root):
            continue
        rel = path.relative_to(root).as_posix()
        files[rel] = {"size": path.stat().st_size, "sha256": sha256(path)}
    rows = [
        f"{rel}\t{record['size']}\t{record['sha256']}"
        for rel, record in sorted(files.items())
    ]
    fingerprint = hashlib.sha256("\n".join(rows).encode("utf-8")).hexdigest()
    return {"schema_version": 1, "root": str(root), "fingerprint": fingerprint, "files": files}


def compare(before: dict, after: dict) -> dict:
    a = before.get("files") or {}
    b = after.get("files") or {}
    added = sorted(set(b) - set(a))
    removed = sorted(set(a) - set(b))
    changed = sorted(
        name for name in set(a) & set(b)
        if a[name] != b[name]
    )
    return {
        "schema_version": 1,
        "status": "PASS" if not (added or removed or changed) else "FAIL",
        "before_fingerprint": before.get("fingerprint"),
        "after_fingerprint": after.get("fingerprint"),
        "added": added,
        "removed": removed,
        "changed": changed,
        "change_count": len(added) + len(removed) + len(changed),
    }


def write(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="command", required=True)
    s = sub.add_parser("snapshot")
    s.add_argument("--root", required=True)
    s.add_argument("--output", required=True)
    c = sub.add_parser("compare")
    c.add_argument("--root", required=True)
    c.add_argument("--before", required=True)
    c.add_argument("--output", required=True)
    args = ap.parse_args()

    root = Path(args.root)
    if args.command == "snapshot":
        value = snapshot(root)
        write(Path(args.output), value)
        print("SOURCE_TREE_SNAPSHOT=" + value["fingerprint"])
        return 0

    before = json.loads(Path(args.before).read_text(encoding="utf-8-sig"))
    after = snapshot(root)
    result = compare(before, after)
    write(Path(args.output), result)
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["status"] == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
