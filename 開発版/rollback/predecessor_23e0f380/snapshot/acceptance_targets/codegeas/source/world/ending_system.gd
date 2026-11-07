# ending_system.gd — 3+ ending families: Evacuation, Remain, Companion-focused
# Ending evaluation at Day 7.
# Protagonist death = immediate game over.
# KMF loss / heroine death / base loss = major failure (not immediate game over).

extends Node

## Ending types
enum EndingType {
	EVACUATE,         # A: 主人公たちは白波市を離れる
	REMAIN,           # B: 地域の一部を維持しながら生活を続ける
	COMPANION_FOCUSED, # C: 多数のNPCを連れて新天地へ向かう
	GAME_OVER_DEATH,   # Protagonist death
	MAJOR_FAILURE,     # Multiple major failures
}

## Ending labels
const ENDING_LABELS: Dictionary = {
	EndingType.EVACUATE: "脱出",
	EndingType.REMAIN: "残留",
	EndingType.COMPANION_FOCUSED: "同行者中心",
	EndingType.GAME_OVER_DEATH: "ゲームオーバー（主人公死亡）",
	EndingType.MAJOR_FAILURE: "重大失敗",
}

var _gs: Node
var _eb: Node
var _nm: Node
var _qm: Node
var _mem: Node

## Ending flags
var _ending_flags: Dictionary = {}

## Evaluated ending
var _final_ending: int = -1
var _ending_score: float = 0.0
var _ending_details: Dictionary = {}

func _ready() -> void:
	_gs = get_node_or_null("/root/GameState")
	_eb = get_node_or_null("/root/EventBus")
	_nm = get_node_or_null("/root/NpcManager")
	_qm = get_node_or_null("/root/QuestManager")
	_mem = get_node_or_null("/root/MemorySystem")

func initialize() -> void:
	_final_ending = -1
	_ending_score = 0.0
	_ending_details = {}
	_ending_flags = {
		"heroine_survived": true,
		"kmf_lost": false,
		"base_lost": false,
		"major_npc_deaths": 0,
		"quests_completed": 0,
		"quests_failed": 0,
		"npcs_saved": [],
		"npcs_lost": [],
		"world_escalated": false,
		"protagonist_alive": true,
	}

	# Integration event wiring
	var nm = get_node_or_null("/root/NpcManager")
	if nm and not nm.npc_died.is_connected(on_npc_death):
		nm.npc_died.connect(on_npc_death)
	if _eb:
		if not _eb.quest_completed.is_connected(_on_quest_result):
			_eb.quest_completed.connect(_on_quest_result)
		if not _eb.player_hp_changed.is_connected(_on_player_hp_changed):
			_eb.player_hp_changed.connect(_on_player_hp_changed)
		if not _eb.kmf_state_changed.is_connected(_on_kmf_state_changed):
			_eb.kmf_state_changed.connect(_on_kmf_state_changed)
		if not _eb.heroine_state_changed.is_connected(_on_heroine_state_changed):
			_eb.heroine_state_changed.connect(_on_heroine_state_changed)

func _on_quest_result(_quest_id: String, success: bool) -> void:
	if success:
		on_quest_completed()
	else:
		on_quest_failed()

func _on_player_hp_changed(hp: float, _max_hp: float) -> void:
	if hp <= 0.0:
		on_protagonist_death()
		evaluate_ending()

func _on_kmf_state_changed() -> void:
	if _gs:
		var kmf = _gs.get_section("kmf")
		if float(kmf.get("durability", 1.0)) <= 0.0 or not bool(kmf.get("owned", true)):
			on_kmflost()

func _on_heroine_state_changed(field: String, _old_val, new_val) -> void:
	if field == "alive" and not bool(new_val):
		set_ending_flag("heroine_survived", false)

## --- Evaluation criteria ---
func evaluate_ending() -> Dictionary:
	## Called on Day 7. Returns ending type + details.
	if _final_ending >= 0:
		return {"ending": _final_ending, "score": _ending_score, "details": _ending_details}
	
	# Check immediate game over conditions
	var player_data = _gs.get_section("player") if _gs else {}
	var protagonist_alive = player_data.get("hp", 100) > 0
	
	if not protagonist_alive:
		_final_ending = EndingType.GAME_OVER_DEATH
		_ending_score = 0.0
		_ending_details = {"cause": "protagonist_death", "day": _gs.get_day() if _gs else 7}
		if _eb:
			_eb.ending_evaluated.emit(ENDING_LABELS[_final_ending], _ending_score)
		return _get_ending_result()
	
	# Count major failures
	var major_failures = 0
	if _ending_flags.get("kmf_lost", false): major_failures += 1
	if _ending_flags.get("base_lost", false): major_failures += 1
	if _ending_flags.get("major_npc_deaths", 0) >= 3: major_failures += 1
	
	if major_failures >= 2:
		_final_ending = EndingType.MAJOR_FAILURE
		_ending_score = 20.0
		_ending_details = _compute_failure_details()
		if _eb:
			_eb.ending_evaluated.emit(ENDING_LABELS[_final_ending], _ending_score)
		return _get_ending_result()
	
	# Score-based ending selection
	_ending_score = _compute_score()
	_ending_details = _compute_ending_details()
	
	# Determine ending type based on score and conditions
	var companion_count = _ending_flags.get("npcs_saved", []).size()
	var world_state = _gs.get_world() if _gs else {}
	var unrest = world_state.get("socialUnrest", 0)
	
	if companion_count >= 5:
		_final_ending = EndingType.COMPANION_FOCUSED
	elif unrest > 70:
		# High unrest: evacuation is best choice
		_final_ending = EndingType.EVACUATE
	elif companion_count >= 2 and unrest <= 50:
		_final_ending = EndingType.REMAIN
	else:
		# Default: evacuation
		_final_ending = EndingType.EVACUATE
	
	if _eb:
		_eb.ending_evaluated.emit(ENDING_LABELS[_final_ending], _ending_score)
	
	return _get_ending_result()

func _compute_score() -> float:
	var score: float = 0.0
	
	# Heroine survival
	if _ending_flags.get("heroine_survived", true):
		score += 25.0
	
	# KMF not lost
	if not _ending_flags.get("kmf_lost", false):
		score += 15.0
	
	# Base not lost
	if not _ending_flags.get("base_lost", false):
		score += 10.0
	
	# NPCs saved
	var saved = _ending_flags.get("npcs_saved", [])
	score += saved.size() * 5.0
	
	# NPCs lost (penalty)
	var lost = _ending_flags.get("npcs_lost", [])
	score -= lost.size() * 8.0
	
	# Quest completion
	var quest_summary = _qm.get_quest_summary() if _qm else {}
	score += quest_summary.get("completed", 0) * 3.0
	score -= quest_summary.get("failed", 0) * 5.0
	
	# System facts collected
	var facts = _mem.get_all_system_facts_sorted() if _mem else []
	score += minf(facts.size() * 0.5, 10.0)
	
	# World state
	var world = _gs.get_world() if _gs else {}
	var unrest = world.get("socialUnrest", 0)
	score -= (unrest - 20) * 0.2  # Penalty for high unrest
	
	return clampf(score, 0.0, 100.0)

func _compute_ending_details() -> Dictionary:
	var details = {
		"score": _ending_score,
		"heroine_survived": _ending_flags.get("heroine_survived", true),
		"kmf_lost": _ending_flags.get("kmf_lost", false),
		"base_lost": _ending_flags.get("base_lost", false),
		"npcs_saved": _ending_flags.get("npcs_saved", []).size(),
		"npcs_lost": _ending_flags.get("npcs_lost", []).size(),
		"quests_completed": _ending_flags.get("quests_completed", 0),
		"quests_failed": _ending_flags.get("quests_failed", 0),
	}
	return details

func _compute_failure_details() -> Dictionary:
	var d = _compute_ending_details()
	d["failure_reason"] = []
	if _ending_flags.get("kmf_lost", false):
		d["failure_reason"].append("kmf_lost")
	if _ending_flags.get("base_lost", false):
		d["failure_reason"].append("base_lost")
	if _ending_flags.get("major_npc_deaths", 0) >= 3:
		d["failure_reason"].append("mass_npc_deaths")
	return d

func _get_ending_result() -> Dictionary:
	return {
		"ending": _final_ending,
		"ending_label": ENDING_LABELS.get(_final_ending, "不明"),
		"score": _ending_score,
		"details": _ending_details,
		"description": _get_ending_description(_final_ending),
	}

func _get_ending_description(ending: int) -> String:
	match ending:
		EndingType.EVACUATE:
			return "脱出エンディング：主人公たちは白波市を離れ、安全な場所へ向かった。この7日間、你は限られた情報の中で最適な判断を重ねた。すべてのNPCを救えたわけではないが、生き残った人々と共に前進する。"
		EndingType.REMAIN:
			return "残留エンディング：主人公たちは白波市の一角に留まり、小さな共同体を築いた。道は険しいが、この街を離れることを選んだあなたにとって、ここが新たな始まりだ。"
		EndingType.COMPANION_FOCUSED:
			return "同行者中心エンディング：主人公は多くのNPCを連れて白波市を後にした。新天地へ向かう長い旅路的だが、一人ではない。"
		EndingType.GAME_OVER_DEATH:
			return "ゲームオーバー：主人公は死亡した。すべての道はここで終わる。"
		EndingType.MAJOR_FAILURE:
			return "重大失敗：主人公は生き残ったが、KMFと仲間大多数を失った。生存はしたが、元の生活に戻ることはできなかった。"
	return "不明のエンディング"

## --- Flag setting ---
func set_ending_flag(key: String, value) -> void:
	var old_val = _ending_flags.get(key)
	_ending_flags[key] = value
	print("[EndingSystem] Flag: %s = %s (was %s)" % [key, value, old_val])

func on_npc_saved(npc_id: String) -> void:
	var saved = _ending_flags.get("npcs_saved", [])
	if not npc_id in saved:
		saved.append(npc_id)
		_ending_flags["npcs_saved"] = saved

func on_npc_death(npc_id: String) -> void:
	var saved = _ending_flags.get("npcs_saved", [])
	if npc_id in saved:
		saved.erase(npc_id)
	var lost = _ending_flags.get("npcs_lost", [])
	if not npc_id in lost:
		lost.append(npc_id)
		_ending_flags["npcs_lost"] = lost
		if npc_id != "yui":
			_ending_flags["major_npc_deaths"] = _ending_flags.get("major_npc_deaths", 0) + 1
	else:
		# Heroine death
		_ending_flags["heroine_survived"] = false

func on_kmflost() -> void:
	_ending_flags["kmf_lost"] = true

func on_base_lost() -> void:
	_ending_flags["base_lost"] = true

func on_quest_completed() -> void:
	_ending_flags["quests_completed"] = _ending_flags.get("quests_completed", 0) + 1

func on_quest_failed() -> void:
	_ending_flags["quests_failed"] = _ending_flags.get("quests_failed", 0) + 1

func on_protagonist_death() -> void:
	_ending_flags["protagonist_alive"] = false

## --- Final evaluation ---
func is_game_over() -> bool:
	return not _ending_flags.get("protagonist_alive", true)

func get_current_ending_preview() -> Dictionary:
	var score = _compute_score()
	var companion_count = _ending_flags.get("npcs_saved", []).size()
	var world = _gs.get_world() if _gs else {}
	var unrest = world.get("socialUnrest", 0)
	
	var candidates = []
	if companion_count >= 5:
		candidates.append({"type": EndingType.COMPANION_FOCUSED, "label": "同行者中心", "score": score + 10})
	if unrest > 70:
		candidates.append({"type": EndingType.EVACUATE, "label": "脱出", "score": score + 5})
	if companion_count >= 2 and unrest <= 50:
		candidates.append({"type": EndingType.REMAIN, "label": "残留", "score": score})
	
	candidates.sort_custom(func(a, b): return a["score"] > b["score"])
	var most_likely = candidates[0] if not candidates.is_empty() else {"type": EndingType.EVACUATE, "label": "脱出", "score": score}
	
	return {
		"current_score": score,
		"heroine_survived": _ending_flags.get("heroine_survived", true),
		"kmf_lost": _ending_flags.get("kmf_lost", false),
		"npcs_saved": companion_count,
		"most_likely_ending": most_likely,
		"candidate_endings": candidates,
	}

## --- Save/Load ---
func serialize() -> Dictionary:
	return {
		"ending_flags": _ending_flags.duplicate(true),
		"final_ending": _final_ending,
		"ending_score": _ending_score,
		"ending_details": _ending_details.duplicate(true),
	}

func deserialize(data: Dictionary) -> void:
	if data.has("ending_flags"):
		_ending_flags = data["ending_flags"].duplicate(true)
	if data.has("final_ending"):
		_final_ending = data["final_ending"]
	if data.has("ending_score"):
		_ending_score = data["ending_score"]
	if data.has("ending_details"):
		_ending_details = data["ending_details"].duplicate(true)
