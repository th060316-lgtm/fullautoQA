from __future__ import annotations
import json, os, sys
from pathlib import Path

def main():
    run_dir = Path(sys.argv[1]).resolve()
    expected_scenarios = int(sys.argv[2]) if len(sys.argv) > 2 else 9
    project_root = Path(__file__).resolve().parents[1]
    failures = []
    warnings = []
    scenario_root = run_dir / "ui_scenarios"
    if not scenario_root.exists():
        scenario_root = run_dir
    result_files = sorted(scenario_root.glob("20*/result.json"))
    if len(result_files) < expected_scenarios:
        failures.append(f"expected at least {expected_scenarios} scenario result files, found {len(result_files)}")
    for result_file in result_files:
        result = json.loads(result_file.read_text(encoding="utf-8"))
        scenario = result.get("scenario", result_file.parent.name)
        if result.get("status") != "success":
            failures.append(f"{scenario}: status={result.get('status')} reason={result.get('reason')}")
        pngs = list(result_file.parent.glob("*.png")) + list((result_file.parent / "milestones").glob("*.png"))
        if not pngs:
            failures.append(f"{scenario}: no screenshot evidence")
        if os.environ.get("AUTOPLAY_RECORDING") != "0" and not result.get("recording_path"):
            warnings.append(f"{scenario}: recording unavailable")
    font_file = project_root / "tests" / "font-support-result.txt"
    if font_file.exists():
        font_result = font_file.read_text(encoding="utf-8", errors="replace").strip()
        if font_result.startswith("MISSING:"):
            failures.append(f"Windows UI font support failed: {font_result}")
    else:
        failures.append("font-support-result.txt missing")
    for log_name in ("godot_headless_boot.log", "godot_import_parse.log"):
        log = run_dir / "logs" / log_name
        if log.exists():
            text = log.read_text(encoding="utf-8", errors="replace")
            if "ObjectDB instances were leaked" in text or "resources still in use at exit" in text:
                warnings.append(f"{log_name}: Godot shutdown leak warning present")
    out = {
        "status": "FAIL" if failures else ("PASS_WITH_WARNINGS" if warnings else "PASS"),
        "failures": failures,
        "warnings": warnings,
        "scenario_results": len(result_files),
    }
    (run_dir / "evidence_audit.json").write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(out, ensure_ascii=False, indent=2))
    return 1 if failures else 0

if __name__ == "__main__":
    raise SystemExit(main())
