# quest_manager.gd — Quest system
# Implements 5+ quest types from the game book:
# - Hospital medicine delivery
# - Evacuation/rescue
# - Missing person search
# - Supply depot securing
# - Road blockade breach
# - Conflict mediation
# - Memory contradiction investigation
# - Return to base
# - Code holder trace investigation

extends Node

var _gs: Node
var _eb: Node
var _rng: Node
var _nm: Node

## Quest status
enum QuestStatus {
	AVAILABLE,   # Can be accepted
	ACTIVE,      # Accepted and in progress
	COMPLETED,   # Successfully completed
	FAILED,      # Failed
	CANCELLED,   # Player cancelled
}

## Quest definition
var _quest_definitions: Dictionary = {}
var _active_quests: Dictionary = {}  # quest_id -> quest state
var _quest_history: Array = []  # completed/failed quests for summary

var _quest_id_counter: int = 0

func _ready() -> void:
	_gs = get_node_or_null("/root/GameState")
	_eb = get_node_or_null("/root/EventBus")
	_rng = get_node_or_null("/root/RngService")
	_nm = get_node_or_null("/root/NpcManager")

func initialize() -> void:
	_define_quests()
	_spawn_initial_quests()
	print("[QuestManager] Initialized %d quest definitions" % _quest_definitions.size())

func _define_quests() -> void:
	_quest_definitions = {
		"quest_hospital_medicine": {
			"id": "quest_hospital_medicine",
			"name": "病院へ医薬品を運ぶ",
			"description": "{Aoi}から要請された医薬品を白波中央病院へ届ける。",
			"type": "delivery",
			"giver": "aoi",
			"target_location": "hospital",
			"reward_affection": 15,
			"reward_trust": 10,
			"objectives": [{"type": "travel", "location": "hospital"}],
			"time_limit": 1440,  # 24 hours in minutes
			"difficulty": 2,
			"requirements": [],
		},
		"quest_evacuation_rescue": {
			"id": "quest_evacuation_rescue",
			"name": "避難民を救助する",
			"description": "市街中心部に取り残された避難民を安全な場所へ連れてくる。",
			"type": "rescue",
			"giver": "sakura",
			"target_location": "city_center",
			"reward_affection": 20,
			"reward_trust": 15,
			"objectives": [
				{"type": "travel", "location": "city_center"},
				{"type": "talk", "npc": "rei"},
				{"type": "escort", "from": "city_center", "to": "evacuation_center"},
			],
			"time_limit": 720,
			"difficulty": 3,
			"requirements": ["quest_hospital_medicine"],
		},
		"quest_missing_person": {
			"id": "quest_missing_person",
			"name": "行方不明NPCを探す",
			"description": "{Hinata}の両親を探してほしい。市内を探索する必要がある。",
			"type": "search",
			"giver": "hinata",
			"target_location": "city_outskirts",
			"reward_affection": 25,
			"reward_trust": 20,
			"objectives": [
				{"type": "travel", "location": "city_outskirts"},
				{"type": "investigate", "area": "outskirts"},
			],
			"time_limit": 1440,
			"difficulty": 2,
			"requirements": [],
		},
		"quest_supply_depot": {
			"id": "quest_supply_depot",
			"name": "食料倉庫を確保する",
			"description": "工業・倉庫地区の食料倉庫を確保し、略奪から守る。",
			"type": "secure",
			"giver": "kenji",
			"target_location": "industrial_area",
			"reward_affection": 5,
			"reward_trust": 8,
			"reward_resources": {"food": 5},
			"objectives": [
				{"type": "travel", "location": "industrial_area"},
				{"type": "combat", "enemy_count": 3},
			],
			"time_limit": 1080,
			"difficulty": 3,
			"requirements": [],
		},
		"quest_road_blockade": {
			"id": "quest_road_blockade",
			"name": "道路封鎖を突破する",
			"description": "旧整備所へ向かう道の封鎖を突破し、整備所へ到達する。",
			"type": "combat",
			"giver": "tanaka",
			"target_location": "base",
			"reward_affection": 10,
			"reward_trust": 10,
			"objectives": [
				{"type": "travel", "location": "base", "mode": "kmf"},
				{"type": "combat", "enemy_count": 2},
			],
			"time_limit": 1440,
			"difficulty": 3,
			"requirements": [],
		},
		"quest_memory_investigation": {
			"id": "quest_memory_investigation",
			"name": "記憶矛盾の原因を調査する",
			"description": "2日目に発生するNPCの証言矛盾を調査し、真相に迫る。",
			"type": "investigation",
			"giver": "yui",
			"target_location": "evacuation_center",
			"reward_affection": 5,
			"reward_trust": 15,
			"objectives": [
				{"type": "talk", "npc": "tanaka"},
				{"type": "talk", "npc": "rei"},
				{"type": "analyze", "category": "contradiction"},
			],
			"time_limit": 720,
			"difficulty": 2,
			"requirements": [],
		},
		"quest_return_to_base": {
			"id": "quest_return_to_base",
			"name": "整備所へ帰還する",
			"description": "整備所に戻り、KMFの整備と休息を取る。",
			"type": "travel",
			"giver": "yui",
			"target_location": "base",
			"reward_affection": 3,
			"reward_trust": 5,
			"objectives": [{"type": "travel", "location": "base"}],
			"time_limit": 2880,
			"difficulty": 1,
			"requirements": [],
		},
		"quest_code_tracer": {
			"id": "quest_code_tracer",
			"name": "コード所持女性の移動痕跡を調べる",
			"description": "旧特別整備所の利用履歴からコード所持女性と護衛男性の移動方向を推測する。",
			"type": "investigation",
			"giver": "nishino",
			"target_location": "base",
			"reward_affection": 8,
			"reward_trust": 20,
			"objectives": [
				{"type": "travel", "location": "base"},
				{"type": "investigate", "area": "maintenance_logs"},
			],
			"time_limit": 2160,
			"difficulty": 2,
			"requirements": [],
		},
		"quest_conflict_mediation": {
			"id": "quest_conflict_mediation",
			"name": "対立中の避難所から特定人物を連れ出す",
			"description": "避難所の派閥対立の最中、{Hinata}を安全な場所へ連れてくる。",
			"type": "rescue",
			"giver": "megumi",
			"target_location": "evacuation_center",
			"reward_affection": 15,
			"reward_trust": 12,
			"objectives": [
				{"type": "travel", "location": "evacuation_center"},
				{"type": "negotiate", "npc": "yoshida"},
				{"type": "escort", "npc": "hinata", "to": "base"},
			],
			"time_limit": 1440,
			"difficulty": 3,
			"requirements": [],
		},
	}

## Spawn initial quests based on game day
func _spawn_initial_quests() -> void:
	# Day 1: Basic quests
	_add_quest("quest_hospital_medicine")
	_add_quest("quest_return_to_base")
	
	# Day 2: Add more
	_add_quest("quest_memory_investigation")

## Add quest to active list
func _add_quest(quest_id: String) -> void:
	if not _quest_definitions.has(quest_id):
		return
	if _active_quests.has(quest_id):
		return
	
	var def = _quest_definitions[quest_id]
	_active_quests[quest_id] = {
		"id": quest_id,
		"name": def["name"],
		"description": def["description"],
		"type": def["type"],
		"status": QuestStatus.AVAILABLE,
		"objectives": def["objectives"].map(func(o): return o.duplicate(true)),
		"completed_objectives": [],
		"time_limit": def["time_limit"],
		"started_day": 0,
		"started_minute": 0,
		"giver": def["giver"],
		"reward_affection": def.get("reward_affection", 0),
		"reward_trust": def.get("reward_trust", 0),
		"reward_resources": def.get("reward_resources", {}),
	}
	_gs.set_quest(quest_id, _active_quests[quest_id]) if _gs else null

## Accept a quest
func accept_quest(quest_id: String) -> bool:
	if not _active_quests.has(quest_id):
		return false
	var qs = _active_quests[quest_id]
	if qs["status"] != QuestStatus.AVAILABLE:
		return false
	
	qs["status"] = QuestStatus.ACTIVE
	qs["started_day"] = _gs.get_day() if _gs else 1
	qs["started_minute"] = _gs.get_minute_of_day() if _gs else 0
	_gs.set_quest(quest_id, _active_quests[quest_id]) if _gs else null
	print("[QuestManager] Quest accepted: %s" % quest_id)
	return true

## Complete an objective
func complete_objective(quest_id: String, objective_index: int) -> void:
	if not _active_quests.has(quest_id):
		return
	var qs = _active_quests[quest_id]
	var objectives = qs["objectives"]
	if objective_index < 0 or objective_index >= objectives.size():
		return
	
	var obj = objectives[objective_index]
	if objective_index in qs["completed_objectives"]:
		return
	
	qs["completed_objectives"].append(objective_index)
	
	# Check if all objectives complete
	if qs["completed_objectives"].size() == objectives.size():
		complete_quest(quest_id, true)
	
	_gs.set_quest(quest_id, _active_quests[quest_id]) if _gs else null

## Complete a quest
func complete_quest(quest_id: String, success: bool) -> void:
	if not _active_quests.has(quest_id):
		return
	var qs = _active_quests[quest_id]
	var status = QuestStatus.COMPLETED if success else QuestStatus.FAILED
	qs["status"] = status
	
	_quest_history.append(qs.duplicate(true))
	
	# Apply rewards
	if success:
		var giver = qs.get("giver", "")
		var reward_affection = qs.get("reward_affection", 0)
		var reward_trust = qs.get("reward_trust", 0)
		
		if _nm and giver != "":
			_nm.modify_affection(giver, reward_affection)
			_nm.modify_trust(giver, reward_trust)
		
		print("[QuestManager] Quest completed: %s (+%d affection, +%d trust to %s)" % [
			quest_id, reward_affection, reward_trust, giver])
	
	_gs.set_quest(quest_id, qs) if _gs else null
	if _eb:
		_eb.quest_completed.emit(quest_id, success)

## Fail quest by time limit
func check_time_limits() -> void:
	var current_day = _gs.get_day() if _gs else 1
	var current_minute = _gs.get_minute_of_day() if _gs else 0
	
	for quest_id in _active_quests.keys():
		var qs = _active_quests[quest_id]
		if qs["status"] != QuestStatus.ACTIVE:
			continue
		
		var elapsed = (current_day - qs["started_day"]) * 1440 + (current_minute - qs["started_minute"])
		if elapsed > qs["time_limit"]:
			complete_quest(quest_id, false)
			print("[QuestManager] Quest timed out: %s" % quest_id)

## Spawn quest based on game day
func on_time_tick(day: int, minute: int) -> void:
	# Spawn every quest whose release day has been reached; large time jumps must not skip content.
	var schedule: Dictionary = {
		2: ["quest_memory_investigation"],
		# Day1 rescue/supply IDs are owned permanently by Day1Controller and must
		# never respawn as legacy quests on later days.
		4: ["quest_missing_person"],
		5: ["quest_code_tracer"],
		6: ["quest_conflict_mediation", "quest_road_blockade"],
	}
	for release_day in schedule.keys():
		if day < int(release_day):
			continue
		for quest_id in schedule[release_day]:
			if not _active_quests.has(quest_id):
				_add_quest(quest_id)
	check_time_limits()

## --- Accessors ---
func get_available_quests() -> Array:
	return _active_quests.values().filter(func(q): return q["status"] == QuestStatus.AVAILABLE).map(func(q): return q.duplicate(true))

func get_active_quests() -> Array:
	return _active_quests.values().filter(func(q): return q["status"] == QuestStatus.ACTIVE).map(func(q): return q.duplicate(true))

func get_completed_quests() -> Array:
	return _quest_history.filter(func(q): return q["status"] == QuestStatus.COMPLETED).duplicate(true)

func get_quest(quest_id: String) -> Dictionary:
	return _active_quests.get(quest_id, {}).duplicate(true)

func get_quest_summary() -> Dictionary:
	return {
		"total": _quest_history.size(),
		"completed": _quest_history.filter(func(q): return q["status"] == QuestStatus.COMPLETED).size(),
		"failed": _quest_history.filter(func(q): return q["status"] == QuestStatus.FAILED).size(),
		"active": get_active_quests().size(),
		"available": get_available_quests().size(),
	}

## --- Save/Load ---
func serialize() -> Dictionary:
	return {
		"active_quests": _active_quests.duplicate(true),
		"quest_history": _quest_history.duplicate(true),
		"quest_id_counter": _quest_id_counter,
	}

func deserialize(data: Dictionary) -> void:
	if data.has("active_quests"):
		_active_quests = data["active_quests"].duplicate(true)
	if data.has("quest_history"):
		_quest_history = data["quest_history"].duplicate(true)
	if data.has("quest_id_counter"):
		_quest_id_counter = data["quest_id_counter"]
