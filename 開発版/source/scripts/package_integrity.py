#!/usr/bin/env python3
"""Offline integrity check for an extracted Phase-3 complete Candidate."""
from __future__ import annotations
import argparse, hashlib, json, sys
from pathlib import Path

def sha256_file(path, chunk=1024*1024):
    h=hashlib.sha256()
    with Path(path).open("rb") as f:
        for block in iter(lambda:f.read(chunk), b""): h.update(block)
    return h.hexdigest()

def load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))

def safe(root, rel):
    root=Path(root).resolve(); rel=str(rel or "")
    p=Path(rel)
    if not rel or p.is_absolute() or p.drive or ":" in rel or ".." in p.parts:
        raise ValueError("PATH_ESCAPE:"+rel)
    full=(root/p).resolve()
    if full != root and root not in full.parents: raise ValueError("PATH_ESCAPE:"+rel)
    return full

def check_core_manifest(root):
    root=Path(root).resolve(); errors=[]
    path=root/"core_manifest.json"
    if not path.is_file(): return ["CORE_MANIFEST_MISSING"]
    try: m=load_json(path)
    except Exception as ex: return ["CORE_MANIFEST_PARSE:"+repr(ex)]
    for key in ("core_version","schema_version","capabilities","files"):
        if not m.get(key): errors.append("CORE_MANIFEST_REQUIRED_FIELD_MISSING:"+key)
    rows=m.get("files") or []
    for row in rows:
        try: p=safe(root,row.get("path"))
        except ValueError as ex: errors.append(str(ex)); continue
        if not p.is_file(): errors.append("CORE_FILE_MISSING:"+str(row.get("path"))); continue
        if p.stat().st_size != int(row.get("size",-1)): errors.append("CORE_SIZE_MISMATCH:"+str(row.get("path"))); continue
        if sha256_file(p) != str(row.get("sha256","")).lower(): errors.append("CORE_HASH_MISMATCH:"+str(row.get("path")))
    listed={str(r.get("path")) for r in rows if str(r.get("path","")).startswith("CORE/")}
    actual={p.relative_to(root).as_posix() for p in (root/"CORE").rglob("*") if p.is_file() and "__pycache__" not in p.parts}
    if listed != actual:
        for rel in sorted(actual-listed):errors.append("CORE_MANIFEST_UNLISTED_FILE:"+rel)
        for rel in sorted(listed-actual):errors.append("CORE_MANIFEST_STALE_FILE:"+rel)
    return errors

def check_file_manifest(root, name, required=True):
    root=Path(root).resolve(); path=root/name
    if not path.is_file(): return [name.upper().replace('.','_')+"_MISSING"] if required else []
    try:data=load_json(path)
    except Exception as ex:return [name.upper().replace('.','_')+"_PARSE:"+repr(ex)]
    errors=[]
    for row in data.get("files") or []:
        try:p=safe(root,row.get("path"))
        except ValueError as ex:errors.append(str(ex));continue
        rel=str(row.get("path"))
        if not p.is_file():errors.append(name+":FILE_MISSING:"+rel);continue
        if p.stat().st_size!=int(row.get("size",-1)):errors.append(name+":SIZE_MISMATCH:"+rel);continue
        if sha256_file(p)!=str(row.get("sha256","")).lower():errors.append(name+":HASH_MISMATCH:"+rel)
    return errors

def check_tools(root, full_payload=False):
    root=Path(root).resolve(); errors=[]; path=root/"tool_manifest.json"
    if not path.is_file(): return ["TOOL_MANIFEST_MISSING"]
    try: rows=load_json(path)
    except Exception as ex: return ["TOOL_MANIFEST_PARSE:"+repr(ex)]
    if not isinstance(rows,list) or not rows: return ["TOOL_MANIFEST_EMPTY"]
    ids={str(r.get("id")) for r in rows}
    if "python" not in ids: errors.append("TOOL_MANIFEST_MISSING_PYTHON")
    if full_payload:
        for row in rows:
            try: p=safe(root,"PAYLOAD/"+str(row.get("file","")))
            except ValueError as ex: errors.append(str(ex)); continue
            key=str(row.get("id"))
            if not p.is_file(): errors.append("PAYLOAD_MISSING:"+key); continue
            if p.stat().st_size != int(row.get("size",-1)): errors.append("PAYLOAD_SIZE_MISMATCH:"+key); continue
            if sha256_file(p) != str(row.get("sha256","")).lower(): errors.append("PAYLOAD_HASH_MISMATCH:"+key)
    return errors

def check_structure(root, require_fresh_marker=False):
    root=Path(root); errors=[]
    for d in ("CORE","PAYLOAD","RUNTIME"):
        if not (root/d).is_dir(): errors.append("MISSING_DIR:"+d)
    for f in ("START_QA.cmd","BOOTSTRAP.ps1","core_manifest.json","python_manifest.json","tool_manifest.json"):
        if not (root/f).is_file(): errors.append("MISSING_FILE:"+f)
    if require_fresh_marker and not (root/"PHASE3_FRESH_EXTRACTION.marker").is_file():
        errors.append("FRESH_EXTRACTION_MARKER_MISSING")
    return errors

def main(argv=None):
    ap=argparse.ArgumentParser()
    ap.add_argument("--root",required=True)
    ap.add_argument("--full-payload",action="store_true")
    ap.add_argument("--require-fresh-marker",action="store_true")
    ap.add_argument("--json-out",default="")
    ns=ap.parse_args(argv)
    root=Path(ns.root).resolve()
    if not root.is_dir(): return 2
    report={
        "root":str(root),
        "structure":check_structure(root,ns.require_fresh_marker),
        "core_manifest":check_core_manifest(root),
        "tool_manifest":check_tools(root,ns.full_payload),
        "python_manifest":check_file_manifest(root,"python_manifest.json",True),
        "git_runtime_manifest":check_file_manifest(root,"git_runtime_manifest.json",False),
    }
    errors=[e for values in report.values() if isinstance(values,list) for e in values]
    report["status"]="PASS" if not errors else "FAIL"; report["error_count"]=len(errors)
    text=json.dumps(report,ensure_ascii=False,indent=2); print(text)
    if ns.json_out: Path(ns.json_out).write_text(text,encoding="utf-8")
    return 0 if not errors else 1

if __name__=="__main__": raise SystemExit(main())
