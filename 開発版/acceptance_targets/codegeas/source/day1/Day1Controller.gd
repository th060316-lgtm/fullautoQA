extends "res://day1/Day1ControllerLegacy.gd"
## Day1 completion integration layer.
## Preserves the reviewed legacy implementation while applying the accepted parts
## of Grok's state-machine design to the Work-completed main candidate.

const COMPLETION_SCHEMA_VERSION: int = 3
const COMPLETION_DEADLINE_OFFSETS: Dictionary = {
	"quest_evacuation_rescue": 150, # 10:30
	"quest_hospital_medicine": 210, # 11:30
	"quest_supply_depot": 300,      # 13:00
}

func initialize_day1() -> void:
	super.initialize_day1()
	if not _initialized or _gs == null:
		return
	_upgrade_completion_state()
	recalculate_current_objective()

func deserialize_runtime(data: Dictionary) -> void:
	super.deserialize_runtime(data)
	if _initialized and _gs:
		upgrade_loaded_state()

func upgrade_loaded_state() -> void:
	if not _initialized or _gs == null:
		return
	_upgrade_completion_state()
	recalculate_current_objective()

func _upgrade_completion_state() -> void:
	var day1: Dictionary = _gs.get_section("day1")
	day1["schema_version"] = COMPLETION_SCHEMA_VERSION
	if not day1.has("end_result"):
		day1["end_result"] = ""
	var states: Dictionary = day1.get("case_states", {})
	var start_min: int = int(day1.get("start_minute", DAY1_START_MINUTE))
	for case_id in states.keys():
		var st: Dictionary = states[case_id]
		if COMPLETION_DEADLINE_OFFSETS.has(case_id):
			st["deadline_abs_minute"] = start_min + int(COMPLETION_DEADLINE_OFFSETS[case_id])
		var status: String = str(st.get("status", "available"))
		if not st.has("stage") or str(st.get("stage", "")).is_empty():
			if status in ["completed", "failed", "expired"]:
				st["stage"] = status
			elif case_id == "quest_evacuation_rescue":
				if bool(day1.get("rescued_evacuees", false)) and _gs.get_player_location() == "evacuation_center":
					st["stage"] = "arrived_evac"
				elif bool(day1.get("used_kmf_transport", false)):
					st["stage"] = "transporting"
				elif bool(day1.get("rei_talked", false)):
					st["stage"] = "rescued"
				elif bool(st.get("known", false)):
					st["stage"] = "known"
				else:
					st["stage"] = "available"
			else:
				st["stage"] = "active" if status == "active" else status
		states[case_id] = st
	day1["case_states"] = states
	_gs.set_section("day1", day1)

func discover_case(case_id: String, source: Dictionary = {}) -> bool:
	var ok: bool = super.discover_case(case_id, source)
	if ok:
		_set_stage_internal(case_id, "known" if case_id == "quest_evacuation_rescue" else "active")
		recalculate_current_objective()
	return ok

func accept_case(case_id: String) -> bool:
	var ok: bool = super.accept_case(case_id)
	if ok:
		_set_stage_internal(case_id, "known" if case_id == "quest_evacuation_rescue" else "active")
		recalculate_current_objective()
	return ok

func try_complete_case(case_id: String, context: Dictionary = {}) -> bool:
	if case_id == "quest_evacuation_rescue":
		var day1: Dictionary = _gs.get_section("day1")
		var at_evac: bool = _gs.get_player_location() == "evacuation_center"
		var talked: bool = bool(context.get("talked_rei", false)) or bool(day1.get("rei_talked", false))
		var rescued: bool = bool(context.get("rescued", false)) or bool(day1.get("rescued_evacuees", false))
		if not at_evac or not talked or not rescued:
			recalculate_current_objective()
			return false
		_set_stage_internal(case_id, "arrived_evac")
		var ctx: Dictionary = context.duplicate(true)
		ctx["talked_rei"] = true
		ctx["rescued"] = true
		var rescue_ok: bool = super.try_complete_case(case_id, ctx)
		if rescue_ok:
			_set_stage_internal(case_id, "completed")
			recalculate_current_objective()
		return rescue_ok
	var ok: bool = super.try_complete_case(case_id, context)
	if ok and str(get_case_state(case_id).get("status", "")) == "completed":
		_set_stage_internal(case_id, "completed")
	recalculate_current_objective()
	return ok

func _fail_case(case_id: String, reason: String) -> void:
	super._fail_case(case_id, reason)
	var state: Dictionary = get_case_state(case_id)
	var status: String = str(state.get("status", "failed"))
	_set_stage_internal(case_id, status)
	recalculate_current_objective()

func on_time_advanced(minutes: int) -> void:
	super.on_time_advanced(minutes)
	if not _initialized or _gs == null:
		return
	recalculate_current_objective()
	if _gs.get_minute_of_day() >= DAY1_SOFT_DEADLINE and get_end_result().is_empty():
		finalize_day1_result()

func try_interact(target_id: String = "") -> bool:
	var before: Dictionary = _gs.get_section("day1") if _gs else {}
	var yui_before: int = int(before.get("yui_talk_count", 0))
	var ok: bool = super.try_interact(target_id)
	if not ok:
		recalculate_current_objective()
		return false
	var day1: Dictionary = _gs.get_section("day1")
	var rescue_state: Dictionary = get_case_state("quest_evacuation_rescue")
	if str(rescue_state.get("status", "")) == "completed":
		_set_stage_internal("quest_evacuation_rescue", "completed")
	elif bool(day1.get("rei_talked", false)):
		if _gs.get_player_location() == "evacuation_center" and bool(day1.get("rescued_evacuees", false)):
			_set_stage_internal("quest_evacuation_rescue", "arrived_evac")
		elif bool(day1.get("used_kmf_transport", false)):
			_set_stage_internal("quest_evacuation_rescue", "transporting")
		else:
			_set_stage_internal("quest_evacuation_rescue", "rescued")
	recalculate_current_objective()
	day1 = _gs.get_section("day1")
	if int(day1.get("yui_talk_count", 0)) > yui_before and _all_cases_terminal(day1):
		finalize_day1_result()
	return true

## ============================================================
## Phase 0.5 Block 1: インタラクション記述 API (副作用ゼロ)
## ============================================================
## 開発計画 3.2:
##   「Interaction時には画面上へ、対象名 / 可能な行動 / 必要キー / 現在距離 /
##    必要なモード / 行動結果の簡潔な説明 を提示する。」
##
## try_interact() と同一の対象解決順序を使うが、状態を変えない (時間・フラグを動かさない)。
## 既存の try_interact() は変更していない (public method / signal 互換維持)。

func get_interaction_options(world_pos: Vector2, mode: String) -> Array:
	var out: Array = []
	if not _initialized:
		return out
	var target_id: String = _resolve_interaction_target()
	if target_id.is_empty():
		return out
	var player_loc: String = str(_gs.get_section("player").get("locationId", "base"))
	var distance: float = 0.0
	var map := _map_manager()
	var player_node := _player_node()
	if map != null and player_node != null and map.has_method("get_npc_marker_position"):
		distance = world_pos.distance_to(map.get_npc_marker_position(target_id))
	out.append(_describe_npc_interaction(target_id, player_loc, mode, distance))
	return out

func _describe_npc_interaction(target_id: String, player_loc: String, mode: String, distance: float) -> Dictionary:
	var npc_name: String = target_id
	if _nm != null:
		var npc: Dictionary = _nm.get_npc(target_id)
		if not npc.is_empty():
			npc_name = str(npc.get("name", target_id))
	var day1: Dictionary = _gs.get_section("day1")
	var base: Dictionary = {
		"target_id": target_id,
		"target_name": npc_name,
		"action_label": "話す",
		"key_label": "F",
		"distance": distance,
		"required_mode": "any",
		"blocked": false,
		"reason": "",
		"hint": "",
		"source": "day1",
	}
	match target_id:
		"yui":
			base["action_label"] = "報告する"
			base["hint"] = "ユイへ現在の状況を報告する"
		"aoi":
			var inventory: Dictionary = day1.get("inventory", {})
			if player_loc == "base" and not bool(inventory.get("medicine_box", false)):
				base["action_label"] = "受け取る"
				base["hint"] = "アオイから医薬品を受け取る"
			elif player_loc == "hospital":
				if bool(inventory.get("medicine_box", false)):
					base["action_label"] = "届ける"
					base["hint"] = "アオイへ医薬品を引き渡す"
				else:
					base["action_label"] = "届ける"
					base["blocked"] = true
					base["reason"] = "医薬品が必要 (拠点のアオイから受け取る)"
					base["hint"] = "まず拠点でアオイから医薬品を受け取る"
			else:
				base["action_label"] = "話す"
				base["hint"] = "アオイに話を聞く"
		"rei":
			base["action_label"] = "救助する"
			base["hint"] = "レイの救助。会話を始める"
			if mode == "kmf":
				base["hint"] = "レイの救助 (KMF搭乗中は搬送まで自動)"
		"sakura":
			if player_loc == "evacuation_center" and bool(day1.get("escorting_rei", false)):
				base["action_label"] = "引き渡す"
				base["hint"] = "サクラへ救助者を引き渡す"
			else:
				base["action_label"] = "話す"
				base["hint"] = "サクラに話を聞く"
		"kenji":
			base["action_label"] = "話す"
			base["hint"] = "ケンジに話を聞く"
	return base

func perform_foot_action(action: String, context: Dictionary = {}) -> Dictionary:
	var result: Dictionary = super.perform_foot_action(action, context)
	if bool(result.get("ok", false)):
		recalculate_current_objective()
	return result

func perform_kmf_action(action: String, context: Dictionary = {}) -> Dictionary:
	var result: Dictionary = super.perform_kmf_action(action, context)
	if bool(result.get("ok", false)):
		if action == "rescue_transport":
			_set_stage_internal("quest_evacuation_rescue", "transporting")
		recalculate_current_objective()
	return result

func advance_stage(case_id: String, new_stage: String, context: Dictionary = {}) -> bool:
	if not _initialized:
		return false
	var state: Dictionary = get_case_state(case_id)
	if state.is_empty():
		return false
	var allowed: Dictionary = {
		"quest_evacuation_rescue": ["available", "known", "discovered_rei", "rescued", "transporting", "arrived_evac", "completed", "failed", "expired"],
		"quest_hospital_medicine": ["available", "active", "delivered", "completed", "failed", "expired"],
		"quest_supply_depot": ["available", "known", "active", "secured", "completed", "failed", "expired"],
	}
	if new_stage not in allowed.get(case_id, []):
		return false
	# Terminal status changes must pass the real completion/failure validation paths.
	if new_stage in ["completed", "failed", "expired"]:
		return false
	var ok: bool = _set_stage_internal(case_id, new_stage)
	if ok:
		if not context.is_empty():
			record_action("case_stage", {"case_id": case_id, "stage": new_stage, "context": context})
		recalculate_current_objective()
	return ok

func _set_stage_internal(case_id: String, new_stage: String) -> bool:
	if _gs == null:
		return false
	var day1: Dictionary = _gs.get_section("day1")
	var states: Dictionary = day1.get("case_states", {})
	if not states.has(case_id):
		return false
	var st: Dictionary = states[case_id]
	if str(st.get("stage", "")) == new_stage:
		return true
	st["stage"] = new_stage
	if new_stage in ["completed", "failed", "expired"]:
		st["status"] = new_stage
	states[case_id] = st
	day1["case_states"] = states
	_gs.set_section("day1", day1)
	return true

func recalculate_current_objective() -> void:
	if not _initialized or _gs == null:
		return
	var day1: Dictionary = _gs.get_section("day1")
	var result: String = str(day1.get("end_result", ""))
	if not result.is_empty():
		_write_objective("Day1終了: %s" % result)
		return
	# Terminal case state takes priority over onboarding. Otherwise a loaded or
	# adversarial state with yui_talked=false can resurrect the opening objective.
	if _all_cases_terminal(day1):
		_write_objective("拠点へ帰投しユイへ結果を報告する")
		return
	if not bool(day1.get("yui_talked", false)):
		_write_objective("拠点でユイと話し状況を確認する")
		return
	var states: Dictionary = day1.get("case_states", {})
	var active: Array = []
	var now: int = _gs.get_minute_of_day()
	for case_id in states.keys():
		var st: Dictionary = states[case_id]
		var status: String = str(st.get("status", ""))
		if bool(st.get("known", false)) and status in ["active", "available"] and now <= int(st.get("deadline_abs_minute", 99999)):
			active.append(str(case_id))
	if not active.is_empty():
		active.sort_custom(func(a, b):
			return int(states[a].get("deadline_abs_minute", 99999)) < int(states[b].get("deadline_abs_minute", 99999))
		)
		_write_objective(_objective_for_case(str(active[0]), states[active[0]], day1))
		return
	if _all_cases_terminal(day1):
		_write_objective("拠点へ帰投しユイへ結果を報告する")
	elif now >= 13 * 60:
		_write_objective("午後の行動: 施設状況を確認し、拠点への帰投準備をする")
	else:
		_write_objective("情報を確認し、次に対応する案件を選ぶ")

func _write_objective(text: String) -> void:
	var day1: Dictionary = _gs.get_section("day1")
	if str(day1.get("current_objective", "")) == text:
		return
	day1["current_objective"] = text
	_gs.set_section("day1", day1)

func _objective_for_case(case_id: String, state: Dictionary, day1: Dictionary) -> String:
	match case_id:
		"quest_evacuation_rescue":
			match str(state.get("stage", "known")):
				"rescued", "transporting":
					return "救助したレイを避難所へ搬送する"
				"arrived_evac":
					return "避難所でサクラへ救助者を引き渡す"
				_:
					return "市街中心部でレイを捜し救助する"
		"quest_hospital_medicine":
			if not bool(day1.get("inventory", {}).get("medicine_box", false)):
				return "拠点のアオイから医薬品を受け取る"
			return "病院へ医薬品を届ける"
		"quest_supply_depot":
			return "工業地区の食料倉庫を調べ確保する"
	return "次の案件へ対応する"

func _case_destination(case_id: String, state: Dictionary, day1: Dictionary) -> String:
	match case_id:
		"quest_evacuation_rescue":
			if str(state.get("stage", "known")) in ["rescued", "transporting", "arrived_evac"]:
				return "evacuation_center"
			return "city_center"
		"quest_hospital_medicine":
			if not bool(day1.get("inventory", {}).get("medicine_box", false)):
				return "base"
			return "hospital"
		"quest_supply_depot":
			return "industrial_area"
	return "base"

func _current_priority_case(day1: Dictionary) -> String:
	var states: Dictionary = day1.get("case_states", {})
	var now: int = _gs.get_minute_of_day()
	var active: Array = []
	for case_id in states.keys():
		var st: Dictionary = states[case_id]
		if bool(st.get("known", false)) and str(st.get("status", "")) in ["active", "available"] and now <= int(st.get("deadline_abs_minute", 99999)):
			active.append(str(case_id))
	if active.is_empty():
		return ""
	active.sort_custom(func(a, b):
		return int(states[a].get("deadline_abs_minute", 99999)) < int(states[b].get("deadline_abs_minute", 99999))
	)
	return str(active[0])

func get_case_overview(case_id: String) -> Dictionary:
	var out: Dictionary = super.get_case_overview(case_id)
	if out.is_empty():
		return out
	var day1: Dictionary = _gs.get_section("day1")
	var state: Dictionary = day1.get("case_states", {}).get(case_id, {})
	var destination: String = _case_destination(case_id, state, day1)
	out["stage"] = str(state.get("stage", ""))
	out["location_id"] = destination
	out["current_location"] = destination

	if _gs.get_player_location() == destination:
		out["foot_eta_minutes"] = 0
		out["kmf_eta_minutes"] = 0

	var deadline: int = int(state.get("deadline_abs_minute", -1))
	var remaining: int = deadline - _gs.get_minute_of_day() if deadline >= 0 else -1
	out["deadline_abs_minute"] = deadline
	out["deadline_minute"] = deadline
	out["remaining_minutes"] = remaining
	if deadline < 0:
		out["deadline_text"] = "期限なし"
		out["remaining_text"] = ""
	else:
		out["deadline_text"] = "%02d:%02d" % [int(deadline / 60), deadline % 60]
		if remaining < 0:
			out["remaining_text"] = "期限切れ"
		elif remaining < 30:
			out["remaining_text"] = "残り%d分 (至急!)" % remaining
		elif remaining < 60:
			out["remaining_text"] = "残り%d分" % remaining
		else:
			out["remaining_text"] = "残り%d時間%d分" % [int(remaining / 60), remaining % 60]

	var foot_eta: int = int(out.get("foot_eta_minutes", 0))
	var kmf_eta: int = int(out.get("kmf_eta_minutes", 0))
	var mode: String = _gs.get_player_mode()
	out["travel_estimate"] = {
		"from": _gs.get_player_location(),
		"to": destination,
		"mode": mode,
		"estimated_minutes": kmf_eta if mode == "kmf" else foot_eta,
		"foot_minutes": foot_eta,
		"kmf_minutes": kmf_eta,
		"is_estimate": true,
		"warning": "現在地です。" if _gs.get_player_location() == destination else "※予測時間。道路状況・敵の有無で変動します。",
	}
	return out

func get_ui_snapshot() -> Dictionary:
	if not _initialized or _gs == null:
		return {}
	var day1: Dictionary = _gs.get_section("day1")
	var destination: String = "base"
	var case_id: String = _current_priority_case(day1)
	if not bool(day1.get("yui_talked", false)):
		destination = "base"
	elif not case_id.is_empty():
		destination = _case_destination(case_id, day1.get("case_states", {}).get(case_id, {}), day1)
	elif _all_cases_terminal(day1):
		destination = "base"
	var deadline: int = -1
	for cid in day1.get("known_cases", []):
		var st: Dictionary = day1.get("case_states", {}).get(cid, {})
		if str(st.get("status", "")) in ["active", "available"]:
			var value: int = int(st.get("deadline_abs_minute", -1))
			if value >= 0 and (deadline < 0 or value < deadline):
				deadline = value
	return {
		"objective": str(day1.get("current_objective", "次の行動を選ぶ")),
		"destination_id": destination,
		"deadline": deadline,
		"end_result": str(day1.get("end_result", "")),
	}

func get_ui_case_rows() -> Array:
	var rows: Array = []
	var day1: Dictionary = _gs.get_section("day1") if _gs else {}
	for cid in day1.get("known_cases", []):
		var state: Dictionary = day1.get("case_states", {}).get(cid, {})
		var def: Dictionary = CASE_DEFS.get(cid, {})
		rows.append({
			"id": str(cid),
			"name": str(def.get("name", cid)),
			"status": str(state.get("status", "")),
			"stage": str(state.get("stage", "")),
			"deadline": int(state.get("deadline_abs_minute", -1)),
		})
	return rows

func finalize_day1_result() -> void:
	if not _initialized or _gs == null:
		return
	var day1: Dictionary = _gs.get_section("day1")
	if not str(day1.get("end_result", "")).is_empty():
		return
	for cid in day1.get("case_states", {}).keys():
		var st: Dictionary = day1.get("case_states", {}).get(cid, {})
		if str(st.get("status", "")) not in ["completed", "failed", "expired"]:
			_fail_case(str(cid), "day1_closed")
	day1 = _gs.get_section("day1")
	var completed: int = 0
	var failed: int = 0
	for st in day1.get("case_states", {}).values():
		if str(st.get("status", "")) == "completed":
			completed += 1
		elif str(st.get("status", "")) in ["failed", "expired"]:
			failed += 1
	var result: String
	if completed == 3:
		result = "全成功"
	elif completed > 0:
		result = "部分成功"
	else:
		result = "全失敗"
	day1["end_result"] = result
	var summary: Dictionary = day1.get("summary", {})
	summary["result"] = result
	summary["completed_count"] = completed
	summary["failed_count"] = failed
	summary["finalized_at_minute"] = _gs.get_minute_of_day()
	day1["summary"] = summary
	day1["current_objective"] = "Day1終了: %s" % result
	_gs.set_section("day1", day1)
	if _eb and _eb.has_signal("player_notice"):
		_eb.player_notice.emit("Day1結果: %s" % result)

func get_end_result() -> String:
	if not _initialized or _gs == null:
		return ""
	return str(_gs.get_section("day1").get("end_result", ""))

func get_result_summary() -> String:
	var result: String = get_end_result()
	return result if not result.is_empty() else "進行中"

func _all_cases_terminal(day1: Dictionary) -> bool:
	var states: Dictionary = day1.get("case_states", {})
	if states.is_empty():
		return false
	for st in states.values():
		if str(st.get("status", "")) not in ["completed", "failed", "expired"]:
			return false
	return true

func consume_action_time(minutes: int, reason: String = "") -> int:
	if _gs == null or minutes <= 0:
		return 0
	var actual: int = _gs.advance_time(minutes)
	if not reason.is_empty():
		record_action("time_cost", {"minutes": actual, "reason": reason})
	return actual

func run_self_tests() -> Dictionary:
	var day1: Dictionary = _gs.get_section("day1") if _gs else {}
	return {
		"schema_v3": int(day1.get("schema_version", 0)) == COMPLETION_SCHEMA_VERSION,
		"objective_nonempty": not str(day1.get("current_objective", "")).is_empty(),
		"rescue_stage_present": get_case_state("quest_evacuation_rescue").has("stage"),
		"end_result_field": day1.has("end_result"),
	}
