# SocialManager.gd — MiniMax root autoload
# Coordinates all social/UI systems.
# Uses only the public API contracts: GameState, EventBus, RngService.
# Does NOT access Grok internals.

extends Node

## All sub-systems registered here for easy access
var npc_manager: Node
var memory_system: Node
var emotion_system: Node
var heroine_system: Node
var male_friend_estimator: Node
var world_event_system: Node
var geass_system: Node
var quest_manager: Node
var ending_system: Node
var debug_hooks: Node

var _gs: Node  # GameState (stub or production)
var _eb: Node  # EventBus (stub or production)
var _rng: Node  # RngService (stub or production)
var _initialized: bool = false

func _ready() -> void:
	# Integrated production candidate: use only production autoloads.
	_gs = get_node_or_null("/root/GameState")
	_eb = get_node_or_null("/root/EventBus")
	_rng = get_node_or_null("/root/RngService")
	if _eb and not _eb.time_advanced.is_connected(on_time_advanced):
		_eb.time_advanced.connect(on_time_advanced)
	print("[SocialManager] GS=%s EB=%s RNG=%s" % [_gs, _eb, _rng])

## Accessors for the contract API
func GS() -> Node:
	return _gs

func EB() -> Node:
	return _eb

func RNG() -> Node:
	return _rng

func gs() -> Node:
	if _gs:
		return _gs
	_gs = get_node_or_null("/root/GameState")
	return _gs

func eb() -> Node:
	if _eb:
		return _eb
	_eb = get_node_or_null("/root/EventBus")
	return _eb

func rng() -> Node:
	if _rng:
		return _rng
	_rng = get_node_or_null("/root/RngService")
	return _rng

## Convenience wrappers matching contract signatures
func get_snapshot() -> Dictionary:
	return gs().get_snapshot() if gs() else {}

func get_heroine() -> Dictionary:
	return gs().get_heroine() if gs() else {}

func set_heroine(data: Dictionary) -> void:
	if gs():
		gs().set_heroine(data)

func advance_time(minutes: int) -> void:
	if gs():
		gs().advance_time(minutes)

func get_day() -> int:
	return gs().get_day() if gs() else 1

func get_minute_of_day() -> int:
	return gs().get_minute_of_day() if gs() else 480

func add_system_fact(fact_id: String, payload: Dictionary) -> void:
	if gs():
		gs().add_system_fact(fact_id, payload)

func add_report(report: Dictionary) -> void:
	if gs():
		gs().add_report(report)

func set_quest(quest_id: String, data: Dictionary) -> void:
	if gs():
		gs().set_quest(quest_id, data)

func get_all_npcs() -> Dictionary:
	return gs().get_all_npcs() if gs() else {}

func set_npc(npc_id: String, data: Dictionary) -> void:
	if gs():
		gs().set_npc(npc_id, data)

func get_npc(npc_id: String) -> Dictionary:
	return gs().get_npc(npc_id) if gs() else {}

func get_world() -> Dictionary:
	return gs().get_world() if gs() else {}

func set_world(data: Dictionary) -> void:
	if gs():
		gs().set_world(data)

## Initialize all sub-systems
func initialize() -> void:
	if _initialized:
		return
	_initialized = true

	# Seed RNG from GameState
	var meta = gs().get_meta_section() if gs() else {}
	var seed = meta.get("seed", 42)
	if rng():
		rng().set_seed(seed)

	# Initialize modules in dependency order.
	for node_name in [
		"NpcManager", "MemorySystem", "EmotionSystem", "HeroineSystem",
		"MaleFriendEstimator", "WorldEventSystem", "GeassSystem",
		"QuestManager", "EndingSystem"
	]:
		var node = get_node_or_null("/root/" + node_name)
		if node and node.has_method("initialize"):
			node.initialize()

	# Keep the heroine copy in NpcManager synchronized with HeroineSystem.
	var hs = get_node_or_null("/root/HeroineSystem")
	var nm = get_node_or_null("/root/NpcManager")
	if hs and nm and nm.has_method("mirror_heroine_state"):
		nm.mirror_heroine_state(hs.get_state())

	print("[SocialManager] All systems initialized")

## Time tick — called each game minute
func on_time_advanced(minutes: int) -> void:
	var day = gs().get_day() if gs() else 1
	var minute = gs().get_minute_of_day() if gs() else 0

	var wes = get_node_or_null("/root/WorldEventSystem")
	if wes:
		wes.on_time_tick(day, minute)

	var geass = get_node_or_null("/root/GeassSystem")
	if geass:
		geass.on_time_tick(day, minute)

	var hs = get_node_or_null("/root/HeroineSystem")
	if hs:
		hs.on_time_tick(day, minute, minutes)

	var qm = get_node_or_null("/root/QuestManager")
	if qm:
		qm.on_time_tick(day, minute)

	# Emotion decay is defined per ~60-minute tick. Apply proportionally by whole hours,
	# with one step for any positive sub-hour advance to keep behavior observable.
	var nm = get_node_or_null("/root/NpcManager")
	var es = get_node_or_null("/root/EmotionSystem")
	if nm and es:
		var steps: int = maxi(1, int(ceil(float(minutes) / 60.0)))
		for npc_id in nm.get_npc_ids():
			var npc = nm.get_npc(npc_id)
			for _i in range(steps):
				es.decay_emotions(npc)
			nm.update_npc(npc_id, {"emotions": npc.get("emotions", {}), "currentEmotion": npc.get("currentEmotion", "neutral")})

	# Day 7 ending evaluation. EndingSystem caches the result, so repeated ticks are safe.
	if day >= 7 and minute >= 12 * 60:
		var ending = get_node_or_null("/root/EndingSystem")
		if ending:
			ending.evaluate_ending()

## Snapshot for save
func serialize() -> Dictionary:
	return {
		"npc_manager": get_node_or_null("/root/NpcManager").serialize() if get_node_or_null("/root/NpcManager") else {},
		"memory_system": get_node_or_null("/root/MemorySystem").serialize() if get_node_or_null("/root/MemorySystem") else {},
		"emotion_system": get_node_or_null("/root/EmotionSystem").serialize() if get_node_or_null("/root/EmotionSystem") else {},
		"heroine_system": get_node_or_null("/root/HeroineSystem").serialize() if get_node_or_null("/root/HeroineSystem") else {},
		"male_friend_estimator": get_node_or_null("/root/MaleFriendEstimator").serialize() if get_node_or_null("/root/MaleFriendEstimator") else {},
		"world_event_system": get_node_or_null("/root/WorldEventSystem").serialize() if get_node_or_null("/root/WorldEventSystem") else {},
		"geass_system": get_node_or_null("/root/GeassSystem").serialize() if get_node_or_null("/root/GeassSystem") else {},
		"quest_manager": get_node_or_null("/root/QuestManager").serialize() if get_node_or_null("/root/QuestManager") else {},
		"ending_system": get_node_or_null("/root/EndingSystem").serialize() if get_node_or_null("/root/EndingSystem") else {},
	}

func deserialize(data: Dictionary) -> void:
	# Restore NPCs first for subsystem dependencies, then restore them again last.
	# HeroineSystem.deserialize() mirrors heroine state into NpcManager, so the
	# final restore is required for exact Save/Load round-trip consistency.
	if get_node_or_null("/root/NpcManager"):
		get_node_or_null("/root/NpcManager").deserialize(data.get("npc_manager", {}))
	if get_node_or_null("/root/MemorySystem"):
		get_node_or_null("/root/MemorySystem").deserialize(data.get("memory_system", {}))
	if get_node_or_null("/root/EmotionSystem"):
		get_node_or_null("/root/EmotionSystem").deserialize(data.get("emotion_system", {}))
	if get_node_or_null("/root/HeroineSystem"):
		get_node_or_null("/root/HeroineSystem").deserialize(data.get("heroine_system", {}))
	if get_node_or_null("/root/MaleFriendEstimator"):
		get_node_or_null("/root/MaleFriendEstimator").deserialize(data.get("male_friend_estimator", {}))
	if get_node_or_null("/root/WorldEventSystem"):
		get_node_or_null("/root/WorldEventSystem").deserialize(data.get("world_event_system", {}))
	if get_node_or_null("/root/GeassSystem"):
		get_node_or_null("/root/GeassSystem").deserialize(data.get("geass_system", {}))
	if get_node_or_null("/root/QuestManager"):
		get_node_or_null("/root/QuestManager").deserialize(data.get("quest_manager", {}))
	if get_node_or_null("/root/EndingSystem"):
		get_node_or_null("/root/EndingSystem").deserialize(data.get("ending_system", {}))
	# Subsystem deserializers (notably HeroineSystem) can mirror data into
	# NpcManager. Re-apply the saved NPC runtime last so the persisted snapshot
	# is the final authoritative social-runtime state.
	if get_node_or_null("/root/NpcManager"):
		get_node_or_null("/root/NpcManager").deserialize(data.get("npc_manager", {}))
