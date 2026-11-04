"""Requirement-driven tool preparation (Phase 3).

Preserves:
- bundled Python bootstrap trust chain (python is always prepared when requested)
- all PAYLOAD tool families remain present; this module only controls *preparation*
- fail-closed for REQUIRED tools
- optional tool failure does not block a target that does not require it
- no fake tool availability

Caller (windows_runner / coordinator path) must supply required_tool_ids from the
frozen capability / target contract. Silent omission of a required id is not allowed.
"""
from __future__ import annotations

import os
import subprocess
import sys
import shutil
import hashlib
import zipfile
import time
from pathlib import Path
from typing import Iterable, Optional, Sequence, Set

from common import read_json, write_json, digest, inside, extract_zip


BOOTSTRAP_CRITICAL = frozenset({"python"})
PROBE_DEFERRED = frozenset({"obs", "ahk", "oculix"})


class Tools:
    def __init__(self, root, evidence):
        self.root = Path(root)
        self.e = evidence
        self.manifest = read_json(self.root / "tool_manifest.json")
        self._by_id = {t["id"]: t for t in self.manifest}
        self.paths = {}
        self._validated_paths = {}
        self.results = []
        self._prepared: Set[str] = set()
        self._failed_required: Set[str] = set()
        self._failed_optional: Set[str] = set()

    def prepare(
        self,
        required: Optional[Iterable[str]] = None,
        optional: Optional[Iterable[str]] = None,
        *,
        prepare_all_if_none: bool = False,
    ):
        """Prepare tools according to explicit requirement sets."""
        if required is None and optional is None:
            if prepare_all_if_none:
                ids = [t["id"] for t in self.manifest]
                required_set = set(ids)
                optional_set: Set[str] = set()
            else:
                raise ValueError(
                    "TOOLS_PREPARE_REQUIRES_EXPLICIT_SETS: "
                    "pass required=... and/or optional=..., "
                    "or prepare_all_if_none=True for legacy full prepare"
                )
        else:
            required_set = {str(x) for x in (required or [])}
            optional_set = {str(x) for x in (optional or [])} - required_set

        if required_set or optional_set:
            required_set |= BOOTSTRAP_CRITICAL & set(self._by_id)

        unknown_required = required_set - set(self._by_id)
        if unknown_required:
            for key in sorted(unknown_required):
                name = f"tool_{key}_error.json"
                write_json(
                    self.e.root / name,
                    {"exception": f"REQUIRED_TOOL_NOT_IN_MANIFEST:{key}"},
                )
                self.results.append(
                    self.e.result(
                        "tool." + key,
                        "HARNESS_ERROR",
                        "REQUIRED_TOOL_NOT_IN_MANIFEST",
                        [name],
                        detail=f"required tool id {key!r} absent from tool_manifest.json",
                        gate="REQUIRED",
                    )
                )
                self._failed_required.add(key)

        ordered = [t for t in self.manifest if t["id"] in (required_set | optional_set)]
        for t in ordered:
            key = t["id"]
            self._prepare_one(t, is_required=key in required_set)

        write_json(self.e.root / "resolved_tools.json", self.paths)
        write_json(
            self.e.root / "tool_prepare_summary.json",
            {
                "required": sorted(required_set),
                "optional": sorted(optional_set),
                "prepared": sorted(self._prepared),
                "failed_required": sorted(self._failed_required),
                "failed_optional": sorted(self._failed_optional),
                "paths": dict(self.paths),
            },
        )
        return self.results

    def get(self, key: str) -> str:
        if key not in self.paths:
            raise OSError("TOOL_UNAVAILABLE:" + key)
        if key in self._validated_paths:
            current = Path(self.paths[key])
            if current.is_symlink() or str(current.resolve()) != self._validated_paths[key] or not current.is_file():
                raise OSError("RUNTIME_POINTER_CHANGED:" + key)
        return self.paths[key]

    def is_available(self, key: str) -> bool:
        try:
            self.get(key)
            return True
        except OSError:
            return False

    def required_failures(self) -> Set[str]:
        return set(self._failed_required)

    def expand(self, argv, work, profile=None):
        values = {k: self.get(k) for k in self.paths}
        values["python"] = self.get("python") if "python" in self.paths else values.get("python", "")
        values["work"] = str(work)
        values["root"] = str(self.root)
        values["seed"] = "{seed}"
        if profile:
            observations = profile.get("observations", {})
            bridge = profile.get("bridge") or (
                observations.get("bridge") if isinstance(observations, dict) else None
            )
            values["state"] = str(Path(work) / bridge) if bridge else ""
            values["endpoint"] = str(
                Path(work) / profile.get("display", {}).get("endpoint", "")
            )
            values["save"] = str(Path(work) / profile.get("save", {}).get("file", ""))
        return [str(v).format_map(values) for v in argv]

    def _prepare_one(self, t: dict, *, is_required: bool) -> None:
        key = t["id"]
        src = inside(self.root, "PAYLOAD/" + t["file"])
        dst = self.root / "RUNTIME" / key
        evidence_path = f"tool_{key}.json"
        gate = "REQUIRED" if is_required else "OPTIONAL"
        try:
            if not src.is_file() or src.stat().st_size != t["size"] or digest(src) != t["sha256"]:
                raise ValueError("PAYLOAD_HASH_MISMATCH")
            runtime_root = (self.root / "RUNTIME").resolve()
            if (self.root / "RUNTIME").is_symlink() or dst.is_symlink() or not dst.resolve().is_relative_to(runtime_root):
                raise OSError("RUNTIME_POINTER_ESCAPE")
            dst.mkdir(parents=True, exist_ok=True)
            marker = dst / "extracted.json"
            if marker.exists() and (marker.is_symlink() or read_json(marker).get("sha256") != t["sha256"]):
                raise OSError("STALE_RUNTIME_CACHE")

            if key == "python":
                exe = self.root / "RUNTIME" / "python" / "python.exe"
            elif key == "oculix":
                exe = src
            else:
                if src.suffix == ".zip" and not marker.exists():
                    extract_zip(src, dst)
                    write_json(marker, {"sha256": t["sha256"]})
                if key == "c" and not marker.exists() and os.name == "nt":
                    r = subprocess.run(
                        [str(src), "-y", "-o" + str(dst)],
                        cwd=dst,
                        capture_output=True,
                        timeout=180,
                    )
                    (self.e.root / "c_extract.log").write_bytes(r.stdout + r.stderr)
                    if r.returncode:
                        raise OSError("C_SFX_EXTRACTION_FAILED")
                    write_json(marker, {"sha256": t["sha256"]})
                if key == "git" and (self.root / "git_runtime_manifest.json").exists():
                    for entry in read_json(self.root / "git_runtime_manifest.json")["files"]:
                        f = inside(self.root, entry["path"])
                        if not f.is_file() or digest(f) != entry["sha256"]:
                            raise OSError("GIT_RUNTIME_HASH_MISMATCH")
                if key == "git" and not any(dst.rglob("git.exe")):
                    raise OSError("GIT_PORTABLE_EXTRACTION_UNAVAILABLE")
                matches = sorted(dst.rglob(t["executable"]))
                if not matches:
                    raise OSError("TOOL_EXECUTABLE_MISSING")
                exe = matches[0]

            if key != "oculix" and (exe.is_symlink() or not exe.resolve().is_relative_to(dst.resolve())):
                raise OSError("RUNTIME_POINTER_ESCAPE")
            if not exe.exists():
                raise OSError("TOOL_EXECUTABLE_MISSING")
            if src.suffix.lower() == ".zip" and key != "python":
                relative_exe = exe.relative_to(dst).as_posix()
                with zipfile.ZipFile(src) as archive:
                    try: expected_exe = hashlib.sha256(archive.read(relative_exe)).hexdigest()
                    except KeyError: raise OSError("RUNTIME_EXECUTABLE_NOT_IN_PAYLOAD")
                if digest(exe) != expected_exe: raise OSError("STALE_RUNTIME_EXECUTABLE")
            self.paths[key] = str(exe.resolve())
            self._validated_paths[key] = self.paths[key]
            self._prepared.add(key)
            write_json(
                self.e.root / evidence_path,
                {
                    "payload_hash": t["sha256"],
                    "executable": str(exe),
                    "runtime_executed": False,
                    "required": is_required,
                },
            )

            if os.name != "nt":
                self.results.append(
                    self.e.result(
                        "tool." + key,
                        "NOT_RUN",
                        "WINDOWS_RUNTIME_REQUIRED",
                        [evidence_path],
                        gate=gate,
                    )
                )
                return

            if key in PROBE_DEFERRED:
                # Payload/executable preparation is complete. Functional acceptance is
                # a separate case (tool.<id>.functional / linkage) executed later.
                self.results.append(
                    self.e.result(
                        "tool." + key + ".prepare",
                        "PASS",
                        "TOOL_PREPARED_FUNCTIONAL_PROBE_DEFERRED",
                        [evidence_path],
                        gate=gate,
                    )
                )
                return

            args_map = {
                "java": ["-version"],
                "node": ["--version"],
                "git": ["--version"],
                "c": ["--version"],
                "godot": ["--headless", "--version"],
                "python": ["-I", "-c", "import sys,tkinter;print(sys.version)"],
                "ffmpeg": ["-version"],
            }
            if key not in args_map:
                self.results.append(
                    self.e.result(
                        "tool." + key,
                        "NOT_RUN",
                        "NO_PROBE_DEFINED",
                        [evidence_path],
                        gate=gate,
                    )
                )
                return

            r = subprocess.run(
                [str(exe), *args_map[key]], capture_output=True, timeout=30, cwd=self.root
            )
            log = f"tool_{key}.log"
            (self.e.root / log).write_bytes(r.stdout + r.stderr)
            status = "PASS" if r.returncode == 0 else "HARNESS_ERROR"
            code = "TOOL_EXECUTED" if r.returncode == 0 else "TOOL_PROBE_FAILED"
            self.results.append(
                self.e.result(
                    "tool." + key,
                    status,
                    code,
                    [evidence_path, log],
                    gate=gate,
                )
            )
            if status != "PASS":
                self.paths.pop(key, None)
                self._validated_paths.pop(key, None)
                self._prepared.discard(key)
                if is_required:
                    self._failed_required.add(key)
                else:
                    self._failed_optional.add(key)

            if key == "git" and r.returncode == 0:
                probe_dir = self.e.root / "git_functional_probe"
                probe_dir.mkdir(exist_ok=True)
                env = os.environ.copy()
                env.update(
                    GIT_CONFIG_NOSYSTEM="1",
                    GIT_CONFIG_GLOBAL=os.devnull,
                    GIT_EXEC_PATH=str(exe.parent),
                    GIT_TEMPLATE_DIR=str(exe.parent / "templates"),
                )
                probe = subprocess.run(
                    [str(exe), "init", "--bare", str(probe_dir / "repo.git")],
                    capture_output=True,
                    timeout=30,
                    env=env,
                )
                (self.e.root / "git_init.log").write_bytes(probe.stdout + probe.stderr)
                ok = probe.returncode == 0 and (probe_dir / "repo.git" / "HEAD").exists()
                self.results.append(
                    self.e.result(
                        "tool.git.functional",
                        "PASS" if ok else "HARNESS_ERROR",
                        "GIT_ISOLATED_INIT" if ok else "GIT_INIT_FAILED",
                        ["git_init.log"],
                        gate=gate,
                    )
                )
                if not ok:
                    if is_required:
                        self._failed_required.add(key)
                    else:
                        self._failed_optional.add(key)

        except Exception as ex:
            name = f"tool_{key}_error.json"
            write_json(self.e.root / name, {"exception": repr(ex), "required": is_required})
            self.results.append(
                self.e.result(
                    "tool." + key,
                    "HARNESS_ERROR",
                    "TOOL_PREPARATION_FAILED",
                    [name],
                    detail=str(ex),
                    gate=gate,
                )
            )
            self.paths.pop(key, None)
            self._validated_paths.pop(key, None)
            self._prepared.discard(key)
            if is_required:
                self._failed_required.add(key)
            else:
                self._failed_optional.add(key)
