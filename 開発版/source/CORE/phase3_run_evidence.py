"""Phase 3 Run evidence adapter for the accepted Management/Sales evaluators.

It translates facts already measured by the authoritative runner into the evaluator
schemas. It does not decide HQ verdicts. Missing facts stay missing, and automated
observations never become human evidence or a positive player-review verdict.
"""
from __future__ import annotations

import ctypes
import json
import os
import ipaddress
import subprocess
from pathlib import Path

from common import archive_eligible, inside, read_json, tree_size, write_json
from audience_summary import build_audience_summary, render_audience_summary
from review_intake import load_review_evidence, merge_review_evidence


def _identity_snapshot(prepared):
    if not prepared:
        return {}
    raw = prepared.get("identity_snapshot")
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except Exception:
        return {}


def _measurements(sessions, root):
    samples = [m for s in sessions for m in getattr(s, "metrics", ()) if isinstance(m, dict)]
    out = {}
    evidence = []
    for session in sessions:
        name = str(session.p.get("game_id", "game")) + "_resources.json"
        if (Path(root) / name).is_file():
            evidence.append(name)

    rams = [m.get("ram") for m in samples if isinstance(m.get("ram"), (int, float))]
    handles = [m.get("handles") for m in samples if isinstance(m.get("handles"), (int, float))]
    if rams:
        out["ram_mb"] = {
            "value": max(rams) / (1024.0 * 1024.0),
            "unit": "mb",
            "statistic": "peak",
            "source": "process_metrics",
            "method": "peak WorkingSetSize",
            "evidence": evidence,
        }
    if handles:
        out["handles"] = {
            "value": max(handles),
            "unit": "count",
            "statistic": "peak",
            "source": "process_metrics",
            "method": "peak process handle count",
            "evidence": evidence,
        }

    cpu = []
    cpu_count = max(1, os.cpu_count() or 1)
    by_pid = {}
    for sample in samples:
        if all(isinstance(sample.get(k), (int, float)) for k in ("pid", "cpu_seconds", "sample_time")):
            by_pid.setdefault(sample["pid"], []).append(sample)
    for rows in by_pid.values():
        rows = sorted(rows, key=lambda x: x["sample_time"])
        if len(rows) >= 2:
            dt = rows[-1]["sample_time"] - rows[0]["sample_time"]
            dc = rows[-1]["cpu_seconds"] - rows[0]["cpu_seconds"]
            if dt > 0 and dc >= 0:
                cpu.append(100.0 * dc / dt / cpu_count)
    if cpu:
        out["cpu_percent"] = {
            "value": max(cpu),
            "unit": "percent",
            "statistic": "max_observed_average",
            "source": "process_metrics",
            "method": "delta(cpu_seconds)/delta(sample_time)/logical_cpu_count",
            "evidence": evidence,
        }

    times = [m.get("sample_time") for m in samples if isinstance(m.get("sample_time"), (int, float))]
    if len(times) >= 2:
        out["runtime_seconds"] = {
            "value": max(times) - min(times),
            "unit": "seconds",
            "statistic": "observed_interval",
            "source": "process_metrics",
            "method": "max(sample_time)-min(sample_time)",
            "evidence": evidence,
        }

    root = Path(root)
    out["disk_bytes"] = {
        "value": tree_size(root, tolerate_excluded_vanish=True),
        "unit": "bytes",
        "source": "run_directory",
        "method": "recursive file size before sealing; transient excluded paths may vanish",
        "evidence": [],
    }
    out["evidence_bytes"] = {
        "value": tree_size(root, eligible_only=True, tolerate_excluded_vanish=True),
        "unit": "bytes",
        "source": "run_directory",
        "method": "archive-eligible file size before sealing",
        "evidence": [],
    }
    return out


def _rows(results, suffix):
    return [r for r in results if str(r.get("test_case", "")).endswith(suffix)]


def _has_real_launch(results):
    return any(
        str(r.get("test_case", "")).endswith(".launch") and r.get("status") == "PASS"
        for r in results
    )


def _network_adapter_snapshot():
    if os.name != "nt":
        return {"status": "NOT_MEASURED", "reason": "WINDOWS_REQUIRED"}
    system_root = os.environ.get("SystemRoot") or os.environ.get("WINDIR")
    if not system_root:
        return {"status": "NOT_MEASURED", "reason": "SYSTEM_ROOT_UNAVAILABLE"}
    powershell = Path(system_root) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
    if not powershell.is_file():
        return {"status": "NOT_MEASURED", "reason": "WINDOWS_POWERSHELL_UNAVAILABLE"}
    script = r"""
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$ErrorActionPreference='Stop'
$rows=@()
$failures=@()
$adapters=@(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
foreach($adapter in $adapters){
  $addresses=@()
  try{
    # Windows PowerShell 5.1 refuses -InterfaceIndex with an Int32 value
    # ("Argument types do not match"), so the index is cast explicitly.
    $index=[uint32]$adapter.ifIndex
    $addresses=@(Get-NetIPAddress -InterfaceIndex $index -ErrorAction Stop | ForEach-Object { [string]$_.IPAddress })
  } catch {
    # Only a genuine "this interface has no address" is tolerated, recognised
    # by the error CATEGORY, which is not localised.  Every other failure
    # means the observation did not happen and must not be reported as an
    # offline machine.
    if ($_.CategoryInfo -and $_.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::ObjectNotFound) {
      $addresses=@()
    } else {
      $failures += ('ADDRESS_QUERY_FAILED:'+[string]$adapter.Name)
    }
  }
  $rows += [pscustomobject]@{name=[string]$adapter.Name;addresses=$addresses}
}
[pscustomobject]@{rows=$rows;failed=$failures} | ConvertTo-Json -Compress -Depth 4
"""
    try:
        proc = subprocess.run(
            [str(powershell), "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=15,
            check=False,
        )
        if proc.returncode != 0:
            return {
                "status": "NOT_MEASURED",
                "reason": "WINDOWS_NETWORK_QUERY_FAILED",
                "exit_code": proc.returncode,
            }
        raw = (proc.stdout or "").strip()
        payload = json.loads(raw or "{}")
        if isinstance(payload, list):
            payload = {"rows": payload, "failed": []}
        failed = payload.get("failed") or []
        if failed:
            # Fail closed: an address query that did not complete is not an
            # observation of "no external address".
            return {
                "status": "NOT_MEASURED",
                "reason": "NETWORK_ADDRESS_QUERY_FAILED",
                "failed_queries": sorted(str(name) for name in failed),
                "method": "windows_powershell_up_adapters_with_nonloopback_ip",
            }
        rows = payload.get("rows") or []
        if not isinstance(rows, list):
            raise ValueError("WINDOWS_NETWORK_QUERY_SCHEMA")
        up_external = []
        for row in rows:
            if not isinstance(row, dict):
                continue
            addresses = row.get("addresses") or []
            if isinstance(addresses, str):
                addresses = [addresses]
            usable = False
            for raw_address in addresses:
                raw_address = str(raw_address).split("%", 1)[0]
                try:
                    ip = ipaddress.ip_address(raw_address)
                except ValueError:
                    continue
                if not ip.is_loopback and not ip.is_unspecified:
                    usable = True
                    break
            if usable:
                up_external.append(str(row.get("name") or "unnamed"))
        return {
            "status": "MEASURED",
            "up_adapter_count": len(up_external),
            "up_adapters": sorted(up_external),
            "method": "windows_powershell_up_adapters_with_nonloopback_ip",
        }
    except Exception as ex:
        return {"status": "NOT_MEASURED", "reason": type(ex).__name__}


def _write_environment_evidence(e):
    data = {
        "platform": os.name,
        "windows": os.name == "nt",
        "start_qa_marker": os.environ.get("FULLAUTOQA_START_QA") == "1",
        "fresh_extraction_marker": os.environ.get("FULLAUTOQA_FRESH_EXTRACTION") == "1",
        "fresh_extraction_id": os.environ.get("FULLAUTOQA_FRESH_EXTRACTION_ID") or None,
        "automated_controller_marker": os.environ.get("FULLAUTOQA_AUTOMATED_CONTROLLER") == "1",
        "admin_status": "UNKNOWN",
        "network_observation": _network_adapter_snapshot(),
    }
    if os.name == "nt":
        try:
            data["admin_status"] = (
                "ELEVATED" if bool(ctypes.windll.shell32.IsUserAnAdmin()) else "STANDARD_USER"
            )
        except Exception:
            pass
    name = "phase3_environment.json"
    write_json(Path(e.root) / name, data)
    return name, data


def _preseal_integrity(results, root):
    root = Path(root)
    checked = 0
    problems = []
    if not any(r.get("test_case") == "preflight.core" and r.get("status") == "PASS" for r in results):
        problems.append("PREFLIGHT_CORE_NOT_PASS")
    for row in results:
        if row.get("status") != "PASS":
            continue
        checked += 1
        refs = row.get("evidence") or []
        if not refs:
            problems.append("PASS_WITHOUT_EVIDENCE:" + str(row.get("test_case")))
            continue
        for rel in refs:
            try:
                path = inside(root, rel)
            except Exception:
                problems.append("EVIDENCE_PATH_INVALID:" + str(rel))
                continue
            if not path.is_file():
                problems.append("EVIDENCE_MISSING:" + str(rel))
    name = "phase3_preseal_integrity.json"
    write_json(root / name, {"ok": not problems, "checked_pass_rows": checked, "problems": problems})
    return not problems, name


def _signals(results, start_qa, fresh, environment_evidence, root, environment=None):
    environment = environment or {}
    out = {}
    perf = _rows(results, ".performance_regression")
    if perf and all(r.get("status") in ("PASS", "FAIL") for r in perf):
        out["performance_regression"] = any(r.get("status") == "FAIL" for r in perf)

    replay = _rows(results, ".seed_replay")
    if replay and all(r.get("status") in ("PASS", "FAIL") for r in replay):
        out["reproducibility"] = {
            "status": all(r.get("status") == "PASS" for r in replay),
            "scope": "same_run_seed_replay",
            "source": "result_rows",
            "test_cases": [str(r.get("test_case")) for r in replay],
            "evidence": sorted({str(ref) for row in replay for ref in
                                ([row["evidence"]] if isinstance(row.get("evidence"), str)
                                 else (row.get("evidence") or []))}),
        }

    if fresh:
        out["fresh_run"] = {"status": True, "evidence": [environment_evidence]}
    if start_qa:
        out["one_click"] = {
            "status": True,
            "evidence": ["reproduction.json", environment_evidence],
        }

    if environment.get("automated_controller_marker"):
        out["manual_intervention"] = {
            "status": False,
            "evidence": [environment_evidence],
            "scope": "controller_required_steps",
        }

    network = environment.get("network_observation") or {}
    if network.get("status") == "MEASURED" and network.get("up_adapter_count") == 0:
        out["offline"] = {
            "status": True,
            "evidence": [environment_evidence],
            "scope": "no_up_non_loopback_ip_interfaces_observed",
        }

    if os.name == "nt":
        try:
            if not bool(ctypes.windll.shell32.IsUserAnAdmin()):
                out["no_admin"] = {"status": True, "evidence": [environment_evidence]}
        except Exception:
            pass

    integrity, integrity_evidence = _preseal_integrity(results, root)
    if integrity:
        out["integrity"] = {"status": True, "evidence": [integrity_evidence]}

    out["residual_risk"] = [
        {
            "severity": "blocker",
            "test_case": r.get("test_case"),
            "status": r.get("status"),
            "reason_code": r.get("reason_code"),
        }
        for r in results
        if r.get("gate") == "REQUIRED" and r.get("status") != "PASS"
    ]
    return out


def build_management_evidence(*, e, sessions, results, run_mode, prepared):
    identities = _identity_snapshot(prepared)
    real = (
        bool(identities)
        and run_mode == "target"
        and all(i.get("certifies_real_target") for i in identities.values())
        and _has_real_launch(results)
    )
    env_name, env = _write_environment_evidence(e)
    fresh = bool(env["fresh_extraction_marker"] and env["fresh_extraction_id"])
    bundle = {
        "schema_version": 1,
        "evidence_kind": "real_game" if real else ("fixture" if run_mode != "target" else "unknown"),
        "run_id": e.run_id,
        "measurements": _measurements(sessions, e.root),
        **_signals(
            results,
            env["start_qa_marker"] and (Path(e.root) / "reproduction.json").is_file(),
            fresh,
            env_name,
            e.root,
            environment=env,
        ),
    }
    if len(identities) == 1:
        item = next(iter(identities.values()))
        if item.get("generation") is not None:
            bundle["target_generation"] = item.get("generation")
        if item.get("fingerprint"):
            bundle["target_fingerprint"] = item.get("fingerprint")
    return bundle


def _phase_evidence(root):
    video = Path(root) / "FULL_EVIDENCE" / "screen.mp4"
    if not video.is_file():
        return None
    return {
        "observed": True,
        "evidence": ["FULL_EVIDENCE/screen.mp4"],
        "notes": (
            "recording exists, but no review outcome was produced; automated capture is "
            "not a comprehension, enjoyment, readability, or product-quality verdict"
        ),
    }


def build_sales_evidence(*, e, sessions, results, run_mode):
    samples = [m for s in sessions for m in getattr(s, "metrics", ()) if isinstance(m, dict)]
    times = [m.get("sample_time") for m in samples if isinstance(m.get("sample_time"), (int, float))]
    duration = (max(times) - min(times)) if len(times) >= 2 else None

    fresh = (
        os.environ.get("FULLAUTOQA_FRESH_EXTRACTION") == "1"
        and bool(os.environ.get("FULLAUTOQA_FRESH_EXTRACTION_ID"))
    )
    start_qa = os.environ.get("FULLAUTOQA_START_QA") == "1"
    session = {
        "session_id": e.run_id,
        "cold_start": bool(fresh),
        "provenance": {
            "source": "fresh_extraction_start_qa" if fresh and start_qa else "automated_run",
            "run_id": e.run_id,
            "fresh_extraction": bool(fresh),
            "start_qa": bool(start_qa),
            "fresh_extraction_id": os.environ.get("FULLAUTOQA_FRESH_EXTRACTION_ID") or None,
        },
        "phases": {},
    }

    phase = _phase_evidence(e.root)
    if phase is not None and duration is not None and duration >= 30:
        session["phases"]["first_30_seconds"] = dict(phase)
    if phase is not None and duration is not None and duration >= 300:
        session["phases"]["first_5_minutes"] = dict(phase)

    bundle = {
        "schema_version": 1,
        "evidence_kind": "model_proxy",
        "reviewer": {"kind": "model_proxy", "id": "fullautoqa-automated-run"},
        "human_test_performed": False,
        "run_id": e.run_id,
        "sessions": [session],
        "product_acceptance": "HOLD",
        "stable": "HOLD",
    }

    # Review evidence produced outside the automated run (a human cold-start
    # playtest, or a validated review analyser) is ingested here.  The intake
    # preserves the reviewer kind, so a proxy review stays a proxy and can
    # never satisfy the human gate; an absent or malformed review leaves the
    # bundle exactly as the automated run produced it.
    review, review_problems, review_source = load_review_evidence(e.root, run_id=e.run_id)
    bundle["review_evidence"] = {
        "source": review_source,
        "status": "PRESENT" if review is not None else "ABSENT",
        "problems": list(review_problems),
    }
    if review is not None:
        bundle, _ = merge_review_evidence(bundle, review)
    return bundle


def write_phase3_hq_evidence(*, e, sessions, results, run_mode, prepared):
    management = build_management_evidence(
        e=e, sessions=sessions, results=results, run_mode=run_mode, prepared=prepared
    )

    packet_path = Path(e.root) / "player_review_packet.json"
    if packet_path.is_file():
        audience = build_audience_summary(read_json(packet_path), "player_review_packet.json")
    else:
        audience = build_audience_summary({}, "player_review_packet.json")
    write_json(Path(e.root) / "audience_summary.json", audience)
    (Path(e.root) / "AUDIENCE_SUMMARY.txt").write_text(
        render_audience_summary(audience), encoding="utf-8"
    )

    sales = build_sales_evidence(e=e, sessions=sessions, results=results, run_mode=run_mode)
    sales["audience_summary"] = audience
    sales["audience_summary_evidence"] = [
        "audience_summary.json",
        "AUDIENCE_SUMMARY.txt",
    ] if audience.get("status") == "GENERATED" else ["audience_summary.json"]

    write_json(Path(e.root) / "management_evidence.json", management)
    write_json(Path(e.root) / "sales_evidence.json", sales)
    return [
        "phase3_environment.json",
        "phase3_preseal_integrity.json",
        "management_evidence.json",
        "sales_evidence.json",
        "audience_summary.json",
        "AUDIENCE_SUMMARY.txt",
    ]
