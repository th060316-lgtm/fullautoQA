# Day1InformationSystem.gd
# MiniMax Phase A: Information provenance + Day1 contradiction events
# Extends MemorySystem reports with full source tracking.
# Contract: EXT-20261019-015_MINIMAX_PHASEA_INFO_CONSEQUENCE_50
#
# MiniMax担当追加 (DAY1-REPAIR-20261019-5TO5):
# - KMFレポート集約（洪水防止）
# - 案件期限・残時間・移動予測
# - Day1終了時の結果通知（day1_feedback）

extends Node

var _gs: Node
var _eb: Node
var _ms: Node
var _nm: Node
var _d1: Node

## Source types for provenance tracking
enum SourceType {
	DIRECT_OBSERVATION = 0,  # Player directly observed at location
	NPC_TESTIMONY = 1,       # NPC told the player directly
	HEARSAY = 2,             # Report heard from another source
	REMOTE_REPORT = 3,       # Written/distant report
	ANALYSIS = 4,            # Structured analysis (yui)
}

## Information records with full provenance
## Maps record_id -> record dictionary
var _information_records: Dictionary = {}

## Processed action IDs to prevent double-processing
var _processed_action_ids: Dictionary = {}

## Contradiction detection records
## Tracks testimony vs observation conflicts
var _contradictions: Array = []

## Hidden case discovery state
var _quest_supply_depot_discovered: bool = false

## Day1 contradiction setup state
var _contradiction_setup_complete: bool = false
var _contradiction_contradicted: bool = false

## --- MiniMax追加: KMFレポート集約（報告洪水防止）---
## KMF使用時に発生したレポートを一時バッファに溜め、一定量に達したら
## 統合digestを生成して通知する。60〜80件の生レポートを保持しつつ、
## プレイヤー向けには凝縮した通知のみを表示する。
var _kmf_reports_buffer: Array = []
var _kmf_reports_history: Array = []
var _kmf_digest_pending: bool = false
var _kmf_digest_generated: Dictionary = {}

## --- MiniMax追加: 案件期限管理---
## 既知案件の概要をキャッシュしてHUD表示を高速化する
var _known_case_overviews: Array = []
var _case_overviews_dirty: bool = true

## --- MiniMax追加: Day1終了状態---
var _day1_ended: bool = false
var _day1_feedback_data: Dictionary = {}

func _ready() -> void:
	_gs = get_node_or_null("/root/GameState")
	_eb = get_node_or_null("/root/EventBus")
	_ms = get_node_or_null("/root/MemorySystem")
	_nm = get_node_or_null("/root/NpcManager")
	_d1 = _find_day1_controller()

	_connect_signals()

func _connect_signals() -> void:
	if _eb == null:
		return
	if _eb.has_signal("time_advanced"):
		_eb.time_advanced.connect(_on_time_advanced)
	if _eb.has_signal("location_changed"):
		_eb.location_changed.connect(_on_location_changed)
	if _eb.has_signal("day1_action_committed"):
		_eb.day1_action_committed.connect(_on_day1_action_committed)
	if _eb.has_signal("day1_case_state_changed"):
		_eb.day1_case_state_changed.connect(_on_day1_case_state_changed)
	if _eb.has_signal("day1_summary_ready"):
		_eb.day1_summary_ready.connect(_on_day1_summary_ready)

func _find_day1_controller() -> Node:
	var p = get_parent()
	if p and p.has_method("discover_case") and p.has_method("record_action"):
		return p
	var root = get_tree().root if get_tree() else null
	if root:
		return root.find_child("Day1Controller", true, false)
	return null

## Initialize Day1 information tracking
func initialize_day1_info() -> void:
	_information_records.clear()
	_processed_action_ids.clear()
	_contradictions.clear()
	_quest_supply_depot_discovered = false
	_contradiction_setup_complete = false
	_contradiction_contradicted = false
	_kmf_reports_buffer.clear()
	_kmf_reports_history.clear()
	_kmf_digest_pending = false
	_kmf_digest_generated.clear()
	_known_case_overviews.clear()
	_case_overviews_dirty = true
	_day1_ended = false
	_day1_feedback_data.clear()
	print("[Day1Info] Information system initialized")

## Add information record with full provenance
func add_information_record(
	content: String,
	source_id: String,
	source_type: int,
	day: int,
	minute: int,
	source_location: String,
	related_npcs: Array = [],
	related_cases: Array = [],
	tags: Array = []
) -> Dictionary:
	var record_id = "info_%s_%d_%d_%d" % [source_id, day, minute, _information_records.size()]

	# Avoid duplicates
	if _information_records.has(record_id):
		return _information_records[record_id]

	var record = {
		"id": record_id,
		"content": content,
		"sourceId": source_id,
		"sourceType": source_type,
		"sourceTypeName": SourceType.keys()[source_type],
		"day": day,
		"minute": minute,
		"sourceLocation": source_location,
		"relatedNpcs": related_npcs.duplicate(true),
		"relatedCases": related_cases.duplicate(true),
		"tags": tags.duplicate(true),
		"contradiction_status": "none",  # none | contradicts | contradicted_by
		"contradiction_with": "",
	}

	_information_records[record_id] = record

	# Also add to MemorySystem report for UI display
	_add_to_memory_system(record)

	# Mark case overviews dirty when new info arrives
	if related_cases.size() > 0:
		_case_overviews_dirty = true

	# Emit event
	if _eb and _eb.has_signal("day1_information_recorded"):
		_eb.day1_information_recorded.emit(record)

	print("[Day1Info] Record added: %s (type=%s, loc=%s)" % [record_id, record["sourceTypeName"], source_location])
	return record

## Add record to MemorySystem (backward compatibility)
func _add_to_memory_system(record: Dictionary) -> void:
	if _ms == null or not _ms.has_method("add_report"):
		return

	# MemorySystem enum order is stable in this project:
	# TESTIMONY=0, RUMOR=1, ANALYSIS=2, CONTRADICTION=4.
	var ms_category: int = 1
	match int(record.get("sourceType", SourceType.REMOTE_REPORT)):
		SourceType.DIRECT_OBSERVATION, SourceType.NPC_TESTIMONY:
			ms_category = 0
		SourceType.HEARSAY, SourceType.REMOTE_REPORT:
			ms_category = 1
		SourceType.ANALYSIS:
			ms_category = 2

	_ms.add_report(
		ms_category,
		str(record.get("content", "")),
		str(record.get("sourceId", "unknown")),
		record.get("relatedNpcs", []),
		-1,
		0.5,
		record.get("tags", []),
		str(record.get("sourceLocation", "unknown")),
		int(record.get("sourceType", SourceType.REMOTE_REPORT)),
		record.get("relatedCases", [])
	)

## Setup Day1 contradiction event
## This creates a scenario where NPC testimony contradicts later direct observation
func setup_day1_contradiction() -> void:
	if _contradiction_setup_complete:
		return

	var current_day = _gs.get_day() if _gs else 1
	var current_minute = _gs.get_minute_of_day() if _gs else 480

	# STEP 1: Add NPC testimony about supply depot
	# Kenji (in industrial area) claims supply depot is secure
	add_information_record(
		"山村健二「物資倉庫は俺たちが守ってる。心配するな。」",
		"kenji",
		SourceType.NPC_TESTIMONY,
		current_day,
		current_minute - 30,
		"industrial_area",
		["kenji"],
		["quest_supply_depot"],
		["supply_depot", "kenji_statement", "authority_claim"]
	)

	# STEP 2: Add second testimony (hearsay from sakura)
	add_information_record(
		"佐藤桜「健二さんがそう言ってるなら大丈夫だと思う…」",
		"sakura",
		SourceType.HEARSAY,
		current_day,
		current_minute - 25,
		"evacuation_center",
		["sakura", "kenji"],
		["quest_supply_depot"],
		["supply_depot", "second_hand", "uncertain"]
	)

	_contradiction_setup_complete = true
	_case_overviews_dirty = true
	_trigger_quest_discovery("quest_supply_depot", {
		"sourceType": "npc_testimony", "sourceId": "kenji",
		"sourceLocation": "industrial_area", "relatedCases": ["quest_supply_depot"]
	})
	print("[Day1Info] Day1 contradiction setup complete (testimony phase)")

## Check and resolve contradiction when player observes directly
func check_contradiction_at_location(location_id: String) -> void:
	if not _contradiction_setup_complete:
		return
	if _contradiction_contradicted:
		return

	# Player observed supply depot area directly
	if location_id == "industrial_area" or location_id == "supply_depot":
		_contradiction_contradicted = true

		# Add direct observation contradicting the testimony
		var current_day = _gs.get_day() if _gs else 1
		var current_minute = _gs.get_minute_of_day() if _gs else 480

		var observation_record = add_information_record(
			"物資倉庫は荒らされ、保管棚が空になっている箇所がある。",
			"player",
			SourceType.DIRECT_OBSERVATION,
			current_day,
			current_minute,
			location_id,
			["kenji"],
			["quest_supply_depot"],
			["supply_depot", "direct_observation", "contradiction"]
		)

		# Mark previous testimonies as contradicted
		for record_id in _information_records:
			var rec = _information_records[record_id]
			if "quest_supply_depot" in rec.get("relatedCases", []) and rec["sourceId"] == "kenji":
				rec["contradiction_status"] = "contradicted_by"
				rec["contradiction_with"] = observation_record["id"]

		observation_record["contradiction_status"] = "contradicts"
		observation_record["contradiction_with"] = "info_kenji_*"

		# Direct observation is also recorded as an immutable system fact.
		if _ms and _ms.has_method("add_system_fact"):
			_ms.add_system_fact(
				"day1_supply_depot_observation",
				"物資倉庫は荒らされ、保管棚が空になっている箇所がある。",
				location_id,
				true
			)

		_contradictions.append({
			"testimony_id": str(observation_record.get("contradiction_with", "")),
			"observation_id": str(observation_record.get("id", "")),
			"case_id": "quest_supply_depot"
		})

		# Add contradiction report to MemorySystem
		if _ms and _ms.has_method("add_report"):
			_ms.add_report(
				4,
				"山村健二の証言と現地で直接確認した状況が一致しない。",
				"analysis",
				["kenji"],
				1,
				0.3,
				["contradiction", "supply_depot"],
				location_id,
				SourceType.ANALYSIS,
				["quest_supply_depot"]
			)

		print("[Day1Info] CONTRADICTION DETECTED: Kenji testimony vs direct observation")

		# Auto-discover quest_supply_depot via Day1Controller if available
		_trigger_quest_discovery("quest_supply_depot", {"type": "contradiction", "location": location_id})

## Internal quest discovery trigger
func _trigger_quest_discovery(case_id: String, source: Dictionary) -> void:
	if _quest_supply_depot_discovered:
		return
	_quest_supply_depot_discovered = true
	_case_overviews_dirty = true

	# Try Day1Controller.discover_case if available
	var d1c = _d1 if _d1 != null else _find_day1_controller()
	if d1c and d1c.has_method("discover_case"):
		d1c.discover_case(case_id, source)
	elif _eb and _eb.has_signal("day1_case_discovered"):
		_eb.day1_case_discovered.emit(case_id, source)

	print("[Day1Info] Quest discovered via contradiction: %s" % case_id)

## ============================================================
## MiniMax追加: KMFレポート集約（報告洪水防止）
## ============================================================
## KMF使用に伴う多量のレポートを一時バッファに溜め、
## 集約digestを生成して通知する。内部では全レポートを保持する。
## 予測時間を表示、成功保証ではないことを明示する。

func _on_day1_action_committed(action: Dictionary) -> void:
	## Day1ConsequenceSystemがKMFレポートを生成した後に呼ばれる。
	## ここでレポート集約判定を行う。
	var mode = str(action.get("mode", ""))
	var action_type = str(action.get("type", ""))

	if mode == "kmf" or action_type.begins_with("kmf"):
		var noise = float(action.get("noise", 0.0))
		var location = str(action.get("locationId", ""))
		var minute = int(action.get("minute", _gs.get_minute_of_day() if _gs else 0))
		var day = int(action.get("day", _gs.get_day() if _gs else 1))

		# KMFレポートを生レポートとしてバッファに追加
		_buffer_kmf_report(action, noise, location, minute, day)

		# 一定量たまったらdigest生成
		if _kmf_reports_buffer.size() >= 3:
			_generate_kmf_digest_from_buffer()
		else:
			_kmf_digest_pending = true

## KMFレポートをバッファに追加
func _buffer_kmf_report(action: Dictionary, noise: float, location: String, minute: int, day: int) -> void:
	var report_content = ""
	var importance = "low"

	if noise > 15.0:
		report_content = "大型KMFが目撃された。住民たちが警戒。"
		importance = "high"
	elif noise > 8.0:
		report_content = "KMFの移動音が聞こえた。"
		importance = "medium"
	else:
		report_content = "遠くで機械音が響いた。"
		importance = "low"

	var buffered = {
		"content": report_content,
		"noise": noise,
		"location": location,
		"minute": minute,
		"day": day,
		"importance": importance,
		"action_id": str(action.get("id", "")),
	}
	_kmf_reports_buffer.append(buffered)
	_kmf_reports_history.append(buffered.duplicate(true))
	print("[Day1Info] KMF report buffered (buffer size: %d)" % _kmf_reports_buffer.size())

## バッファからKMF digestを生成
func _generate_kmf_digest_from_buffer() -> Dictionary:
	if _kmf_reports_buffer.is_empty():
		return {}

	# 集約対象をコピーしてバッファをクリア
	var reports = _kmf_reports_buffer.duplicate(true)
	_kmf_reports_buffer.clear()
	_kmf_digest_pending = false

	# 最重要度の判定
	var max_importance = "low"
	var high_count = 0
	var medium_count = 0
	var low_count = 0
	var locations: Array = []
	var total_noise = 0.0

	for r in reports:
		var imp = str(r.get("importance", "low"))
		match imp:
			"high": high_count += 1; max_importance = "high"
			"medium": medium_count += 1; if max_importance != "high": max_importance = "medium"
			_: low_count += 1
		if str(r.get("location", "")) not in locations:
			locations.append(r.get("location", ""))
		total_noise += float(r.get("noise", 0.0))

	# digest文生成
	var digest_content = ""
	var digest_short = ""
	match max_importance:
		"high":
			if high_count >= 3:
				digest_content = "複数地点で大型KMFが目撃された。住民たちの警戒が大幅に高まっている。"
				digest_short = "【警戒】複数地点で大型KMF (%d件)" % high_count
			elif high_count >= 1:
				digest_content = "街中で大型KMFが目撃され、住民たちが警戒を強めている。"
				digest_short = "【警戒】大型KMFが目撃された (%d件)" % high_count
		"medium":
			if medium_count >= 2:
				digest_content = "複数地点でKMFの移動が確認された。"
				digest_short = "KMF移動が複数確認 (%d件)" % medium_count
			else:
				digest_content = "KMFの移動音が報告されている。"
				digest_short = "KMF移動 (%d件)" % medium_count
		_:
			digest_content = "遠方で機械音が報告されている。"
			digest_short = "遠方で機械音 (%d件)" % low_count

	_kmf_digest_generated = {
		"content": digest_content,
		"short": digest_short,
		"importance": max_importance,
		"total_reports": reports.size(),
		"high_count": high_count,
		"medium_count": medium_count,
		"low_count": low_count,
		"locations": locations,
		"total_noise": total_noise,
		"generated_at_minute": _gs.get_minute_of_day() if _gs else 0,
		"generated_at_day": _gs.get_day() if _gs else 1,
	}

	# MemorySystemにdigestレポートとして追加
	if _ms and _ms.has_method("add_report"):
		var conf = 1  # RUMOR = POSSIBLE
		if max_importance == "high":
			conf = 2  # PROBABLE
		_ms.add_report(
			1,  # RUMOR
			digest_content,
			"kmf_digest",
			[],
			conf,
			0.3,
			["kmf", "digest", max_importance],
			",".join(locations),
			3,  # REMOTE_REPORT
			[]
		)

	# EventBusにdigest準備完了を通知
	if _eb and _eb.has_signal("kmf_digest_ready"):
		_eb.kmf_digest_ready.emit(_kmf_digest_generated.duplicate(true))

	print("[Day1Info] KMF digest generated: %s (%d reports consolidated)" % [digest_short, reports.size()])
	return _kmf_digest_generated

## 手動でKMF digestを生成（ HUDから呼び出し）
func flush_kmf_digest() -> Dictionary:
	return _generate_kmf_digest_from_buffer()

## 直近のKMF digestを取得（ HUD表示用）
func get_latest_kmf_digest() -> Dictionary:
	if _kmf_digest_pending and not _kmf_reports_buffer.is_empty():
		_generate_kmf_digest_from_buffer()
	return _kmf_digest_generated.duplicate(true)

## 全KMFレポートを取得（内部保持用 — UI非露出）
func get_all_kmf_buffered_reports() -> Array:
	return _kmf_reports_history.duplicate(true)

## ============================================================
## MiniMax追加: 案件概要・期限・残時間・移動予測
## ============================================================
## API契約: get_known_case_overviews()
## Day1ControllerのCASE_DEFSとcase_statesを使用して
## 既知案件の概要を返す。移動予測は成功保証ではない。

func get_known_case_overviews() -> Array:
	## キャッシュ更新判定
	if not _case_overviews_dirty:
		return _known_case_overviews.duplicate(true)

	_refresh_case_overviews()
	return _known_case_overviews.duplicate(true)

func _refresh_case_overviews() -> void:
	_known_case_overviews.clear()
	_case_overviews_dirty = false

	var day1: Dictionary = {}
	var now_minute = 0
	var now_day = 1

	if _gs:
		day1 = _gs.get_section("day1")
		now_minute = _gs.get_minute_of_day()
		now_day = _gs.get_day()

	var known_cases: Array = day1.get("known_cases", [])
	var case_states: Dictionary = day1.get("case_states", {})
	var player_loc = str(_gs.get_section("player").get("locationId", "base") if _gs else "base")
	var mode = str(_gs.get_section("player").get("mode", "foot") if _gs else "foot")

	# CASE_DEFS（Day1Controllerから取得）
	var case_defs: Dictionary = {
		"quest_hospital_medicine": {
			"name": "病院医薬品輸送",
			"region": "hospital",
			"required_location": "hospital",
			"description": "医薬品を病院へ届ける。",
		},
		"quest_evacuation_rescue": {
			"name": "避難民救助",
			"region": "city_center",
			"required_location": "evacuation_center",
			"description": "市街に取り残された避難民を救助。",
		},
		"quest_supply_depot": {
			"name": "食料倉庫確保",
			"region": "industrial_area",
			"required_location": "industrial_area",
			"description": "工業地区の食料倉庫を確保。",
		},
	}

	for case_id in known_cases:
		var state = case_states.get(case_id, {})
		var def = case_defs.get(case_id, {})

		# GameState case state is canonical. Runtime-only discovery flags from old
		# saves must not hide a case that is already known in the canonical state.
		if case_id == "quest_supply_depot" and not bool(state.get("known", false)):
			continue

		var deadline_min = int(state.get("deadline_abs_minute", 0))
		var remaining = deadline_min - now_minute
		var status = str(state.get("status", "active"))

		# Dynamic destination: rescue starts in the city and changes to the
		# evacuation center only after the rescue/transport stage.
		var destination: String = str(def.get("required_location", ""))
		if case_id == "quest_evacuation_rescue":
			var rescue_stage: String = str(state.get("stage", "known"))
			destination = "evacuation_center" if rescue_stage in ["rescued", "transporting", "arrived_evac", "completed"] else "city_center"

		# 移動予測（成功保証ではない）
		var travel = _get_travel_estimate(player_loc, destination, mode)

		var overview: Dictionary = {
			"id": case_id,
			"name": str(def.get("name", case_id)),
			"status": status,
			"deadline_minute": deadline_min,
			"remaining_minutes": remaining,
			"remaining_text": _format_remaining_time(remaining),
			"deadline_text": _format_minute(deadline_min),
			"current_location": destination,
			"player_location": player_loc,
			"player_mode": mode,
			"travel_estimate": travel,
			"description": str(def.get("description", "")),
			"discovered": bool(state.get("known", false)),
			"result_reason": str(state.get("result_reason", "")),
		}
		_known_case_overviews.append(overview)

	# 期限が近い順にソート
	_known_case_overviews.sort_custom(func(a, b):
		if a["status"] != b["status"]:
			var order = {"active": 0, "available": 1, "completed": 2, "failed": 3, "expired": 4}
			var sa = order.get(a["status"], 9)
			var sb = order.get(b["status"], 9)
			return sa < sb
		return a["remaining_minutes"] < b["remaining_minutes"]
	)

## 移動時間予測（徒步/KMF別）
func _get_travel_estimate(from: String, to: String, mode: String) -> Dictionary:
	## 各地点間の徒步/KMF所要時間予測（概算）
	## 値は目安であり、成功保証ではない
	var foot_times: Dictionary = {
		"base->hospital": 20,
		"base->city_center": 25,
		"base->evacuation_center": 35,
		"base->industrial_area": 40,
		"hospital->base": 20,
		"hospital->city_center": 15,
		"hospital->evacuation_center": 30,
		"hospital->industrial_area": 35,
		"city_center->base": 25,
		"city_center->hospital": 15,
		"city_center->evacuation_center": 20,
		"city_center->industrial_area": 25,
		"evacuation_center->base": 35,
		"evacuation_center->hospital": 30,
		"evacuation_center->city_center": 20,
		"evacuation_center->industrial_area": 30,
		"industrial_area->base": 40,
		"industrial_area->hospital": 35,
		"industrial_area->city_center": 25,
		"industrial_area->evacuation_center": 30,
	}

	var kmf_times: Dictionary = {
		"base->hospital": 5,
		"base->city_center": 8,
		"base->evacuation_center": 12,
		"base->industrial_area": 15,
		"hospital->base": 5,
		"hospital->city_center": 4,
		"hospital->evacuation_center": 10,
		"hospital->industrial_area": 12,
		"city_center->base": 8,
		"city_center->hospital": 4,
		"city_center->evacuation_center": 6,
		"city_center->industrial_area": 8,
		"evacuation_center->base": 12,
		"evacuation_center->hospital": 10,
		"evacuation_center->city_center": 6,
		"evacuation_center->industrial_area": 10,
		"industrial_area->base": 15,
		"industrial_area->hospital": 12,
		"industrial_area->city_center": 8,
		"industrial_area->evacuation_center": 10,
	}

	var key = "%s->%s" % [from, to]
	var foot_time = foot_times.get(key, 30)
	var kmf_time = kmf_times.get(key, 10)

	var times = foot_times if mode == "foot" else kmf_times
	var estimated = times.get(key, 20)

	return {
		"from": from,
		"to": to,
		"mode": mode,
		"estimated_minutes": estimated,
		"foot_minutes": foot_time,
		"kmf_minutes": kmf_time,
		"is_estimate": true,
		"warning": "※予測時間。道路状況・敵の有無で変動します。" if mode == "foot" else "※予測時間。封鎖・戦闘で遅延の可能性があります。",
	}

func _format_remaining_time(minutes: int) -> String:
	if minutes < 0:
		return "期限切れ"
	elif minutes < 30:
		return "残り%d分 (至急!)" % minutes
	elif minutes < 60:
		return "残り%d分" % minutes
	else:
		var h = minutes / 60
		var m = minutes % 60
		return "残り%d時間%d分" % [h, m]

func _format_minute(minute: int) -> String:
	var h = minute / 60
	var m = minute % 60
	return "%02d:%02d" % [h, m]

## ============================================================
## MiniMax追加: Day1終了時の結果通知（day1_feedback）
## ============================================================
## Day1SummarySystemが生成するデータを使用して結果通知を生成する。
## 救出・喪失した人物、任務の成否、施設状態、KMF消費を表示。

func _on_day1_summary_ready(summary: Dictionary) -> void:
	if _day1_ended:
		return
	_day1_ended = true
	_day1_feedback_data = _build_day1_feedback(summary)

	if _eb and _eb.has_signal("day1_feedback_ready"):
		_eb.day1_feedback_ready.emit(_day1_feedback_data.duplicate(true))

	print("[Day1Info] Day1 feedback ready: %d completed, %d failed" % [
		_day1_feedback_data.get("completed_count", 0),
		_day1_feedback_data.get("failed_count", 0)
	])

func _on_day1_case_state_changed(case_id: String, old_status: String, new_status: String) -> void:
	_case_overviews_dirty = true

func _on_time_advanced(minutes: int) -> void:
	var current_minute = _gs.get_minute_of_day() if _gs else 0

	# Setup contradiction early in Day1 if not done
	if not _contradiction_setup_complete and _gs.get_day() == 1:
		if current_minute >= 500 and current_minute < 600:
			setup_day1_contradiction()

	# Day1終了判定
	if _gs and _gs.get_day() >= 2 and not _day1_ended:
		_trigger_day1_end()

func _trigger_day1_end() -> void:
	if _day1_ended:
		return
	_day1_ended = true

	# Finalize canonical Day1 result before any feedback/end UI can be emitted.
	var d1 = _find_day1_controller()
	if d1 and d1.has_method("finalize_day1_result"):
		d1.finalize_day1_result()

	# Day1SummarySystemに summaries 生成をリクエスト
	var summary_node = get_parent().get_node_or_null("Day1SummarySystem") if get_parent() else null
	var summary: Dictionary = {}

	if summary_node and summary_node.has_method("generate_day1_summary"):
		summary = summary_node.generate_day1_summary()
	elif summary_node and summary_node.has_method("get_summary"):
		summary = summary_node.get_summary()

	_day1_feedback_data = _build_day1_feedback(summary)

	if _eb and _eb.has_signal("day1_feedback_ready"):
		_eb.day1_feedback_ready.emit(_day1_feedback_data.duplicate(true))

func _build_day1_feedback(summary: Dictionary) -> Dictionary:
	var day1: Dictionary = _gs.get_section("day1") if _gs else {}
	var case_states: Dictionary = day1.get("case_states", {})

	# 案件サマリー
	var completed_cases: Array = []
	var failed_cases: Array = []
	var expired_cases: Array = []
	var active_cases: Array = []

	for case_id in case_states:
		var state = case_states[case_id]
		var status = str(state.get("status", ""))
		var info: Dictionary = {
			"id": case_id,
			"name": _get_case_display_name(case_id),
			"result_reason": str(state.get("result_reason", "")),
		}
		match status:
			"completed": completed_cases.append(info)
			"failed": failed_cases.append(info)
			"expired": expired_cases.append(info)
			"active", "available": active_cases.append(info)

	# NPC状態
	var rescued_npcs: Array = []
	var lost_npcs: Array = []
	var departed_npcs: Array = []

	if summary.has("npcs"):
		var npc_summary = summary["npcs"]
		for n in npc_summary.get("rescued", []):
			rescued_npcs.append({"id": str(n.get("id", "")), "name": str(n.get("name", ""))})
		for n in npc_summary.get("lost", []):
			lost_npcs.append({"id": str(n.get("id", "")), "name": str(n.get("name", ""))})
		for n in npc_summary.get("departed", []):
			departed_npcs.append({"id": str(n.get("id", "")), "name": str(n.get("name", ""))})

	# 施設状態
	var facilities: Array = []
	var day1_facs: Dictionary = day1.get("facilities", {})
	for fid in day1_facs:
		var f = day1_facs[fid]
		facilities.append({
			"id": fid,
			"name": _get_facility_display_name(fid),
			"operational": bool(f.get("operational", true)),
			"capacity": float(f.get("capacity", 0.0)),
			"pressure": float(f.get("pressure", 0.0)),
			"service_level": float(f.get("service_level", 0.0)),
			"reason": str(f.get("reason", "")),
		})

	# KMF消費
	var kmf_state: Dictionary = summary.get("kmf_state", {})
	var kmf_exposure = float(day1.get("kmf_exposure", 0.0))
	var kmf_events = kmf_state.get("major_events", [])

	# 確定情報（直接確認した事実）
	var confirmed_info: Array = []
	for rec in _information_records.values():
		if int(rec.get("sourceType", -1)) == SourceType.DIRECT_OBSERVATION:
			confirmed_info.append({
				"content": str(rec.get("content", "")),
				"location": str(rec.get("sourceLocation", "")),
			})

	var feedback: Dictionary = {
		"day": 1,
		"generated_at": _gs.get_time_string() if _gs else "Day 1",
		"completed_count": completed_cases.size(),
		"failed_count": failed_cases.size(),
		"expired_count": expired_cases.size(),
		"completed_cases": completed_cases,
		"failed_cases": failed_cases,
		"expired_cases": expired_cases,
		"active_cases": active_cases,
		"rescued_npcs": rescued_npcs,
		"lost_npcs": lost_npcs,
		"departed_npcs": departed_npcs,
		"facilities": facilities,
		"kmf_exposure": kmf_exposure,
		"kmf_use_count": kmf_events.size(),
		"kmf_consumed": kmf_exposure > 0.0,
		"confirmed_info": confirmed_info,
		"summary_text": _build_feedback_text(completed_cases, failed_cases, expired_cases,
		                                    rescued_npcs, lost_npcs, facilities, kmf_exposure),
	}

	return feedback

func _build_feedback_text(completed: Array, failed: Array, expired: Array,
                          rescued: Array, lost: Array, facilities: Array,
                          kmf_exp: float) -> String:
	var lines: Array = []

	if not completed.is_empty():
		lines.append("【救助・達成】")
		for c in completed:
			lines.append("  ○ %s" % c.get("name", "?"))

	if not expired.is_empty():
		lines.append("【期限切れ】")
		for c in expired:
			lines.append("  △ %s" % c.get("name", "?"))

	if not failed.is_empty():
		lines.append("【失敗】")
		for c in failed:
			lines.append("  × %s" % c.get("name", "?"))

	if not rescued.is_empty():
		lines.append("【生存者】")
		for n in rescued:
			lines.append("  ○ %s" % n.get("name", "?"))

	if not lost.is_empty():
		lines.append("【喪失】")
		for n in lost:
			lines.append("  × %s" % n.get("name", "?"))

	if kmf_exp > 0.0:
		var level_str = "低" if kmf_exp < 15.0 else ("中" if kmf_exp < 40.0 else "高")
		lines.append("【KMF露出】 %s (%.1f)" % [level_str, kmf_exp])

	return "\n".join(lines)

func _get_case_display_name(case_id: String) -> String:
	var names: Dictionary = {
		"quest_hospital_medicine": "病院医薬品輸送",
		"quest_evacuation_rescue": "避難民救助",
		"quest_supply_depot": "食料倉庫確保",
	}
	return names.get(case_id, case_id)

func _get_facility_display_name(facility_id: String) -> String:
	var names: Dictionary = {
		"hospital": "病院",
		"evacuation_center": "避難所",
		"maintenance": "整備施設",
	}
	return names.get(facility_id, facility_id)

## Day1 feedbackデータを取得（ HUDが呼び出し）
func get_day1_feedback() -> Dictionary:
	if _day1_feedback_data.is_empty() and _day1_ended:
		_day1_feedback_data = _build_day1_feedback({})
	return _day1_feedback_data.duplicate(true)

## Day1終了判定
func is_day1_ended() -> bool:
	return _day1_ended

## ============================================================
## 既存API（変更なし）
## ============================================================

## Handle location changes (for contradiction detection)
func _on_location_changed(location_id: String) -> void:
	check_contradiction_at_location(location_id)

## Get information record by ID
func get_record(record_id: String) -> Dictionary:
	return _information_records.get(record_id, {})

## Get all information records
func get_all_records() -> Array:
	return _information_records.values()

## Get records by source type
func get_records_by_source_type(source_type: int) -> Array:
	return _information_records.values().filter(
		func(r): return r["sourceType"] == source_type
	)

## Get records by location
func get_records_by_location(location_id: String) -> Array:
	return _information_records.values().filter(
		func(r): return r["sourceLocation"] == location_id
	)

## Get contradictory records
func get_contradictions() -> Array:
	return _contradictions

## Get records related to a case
func get_records_for_case(case_id: String) -> Array:
	return _information_records.values().filter(
		func(r): return case_id in r.get("relatedCases", [])
	)

## Check if quest_supply_depot was discovered
func is_quest_supply_depot_discovered() -> bool:
	return _quest_supply_depot_discovered

## Export records for UI display (without truth/is_true)
func export_ui_records() -> Array:
	var result = []
	for rec in _information_records.values():
		var ui_rec = {
			"id": rec["id"],
			"content": rec["content"],
			"sourceId": rec["sourceId"],
			"sourceTypeName": rec["sourceTypeName"],
			"day": rec["day"],
			"minute": rec["minute"],
			"sourceLocation": rec["sourceLocation"],
			"relatedNpcs": rec["relatedNpcs"],
			"tags": rec["tags"],
			"contradiction_status": rec["contradiction_status"],
		}
		# NOTE: truth/is_true NOT included - UI should not show definitive truth
		result.append(ui_rec)
	return result

## Save/Load support
func serialize() -> Dictionary:
	return {
		"information_records": _information_records.duplicate(true),
		"processed_action_ids": _processed_action_ids.duplicate(),
		"contradictions": _contradictions.duplicate(true),
		"quest_supply_depot_discovered": _quest_supply_depot_discovered,
		"contradiction_setup_complete": _contradiction_setup_complete,
		"contradiction_contradicted": _contradiction_contradicted,
		"kmf_reports_buffer": _kmf_reports_buffer.duplicate(true),
		"kmf_reports_history": _kmf_reports_history.duplicate(true),
		"kmf_digest_pending": _kmf_digest_pending,
		"kmf_digest_generated": _kmf_digest_generated.duplicate(true),
		"known_case_overviews": _known_case_overviews.duplicate(true),
		"case_overviews_dirty": _case_overviews_dirty,
		"day1_ended": _day1_ended,
		"day1_feedback_data": _day1_feedback_data.duplicate(true),
	}

func deserialize(data: Dictionary) -> void:
	if data.has("information_records"):
		_information_records = data["information_records"].duplicate(true)
	if data.has("processed_action_ids"):
		_processed_action_ids = data["processed_action_ids"].duplicate()
	if data.has("contradictions"):
		_contradictions = data["contradictions"].duplicate(true)
	if data.has("quest_supply_depot_discovered"):
		_quest_supply_depot_discovered = data["quest_supply_depot_discovered"]
	if data.has("contradiction_setup_complete"):
		_contradiction_setup_complete = data["contradiction_setup_complete"]
	if data.has("contradiction_contradicted"):
		_contradiction_contradicted = data["contradiction_contradicted"]
	if data.has("kmf_reports_buffer"):
		_kmf_reports_buffer = data["kmf_reports_buffer"].duplicate(true)
	if data.has("kmf_reports_history"):
		_kmf_reports_history = data["kmf_reports_history"].duplicate(true)
	if data.has("kmf_digest_pending"):
		_kmf_digest_pending = data["kmf_digest_pending"]
	if data.has("kmf_digest_generated"):
		_kmf_digest_generated = data["kmf_digest_generated"].duplicate(true)
	if data.has("known_case_overviews"):
		_known_case_overviews = data["known_case_overviews"].duplicate(true)
	if data.has("case_overviews_dirty"):
		_case_overviews_dirty = data["case_overviews_dirty"]
	if data.has("day1_ended"):
		_day1_ended = data["day1_ended"]
	if data.has("day1_feedback_data"):
		_day1_feedback_data = data["day1_feedback_data"].duplicate(true)
