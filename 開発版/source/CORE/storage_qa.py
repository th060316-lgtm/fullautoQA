"""Generic declared-storage inspector / checker for FullAutoQA.

Inspects only safely resolved declared locations.
Rejects path escape.
Snapshots file set, size and SHA-256.
Detects addition, removal and modification.
Supports generic save/load persistence comparison.
Makes no engine-specific assumption.
Does not require undeclared access outside the isolated run/user area.
Missing / unobservable storage remains explicit NOT_RUN / non-PASS.
Modifying a source file is never treated as evidence that save/load worked.
"""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple


class StorageQAError(Exception):
    """Base for storage QA failures (path escape, missing root, etc.)."""
    pass


class PathEscapeError(StorageQAError):
    pass


class StorageUnavailable(StorageQAError):
    """Raised when declared storage cannot be observed; caller maps to NOT_RUN."""
    pass


def _sha256_file(path: Path, chunk_size: int = 65536) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def safe_resolve(root: Path, declared: str | Path) -> Path:
    """Resolve declared path under root; reject any escape outside root.

    root must exist and be a directory. declared may be relative or absolute;
    the final resolved path must be inside root (or equal to root).
    """
    root = Path(root).resolve()
    if not root.is_dir():
        raise StorageUnavailable(f"STORAGE_ROOT_UNAVAILABLE:{root}")

    cand = Path(declared)
    if not cand.is_absolute():
        cand = (root / cand).resolve()
    else:
        cand = cand.resolve()

    try:
        cand.relative_to(root)
    except ValueError:
        raise PathEscapeError(f"STORAGE_PATH_ESCAPE:{declared}-> {cand} not under {root}")
    return cand


class StorageSnapshot:
    """Immutable snapshot of a set of files: relpath -> (size, sha256)."""

    __slots__ = ("root", "files", "timestamp_note")

    def __init__(self, root: Path, files: Dict[str, Tuple[int, str]], timestamp_note: str = ""):
        self.root = Path(root)
        self.files = dict(files)  # relpath (posix) -> (size, sha256)
        self.timestamp_note = timestamp_note  # never used as reward signal

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, StorageSnapshot):
            return False
        return self.files == other.files

    def __repr__(self) -> str:
        return f"StorageSnapshot(root={self.root!s}, n={len(self.files)})"

    def paths(self) -> Set[str]:
        return set(self.files.keys())

    def to_dict(self) -> dict:
        return {
            "root": str(self.root),
            "files": {k: {"size": v[0], "sha256": v[1]} for k, v in sorted(self.files.items())},
            "note": self.timestamp_note,
        }


class StorageDiff:
    __slots__ = ("added", "removed", "modified", "unchanged")

    def __init__(
        self,
        added: Set[str],
        removed: Set[str],
        modified: Set[str],
        unchanged: Set[str],
    ):
        self.added = set(added)
        self.removed = set(removed)
        self.modified = set(modified)
        self.unchanged = set(unchanged)

    @property
    def changed(self) -> bool:
        return bool(self.added or self.removed or self.modified)

    def to_dict(self) -> dict:
        return {
            "added": sorted(self.added),
            "removed": sorted(self.removed),
            "modified": sorted(self.modified),
            "unchanged": sorted(self.unchanged),
            "changed": self.changed,
        }


def diff_snapshots(before: StorageSnapshot, after: StorageSnapshot) -> StorageDiff:
    b = before.files
    a = after.files
    added = set(a) - set(b)
    removed = set(b) - set(a)
    common = set(a) & set(b)
    modified = {p for p in common if a[p] != b[p]}
    unchanged = common - modified
    return StorageDiff(added, removed, modified, unchanged)


class StorageInspector:
    """Generic inspector bound to an isolated root and a list of declared locations.

    declared_locations: list of relative paths or globs under root that the
    profile declares as the game's save / config / user data area.
    Only those locations (and their descendants when directories) are examined.
    """

    def __init__(self, root: str | Path, declared_locations: List[str] | None = None):
        self.root = Path(root).resolve()
        if not self.root.is_dir():
            raise StorageUnavailable(f"STORAGE_ROOT_UNAVAILABLE:{self.root}")
        self.declared = list(declared_locations or [])
        self._validated_paths: List[Path] = []
        for d in self.declared:
            # Validate each declared entry up-front for escape.
            # Directories are allowed; we will walk them later.
            p = safe_resolve(self.root, d)
            self._validated_paths.append(p)

    def _collect_files(self) -> Dict[str, Tuple[int, str]]:
        """Walk validated locations and return relpath -> (size, sha256)."""
        out: Dict[str, Tuple[int, str]] = {}
        if not self._validated_paths:
            # No declared locations => unobservable
            raise StorageUnavailable("STORAGE_NO_DECLARED_LOCATIONS")

        for base in self._validated_paths:
            if not base.exists():
                # Declared but missing is observable as empty; do not raise here.
                continue
            if base.is_file():
                try:
                    rel = base.relative_to(self.root).as_posix()
                    out[rel] = (base.stat().st_size, _sha256_file(base))
                except OSError:
                    raise StorageUnavailable(f"STORAGE_UNREADABLE:{base}")
            elif base.is_dir():
                for dirpath, _dirnames, filenames in os.walk(base):
                    for name in filenames:
                        fp = Path(dirpath) / name
                        try:
                            # Re-check escape for every discovered file
                            safe_resolve(self.root, fp)
                            rel = fp.relative_to(self.root).as_posix()
                            out[rel] = (fp.stat().st_size, _sha256_file(fp))
                        except PathEscapeError:
                            raise
                        except OSError:
                            raise StorageUnavailable(f"STORAGE_UNREADABLE:{fp}")
            else:
                # Socket, device, etc. — treat as unavailable for QA
                raise StorageUnavailable(f"STORAGE_UNSUPPORTED_TYPE:{base}")
        return out

    def snapshot(self, note: str = "") -> StorageSnapshot:
        """Take a snapshot of all files under declared locations."""
        files = self._collect_files()
        return StorageSnapshot(self.root, files, timestamp_note=note)

    def compare(self, before: StorageSnapshot, after: StorageSnapshot) -> StorageDiff:
        return diff_snapshots(before, after)

    def check_persistence(
        self,
        pre_save: StorageSnapshot,
        post_save: StorageSnapshot,
        post_mutation: StorageSnapshot,
        post_load: StorageSnapshot,
    ) -> dict:
        """Verify observable save -> mutation -> load restoration.

        PASS requires all three facts:
        1. save changed declared storage relative to pre-save;
        2. the declared storage was then observably changed before load;
        3. load restored declared storage exactly to the post-save snapshot.

        This prevents "nothing changed, therefore load worked" false positives.
        """
        save_diff = diff_snapshots(pre_save, post_save)
        mutation_diff = diff_snapshots(post_save, post_mutation)
        load_diff = diff_snapshots(post_save, post_load)

        save_had_effect = save_diff.changed
        mutation_had_effect = mutation_diff.changed
        load_restored = not load_diff.changed

        reasons = []
        if not save_had_effect:
            reasons.append("SAVE_NO_OBSERVABLE_EFFECT")
        if not mutation_had_effect:
            reasons.append("STORAGE_NOT_MUTATED_BEFORE_LOAD")
        if not load_restored:
            reasons.append("LOAD_DID_NOT_RESTORE")

        if not save_had_effect or not load_restored:
            status = "FAIL"
        elif not mutation_had_effect:
            status = "INCONCLUSIVE"
        else:
            status = "PASS"

        return {
            "status": status,
            "reason_code": reasons[0] if reasons else "STORAGE_RESTORED",
            "reasons": reasons,
            "save_diff": save_diff.to_dict(),
            "mutation_diff": mutation_diff.to_dict(),
            "load_diff": load_diff.to_dict(),
            "save_had_effect": save_had_effect,
            "mutation_had_effect": mutation_had_effect,
            "load_restored": load_restored,
        }


def inspect_declared_storage(
    root: str | Path,
    declared_locations: List[str],
) -> StorageInspector:
    """Factory that fails closed on path escape or missing root."""
    return StorageInspector(root, declared_locations)