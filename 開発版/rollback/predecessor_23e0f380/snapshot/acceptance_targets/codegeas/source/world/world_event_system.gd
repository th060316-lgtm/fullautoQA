# world_event_system.gd — World progression and 7-day event schedule
# World events progress INDEPENDENTLY of the protagonist's actions.
# Player inactivity does not stop the world from moving forward.

extends Node

var _gs: Node
var _eb: Node
var _rng: Node
var _nm: Node

## World event queue
var _event_queue: Array = []  # Pending scheduled events
var _triggered_events: Array = []  # Events that have fired

## World state
var _world_state: Dictionary = {
	"socialUnrest": 20,
	"trafficChaos": 20,
	"militaryTension": 10,
	"geassSpread": 5,
	"codeHolderRegion": "unknown",
	"guardianRegion": "unknown",
	"day": 1,
	"eventCount": 0,
}

## 7-day event schedule (data-driven)
## Format: {day, hour, minute, event_id, description, priority, repeatable, triggered}
const SCHEDULED_EVENTS: Array = [
	# Day 1: Observation basics
	{"day": 1, "hour": 10, "minute": 0, "event_id": "day1_morning_quiet", "description": "白波市は静かだ。朝の情報を集める機会がある。", "priority": 1, "repeatable": false, "triggered": false},
	{"day": 1, "hour": 14, "minute": 0, "event_id": "day1_afternoon_gunfire", "description": "市街中心部で銃声。NPCたちが警戒を強める。", "priority": 2, "repeatable": false, "triggered": false, "effects": {"socialUnrest": +10, "trafficChaos": +5}},
	{"day": 1, "hour": 18, "minute": 0, "event_id": "day1_evening_refugees", "description": "新たな避難民が流入。情報が錯綜し始める。", "priority": 1, "repeatable": false, "triggered": false, "effects": {"socialUnrest": +5}},
	
	# Day 2: Testimonies / memory contradictions
	{"day": 2, "hour": 9, "minute": 0, "event_id": "day2_morning_contradiction", "description": "二人のNPCの証言が矛盾。記憶の信憑性が問われる。", "priority": 2, "repeatable": false, "triggered": false, "effects": {"socialUnrest": +5}},
	{"day": 2, "hour": 13, "minute": 0, "event_id": "day2_afternoon_supplies", "description": "物資輸送車が略奪される。資源確保が困難に。", "priority": 2, "repeatable": false, "triggered": false, "effects": {"socialUnrest": +8, "trafficChaos": +10}},
	{"day": 2, "hour": 20, "minute": 0, "event_id": "day2_night_geass_ripple", "description": "夜の街で奇妙な記憶の揺らぎを訴えるNPCがいる。", "priority": 2, "repeatable": false, "triggered": false, "effects": {"geassSpread": +5}},
	
	# Day 3: Emotional amplification and group conflict
	{"day": 3, "hour": 8, "minute": 0, "event_id": "day3_morning_emotion_surge", "description": "避難所で感情的対立が発生。感情が増幅されている可能性がある。", "priority": 3, "repeatable": false, "triggered": false, "effects": {"socialUnrest": +15}},
	{"day": 3, "hour": 12, "minute": 0, "event_id": "day3_noon_militia_activity", "description": "武装勢力が活動範囲を拡大。市の緊張が高まっている。", "priority": 3, "repeatable": false, "triggered": false, "effects": {"socialUnrest": +10, "militaryTension": +5}},
	{"day": 3, "hour": 17, "minute": 0, "event_id": "day3_evening_rescue_needed", "description": "救助要請。NPCの運命はあなたの行動次第。", "priority": 2, "repeatable": false, "triggered": false, "effects": {"socialUnrest": +5}},
	
	# Day 4: Supply shortage and information vs resource tradeoff
	{"day": 4, "hour": 9, "minute": 0, "event_id": "day4_morning_shortage", "description": "食糧・医薬品の不足が深刻化。情報を取るか物資を取るか。", "priority": 3, "repeatable": false, "triggered": false, "effects": {"socialUnrest": +12, "trafficChaos": +5}},
	{"day": 4, "hour": 15, "minute": 0, "event_id": "day4_afternoon_ambush", "description": "武装勢力による待ち伏せ。負傷者が増える。", "priority": 3, "repeatable": false, "triggered": false, "effects": {"socialUnrest": +10}},
	{"day": 4, "hour": 21, "minute": 0, "event_id": "day4_night_rumor_spread", "description": "都市各处で噂が流れる。コード所持女性の手がかりも。", "priority": 2, "repeatable": false, "triggered": false, "effects": {"geassSpread": +3}},
	
	# Day 5: Social epicenter impact
	{"day": 5, "hour": 10, "minute": 0, "event_id": "day5_morning_social_shift", "description": "社会的震源による影響拡大。NPCの判断が変化し始める。", "priority": 3, "repeatable": false, "triggered": false, "effects": {"socialUnrest": +15, "geassSpread": +5}},
	{"day": 5, "hour": 14, "minute": 0, "event_id": "day5_afternoon_faction_split", "description": "市内勢力図が変化。派閥が形成され始める。", "priority": 3, "repeatable": false, "triggered": false, "effects": {"socialUnrest": +10, "militaryTension": +5}},
	{"day": 5, "hour": 19, "minute": 0, "event_id": "day5_evening_militants_move", "description": "武装勢力が移動中。旧整備所方面の可能性。", "priority": 2, "repeatable": false, "triggered": false, "effects": {"trafficChaos": +8}},
	
	# Day 6: Code holder / guardian approach information
	{"day": 6, "hour": 9, "minute": 0, "event_id": "day6_morning_approach_warning", "description": "コード所持女性と護衛男性が白波市近郊に接近した可能性が浮上。", "priority": 3, "repeatable": false, "triggered": false, "effects": {"socialUnrest": +20, "militaryTension": +15, "geassSpread": +10}},
	{"day": 6, "hour": 13, "minute": 0, "event_id": "day6_afternoon_conflict_point", "description": "旧整備所の利用か、離散かの判断迫る。", "priority": 3, "repeatable": false, "triggered": false, "effects": {"socialUnrest": +10}},
	{"day": 6, "hour": 20, "minute": 0, "event_id": "day6_night_final_prep", "description": "最後の準備期間。NPCとの関係が運命を左右する。", "priority": 2, "repeatable": false, "triggered": false, "effects": {"socialUnrest": +5}},
	
	# Day 7: Final judgment
	{"day": 7, "hour": 8, "minute": 0, "event_id": "day7_morning_final_event", "description": "大型イベント。脱出・残留・同行者中心の最終判断が迫られる。", "priority": 4, "repeatable": false, "triggered": false, "effects": {"socialUnrest": +25}},
	{"day": 7, "hour": 12, "minute": 0, "event_id": "day7_noon_ending_check", "description": "エンディング判定。この7日間の全行動が評価される。", "priority": 4, "repeatable": false, "triggered": false, "effects": {}},
]

var _scheduled_events_state: Array = []

func _ready() -> void:
	_gs = get_node_or_null("/root/GameState")
	_eb = get_node_or_null("/root/EventBus")
	_rng = get_node_or_null("/root/RngService")
	_nm = get_node_or_null("/root/NpcManager")

func initialize() -> void:
	# Initialize scheduled events state
	_scheduled_events_state = SCHEDULED_EVENTS.map(func(e): return e.duplicate(true))
	
	# Initialize world state
	if _gs:
		var gs_world = _gs.get_world()
		if not gs_world.is_empty():
			_world_state = gs_world.duplicate(true)
		else:
			_gs.set_world(_world_state)
	
	print("[WorldEventSystem] Initialized %d scheduled events" % _scheduled_events_state.size())

## Convert hour/minute to minute-of-day
func _tod_minute(hour: int, minute: int) -> int:
	return hour * 60 + minute

## Get minute-of-day from current game state
func _current_minute_of_day() -> int:
	return _gs.get_minute_of_day() if _gs else 480

## Check and fire scheduled events
func on_time_tick(day: int, minute: int) -> void:
	if day < 1 or day > 7:
		return
	
	# Update world state
	_world_state["day"] = day
	
	# Check each scheduled event
	for ev in _scheduled_events_state:
		if ev["triggered"]:
			continue
		if int(ev["day"]) > day:
			continue
		var ev_minute = _tod_minute(ev["hour"], ev["minute"])
		if int(ev["day"]) < day or minute >= ev_minute:
			_trigger_scheduled_event(ev)

func _trigger_scheduled_event(ev: Dictionary) -> void:
	ev["triggered"] = true
	_triggered_events.append(ev.duplicate(true))
	_world_state["eventCount"] = _world_state.get("eventCount", 0) + 1
	
	# Apply effects to world state
	if ev.has("effects"):
		for key in ev["effects"]:
			var delta = ev["effects"][key]
			if key in ["socialUnrest", "trafficChaos", "militaryTension", "geassSpread"]:
				_world_state[key] = clampi(_world_state.get(key, 0) + delta, 0, 100)
	
	# Apply effects to NPCs
	if ev.has("effects"):
		_apply_world_effects_to_npcs(ev["effects"])
	
	# Sync to GameState
	_gs.set_world(_world_state) if _gs else null
	
	# Emit event
	if _eb:
		_eb.world_event_triggered.emit(ev["event_id"])
		_eb.emit_fact_observed(ev["event_id"], {
			"description": ev["description"],
			"day": ev["day"],
			"effects": ev.get("effects", {}),
		})
	
	print("[WorldEvent] Day %d %02d:%02d — %s" % [ev["day"], ev["hour"], ev["minute"], ev["description"]])

func _apply_world_effects_to_npcs(effects: Dictionary) -> void:
	if not _nm:
		return
	
	# Social unrest affects NPC behavior
	var unrest = effects.get("socialUnrest", 0)
	if unrest != 0:
		var npc_ids = _nm.get_npc_ids()
		for npc_id in npc_ids:
			var fear_delta = unrest / 10  # ~+1 fear per 10 unrest
			var anger_delta = unrest / 15
			var npc = _nm.get_npc(npc_id)
			if not npc.is_empty():
				var emotions = npc.get("emotions", {})
				emotions["fear"] = clampf(emotions.get("fear", 0.0) + fear_delta * 0.1, 0.0, 1.0)
				emotions["anger"] = clampf(emotions.get("anger", 0.0) + anger_delta * 0.1, 0.0, 1.0)
				_nm.update_npc(npc_id, {"emotions": emotions})

## --- World state access ---
func get_world_state() -> Dictionary:
	return _world_state.duplicate(true)

func get_world_value(key: String, default = 0):
	return _world_state.get(key, default)

func modify_world_value(key: String, delta: int) -> void:
	if key in ["socialUnrest", "trafficChaos", "militaryTension", "geassSpread"]:
		_world_state[key] = clampi(_world_state.get(key, 0) + delta, 0, 100)
		_gs.set_world(_world_state) if _gs else null
		if _eb:
			_eb.world_state_changed.emit(key, _world_state.get(key) - delta, _world_state[key])

## --- Event queue management ---
func queue_event(event_data: Dictionary, delay_minutes: int = 0) -> void:
	var ev = event_data.duplicate(true)
	ev["queued_at_day"] = _gs.get_day() if _gs else 1
	ev["queued_at_minute"] = _gs.get_minute_of_day() if _gs else 0
	ev["delay_minutes"] = delay_minutes
	_event_queue.append(ev)

func process_event_queue() -> void:
	if _event_queue.is_empty():
		return
	var current_day = _gs.get_day() if _gs else 1
	var current_minute = _gs.get_minute_of_day() if _gs else 0
	
	var still_queued = []
	for ev in _event_queue:
		var delay = ev.get("delay_minutes", 0)
		var elapsed = (current_day - ev["queued_at_day"]) * 1440 + (current_minute - ev["queued_at_minute"])
		if elapsed >= delay:
			# Fire the event
			_trigger_instant_event(ev)
		else:
			still_queued.append(ev)
	_event_queue = still_queued

func _trigger_instant_event(ev: Dictionary) -> void:
	if _eb:
		_eb.world_event_triggered.emit(ev.get("event_id", "queued_event"))
	
	# Apply effects
	if ev.has("effects"):
		for key in ev["effects"]:
			if key in ["socialUnrest", "trafficChaos", "militaryTension", "geassSpread"]:
				modify_world_value(key, ev["effects"][key])

## --- Check if world is escalating ---
func is_world_escalating() -> bool:
	return _world_state.get("socialUnrest", 0) > 60 or _world_state.get("militaryTension", 0) > 50

func is_code_holder_close() -> bool:
	var region = _world_state.get("codeHolderRegion", "unknown")
	return region in ["nearby", "approaching"]

## --- Day progression check ---
func get_current_day_events() -> Array:
	var day = _gs.get_day() if _gs else 1
	return _triggered_events.filter(func(e): return e["day"] == day).duplicate(true)

func get_all_triggered_events() -> Array:
	return _triggered_events.duplicate(true)

func get_upcoming_events(lookahead_days: int = 3) -> Array:
	var day = _gs.get_day() if _gs else 1
	var result = []
	for ev in _scheduled_events_state:
		if not ev["triggered"] and ev["day"] >= day and ev["day"] <= day + lookahead_days:
			result.append(ev.duplicate(true))
	result.sort_custom(func(a, b): 
		if a["day"] != b["day"]: return a["day"] < b["day"]
		return _tod_minute(a["hour"], a["minute"]) < _tod_minute(b["hour"], b["minute"])
	)
	return result

## --- Save/Load ---
func serialize() -> Dictionary:
	return {
		"world_state": _world_state.duplicate(true),
		"scheduled_events_state": _scheduled_events_state.duplicate(true),
		"triggered_events": _triggered_events.duplicate(true),
		"event_queue": _event_queue.duplicate(true),
	}

func deserialize(data: Dictionary) -> void:
	if data.has("world_state"):
		_world_state = data["world_state"].duplicate(true)
		_gs.set_world(_world_state) if _gs else null
	if data.has("scheduled_events_state"):
		_scheduled_events_state = data["scheduled_events_state"].duplicate(true)
	if data.has("triggered_events"):
		_triggered_events = data["triggered_events"].duplicate(true)
	if data.has("event_queue"):
		_event_queue = data["event_queue"].duplicate(true)
