# Day1Controller.gd
# Phase A World/Gameplay 50% implementation (Grok)
# EXT-20261019-014
# 状態: 未検証外部成果

extends Node
class_name Day1Controller

## --- 定数 ---
const DAY1_START_MINUTE: int = 8 * 60
const DAY1_SOFT_DEADLINE: int = 18 * 60   # 18:00
const DAY1_HARD_DEADLINE: int = 22 * 60   # 22:00

## 案件定義（既存quest idを優先使用）
const CASE_DEFS: Dictionary = {
	"quest_hospital_medicine": {
		"id": "quest_hospital_medicine",
		"name": "病院医薬品輸送",
		"initial_known": true,
		"region": "hospital",
		"required_location": "hospital",
		"required_item": "medicine_box",
		"required_npc": "aoi",
		"deadline_offset": 80,  # 09:20。全部は救えない短時間圧力
		"foot_advantage": "observe_and_stealth",
		"kmf_advantage": "fast_delivery",
		"description": "医薬品を病院へ届ける。徒歩は潜伏観察、KMFは高速輸送が有効。",
	},
	"quest_evacuation_rescue": {
		"id": "quest_evacuation_rescue",
		"name": "避難民救助",
		"initial_known": true,
		"region": "city_center",
		"required_location": "city_center",
		"required_item": "",
		"required_npc": "rei",
		"deadline_offset": 65,  # 09:05。救助は最優先級
		"foot_advantage": "close_talk",
		"kmf_advantage": "rubble_breakthrough_and_transport",
		"description": "市街に取り残された避難民を救助。徒歩は近接会話、KMFは瓦礫突破と輸送。",
	},
	"quest_supply_depot": {
		"id": "quest_supply_depot",
		"name": "食料倉庫確保",
		"initial_known": false,  # 世界側では開始済みだが初期unknown
		"region": "industrial_area",
		"required_location": "industrial_area",
		"required_item": "",
		"required_npc": "kenji",
		"deadline_offset": 100,  # 09:40。初期unknownのまま進行
		"foot_advantage": "stealth_approach",
		"kmf_advantage": "combat_superiority",
		"description": "工業地区の食料倉庫を確保。初期はunknown。報告/NPC情報から発見可能。",
	},
}

## Facility IDs
const FACILITY_IDS: Array = ["hospital", "evacuation_center", "maintenance"]

## NPC targets for goal-based movement
const GOAL_NPCS: Array = ["yui", "aoi", "sakura", "rei"]

var _gs: Node
var _qm: Node
var _eb: Node
var _nm: Node
var _initialized: bool = false
var _info_system: Node = null
var _consequence_system: Node = null
var _summary_system: Node = null

func _ready() -> void:
	_gs = get_node_or_null("/root/GameState")
	_qm = get_node_or_null("/root/QuestManager")
	_eb = get_node_or_null("/root/EventBus")
	_nm = get_node_or_null("/root/NpcManager")

## Main.gd から呼ばれる正式初期化
func initialize_day1() -> void:
	if _initialized:
		push_warning("Day1Controller: already initialized")
		return
	if _gs == null:
		push_error("Day1Controller: GameState not found")
		return

	var day1: Dictionary = _gs.get_section("day1")
	if day1.is_empty() or int(day1.get("schema_version", 0)) < 2:
		day1 = _default_day1_schema_v2()
	else:
		# ensure keys exist
		day1 = _ensure_schema_v2(day1)

	# 3案件を世界側で同時進行開始
	var known: Array = []
	var case_states: Dictionary = {}
	var start_min: int = int(day1.get("start_minute", DAY1_START_MINUTE))
	for case_id in CASE_DEFS.keys():
		var def: Dictionary = CASE_DEFS[case_id]
		var initially_known: bool = bool(def.get("initial_known", false))
		var st: Dictionary = {
			"known": initially_known,
			"accepted": initially_known,
			"status": "active" if initially_known else "available",
			"deadline_abs_minute": start_min + int(def.get("deadline_offset", 360)),
			"discovered_by": "",
			"result_reason": "",
			"progress": 0.0,
			"world_running": true,  # プレイヤーが知らなくても進行
		}
		if st["known"]:
			known.append(case_id)
			st["discovered_by"] = "initial"
		case_states[case_id] = st

	day1["started"] = true
	day1["known_cases"] = known
	day1["case_states"] = case_states
	day1["current_objective"] = "初期認知案件を確認し、優先して対応する"
	day1["kmf_exposure"] = 0.0
	_gs.set_section("day1", day1)

	# Facility初期状態
	_init_facilities(day1)

	# NPC runtime初期化（目的移動用）
	_init_npc_runtime(day1)

	# Optional MiniMax modules (存在しなくてもboot可能)
	_try_attach_optional_modules()

	_initialized = true
	_initialize_optional_modules()
	if _eb:
		_eb.debug_message.emit("Day1Controller PhaseA initialized. known=%d total_cases=3" % known.size())
	print("[Day1Controller] initialize_day1 complete. known_cases=%s" % str(known))

func _default_day1_schema_v2() -> Dictionary:
	return {
		"schema_version": 2,
		"started": false,
		"start_minute": DAY1_START_MINUTE,
		"soft_deadline": DAY1_SOFT_DEADLINE,
		"hard_deadline": DAY1_HARD_DEADLINE,
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

func _ensure_schema_v2(day1: Dictionary) -> Dictionary:
	if not day1.has("known_cases"):
		day1["known_cases"] = []
	if not day1.has("case_states"):
		day1["case_states"] = {}
	if not day1.has("facilities"):
		day1["facilities"] = {
			"hospital": {"operational": true, "capacity": 0.7, "reason": "initial"},
			"evacuation_center": {"operational": true, "pressure": 0.3, "reason": "initial"},
			"maintenance": {"operational": true, "service_level": 0.8, "reason": "initial"},
		}
	if not day1.has("npc_runtime"):
		day1["npc_runtime"] = {}
	if not day1.has("kmf_exposure"):
		day1["kmf_exposure"] = 0.0
	if not day1.has("summary"):
		day1["summary"] = {}
	day1["schema_version"] = 2
	return day1

func _init_facilities(day1: Dictionary) -> void:
	var fac: Dictionary = day1.get("facilities", {})
	for fid in FACILITY_IDS:
		if not fac.has(fid):
			match fid:
				"hospital":
					fac[fid] = {"operational": true, "capacity": 0.7, "reason": "initial"}
				"evacuation_center":
					fac[fid] = {"operational": true, "pressure": 0.3, "reason": "initial"}
				"maintenance":
					fac[fid] = {"operational": true, "service_level": 0.8, "reason": "initial"}
	day1["facilities"] = fac
	_gs.set_section("day1", day1)

func _init_npc_runtime(day1: Dictionary) -> void:
	var runtime: Dictionary = day1.get("npc_runtime", {})
	var defaults: Dictionary = {
		"yui": {"locationId": "base", "currentGoal": "support_player", "currentAction": "wait", "last_moved_minute": 0},
		"aoi": {"locationId": "base", "currentGoal": "medicine_request", "currentAction": "brief", "last_moved_minute": 0},
		"sakura": {"locationId": "evacuation_center", "currentGoal": "manage_evacuees", "currentAction": "coordinate", "last_moved_minute": 0},
		"rei": {"locationId": "city_center", "currentGoal": "wait_rescue", "currentAction": "shelter", "last_moved_minute": 0},
	}
	for nid in GOAL_NPCS:
		if not runtime.has(nid):
			runtime[nid] = defaults.get(nid, {"locationId": "base", "currentGoal": "survive", "currentAction": "idle", "last_moved_minute": 0}).duplicate(true)
	day1["npc_runtime"] = runtime
	_gs.set_section("day1", day1)
	# Sync to NpcManager if available
	if _nm:
		for nid in runtime.keys():
			if _nm.has_method("update_npc"):
				_nm.update_npc(nid, {"locationId": runtime[nid].get("locationId", "base")})

func _try_attach_optional_modules() -> void:
	# MiniMax modules: 存在しなくてもparse/boot可能
	var paths: Array = [
		"res://day1/Day1InformationSystem.gd",
		"res://day1/Day1ConsequenceSystem.gd",
		"res://day1/Day1SummarySystem.gd",
	]
	for p in paths:
		if ResourceLoader.exists(p):
			var scr = load(p)
			if scr:
				var inst = scr.new()
				if p.ends_with("InformationSystem.gd"):
					inst.name = "Day1InformationSystem"
				elif p.ends_with("ConsequenceSystem.gd"):
					inst.name = "Day1ConsequenceSystem"
				elif p.ends_with("SummarySystem.gd"):
					inst.name = "Day1SummarySystem"
				add_child(inst)
				if p.ends_with("InformationSystem.gd"):
					_info_system = inst
				elif p.ends_with("ConsequenceSystem.gd"):
					_consequence_system = inst
				elif p.ends_with("SummarySystem.gd"):
					_summary_system = inst
				print("[Day1Controller] Attached optional module: %s" % p)

func _initialize_optional_modules() -> void:
	if _info_system and _info_system.has_method("initialize_day1_info"):
		_info_system.initialize_day1_info()
	if _consequence_system and _consequence_system.has_method("initialize"):
		_consequence_system.initialize()

func serialize_runtime() -> Dictionary:
	return {
		"information": _info_system.serialize() if _info_system and _info_system.has_method("serialize") else {},
		"consequence": _consequence_system.serialize() if _consequence_system and _consequence_system.has_method("serialize") else {},
		"summary": _summary_system.serialize() if _summary_system and _summary_system.has_method("serialize") else {},
	}

func deserialize_runtime(data: Dictionary) -> void:
	if _info_system and _info_system.has_method("deserialize"):
		_info_system.deserialize(data.get("information", {}))
	if _consequence_system and _consequence_system.has_method("deserialize"):
		_consequence_system.deserialize(data.get("consequence", {}))
	if _summary_system and _summary_system.has_method("deserialize"):
		_summary_system.deserialize(data.get("summary", {}))

## --- 公開API (契約必須) ---

func discover_case(case_id: String, source: Dictionary = {}) -> bool:
	if not _initialized:
		return false
	var day1: Dictionary = _gs.get_section("day1")
	var states: Dictionary = day1.get("case_states", {})
	if not states.has(case_id):
		return false
	var st: Dictionary = states[case_id]
	if bool(st.get("known", false)):
		return false  # already known
	var old_status: String = str(st.get("status", "available"))
	st["known"] = true
	st["accepted"] = true
	st["discovered_by"] = str(source.get("sourceType", source.get("type", "unknown")))
	st["status"] = "active"
	states[case_id] = st
	var known: Array = day1.get("known_cases", [])
	if case_id not in known:
		known.append(case_id)
	day1["known_cases"] = known
	day1["case_states"] = states
	_gs.set_section("day1", day1)
	if _eb:
		_eb.day1_case_discovered.emit(case_id, source)
		_eb.day1_case_state_changed.emit(case_id, old_status, "active")
	print("[Day1Controller] Case discovered: %s via %s" % [case_id, st["discovered_by"]])
	return true

func accept_case(case_id: String) -> bool:
	if not _initialized:
		return false
	var day1: Dictionary = _gs.get_section("day1")
	var states: Dictionary = day1.get("case_states", {})
	if not states.has(case_id):
		return false
	var st: Dictionary = states[case_id]
	if not bool(st.get("known", false)):
		return false
	if bool(st.get("accepted", false)):
		return false
	if str(st.get("status", "")) in ["completed", "failed", "expired"]:
		return false
	var old_status: String = str(st.get("status", "available"))
	st["accepted"] = true
	st["status"] = "active"
	states[case_id] = st
	day1["case_states"] = states
	day1["current_objective"] = CASE_DEFS.get(case_id, {}).get("name", case_id)
	_gs.set_section("day1", day1)
	record_action("accept_case", {"case_id": case_id})
	if _eb:
		_eb.day1_case_state_changed.emit(case_id, old_status, "active")
	print("[Day1Controller] Accepted: %s" % case_id)
	return true

func get_case_state(case_id: String) -> Dictionary:
	if not _initialized or _gs == null:
		return {}
	var day1: Dictionary = _gs.get_section("day1")
	return day1.get("case_states", {}).get(case_id, {}).duplicate(true)

func get_known_cases() -> Array:
	if not _initialized or _gs == null:
		return []
	var day1: Dictionary = _gs.get_section("day1")
	return day1.get("known_cases", []).duplicate()

## Public overview for UI (known cases only; no hidden truth)
func get_case_overview(case_id: String) -> Dictionary:
	if not _initialized or _gs == null:
		return {}
	var day1: Dictionary = _gs.get_section("day1")
	var states: Dictionary = day1.get("case_states", {})
	if not states.has(case_id):
		return {}
	var st: Dictionary = states[case_id]
	if not bool(st.get("known", false)):
		return {}  # 未知案件は露出しない
	var def: Dictionary = CASE_DEFS.get(case_id, {})
	var now: int = _gs.get_minute_of_day()
	var deadline: int = int(st.get("deadline_abs_minute", 9999))
	var remaining: int = max(0, deadline - now)
	var status: String = str(st.get("status", "available"))
	# ETA estimates (prediction only; no route disclosure)
	var foot_eta: int = 25
	var kmf_eta: int = 12
	var action_est: int = 15
	match case_id:
		"quest_hospital_medicine":
			foot_eta = 30
			kmf_eta = 12
			action_est = 20
		"quest_evacuation_rescue":
			foot_eta = 22
			kmf_eta = 10
			action_est = 15
		"quest_supply_depot":
			foot_eta = 35
			kmf_eta = 15
			action_est = 25
	return {
		"id": case_id,
		"name": str(def.get("name", case_id)),
		"known": true,
		"status": status,
		"deadline_abs_minute": deadline,
		"remaining_minutes": remaining,
		"foot_eta_minutes": foot_eta,
		"kmf_eta_minutes": kmf_eta,
		"estimated_action_minutes": action_est,
		"location_id": str(def.get("required_location", "")),
		"resolution_method": str(st.get("result_reason", "")),
		"result_reason": str(st.get("result_reason", "")),
		"progress": float(st.get("progress", 0.0)),
	}

func get_known_case_overviews() -> Array:
	var out: Array = []
	for cid in get_known_cases():
		var ov: Dictionary = get_case_overview(str(cid))
		if not ov.is_empty():
			out.append(ov)
	return out

func record_action(action_type: String, payload: Dictionary = {}) -> Dictionary:
	if not _initialized:
		return {}
	var day1: Dictionary = _gs.get_section("day1")
	var actions: Array = day1.get("actions", [])
	var action: Dictionary = {
		"id": "d%d_m%d_a%d" % [_gs.get_day(), _gs.get_minute_of_day(), actions.size()],
		"type": action_type,
		"payload": payload.duplicate(true),
		"minute": _gs.get_minute_of_day() if _gs else 0,
		"day": _gs.get_day() if _gs else 1,
		"mode": _gs.get_player_mode() if _gs and _gs.has_method("get_player_mode") else "foot",
		"locationId": _gs.get_section("player").get("locationId", "base") if _gs else "base",
	}
	# Contract: payload keys are also available at top level for consequence consumers.
	for key in payload.keys():
		action[key] = payload[key]
	actions.append(action)
	day1["actions"] = actions
	_gs.set_section("day1", day1)
	if _eb:
		_eb.day1_action_committed.emit(action)
	return action

func get_actions() -> Array:
	if not _initialized or _gs == null:
		return []
	return _gs.get_section("day1").get("actions", []).duplicate(true)

func get_facility_state(facility_id: String) -> Dictionary:
	if not _initialized or _gs == null:
		return {}
	var day1: Dictionary = _gs.get_section("day1")
	return day1.get("facilities", {}).get(facility_id, {}).duplicate(true)

func apply_facility_delta(facility_id: String, changes: Dictionary, reason: String) -> bool:
	if not _initialized or _gs == null:
		return false
	if facility_id not in FACILITY_IDS:
		return false
	var day1: Dictionary = _gs.get_section("day1")
	var facs: Dictionary = day1.get("facilities", {})
	var fac: Dictionary = facs.get(facility_id, {}).duplicate(true)
	for k in changes.keys():
		fac[k] = changes[k]
	fac["reason"] = reason
	facs[facility_id] = fac
	day1["facilities"] = facs
	_gs.set_section("day1", day1)
	if _eb:
		_eb.day1_facility_changed.emit(facility_id, fac.duplicate(true), reason)
	print("[Day1Controller] Facility %s changed: %s reason=%s" % [facility_id, str(changes), reason])
	return true

func get_current_objective() -> String:
	if not _initialized or _gs == null:
		return ""
	return str(_gs.get_section("day1").get("current_objective", ""))

func get_deadline_text() -> String:
	if not _initialized or _gs == null:
		return "期限: ---"
	var day1: Dictionary = _gs.get_section("day1")
	var nearest: int = 99999
	for case_id in day1.get("known_cases", []):
		var st: Dictionary = day1.get("case_states", {}).get(case_id, {})
		if str(st.get("status", "")) in ["active", "available"]:
			nearest = mini(nearest, int(st.get("deadline_abs_minute", 99999)))
	if nearest >= 99999:
		return "期限: Day1案件終了"
	return "期限: 最短 %02d:%02d" % [int(nearest / 60), nearest % 60]

func is_initialized() -> bool:
	return _initialized

## --- World condition based completion (G2) ---
## 無条件完了禁止。location / item / NPC / deadline を使用

func try_complete_case(case_id: String, context: Dictionary = {}) -> bool:
	if not _initialized:
		_emit_day1_feedback("failure", "not_initialized", case_id, "未初期化", "Day1未初期化", "try_complete")
		return false
	var day1: Dictionary = _gs.get_section("day1")
	var states: Dictionary = day1.get("case_states", {})
	if not states.has(case_id):
		_emit_day1_feedback("failure", "unknown_case", case_id, "未知の案件", "案件ID不正", "try_complete")
		return false
	var st: Dictionary = states[case_id]
	var cur_status: String = str(st.get("status", ""))
	if cur_status == "completed":
		_emit_day1_feedback("info", "already_completed", case_id, "既に完了", "この案件は完了済みです", "try_complete")
		return true  # 成功扱いで矛盾を解消。二重適用は後続で防止
	if cur_status in ["failed", "expired"]:
		_emit_day1_feedback("failure", "already_failed", case_id, "既に失敗/期限切れ", str(st.get("result_reason", "")), "try_complete")
		return false
	if cur_status != "active":
		_emit_day1_feedback("warning", "not_active", case_id, "進行中でない", cur_status, "try_complete")
		return false
	if not bool(st.get("known", false)):
		_emit_day1_feedback("failure", "unknown_to_player", case_id, "未発見案件", "先に発見が必要", "try_complete")
		return false

	var def: Dictionary = CASE_DEFS.get(case_id, {})
	var player_loc: String = str(_gs.get_section("player").get("locationId", ""))
	var mode: String = str(_gs.get_section("player").get("mode", "foot"))
	var inv: Dictionary = day1.get("inventory", {})
	var now: int = _gs.get_minute_of_day()

	# deadline check
	var deadline: int = int(st.get("deadline_abs_minute", 9999))
	if now > deadline:
		_fail_case(case_id, "deadline_exceeded")
		_emit_day1_feedback("failure", "deadline_exceeded", case_id, "期限切れ", "期限を過ぎたため失敗", "try_complete")
		return false

	var ok: bool = false
	var reason: String = ""

	match case_id:
		"quest_hospital_medicine":
			var has_item: bool = bool(inv.get("medicine_box", false)) or bool(context.get("has_medicine", false))
			var at_loc: bool = player_loc == "hospital" or player_loc == def.get("required_location", "hospital")
			var talked_aoi: bool = bool(day1.get("aoi_talked", false)) or bool(context.get("talked_aoi", false))
			if at_loc and has_item and talked_aoi:
				ok = true
				reason = "delivered_medicine"
				apply_facility_delta("hospital", {"capacity": min(1.0, float(get_facility_state("hospital").get("capacity", 0.5)) + 0.2), "reason": "medicine_delivered"}, "medicine_delivered")
				day1 = _gs.get_section("day1")
				day1["hospital_success"] = true
			elif OS.is_debug_build() and bool(context.get("force", false)):
				ok = true
				reason = "debug_force"
			else:
				var miss: String = ""
				if not at_loc:
					miss = "wrong_location"
				elif not has_item:
					miss = "missing_item"
				else:
					miss = "missing_npc_talk"
				_emit_day1_feedback("failure", miss, case_id, "条件不足", miss, "try_complete")
				return false

		"quest_evacuation_rescue":
			var at_loc: bool = player_loc == "evacuation_center" or player_loc == "city_center"
			var talked: bool = bool(context.get("talked_rei", false)) or bool(day1.get("rei_talked", false))
			var rescued: bool = bool(context.get("rescued", false)) or bool(day1.get("rescued_evacuees", false))
			if (at_loc or player_loc == "evacuation_center") and talked and rescued:
				if mode == "kmf" or bool(context.get("used_kmf_transport", false)):
					ok = true
					reason = "kmf_rescue_transport"
				elif mode == "foot" and talked:
					ok = true
					reason = "foot_close_talk_escort"
				else:
					_emit_day1_feedback("failure", "mode_mismatch", case_id, "条件不足", "mode", "try_complete")
					return false
				apply_facility_delta("evacuation_center", {"pressure": max(0.0, float(get_facility_state("evacuation_center").get("pressure", 0.5)) - 0.15), "reason": "evacuees_rescued"}, "evacuees_rescued")
				day1 = _gs.get_section("day1")
				day1["rescue_success"] = true
				day1["rescued_evacuees"] = true
				# mark rescued for summary
				if not day1.has("rescued_npcs"):
					day1["rescued_npcs"] = []
				if not "rei" in day1["rescued_npcs"]:
					day1["rescued_npcs"].append("rei")
			elif OS.is_debug_build() and bool(context.get("force", false)):
				ok = true
				reason = "debug_force"
			else:
				_emit_day1_feedback("failure", "conditions_not_met", case_id, "条件不足", "talk/rescued/loc", "try_complete")
				return false

		"quest_supply_depot":
			var at_loc: bool = player_loc == "industrial_area" or player_loc == def.get("required_location", "industrial_area")
			var cleared: bool = bool(context.get("enemies_cleared", false)) or bool(day1.get("supply_cleared", false))
			if at_loc and cleared:
				ok = true
				reason = str(day1.get("supply_method", "depot_secured"))
				if reason == "":
					reason = "depot_secured"
				day1["depot_success"] = true
			elif OS.is_debug_build() and bool(context.get("force", false)):
				ok = true
				reason = "debug_force"
			else:
				_emit_day1_feedback("failure", "not_cleared", case_id, "未確保", "敵排除または潜伏未完了", "try_complete")
				return false

		_:
			return false

	if ok:
		var old_status: String = str(st.get("status", "active"))
		st["status"] = "completed"
		st["result_reason"] = reason
		st["progress"] = 1.0
		states[case_id] = st
		day1["case_states"] = states
		_gs.set_section("day1", day1)
		record_action("complete_case", {"case_id": case_id, "reason": reason, "mode": mode})
		var service_costs = {
			"quest_hospital_medicine": 20,
			"quest_evacuation_rescue": 15,
			"quest_supply_depot": 20,
		}
		_gs.advance_time(int(service_costs.get(case_id, 10)))
		if _eb:
			_eb.day1_case_state_changed.emit(case_id, old_status, "completed")
			_eb.quest_completed.emit(case_id, true)
		_emit_day1_feedback("success", "case_completed", case_id, str(CASE_DEFS.get(case_id, {}).get("name", case_id)) + " 完了", reason, "try_complete")
		print("[Day1Controller] Case completed: %s reason=%s" % [case_id, reason])
		return true
	return false

func _fail_case(case_id: String, reason: String) -> void:
	var day1: Dictionary = _gs.get_section("day1")
	var states: Dictionary = day1.get("case_states", {})
	if not states.has(case_id):
		return
	var st: Dictionary = states[case_id]
	if str(st.get("status", "")) in ["completed", "failed", "expired"]:
		return
	var old_status: String = str(st.get("status", "active"))
	st["status"] = "expired" if reason == "deadline_exceeded" else "failed"
	st["result_reason"] = reason
	states[case_id] = st
	day1["case_states"] = states
	_gs.set_section("day1", day1)
	# 状況悪化例
	if case_id == "quest_hospital_medicine":
		apply_facility_delta("hospital", {"capacity": max(0.1, float(get_facility_state("hospital").get("capacity", 0.5)) - 0.25), "operational": true}, "medicine_late")
	elif case_id == "quest_evacuation_rescue":
		apply_facility_delta("evacuation_center", {"pressure": min(1.0, float(get_facility_state("evacuation_center").get("pressure", 0.5)) + 0.2)}, "rescue_failed")
	if _eb:
		_eb.day1_case_state_changed.emit(case_id, old_status, st["status"])
	print("[Day1Controller] Case %s -> %s (%s)" % [case_id, st["status"], reason])

## 時間進行時に呼ぶ（Main or time_advanced接続）
func on_time_advanced(minutes: int) -> void:
	if not _initialized:
		return
	var day1: Dictionary = _gs.get_section("day1")
	var states: Dictionary = day1.get("case_states", {})
	var now: int = _gs.get_minute_of_day()
	for case_id in states.keys():
		var st: Dictionary = states[case_id]
		if str(st.get("status", "")) in ["completed", "failed", "expired"]:
			continue
		if not bool(st.get("world_running", true)):
			continue
		# プレイヤーが知らなくてもdeadline進行
		var deadline: int = int(st.get("deadline_abs_minute", 9999))
		if now > deadline:
			_fail_case(case_id, "deadline_exceeded")
			continue
		# 状況悪化（例: pressure上昇）
		if case_id == "quest_evacuation_rescue" and str(st.get("status", "")) != "completed":
			var pressure: float = float(get_facility_state("evacuation_center").get("pressure", 0.3))
			if pressure < 0.9:
				apply_facility_delta("evacuation_center", {"pressure": min(1.0, pressure + 0.02 * (minutes / 30.0))}, "time_pressure")
	# Hidden third case is not in initial player awareness.
	# After at least 20 in-game minutes, testimony/report reaches the player.
	if _info_system and now >= DAY1_START_MINUTE + 20:
		if _info_system.has_method("setup_day1_contradiction"):
			_info_system.setup_day1_contradiction()

	# NPC目的移動
	_update_npc_goals(minutes)

## --- G3: 徒歩/KMF固有能力 ---

func perform_foot_action(action: String, context: Dictionary = {}) -> Dictionary:
	## 徒歩固有: 屋内、近接会話、観察、低発見/潜伏。倉庫は観測+潜伏+探索でKMFなし成功可能。
	if not _initialized:
		return {"ok": false, "reason": "not_initialized"}
	var mode: String = str(_gs.get_section("player").get("mode", "foot"))
	if mode != "foot":
		return {"ok": false, "reason": "not_foot_mode"}
	var result: Dictionary = {"ok": false, "action": action, "code": "ok"}
	var player_loc: String = str(_gs.get_section("player").get("locationId", ""))
	var day1: Dictionary = _gs.get_section("day1")
	match action:
		"observe":
			result["ok"] = true
			result["info"] = context.get("target", "area")
			record_action("foot_observe", {"target": context.get("target", ""), "stealth": true, "location": player_loc})
			day1 = _gs.get_section("day1")
			if _eb:
				_eb.day1_information_recorded.emit({"type": "observation", "source": "player_foot", "content": str(context.get("target", ""))})
			# industrial observe contributes to depot progress
			if player_loc == "industrial_area" or str(context.get("target", "")) == "industrial_area" or str(context.get("target", "")) == "supply_depot":
				var progress: float = float(day1.get("supply_stealth_progress", 0.0))
				progress = min(1.0, progress + 0.35)
				day1["supply_stealth_progress"] = progress
				if progress >= 0.7:
					day1["supply_observed"] = true
				_gs.set_section("day1", day1)
				result["progress"] = progress
		"close_talk":
			var npc_id: String = str(context.get("npc_id", ""))
			if npc_id == "":
				return {"ok": false, "reason": "no_npc", "code": "missing_npc"}
			result["ok"] = true
			result["npc"] = npc_id
			record_action("foot_close_talk", {"npc_id": npc_id})
			day1 = _gs.get_section("day1")
			if npc_id == "rei":
				day1["rei_talked"] = true
				_gs.set_section("day1", day1)
			elif npc_id == "aoi":
				day1["aoi_talked"] = true
				_gs.set_section("day1", day1)
			elif npc_id == "kenji":
				day1["kenji_talked"] = true
				# talking to kenji at depot can help secure
				if player_loc == "industrial_area":
					day1["supply_contact"] = true
				_gs.set_section("day1", day1)
		"stealth_move":
			result["ok"] = true
			record_action("foot_stealth", {"location": context.get("location", player_loc)})
			day1 = _gs.get_section("day1")
			if player_loc == "industrial_area" or str(context.get("location", "")) == "industrial_area":
				var progress2: float = float(day1.get("supply_stealth_progress", 0.0))
				progress2 = min(1.0, progress2 + 0.4)
				day1["supply_stealth_progress"] = progress2
				if progress2 >= 0.9 or (bool(day1.get("supply_observed", false)) and progress2 >= 0.6):
					day1["supply_cleared"] = true
					day1["supply_method"] = "foot_stealth"
				_gs.set_section("day1", day1)
				result["progress"] = progress2
				result["cleared"] = bool(day1.get("supply_cleared", false))
		"indoor_search":
			result["ok"] = true
			record_action("foot_indoor_search", context)
			day1 = _gs.get_section("day1")
			if bool(context.get("find_medicine", false)):
				var inv = day1.get("inventory", {})
				inv["medicine_box"] = true
				day1["inventory"] = inv
				_gs.set_section("day1", day1)
			# search at industrial can secure depot via stealth path
			if player_loc == "industrial_area" or str(context.get("location", "")) == "industrial_area":
				var progress3: float = float(day1.get("supply_stealth_progress", 0.0))
				progress3 = min(1.0, progress3 + 0.5)
				day1["supply_stealth_progress"] = progress3
				if progress3 >= 0.8 or bool(day1.get("supply_observed", false)):
					day1["supply_cleared"] = true
					day1["supply_method"] = "foot_search"
				_gs.set_section("day1", day1)
				result["progress"] = progress3
				result["cleared"] = bool(day1.get("supply_cleared", false))
		"approach":
			# approach for close interaction without combat
			result["ok"] = true
			record_action("foot_approach", {"target": context.get("target", ""), "location": player_loc})
			day1 = _gs.get_section("day1")
			if player_loc == "industrial_area":
				var progress4: float = float(day1.get("supply_stealth_progress", 0.0))
				progress4 = min(1.0, progress4 + 0.25)
				day1["supply_stealth_progress"] = progress4
				_gs.set_section("day1", day1)
				result["progress"] = progress4
		_:
			return {"ok": false, "reason": "unknown_foot_action", "code": "unknown_action"}
	if bool(result.get("ok", false)):
		var foot_costs = {"observe": 10, "close_talk": 5, "stealth_move": 15, "indoor_search": 20, "approach": 8}
		_gs.advance_time(int(foot_costs.get(action, 5)))
		# fatigue cost for foot (no KMF resources)
		if _gs.has_method("add_fatigue"):
			_gs.add_fatigue(float(foot_costs.get(action, 5)) * 0.15)
		_emit_day1_feedback("info", "foot_" + action, "", "徒歩行動: " + action, "成功", action)
	return result

func perform_kmf_action(action: String, context: Dictionary = {}) -> Dictionary:
	## KMF固有: 高速、瓦礫/封鎖突破、救助/輸送、戦闘優位。資源は一回のみ消費。
	if not _initialized:
		return {"ok": false, "reason": "not_initialized", "code": "not_initialized"}
	var mode: String = str(_gs.get_section("player").get("mode", "foot"))
	if mode != "kmf":
		return {"ok": false, "reason": "not_kmf_mode", "code": "wrong_mode"}
	var result: Dictionary = {"ok": false, "action": action, "code": "ok"}
	var noise: float = 8.0
	# Resource costs (applied exactly once per successful action)
	var energy_cost: float = 0.0
	var ammo_cost: int = 0
	var durability_cost: float = 0.0
	match action:
		"high_speed_travel":
			energy_cost = 8.0
			durability_cost = 1.5
			noise = 6.0
		"rubble_breakthrough":
			energy_cost = 15.0
			durability_cost = 4.0
			noise = 12.0
		"rescue_transport":
			energy_cost = 12.0
			durability_cost = 2.5
			noise = 10.0
		"combat_superiority":
			energy_cost = 18.0
			ammo_cost = 6
			durability_cost = 5.0
			noise = 15.0
		_:
			return {"ok": false, "reason": "unknown_kmf_action", "code": "unknown_action"}

	# Pre-check resources (no double charge)
	var kmf_sec: Dictionary = _gs.get_section("kmf")
	if float(kmf_sec.get("energy", 0)) < energy_cost:
		return {"ok": false, "reason": "insufficient_energy", "code": "no_energy", "needed": energy_cost}
	if ammo_cost > 0 and int(kmf_sec.get("ammo", 0)) < ammo_cost:
		return {"ok": false, "reason": "insufficient_ammo", "code": "no_ammo", "needed": ammo_cost}
	if float(kmf_sec.get("durability", 0)) <= 0.0:
		return {"ok": false, "reason": "kmf_destroyed", "code": "destroyed"}

	# Apply costs exactly once
	if energy_cost > 0.0 and _gs.has_method("consume_kmf_energy"):
		_gs.consume_kmf_energy(energy_cost)
	if ammo_cost > 0 and _gs.has_method("consume_kmf_ammo"):
		_gs.consume_kmf_ammo(ammo_cost)
	if durability_cost > 0.0 and _gs.has_method("damage_kmf"):
		_gs.damage_kmf(durability_cost)
	var kmf_after_cost: Dictionary = _gs.get_section("kmf")
	kmf_after_cost["maintenanceLoad"] = float(kmf_after_cost.get("maintenanceLoad", 0.0)) + durability_cost + energy_cost * 0.05 + float(ammo_cost) * 0.1
	_gs.set_section("kmf", kmf_after_cost)

	result["ok"] = true
	result["energy_spent"] = energy_cost
	result["ammo_spent"] = ammo_cost
	result["durability_spent"] = durability_cost
	result["noise"] = noise

	var day1: Dictionary = _gs.get_section("day1")
	match action:
		"high_speed_travel":
			record_action("kmf_high_speed", {"to": context.get("to", ""), "noise": noise, "mode": "kmf", "energy": energy_cost})
		"rubble_breakthrough":
			day1["road_blockade_cleared"] = true
			if not day1.has("world_changes"):
				day1["world_changes"] = {}
			day1["world_changes"]["road_blockade"] = "cleared"
			_gs.set_section("day1", day1)
			record_action("kmf_rubble_breakthrough", {"noise": noise, "mode": "kmf", "energy": energy_cost, "durability": durability_cost})
		"rescue_transport":
			day1["rescued_evacuees"] = true
			_gs.set_section("day1", day1)
			record_action("kmf_rescue_transport", {"from": context.get("from", ""), "to": context.get("to", ""), "noise": noise, "mode": "kmf", "energy": energy_cost})
		"combat_superiority":
			day1["supply_cleared"] = true
			day1["supply_method"] = "kmf_combat"
			_gs.set_section("day1", day1)
			record_action("kmf_combat", {"enemies": context.get("enemies", 3), "noise": noise, "mode": "kmf", "ammo": ammo_cost, "energy": energy_cost})

	var time_costs = {"high_speed_travel": 5, "rubble_breakthrough": 15, "rescue_transport": 20, "combat_superiority": 25}
	_gs.advance_time(int(time_costs.get(action, 10)))
	day1 = _gs.get_section("day1")
	# exposure increase
	var old_exp: float = float(day1.get("kmf_exposure", 0.0))
	var new_exp: float = min(100.0, old_exp + noise * 0.8)
	day1["kmf_exposure"] = new_exp
	_gs.set_section("day1", day1)
	if _eb and _eb.has_signal("day1_kmf_exposure_changed"):
		_eb.day1_kmf_exposure_changed.emit(old_exp, new_exp, action)
	var heroine = get_node_or_null("/root/HeroineSystem")
	if heroine:
		if heroine.has_method("modify_fear"):
			heroine.modify_fear(2 if noise < 12.0 else 4)
		if heroine.has_method("modify_trust") and noise >= 12.0:
			heroine.modify_trust(-1)
	_emit_day1_feedback("info", "kmf_" + action, "", "KMF行動: " + action, "資源消費済", action)
	return result

## --- G4: NPC目的移動 ---

func _update_npc_goals(minutes: int) -> void:
	if not _initialized or _gs == null:
		return
	var day1: Dictionary = _gs.get_section("day1")
	var runtime: Dictionary = day1.get("npc_runtime", {})
	var now: int = _gs.get_minute_of_day()
	var states: Dictionary = day1.get("case_states", {})

	for nid in GOAL_NPCS:
		if not runtime.has(nid):
			continue
		var rt: Dictionary = runtime[nid]
		var from_loc: String = str(rt.get("locationId", "base"))
		var goal: String = str(rt.get("currentGoal", "survive"))
		var new_loc: String = from_loc
		var reason: String = ""

		match nid:
			"yui":
				# プレイヤー支援。危険が高まるとbaseへ
				if float(day1.get("kmf_exposure", 0.0)) > 30.0:
					new_loc = "base"
					reason = "high_kmf_exposure_shelter"
					rt["currentGoal"] = "shelter"
				elif now > 16 * 60:
					new_loc = "base"
					reason = "evening_return"
			"aoi":
				# Aoi briefs the player at base and only heads to hospital after
				# the medicine cargo has been handed over.
				var st = states.get("quest_hospital_medicine", {})
				var inv: Dictionary = day1.get("inventory", {})
				if str(st.get("status", "")) == "active" and not bool(inv.get("medicine_box", false)):
					new_loc = "base"
					rt["currentGoal"] = "hand_over_medicine"
				elif str(st.get("status", "")) == "active":
					new_loc = "hospital"
					reason = "medicine_delivery_support"
					rt["currentGoal"] = "assist_medicine"
				elif not bool(st.get("known", true)):
					new_loc = "base"
				else:
					if now > 14 * 60 and from_loc != "hospital":
						new_loc = "hospital"
						reason = "check_hospital_status"
			"sakura":
				# 避難所管理
				var pressure: float = float(get_facility_state("evacuation_center").get("pressure", 0.3))
				if pressure > 0.6:
					new_loc = "evacuation_center"
					reason = "high_pressure_manage"
					rt["currentGoal"] = "manage_evacuees"
				elif now > 15 * 60:
					new_loc = "evacuation_center"
					reason = "evening_coordination"
			"rei":
				# 救助待ち。救助案件がactiveなら待機継続、完了後はevacへ
				var st = states.get("quest_evacuation_rescue", {})
				if str(st.get("status", "")) == "completed":
					new_loc = "evacuation_center"
					reason = "rescued_move_to_center"
					rt["currentGoal"] = "settle"
				elif str(st.get("status", "")) == "expired" or str(st.get("status", "")) == "failed":
					# 危険回避で移動を試みるが失敗しやすい
					if now % 60 < 10:
						new_loc = "city_center"
						reason = "desperate_wait"
				else:
					new_loc = "city_center"
					reason = "awaiting_rescue"

		if new_loc != from_loc:
			rt["locationId"] = new_loc
			rt["last_moved_minute"] = now
			rt["currentAction"] = "moving"
			runtime[nid] = rt
			day1["npc_runtime"] = runtime
			_gs.set_section("day1", day1)
			if _nm and _nm.has_method("update_npc"):
				_nm.update_npc(nid, {"locationId": new_loc, "currentGoal": rt.get("currentGoal", ""), "currentAction": "moving"})
			if _eb:
				_eb.day1_npc_moved.emit(nid, from_loc, new_loc, reason)
			print("[Day1Controller] NPC moved: %s %s -> %s (%s)" % [nid, from_loc, new_loc, reason])
		else:
			rt["currentAction"] = "idle" if goal == "survive" else "acting"
			runtime[nid] = rt

	day1["npc_runtime"] = runtime
	_gs.set_section("day1", day1)

## 外部からNPC移動を強制/要求
func request_npc_move(npc_id: String, to_location: String, reason: String = "external") -> bool:
	if not _initialized or npc_id not in GOAL_NPCS:
		return false
	var day1: Dictionary = _gs.get_section("day1")
	var runtime: Dictionary = day1.get("npc_runtime", {})
	if not runtime.has(npc_id):
		return false
	var rt: Dictionary = runtime[npc_id]
	var from_loc: String = str(rt.get("locationId", "base"))
	if from_loc == to_location:
		return true
	rt["locationId"] = to_location
	rt["last_moved_minute"] = _gs.get_minute_of_day()
	rt["currentAction"] = "moving"
	runtime[npc_id] = rt
	day1["npc_runtime"] = runtime
	_gs.set_section("day1", day1)
	if _nm and _nm.has_method("update_npc"):
		_nm.update_npc(npc_id, {"locationId": to_location})
	if _eb:
		_eb.day1_npc_moved.emit(npc_id, from_loc, to_location, reason)
	return true

## インタラクト入口
func _map_manager() -> Node:
	var root = get_tree().root if get_tree() else null
	return root.find_child("MapManager", true, false) if root else null

func _player_node() -> Node:
	return get_tree().get_first_node_in_group("player") if get_tree() else null

func _is_npc_in_interaction_range(npc_id: String, max_distance: float = 72.0) -> bool:
	var map = _map_manager()
	var player_node = _player_node()
	if map == null or player_node == null or not map.has_method("get_npc_marker_position"):
		return false
	var marker_pos: Vector2 = map.get_npc_marker_position(npc_id)
	if marker_pos.x < -9000.0:
		return false
	return player_node.global_position.distance_to(marker_pos) <= max_distance

func _resolve_interaction_target() -> String:
	if _nm == null:
		return ""
	var player_loc: String = str(_gs.get_section("player").get("locationId", "base"))
	var map = _map_manager()
	var player_node = _player_node()
	if map and player_node and map.has_method("get_nearest_npc_id"):
		var nearest: String = str(map.get_nearest_npc_id(player_node.global_position, 72.0))
		if nearest != "":
			var npc: Dictionary = _nm.get_npc(nearest)
			if not npc.is_empty() and bool(npc.get("alive", true)) and bool(npc.get("present", true)):
				if str(npc.get("locationId", "")) == player_loc:
					return nearest
	return ""

func try_interact(target_id: String = "") -> bool:
	if not _initialized:
		return false
	var day1: Dictionary = _gs.get_section("day1")
	var player: Dictionary = _gs.get_section("player")
	var player_loc: String = str(player.get("locationId", "base"))
	var mode: String = str(player.get("mode", "foot"))

	if target_id == "":
		target_id = _resolve_interaction_target()

	# A named NPC can only be interacted with in the same semantic location.
	if target_id != "" and _nm:
		var target: Dictionary = _nm.get_npc(target_id)
		if target.is_empty() or not bool(target.get("alive", true)) or not bool(target.get("present", true)):
			return false
		if str(target.get("locationId", "")) != player_loc:
			return false
		if not _is_npc_in_interaction_range(target_id):
			return false

	if target_id == "yui":
		var talk_count: int = int(day1.get("yui_talk_count", 0)) + 1
		day1["yui_talk_count"] = talk_count
		var heroine = get_node_or_null("/root/HeroineSystem")
		if not bool(day1.get("yui_talked", false)):
			day1["yui_talked"] = true
			day1["current_objective"] = "病院と市街救助のどちらを先にするか決める"
			_gs.set_section("day1", day1)
			record_action("talk", {"npc": "yui", "conversation": "initial_briefing"})
			if heroine and heroine.has_method("on_conversation_result"):
				heroine.on_conversation_result("shared_info", {"source": "day1_initial"})
			_gs.advance_time(5)
			return true
		_gs.set_section("day1", day1)
		var completed_count: int = 0
		for case_state in day1.get("case_states", {}).values():
			if str(case_state.get("status", "")) == "completed":
				completed_count += 1
		var result_type: String = "helped" if completed_count > 0 else "shared_info"
		record_action("talk", {"npc": "yui", "conversation": "follow_up", "completed_cases": completed_count})
		if heroine and heroine.has_method("on_conversation_result"):
			heroine.on_conversation_result(result_type, {"source": "day1_follow_up", "completed_cases": completed_count})
		_gs.advance_time(5)
		return true

	if target_id == "aoi":
		day1["aoi_talked"] = true
		# Persist the conversation flag in every location, not only at base.
		_gs.set_section("day1", day1)
		var inv: Dictionary = day1.get("inventory", {})
		# At base, Aoi hands over the medicine cargo; delivery must occur at hospital.
		if player_loc == "base" and not bool(inv.get("medicine_box", false)):
			inv["medicine_box"] = true
			day1["inventory"] = inv
			_gs.set_section("day1", day1)
			record_action("talk", {"npc": "aoi", "topic": "medicine_received"})
			_gs.advance_time(5)
			return true
		record_action("talk", {"npc": "aoi", "topic": "medicine"})
		if player_loc == "hospital":
			return try_complete_case("quest_hospital_medicine", {"talked_aoi": true})
		return true

	if target_id == "rei":
		day1["rei_talked"] = true
		day1["escorting_rei"] = true
		_gs.set_section("day1", day1)
		record_action("talk", {"npc": "rei", "topic": "rescue"})
		if mode == "kmf":
			perform_kmf_action("rescue_transport", {"from": "city_center", "to": "evacuation_center"})
			day1 = _gs.get_section("day1")
			day1["used_kmf_transport"] = true
			_gs.set_section("day1", day1)
		else:
			perform_foot_action("close_talk", {"npc_id": "rei"})
		return true

	if target_id == "sakura":
		record_action("talk", {"npc": "sakura", "topic": "evacuation"})
		if player_loc == "evacuation_center" and bool(day1.get("escorting_rei", false)):
			if request_npc_move("rei", "evacuation_center", "escort_completed"):
				day1 = _gs.get_section("day1")
				day1["rescued_evacuees"] = true
				_gs.set_section("day1", day1)
			return try_complete_case("quest_evacuation_rescue", {
				"talked_rei": true,
				"rescued": true,
				"used_kmf_transport": bool(day1.get("used_kmf_transport", false))
			})
		return true

	if target_id == "kenji":
		record_action("talk", {"npc": "kenji", "topic": "supply_depot"})
		return true

	# Location-context fallback when no NPC is at hand.
	if player_loc == "hospital" and bool(day1.get("aoi_talked", false)):
		return try_complete_case("quest_hospital_medicine", {"talked_aoi": true})

	if player_loc == "evacuation_center" and bool(day1.get("escorting_rei", false)):
		request_npc_move("rei", "evacuation_center", "escort_completed")
		day1 = _gs.get_section("day1")
		day1["rescued_evacuees"] = true
		_gs.set_section("day1", day1)
		return try_complete_case("quest_evacuation_rescue", {
			"talked_rei": true, "rescued": true,
			"used_kmf_transport": bool(day1.get("used_kmf_transport", false))
		})

	if player_loc == "industrial_area" and bool(get_case_state("quest_supply_depot").get("known", false)):
		var supply_action: Dictionary = {}
		if mode == "kmf":
			supply_action = perform_kmf_action("combat_superiority", {"enemies": 3})
		else:
			supply_action = perform_foot_action("stealth_move", {"location": "industrial_area"})
		# Foot stealth only completes the case once its canonical progress threshold
		# has actually cleared the depot. One F press must not force success.
		var latest_day1: Dictionary = _gs.get_section("day1")
		return try_complete_case("quest_supply_depot", {
			"enemies_cleared": bool(supply_action.get("cleared", latest_day1.get("supply_cleared", false)))
		})

	return false

## デバッグ用（debug buildのみ）
func debug_force_complete(case_id: String) -> bool:
	if not OS.is_debug_build():
		return false
	return try_complete_case(case_id, {"force": true})

func get_help_text() -> String:
	return "操作: WASD移動 / F:会話・行動 / E:KMF乗降 / I:情報 / Space:射撃 / F5:Save / F6:Load"

func get_remaining_minutes() -> int:
	if _gs == null:
		return 0
	var day1: Dictionary = _gs.get_section("day1")
	var hard: int = int(day1.get("hard_deadline", DAY1_HARD_DEADLINE))
	return max(0, hard - _gs.get_minute_of_day())

## Unified feedback to EventBus (MiniMax UI listens to day1_feedback)
func _emit_day1_feedback(kind: String, code: String, case_id: String, title: String, detail: String, source_action_id: String = "") -> void:
	if _eb == null or not _eb.has_signal("day1_feedback"):
		return
	var payload: Dictionary = {
		"id": "fb_%d_%d_%s" % [_gs.get_day() if _gs else 1, _gs.get_minute_of_day() if _gs else 0, code],
		"kind": kind,  # success|failure|warning|info
		"code": code,
		"case_id": case_id,
		"title": title,
		"detail": detail,
		"day": _gs.get_day() if _gs else 1,
		"minute": _gs.get_minute_of_day() if _gs else 0,
		"location_id": str(_gs.get_section("player").get("locationId", "")) if _gs else "",
		"source_action_id": source_action_id,
	}
	_eb.day1_feedback.emit(payload)

