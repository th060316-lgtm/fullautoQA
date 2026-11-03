"""Phase 3 Run evidence adapter for the accepted Management/Sales evaluators.

It translates facts already measured by the authoritative runner into the evaluator
schemas. It does not decide HQ verdicts. Missing facts stay missing, and automated
observations never become human evidence.
"""
from __future__ import annotations
import ctypes, json, os
from pathlib import Path
from common import archive_eligible, write_json

def _identity_snapshot(prepared):
    if not prepared:return {}
    raw=prepared.get("identity_snapshot")
    if not raw:return {}
    try:return json.loads(raw)
    except Exception:return {}

def _measurements(sessions,root):
    samples=[m for s in sessions for m in getattr(s,"metrics",()) if isinstance(m,dict)]
    out={}; evidence=[]
    for session in sessions:
        name=str(session.p.get("game_id","game"))+"_resources.json"
        if (Path(root)/name).is_file():evidence.append(name)
    rams=[m.get("ram") for m in samples if isinstance(m.get("ram"),(int,float))]
    handles=[m.get("handles") for m in samples if isinstance(m.get("handles"),(int,float))]
    if rams:out["ram_mb"]={"value":max(rams)/(1024.0*1024.0),"unit":"mb","statistic":"peak","source":"process_metrics","method":"peak WorkingSetSize","evidence":evidence}
    if handles:out["handles"]={"value":max(handles),"unit":"count","statistic":"peak","source":"process_metrics","method":"peak process handle count","evidence":evidence}
    cpu=[]; cpu_count=max(1,os.cpu_count() or 1); by_pid={}
    for m in samples:
        if all(isinstance(m.get(k),(int,float)) for k in ("pid","cpu_seconds","sample_time")):
            by_pid.setdefault(m["pid"],[]).append(m)
    for rows in by_pid.values():
        rows=sorted(rows,key=lambda x:x["sample_time"])
        if len(rows)>=2:
            dt=rows[-1]["sample_time"]-rows[0]["sample_time"]; dc=rows[-1]["cpu_seconds"]-rows[0]["cpu_seconds"]
            if dt>0 and dc>=0:cpu.append(100.0*dc/dt/cpu_count)
    if cpu:out["cpu_percent"]={"value":max(cpu),"unit":"percent","statistic":"max_observed_average","source":"process_metrics","method":"delta(cpu_seconds)/delta(sample_time)/logical_cpu_count","evidence":evidence}
    times=[m.get("sample_time") for m in samples if isinstance(m.get("sample_time"),(int,float))]
    if len(times)>=2:out["runtime_seconds"]={"value":max(times)-min(times),"unit":"seconds","statistic":"observed_interval","source":"process_metrics","method":"max(sample_time)-min(sample_time)","evidence":evidence}
    root=Path(root)
    try:
        out["disk_bytes"]={"value":sum(p.stat().st_size for p in root.rglob("*") if p.is_file()),"unit":"bytes","source":"run_directory","method":"recursive file size before sealing","evidence":[]}
        out["evidence_bytes"]={"value":sum(p.stat().st_size for p in root.rglob("*") if p.is_file() and archive_eligible(p.relative_to(root))),"unit":"bytes","source":"run_directory","method":"archive-eligible file size before sealing","evidence":[]}
    except OSError:pass
    return out

def _rows(results,suffix):
    return [r for r in results if str(r.get("test_case","")).endswith(suffix)]

def _write_environment_evidence(e):
    data={
        "platform":os.name,
        "windows":os.name=="nt",
        "start_qa_marker":os.environ.get("FULLAUTOQA_START_QA")=="1",
        "fresh_extraction_marker":os.environ.get("FULLAUTOQA_FRESH_EXTRACTION")=="1",
        "fresh_extraction_id":os.environ.get("FULLAUTOQA_FRESH_EXTRACTION_ID") or None,
        "admin_status":"UNKNOWN",
    }
    if os.name=="nt":
        try:data["admin_status"]="ELEVATED" if bool(ctypes.windll.shell32.IsUserAnAdmin()) else "STANDARD_USER"
        except Exception:pass
    name="phase3_environment.json";write_json(Path(e.root)/name,data);return name,data

def _signals(results,start_qa,fresh,environment_evidence):
    out={}
    perf=_rows(results,".performance_regression")
    if perf and all(r.get("status") in ("PASS","FAIL") for r in perf):
        out["performance_regression"]=any(r.get("status")=="FAIL" for r in perf)
    replay=_rows(results,".seed_replay")
    if replay and all(r.get("status") in ("PASS","FAIL") for r in replay):
        out["reproducibility"]=all(r.get("status")=="PASS" for r in replay)
    if fresh:out["fresh_run"]={"status":True,"evidence":[environment_evidence]}
    if start_qa:out["one_click"]={"status":True,"evidence":["reproduction.json",environment_evidence]}
    if os.name=="nt":
        try:
            if not bool(ctypes.windll.shell32.IsUserAnAdmin()):
                out["no_admin"]={"status":True,"evidence":[environment_evidence]}
        except Exception:pass
    out["residual_risk"]=[
        {"severity":"blocker","test_case":r.get("test_case"),"status":r.get("status"),"reason_code":r.get("reason_code")}
        for r in results if r.get("gate")=="REQUIRED" and r.get("status")!="PASS"
    ]
    return out

def build_management_evidence(*,e,sessions,results,run_mode,prepared):
    identities=_identity_snapshot(prepared)
    real=bool(identities) and run_mode=="target" and all(i.get("certifies_real_target") for i in identities.values())
    env_name,env=_write_environment_evidence(e)
    bundle={
        "schema_version":1,
        "evidence_kind":"real_game" if real else "fixture",
        "run_id":e.run_id,
        "measurements":_measurements(sessions,e.root),
        **_signals(results,env["start_qa_marker"] and (Path(e.root)/"reproduction.json").is_file(),env["fresh_extraction_marker"],env_name),
    }
    if len(identities)==1:
        item=next(iter(identities.values()))
        if item.get("generation") is not None:bundle["target_generation"]=item.get("generation")
        if item.get("fingerprint"):bundle["target_fingerprint"]=item.get("fingerprint")
    return bundle

def _phase_evidence(root):
    video=Path(root)/"FULL_EVIDENCE"/"screen.mp4"
    if not video.is_file():return None
    return {"observed":True,"status":"pass","findings":[],"evidence":["FULL_EVIDENCE/screen.mp4"],
            "notes":"automated proxy observation only; not a human comprehension/enjoyment claim"}

def build_sales_evidence(*,e,sessions,results,run_mode):
    samples=[m for s in sessions for m in getattr(s,"metrics",()) if isinstance(m,dict)]
    times=[m.get("sample_time") for m in samples if isinstance(m.get("sample_time"),(int,float))]
    duration=(max(times)-min(times)) if len(times)>=2 else None
    fresh=os.environ.get("FULLAUTOQA_FRESH_EXTRACTION")=="1"; start_qa=os.environ.get("FULLAUTOQA_START_QA")=="1"
    session={"session_id":e.run_id,"cold_start":bool(fresh),
             "provenance":{"source":"fresh_extraction_start_qa" if fresh and start_qa else "automated_run",
                           "run_id":e.run_id,"fresh_extraction":bool(fresh),"start_qa":bool(start_qa),
                           "fresh_extraction_id":os.environ.get("FULLAUTOQA_FRESH_EXTRACTION_ID") or None},
             "phases":{}}
    phase=_phase_evidence(e.root)
    if phase is not None and duration is not None and duration>=30:session["phases"]["first_30_seconds"]=dict(phase)
    if phase is not None and duration is not None and duration>=300:session["phases"]["first_5_minutes"]=dict(phase)
    return {"schema_version":1,"evidence_kind":"model_proxy",
            "reviewer":{"kind":"model_proxy","id":"fullautoqa-automated-run"},
            "human_test_performed":False,"run_id":e.run_id,"sessions":[session],
            "product_acceptance":"HOLD","stable":"HOLD"}

def write_phase3_hq_evidence(*,e,sessions,results,run_mode,prepared):
    management=build_management_evidence(e=e,sessions=sessions,results=results,run_mode=run_mode,prepared=prepared)
    sales=build_sales_evidence(e=e,sessions=sessions,results=results,run_mode=run_mode)
    write_json(Path(e.root)/"management_evidence.json",management)
    write_json(Path(e.root)/"sales_evidence.json",sales)
    return ["phase3_environment.json","management_evidence.json","sales_evidence.json"]
