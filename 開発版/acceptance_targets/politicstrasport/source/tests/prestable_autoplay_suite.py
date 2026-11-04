from __future__ import annotations
import json, os, subprocess, sys
from pathlib import Path

def main():
    run_dir = Path(sys.argv[1]).resolve()
    godot = sys.argv[2] if len(sys.argv) > 2 else ""
    project_root = Path(__file__).resolve().parents[1]
    repo_root = project_root.parents[1]
    auto_root = repo_root / ".ci" / "autoplayer"
    base = json.loads((auto_root / "config.json").read_text(encoding="utf-8"))
    base.setdefault("run", {})["runs_directory"] = str(run_dir / "ui_scenarios")
    base.setdefault("recording", {})["enabled"] = True
    base.setdefault("agent", {})["mode"] = "politics_transport_human"
    base["agent"]["seed"] = 20261101
    base["agent"]["max_idle_steps"] = 220
    scenarios = list(base.setdefault("suite", {}).get("scenarios", []))
    if "human_intervention_cycle" not in scenarios:
        scenarios.append("human_intervention_cycle")
    base["suite"]["scenarios"] = scenarios
    extended = list(base["suite"].get("extended_scenarios", []))
    if "human_long_term_manager" not in extended:
        extended.append("human_long_term_manager")
    base["suite"]["extended_scenarios"] = extended
    runtime_cfg = auto_root / "prestable_runtime_config.json"
    runtime_cfg.write_text(json.dumps(base, ensure_ascii=False, indent=2), encoding="utf-8")
    if godot:
        os.environ["GODOT4"] = godot
        os.environ["GODOT"] = godot
    os.environ["AUTOPLAY_NO_DIALOG"] = "1"
    os.environ["AUTOPLAY_NO_PAUSE"] = "1"
    os.environ["AUTOPLAY_MAXIMIZED"] = "1"
    os.environ["AUTOPLAY_INPUT_MODE"] = "godot"
    cmd = [sys.executable, str(auto_root / "python" / "suite_runner.py"), str(runtime_cfg), "--extended"]
    print("PRESTABLE REAL-UI AUTOPLAY:", cmd)
    rc = subprocess.call(cmd, cwd=str(auto_root))
    last = Path(base["run"]["runs_directory"]) / "LAST_SUITE_RESULT.json"
    if last.exists():
        summary = json.loads(last.read_text(encoding="utf-8"))
        (run_dir / "prestable_autoplay_summary.json").write_text(
            json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
        print("PRESTABLE SUITE SUMMARY", json.dumps({
            "success": summary.get("success"), "failed": summary.get("failed")
        }, ensure_ascii=False))
    return rc

if __name__ == "__main__":
    raise SystemExit(main())
