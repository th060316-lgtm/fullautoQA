extends Node
## GameState - 共通ゲーム状態管理 (Grok Core実装)
## 公開APIは共通インターフェース契約に準拠。MiniMaxは変更しない。

const SCHEMA_VERSION: int = 3
const MAX_DAY: int = 7
const MINUTES_PER_DAY: int = 24 * 60
const CampaignDefaults = preload("res://sandbox/FoundationDefaults.gd")

var _state: Dictionary = {}

func _ready() -> void:
	_init_default_state()

func _init_default_state() -> void:
	_state = {
		"meta": {
			"schemaVersion": SCHEMA_VERSION,
			"seed": 0,
			"day": 1,
			"minuteOfDay": 8 * 60,  # 08:00開始
		},
		"player": {
			"hp": 100.0,
			"max_hp": 100.0,
			"injury": 0.0,
			"fatigue": 0.0,
			"food": 3.0,
			"locationId": "base",
			"mode": "foot",  # "foot" | "kmf"
			"position": {"x": 64.0, "y": 64.0},
			"alive": true,
		},
		"kmf": {
			"owned": true,
			"boarded": false,
			"durability": 100.0,
			"max_durability": 100.0,
			"energy": 100.0,
			"max_energy": 100.0,
			"ammo": 30,
			"max_ammo": 30,
			"sensor": 100.0,
			"position": {"x": 96.0, "y": 64.0},
			"visibilityNoise": 0.0,
			"cargo_weight": 0.0,
			"max_cargo": 5.0,
			"maintenanceLoad": 0.0,
		},
		"heroine": {
			"id": "yui",
			"name": "水城ユイ",
			"alive": true,
			"present": true,
			"locationId": "base",
			"affection": 0,
			"interactionTotal": 0,
			"interactionRecent": 0,
			"trust": 0,
			"fear": 0,
			"dependence": 0,
			"emotions": {
				"joy": 0.0, "anger": 0.0, "sadness": 0.0, "fear": 0.0,
				"surprise": 0.0, "disgust": 0.0, "hope": 0.3, "anxiety": 0.2,
			},
			"currentAction": "idle",
			"currentGoal": "survive_with_player",
		},
		"npcs": {},  # MiniMax担当領域。汎用Dictionaryとして保持
		"world": {
			"socialUnrest": 20,
			"trafficChaos": 20,
			"militaryTension": 10,
			"geassSpread": 5,
			"codeHolderRegion": "unknown",
			"guardianRegion": "unknown",
		},
		"systemFacts": {},  # 確定事実。記憶改変で書換えない
		"reports": [],      # 証言・分析
		"quests": {},       # MiniMax担当。汎用保持
		"map": {
			"explored": {},  # cell_key -> true
		},
		"npcMemories": {},  # MiniMax担当。確定事実と分離
		"day1": _init_day1_state(),
		"campaign": CampaignDefaults.create_campaign(),
	}
	# SeedをRngServiceと同期
	if has_node("/root/RngService"):
		var seed_val = RngService.get_seed()
		_state["meta"]["seed"] = seed_val

# --- 公開API (契約準拠) ---

func get_snapshot() -> Dictionary:
	return _deep_copy(_state)

func apply_snapshot(snapshot: Dictionary) -> bool:
	if snapshot == null or snapshot.is_empty():
		push_error("GameState.apply_snapshot: empty snapshot")
		return false
	if not can_apply_snapshot(snapshot):
		return false
	var candidate: Dictionary = _deep_copy(snapshot)
	var meta: Dictionary = candidate.get("meta", {})
	var version := int(meta.get("schemaVersion", 1))
	# v1/v2 -> v3: retain unknown data and recursively add only missing defaults.
	meta["schemaVersion"] = SCHEMA_VERSION
	meta["day"] = int(meta.get("day", 1))
	meta["minuteOfDay"] = int(meta.get("minuteOfDay", 8 * 60))
	candidate["meta"] = meta
	var defaults: Dictionary = _create_default_snapshot()
	_merge_missing(candidate, defaults)
	var default_day1: Dictionary = _init_day1_state()
	if not candidate.has("day1") or not (candidate["day1"] is Dictionary):
		candidate["day1"] = default_day1
	else:
		var saved_day1: Dictionary = candidate["day1"]
		for key in default_day1.keys():
			if not saved_day1.has(key):
				saved_day1[key] = _deep_copy(default_day1[key])
		candidate["day1"] = saved_day1
	_state = candidate
	return true

func can_apply_snapshot(snapshot: Dictionary) -> bool:
	if snapshot == null or snapshot.is_empty():
		return false
	if snapshot.has("meta") and not (snapshot["meta"] is Dictionary):
		return false
	var version := int(snapshot.get("meta", {}).get("schemaVersion", 1))
	if version > SCHEMA_VERSION:
		push_warning("GameState: unsupported future schemaVersion %d" % version)
		return false
	if snapshot.has("campaign"):
		if not (snapshot["campaign"] is Dictionary):
			return false
		var campaign_version := int(snapshot["campaign"].get("schema_version", 1))
		if campaign_version > CampaignDefaults.CAMPAIGN_SCHEMA_VERSION:
			push_warning("GameState: unsupported future campaign schema_version %d" % campaign_version)
			return false
	return true

func _create_default_snapshot() -> Dictionary:
	var previous: Dictionary = _state
	_init_default_state()
	var defaults: Dictionary = _deep_copy(_state)
	_state = previous
	return defaults

func _merge_missing(target: Dictionary, defaults: Dictionary) -> void:
	for key in defaults.keys():
		if not target.has(key):
			target[key] = _deep_copy(defaults[key])
		elif target[key] is Dictionary and defaults[key] is Dictionary:
			_merge_missing(target[key], defaults[key])

func _init_day1_state() -> Dictionary:
	return {
		"schema_version": 2,
		"started": false,
		"start_minute": 8 * 60,
		"soft_deadline": 18 * 60,
		"hard_deadline": 22 * 60,
		"known_cases": [],
		"case_states": {},
		"inventory": {},
		"facilities": {
			"hospital": {"operational": true, "capacity": 0.7, "reason": "initial"},
			"evacuation_center": {"operational": true, "pressure": 0.3, "reason": "initial"},
			"maintenance": {"operational": true, "service_level": 0.8, "reason": "initial"},
		},
		"npc_runtime": {},
		"actions": [],
		"world_changes": {},
		"kmf_exposure": 0.0,
		"summary": {},
		"current_objective": "",
		"yui_talked": false,
		"road_blockade_cleared": false,
	}

func get_section(section_name: String) -> Dictionary:
	if _state.has(section_name):
		var sec = _state[section_name]
		if sec is Dictionary:
			return _deep_copy(sec)
		return {}
	return {}

func set_section(section_name: String, value: Dictionary, notify: bool = true) -> void:
	var old_value: Dictionary = get_section(section_name)
	_state[section_name] = _deep_copy(value)
	if not notify or old_value == value:
		return
	match section_name:
		"player":
			var old_mode := str(old_value.get("mode", "foot"))
			var new_mode := str(value.get("mode", "foot"))
			if old_mode != new_mode:
				EventBus.player_mode_changed.emit(new_mode)
			var old_loc := str(old_value.get("locationId", ""))
			var new_loc := str(value.get("locationId", ""))
			if old_loc != new_loc:
				EventBus.location_changed.emit(new_loc)
		"kmf":
			EventBus.kmf_state_changed.emit()
		"heroine":
			pass
		"world":
			pass

func advance_time(minutes: int) -> int:
	if minutes <= 0:
		return 0
	var meta: Dictionary = _state["meta"]
	var old_total := (int(meta["day"]) - 1) * MINUTES_PER_DAY + int(meta["minuteOfDay"])
	var max_total := (MAX_DAY - 1) * MINUTES_PER_DAY + (MINUTES_PER_DAY - 1)
	var new_total := mini(old_total + minutes, max_total)
	var actual_minutes := maxi(0, new_total - old_total)
	if actual_minutes <= 0:
		return 0
	meta["day"] = int(new_total / MINUTES_PER_DAY) + 1
	meta["minuteOfDay"] = new_total % MINUTES_PER_DAY
	_apply_time_effects(actual_minutes)
	EventBus.time_advanced.emit(actual_minutes)
	return actual_minutes

func get_day() -> int:
	return int(_state.get("meta", {}).get("day", 1))

func get_minute_of_day() -> int:
	return int(_state.get("meta", {}).get("minuteOfDay", 0))

# --- 追加便利API (Core内部用) ---

func is_player_alive() -> bool:
	return bool(_state.get("player", {}).get("alive", true))

func get_player_mode() -> String:
	return str(_state.get("player", {}).get("mode", "foot"))

func set_player_mode(mode: String) -> void:
	if mode != "foot" and mode != "kmf":
		push_error("Invalid player mode: " + mode)
		return
	var player = _state["player"]
	var kmf = _state["kmf"]
	if mode == "kmf":
		if not kmf.get("owned", false):
			push_warning("KMF not owned")
			return
		if kmf.get("durability", 0) <= 0:
			push_warning("KMF destroyed")
			return
		player["mode"] = "kmf"
		kmf["boarded"] = true
		# 位置同期
		player["position"] = kmf["position"].duplicate()
		kmf["visibilityNoise"] = 0.6  # 搭乗時目立つ
	else:
		player["mode"] = "foot"
		kmf["boarded"] = false
		kmf["visibilityNoise"] = 0.0
		# 降機時、KMF位置をプレイヤー近傍に残す
		kmf["position"] = player["position"].duplicate()
	EventBus.player_mode_changed.emit(mode)
	EventBus.kmf_state_changed.emit()
	EventBus.visibility_noise_changed.emit(float(kmf.get("visibilityNoise", 0.0)))

func get_player_position() -> Vector2:
	var pos = _state.get("player", {}).get("position", {"x": 0, "y": 0})
	return Vector2(float(pos.get("x", 0)), float(pos.get("y", 0)))

func set_player_position(pos: Vector2) -> void:
	_state["player"]["position"] = {"x": pos.x, "y": pos.y}
	if get_player_mode() == "kmf":
		_state["kmf"]["position"] = {"x": pos.x, "y": pos.y}

func set_player_location(location_id: String) -> void:
	if location_id.is_empty():
		return
	var player: Dictionary = _state["player"]
	if str(player.get("locationId", "")) == location_id:
		return
	player["locationId"] = location_id
	EventBus.location_changed.emit(location_id)

func get_player_location() -> String:
	return str(_state.get("player", {}).get("locationId", "base"))

func damage_player(amount: float) -> void:
	var player = _state["player"]
	player["hp"] = maxf(0.0, float(player["hp"]) - amount)
	if player["hp"] <= 0.0:
		player["alive"] = false
		player["hp"] = 0.0
	EventBus.player_hp_changed.emit(float(player["hp"]), float(player.get("max_hp", 100.0)))

func heal_player(amount: float) -> void:
	var player = _state["player"]
	player["hp"] = minf(float(player.get("max_hp", 100.0)), float(player["hp"]) + amount)
	EventBus.player_hp_changed.emit(float(player["hp"]), float(player.get("max_hp", 100.0)))

func add_fatigue(amount: float) -> void:
	var player = _state["player"]
	player["fatigue"] = clampf(float(player["fatigue"]) + amount, 0.0, 100.0)
	EventBus.player_fatigue_changed.emit(float(player["fatigue"]))

func consume_food(amount: float = 1.0) -> bool:
	var player = _state["player"]
	if float(player["food"]) < amount:
		return false
	player["food"] = float(player["food"]) - amount
	return true

func damage_kmf(amount: float) -> void:
	var kmf = _state["kmf"]
	kmf["durability"] = maxf(0.0, float(kmf["durability"]) - amount)
	if kmf["durability"] <= 0.0:
		kmf["durability"] = 0.0
		# KMF喪失は重大失敗だが即ゲームオーバーにしない
		if get_player_mode() == "kmf":
			set_player_mode("foot")
		kmf["owned"] = false  # 喪失扱い。再取得は別途
		kmf["boarded"] = false
	EventBus.kmf_state_changed.emit()

func consume_kmf_energy(amount: float) -> bool:
	var kmf = _state["kmf"]
	if float(kmf["energy"]) < amount:
		return false
	kmf["energy"] = float(kmf["energy"]) - amount
	EventBus.kmf_state_changed.emit()
	return true

func consume_kmf_ammo(amount: int = 1) -> bool:
	var kmf = _state["kmf"]
	if int(kmf["ammo"]) < amount:
		return false
	kmf["ammo"] = int(kmf["ammo"]) - amount
	EventBus.kmf_state_changed.emit()
	return true

func mark_explored(cell_x: int, cell_y: int) -> void:
	var key = "%d_%d" % [cell_x, cell_y]
	_state["map"]["explored"][key] = true

func is_explored(cell_x: int, cell_y: int) -> bool:
	var key = "%d_%d" % [cell_x, cell_y]
	return bool(_state.get("map", {}).get("explored", {}).get(key, false))

func add_system_fact(fact_id: String, payload: Dictionary) -> void:
	# 確定事実。記憶改変で書換えない
	if _state["systemFacts"].has(fact_id):
		return
	_state["systemFacts"][fact_id] = {
		"payload": payload.duplicate(true),
		"day": get_day(),
		"minute": get_minute_of_day(),
	}
	EventBus.fact_observed.emit(fact_id, payload)

func get_time_string() -> String:
	var day = get_day()
	var mod = get_minute_of_day()
	var h: int = int(mod / 60)
	var m = mod % 60
	return "Day %d %02d:%02d" % [day, h, m]

func dump_state() -> String:
	return JSON.stringify(_state, "\t")

func _apply_time_effects(minutes: int) -> void:
	# 簡易: 時間経過で疲労増加、食料消費判定
	var hours = float(minutes) / 60.0
	add_fatigue(hours * 2.0)
	# 4時間ごとに食料1消費（簡易）
	var player = _state["player"]
	var food_timer = float(player.get("_food_timer", 0.0)) + hours
	while food_timer >= 4.0:
		food_timer -= 4.0
		if not consume_food(1.0):
			# 食料不足でHP減少
			damage_player(5.0)
			add_fatigue(5.0)
	player["_food_timer"] = food_timer

func _deep_copy(d: Variant) -> Variant:
	if d is Dictionary:
		var out: Dictionary = {}
		for k in d.keys():
			out[k] = _deep_copy(d[k])
		return out
	elif d is Array:
		var out: Array = []
		for v in d:
			out.append(_deep_copy(v))
		return out
	else:
		return d

# --- Social/UI integration helper API ---
func get_meta_section() -> Dictionary:
	return get_section("meta")

func set_meta_section(data: Dictionary) -> void:
	set_section("meta", data)

func get_heroine() -> Dictionary:
	return get_section("heroine")

func set_heroine(data: Dictionary) -> void:
	set_section("heroine", data)

func get_npc(npc_id: String) -> Dictionary:
	var npcs: Dictionary = _state.get("npcs", {})
	return _deep_copy(npcs.get(npc_id, {}))

func set_npc(npc_id: String, data: Dictionary) -> void:
	if not _state.has("npcs") or not (_state["npcs"] is Dictionary):
		_state["npcs"] = {}
	_state["npcs"][npc_id] = _deep_copy(data)
	EventBus.npc_state_changed.emit(npc_id)

func get_all_npcs() -> Dictionary:
	return get_section("npcs")

func get_world() -> Dictionary:
	return get_section("world")

func set_world(data: Dictionary) -> void:
	set_section("world", data)

func get_reports() -> Array:
	return _deep_copy(_state.get("reports", []))

func add_report(report: Dictionary) -> void:
	if not _state.has("reports") or not (_state["reports"] is Array):
		_state["reports"] = []
	_state["reports"].append(_deep_copy(report))

func get_quests() -> Dictionary:
	return get_section("quests")

func set_quest(quest_id: String, data: Dictionary) -> void:
	if not _state.has("quests") or not (_state["quests"] is Dictionary):
		_state["quests"] = {}
	_state["quests"][quest_id] = _deep_copy(data)
	EventBus.quest_changed.emit(quest_id)

func get_system_facts() -> Dictionary:
	return get_section("systemFacts")

