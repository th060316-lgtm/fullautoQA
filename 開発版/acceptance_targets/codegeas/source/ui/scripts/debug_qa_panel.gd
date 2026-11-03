# ui/scripts/debug_qa_panel.gd
# QA DEBUG PANEL — shows internal truth values
# WARNING: This panel exposes data that should NOT be shown in normal game UI.
# Only enabled in debug/development mode.

extends Control

var _debug: Node

@onready var truth_output: TextEdit = $MarginContainer/ScrollContainer/TruthOutput

const QA_ONLY_WARNING = "⚠ QA ONLY — INTERNAL TRUTH VALUES ⚠\n" + "="*50 + "\n"

func _ready() -> void:
	_debug = get_node_or_null("/root/DebugHooks")
	_refresh()

func _refresh() -> void:
	var lines = [QA_ONLY_WARNING]
	
	# Time
	var gs = get_node_or_null("/root/GameState") or get_node_or_null("/root/GameStateStub")
	if gs:
		lines.append("Day: %d  Minute: %d" % [gs.get_day(), gs.get_minute_of_day()])
	
	# NPC true affections
	lines.append("\n━━ TRUE NPC AFFECTIONS ━━")
	var nm = get_node_or_null("/root/NpcManager")
	if nm:
		for npc_id in nm.get_npc_ids():
			var aff = nm.get_npc(npc_id).get("affection", 0)
			var trust = nm.get_npc(npc_id).get("trust", 0)
			lines.append("  %s: aff=%+d trust=%+d" % [npc_id, aff, trust])
	
	# Heroine
	lines.append("\n━━ HEROINE TRUE STATE ━━")
	var hs = get_node_or_null("/root/HeroineSystem")
	if hs:
		var st = hs.get_state()
		lines.append("  affection: %d" % st.get("affection", 0))
		lines.append("  trust: %d  fear: %d  dependence: %d" % [
			st.get("trust", 0), st.get("fear", 0), st.get("dependence", 0)])
		lines.append("  interactionTotal: %d  interactionRecent: %d" % [
			st.get("interactionTotal", 0), st.get("interactionRecent", 0)])
		lines.append("  band: %s" % hs.get_affection_band_label())
	
	# System facts
	lines.append("\n━━ SYSTEM FACTS ━━")
	var mem = get_node_or_null("/root/MemorySystem")
	if mem:
		var facts = mem.get_system_facts()
		lines.append("  Count: %d" % facts.size())
		for fid in facts:
			lines.append("  [%s] %s" % [fid, facts[fid].get("description", "?")])
	
	# World state
	lines.append("\n━━ WORLD STATE ━━")
	var wes = get_node_or_null("/root/WorldEventSystem")
	if wes:
		var ws = wes.get_world_state()
		for key in ["socialUnrest", "trafficChaos", "militaryTension", "geassSpread"]:
			lines.append("  %s: %d" % [key, ws.get(key, 0)])
	
	# Ending preview
	lines.append("\n━━ ENDING PREVIEW ━━")
	var es = get_node_or_null("/root/EndingSystem")
	if es:
		var preview = es.get_current_ending_preview()
		lines.append("  Score: %.1f" % preview.get("current_score", 0.0))
		lines.append("  Most likely: %s" % preview.get("most_likely_ending", {}).get("label", "?"))
		lines.append("  NPCs saved: %d  KMF lost: %s  Heroine alive: %s" % [
			preview.get("npcs_saved", 0), preview.get("kmf_lost", false), preview.get("heroine_survived", true)])
	
	truth_output.text = "\n".join(lines)

func _on_run_tests_pressed() -> void:
	var results = _debug.run_qa_tests() if _debug else "DebugHooks not available"
	truth_output.text = QA_ONLY_WARNING + "\n━━ QA TEST RESULTS ━━\n\n" + results

func _on_dump_state_pressed() -> void:
	var dump = _debug.dump_full_state() if _debug else "DebugHooks not available"
	truth_output.text = QA_ONLY_WARNING + "\n━━ FULL STATE DUMP ━━\n\n" + dump

func _on_advance_day_pressed() -> void:
	_debug.advance_day() if _debug else null
	_refresh()

func _on_refresh_pressed() -> void:
	_refresh()
