# heroine_system.gd — Heroine (水城ユイ) behavior and state management
# CRITICAL RULES from specification:
# - affection -100 does NOT directly trigger protagonist death
# - affection near 0 is NOT automatically safe (most unpredictable)
# - affection and interactionTotal/interactionRecent are SEPARATE variables
# - protagonist can survive/win heroine KMF battles if superior in skill/terrain/conditions
# - high affection does NOT prevent conflict from independent goals or geass effects

extends Node

const HEROINE_ID = "yui"

var _gs: Node
var _eb: Node
var _rng: Node
var _nm: Node

## Heroine state
var _state: Dictionary = {}

## Interaction thresholds (data-driven, adjustable)
const INTERACTION_RECENT_RESET_THRESHOLD: int = 100  # interactionRecent resets when exceeded
const TRUST_AFFECTION_SCALE: float = 0.5  # trust grows with positive affection over time

## Affection action thresholds (data-driven)
var _affinity_thresholds: Dictionary = {
	"abandon_threshold": -80,   # below this: hostility grows
	"betray_possible": -50,    # below this: betrayal possible
	"danger_zone": -10,        # -10 to +10: unpredictable, uncertain
	"trust_grows": 30,         # above this: trust-building behavior
	"strong_bond": 70,        # above this: protective/cooperative behavior
}

## Heroine action types
enum ActionType {
	IDLE, TALK, ANALYZE, WARN, REQUEST, FLEE, ATTACK, COOPERATE, SHARE_INFO, FOLLOW
}

func _ready() -> void:
	_gs = get_node_or_null("/root/GameState")
	_eb = get_node_or_null("/root/EventBus")
	_rng = get_node_or_null("/root/RngService")
	_nm = get_node_or_null("/root/NpcManager")

func initialize() -> void:
	# Load initial heroine state from GameState
	var gs_heroine = _gs.get_heroine() if _gs else {}
	if gs_heroine.is_empty():
		_state = {
			"id": HEROINE_ID,
			"name": "水城ユイ",
			"alive": true,
			"present": true,
			"affection": 0,
			"interactionTotal": 0,
			"interactionRecent": 0,
			"trust": 0,
			"fear": 0,
			"dependence": 0,
			"emotions": {
				"joy": 0.0, "anger": 0.0, "sadness": 0.0,
				"fear": 0.0, "surprise": 0.0, "disgust": 0.0,
				"hope": 0.3, "anxiety": 0.2
			},
			"currentAction": "idle",
			"currentGoal": "survive_with_player",
		}
	else:
		_state = gs_heroine.duplicate(true)
	_sync_to_gs()

func _sync_to_gs() -> void:
	if _gs:
		_gs.set_heroine(_state)
	var nm = get_node_or_null("/root/NpcManager")
	if nm and nm.has_method("mirror_heroine_state"):
		nm.mirror_heroine_state(_state)

func apply_external_updates(updates: Dictionary) -> void:
	for key in updates.keys():
		_state[key] = updates[key]
	if _state.has("affection"):
		_state["affection"] = clampi(int(_state["affection"]), -100, 100)
	_sync_to_gs()

## --- Affection management ---

func get_affection() -> int:
	return _state.get("affection", 0)

func set_affection(val: int) -> void:
	var old = _state.get("affection", 0)
	var new_val = clampi(val, -100, 100)
	_state["affection"] = new_val
	if _eb:
		_eb.affection_changed.emit(HEROINE_ID, old, new_val)
		_eb.heroine_state_changed.emit("affection", old, new_val)
	_sync_to_gs()

func modify_affection(delta: int, reason: String = "") -> void:
	var old = _state.get("affection", 0)
	set_affection(old + delta)
	print("[Heroine] affection %s (%+d) reason: %s" % [old, delta, reason])

## --- Interaction management ---

func add_interaction(amount: int = 1, interaction_type: String = "talk") -> void:
	var old_total = _state.get("interactionTotal", 0)
	var old_recent = _state.get("interactionRecent", 0)
	_state["interactionTotal"] = old_total + amount
	
	var new_recent = old_recent + amount
	if new_recent > INTERACTION_RECENT_RESET_THRESHOLD:
		new_recent = int(new_recent * 0.3)  # Decay rather than hard reset
	_state["interactionRecent"] = new_recent
	
	if _eb:
		_eb.heroine_state_changed.emit("interactionTotal", old_total, _state["interactionTotal"])
		_eb.heroine_state_changed.emit("interactionRecent", old_recent, new_recent)
	_sync_to_gs()

func get_interaction_total() -> int:
	return _state.get("interactionTotal", 0)

func get_interaction_recent() -> int:
	return _state.get("interactionRecent", 0)

## --- Trust, Fear, Dependence ---

func modify_trust(delta: int) -> void:
	var old = _state.get("trust", 0)
	_state["trust"] = clampi(old + delta, -100, 100)
	if _eb:
		_eb.heroine_state_changed.emit("trust", old, _state["trust"])
	_sync_to_gs()

func modify_fear(delta: int) -> void:
	var old = _state.get("fear", 0)
	_state["fear"] = clampi(old + delta, -100, 100)
	if _eb:
		_eb.heroine_state_changed.emit("fear", old, _state["fear"])
	_sync_to_gs()

func modify_dependence(delta: int) -> void:
	var old = _state.get("dependence", 0)
	_state["dependence"] = clampi(old + delta, 0, 100)  # Dependence can't be negative
	if _eb:
		_eb.heroine_state_changed.emit("dependence", old, _state["dependence"])
	_sync_to_gs()

## --- Emotion handling ---
func get_emotions() -> Dictionary:
	return _state.get("emotions", {}).duplicate(true)

func set_emotion(emotion_type: String, value: float) -> void:
	var emotions = _state.get("emotions", {})
	emotions[emotion_type] = clampf(value, 0.0, 1.0)
	_state["emotions"] = emotions
	if _eb:
		_eb.emotion_changed.emit(HEROINE_ID, emotion_type, value)
	_sync_to_gs()

func modify_emotion(emotion_type: String, delta: float) -> void:
	var emotions = _state.get("emotions", {})
	var old_val = emotions.get(emotion_type, 0.0)
	emotions[emotion_type] = clampf(old_val + delta, 0.0, 1.0)
	_state["emotions"] = emotions
	if _eb:
		_eb.emotion_changed.emit(HEROINE_ID, emotion_type, emotions[emotion_type])
	_sync_to_gs()

func get_dominant_emotion() -> String:
	var emotions = _state.get("emotions", {})
	var best = "neutral"
	var best_val = 0.0
	for k in ["joy", "anger", "sadness", "fear", "surprise", "disgust", "hope", "anxiety"]:
		var v = emotions.get(k, 0.0)
		if v > best_val:
			best_val = v
			best = k
	return best

## --- Affection band classification ---
enum AffectionBand {
	HOSTILE_CERTAIN = 0,   # -100 to -81
	HOSTILE_LIKELY = 1,     # -80 to -51
	DANGER_ZONE_NEG = 2,   # -50 to -11
	UNCERTAIN = 3,          # -10 to +10  ← THE MOST DANGEROUS BAND
	DANGER_ZONE_POS = 4,    # +11 to +50
	FRIENDLY = 5,          # +51 to +80
	DEVOTED = 6,            # +81 to +100
}

func get_affection_band() -> int:
	var a = _state.get("affection", 0)
	if a <= -81: return AffectionBand.HOSTILE_CERTAIN
	elif a <= -51: return AffectionBand.HOSTILE_LIKELY
	elif a <= -11: return AffectionBand.DANGER_ZONE_NEG
	elif a <= 10: return AffectionBand.UNCERTAIN
	elif a <= 50: return AffectionBand.DANGER_ZONE_POS
	elif a <= 80: return AffectionBand.FRIENDLY
	else: return AffectionBand.DEVOTED

func get_affection_band_label() -> String:
	var band = get_affection_band()
	var labels = [
		"敵対確定", "敵対の可能性", "負の危険域",
		"未確定（最大不確実性）", "正の危険域",
		"友好", "献身"
	]
	return labels[band]

## --- Decision logic: determine heroine action based on state ---
func get_next_action() -> ActionType:
	## KEY: Affection near 0 is NOT safe. It's the most unpredictable state.
	## Affection -100 does NOT directly kill the protagonist.
	var affection = _state.get("affection", 0)
	var trust = _state.get("trust", 0)
	var fear = _state.get("fear", 0)
	var dependence = _state.get("dependence", 0)
	var emotions = _state.get("emotions", {})
	var world = _gs.get_world() if _gs else {}
	var unrest = world.get("socialUnrest", 0)
	
	# Dead or absent
	if not _state.get("alive", true) or not _state.get("present", true):
		return ActionType.IDLE
	
	# Critical fear — flee regardless of affection
	if fear > 70:
		return ActionType.FLEE
	
	# High anger — may attack or oppose
	if emotions.get("anger", 0.0) > 0.7:
		if affection < -50:
			return ActionType.ATTACK
		else:
			return ActionType.WARN  # Frustrated but not hostile
	
	# Affiliation band determines baseline behavior
	var band = get_affection_band()
	match band:
		AffectionBand.HOSTILE_CERTAIN, AffectionBand.HOSTILE_LIKELY:
			## Affection is very negative: betrayal, obstruction, or hostility possible
			## But protagonist can survive if more skilled/positioned/equipped
			var roll = _rng.randf() if _rng else 0.5
			if fear > 50:
				return ActionType.FLEE  # Afraid but hostile
			elif roll < 0.3:
				return ActionType.ATTACK  # May actively oppose
			elif roll < 0.6:
				return ActionType.WARN  # Verbal opposition
			else:
				return ActionType.IDLE  # Passive resistance
		
		AffectionBand.DANGER_ZONE_NEG:
			## Negative but not extreme: unstable
			var roll = _rng.randf() if _rng else 0.5
			if emotions.get("fear", 0.0) > 0.5:
				return ActionType.FLEE
			elif roll < 0.15:
				return ActionType.ATTACK  # Minor chance of hostile action
			elif roll < 0.4:
				return ActionType.WARN
			else:
				return ActionType.IDLE
		
		AffectionBand.UNCERTAIN:
			## CRITICAL: Affection near 0 — most unpredictable, least motivated to cooperate
			## Not automatically safe. Behavior is driven by fear, dependence, and goals.
			var roll = _rng.randf() if _rng else 0.5
			if fear > 40:
				return ActionType.FLEE
			elif dependence > 30:
				return ActionType.FOLLOW  # Stays due to dependence, not affection
			elif roll < 0.1:
				return ActionType.ATTACK  # Unpredictable aggression
			elif roll < 0.3:
				return ActionType.ANALYZE  # Observing, not committing
			elif roll < 0.5:
				return ActionType.TALK  # Testing boundaries
			else:
				return ActionType.IDLE
		
		AffectionBand.DANGER_ZONE_POS:
			## Positive but moderate: cooperative potential
			var roll = _rng.randf() if _rng else 0.5
			if roll < 0.3:
				return ActionType.COOPERATE
			elif roll < 0.5:
				return ActionType.SHARE_INFO
			elif roll < 0.7:
				return ActionType.ANALYZE
			else:
				return ActionType.TALK
		
		AffectionBand.FRIENDLY, AffectionBand.DEVOTED:
			## High positive: protective and cooperative
			if emotions.get("sadness", 0.0) > 0.6:
				return ActionType.SHARE_INFO  # Grieving but helpful
			var roll = _rng.randf() if _rng else 0.5
			if roll < 0.4:
				return ActionType.COOPERATE
			elif roll < 0.6:
				return ActionType.SHARE_INFO
			elif roll < 0.8:
				return ActionType.ANALYZE
			else:
				return ActionType.TALK
	
	return ActionType.IDLE

## --- Conversation result processing ---
func on_conversation_result(result_type: String, data: Dictionary) -> void:
	## Process the result of a player-NPC or player-heroine conversation
	match result_type:
		"helped":
			modify_affection(+10, "player helped heroine")
			modify_trust(+5)
			modify_dependence(+3)
			modify_emotion("joy", 0.2)
			modify_emotion("hope", 0.1)
			add_interaction(5, "helped")
		"shared_info":
			modify_affection(+3, "shared information")
			modify_trust(+2)
			add_interaction(2, "info exchange")
		"protected":
			modify_affection(+15, "protected her")
			modify_trust(+8)
			modify_fear(-10)
			modify_emotion("joy", 0.3)
			modify_emotion("fear", -0.2)
			add_interaction(8, "protection")
		"ignored":
			modify_affection(-5, "player ignored her")
			modify_emotion("sadness", 0.1)
			modify_emotion("anxiety", 0.1)
		"rejected":
			modify_affection(-15, "player rejected her request")
			modify_emotion("anger", 0.2)
			modify_emotion("sadness", 0.2)
			add_interaction(-3, "rejected")
		"attacked":
			modify_affection(-30, "player attacked her")
			modify_emotion("anger", 0.5)
			modify_emotion("fear", 0.3)
		"betrayed":
			modify_affection(-50, "player betrayed her")
			modify_trust(-30)
			modify_emotion("anger", 0.6)
			modify_emotion("sadness", 0.4)
	
	# Recalculate dependence based on context
	var world = _gs.get_world() if _gs else {}
	var day = _gs.get_day() if _gs else 1
	if day >= 4:
		# Later days: dependence grows if player is the main resource
		if _state.get("trust", 0) > 30:
			modify_dependence(+1)

## --- Time tick: decay interactionRecent, apply natural changes ---
func on_time_tick(day: int, minute: int, elapsed_minutes: int = 60) -> void:
	var steps: int = maxi(1, int(ceil(float(elapsed_minutes) / 60.0)))
	var recent = int(_state.get("interactionRecent", 0))
	if recent > 0:
		_state["interactionRecent"] = maxi(0, recent - steps)
	var affection = int(_state.get("affection", 0))
	var trust = int(_state.get("trust", 0))
	if affection > 30 and trust < affection:
		_state["trust"] = mini(affection, trust + steps)
	var fear = int(_state.get("fear", 0))
	if fear > 0:
		_state["fear"] = maxi(0, fear - steps)
	# Consume RNG once per logical tick, not per UI refresh.
	_state["currentAction"] = ActionType.keys()[get_next_action()]
	_sync_to_gs()

## --- Heroine KMF battle outcome ---
func evaluate_heroine_kmf_battle(
	player_strength: float,
	heroine_strength: float,
	terrain_bonus_player: float,
	protagonist_has_advantage: bool
) -> Dictionary:
	## IMPORTANT: This is a standard combat resolution.
	## Protagonist can WIN or SURVIVE if superior in strength/skill/terrain.
	## Affection does NOT automatically decide the outcome.
	## Returns: {outcome: "win", "lose", "draw", "retreat", survived: bool, reason: String}
	
	var world = _gs.get_world() if _gs else {}
	var unrest = world.get("socialUnrest", 0)
	
	# Calculate effective strengths
	var player_eff = player_strength * (1.0 + terrain_bonus_player)
	var heroine_eff = heroine_strength
	
	# Affection slightly influences heroine's willingness to fight/flee
	var affection = _state.get("affection", 0)
	if affection < -50:
		heroine_eff *= 1.2  # Hostile heroine fights harder
	elif affection > 50:
		heroine_eff *= 0.8  # Friendly heroine may hesitate
	
	# Roll for randomness
	var roll = _rng.randf_range(0.0, 1.0) if _rng else 0.5
	
	var threshold_win = 0.35  # player wins if player_eff > heroine_eff * threshold
	var threshold_draw = 0.5
	
	var ratio = player_eff / maxf(heroine_eff, 0.1)
	
	if protagonist_has_advantage:
		ratio *= 1.3
	
	if ratio > 1.5:
		return {"outcome": "win", "survived": true, "reason": "protagonist dominated the fight"}
	elif ratio > 1.1:
		if roll < 0.7:
			return {"outcome": "win", "survived": true, "reason": "protagonist prevailed through skill"}
		else:
			return {"outcome": "draw", "survived": true, "reason": "mutual exhaustion"}
	elif ratio > 0.8:
		if roll < 0.4:
			return {"outcome": "win", "survived": true, "reason": "narrow victory"}
		elif roll < 0.7:
			return {"outcome": "retreat", "survived": true, "reason": "both retreated"}
		else:
			return {"outcome": "lose", "survived": false, "reason": "defeated by heroine"}
	else:
		if roll < 0.5:
			return {"outcome": "retreat", "survived": true, "reason": "forced to retreat"}
		else:
			return {"outcome": "lose", "survived": false, "reason": "overpowered by heroine"}
	_sync_to_gs()

## --- Heroine state ---
func is_alive() -> bool:
	return _state.get("alive", true)

func is_present() -> bool:
	return _state.get("present", true)

func kill() -> void:
	_state["alive"] = false
	_state["present"] = false
	_state["currentAction"] = "dead"
	if _eb:
		_eb.heroine_state_changed.emit("alive", true, false)
	_sync_to_gs()
	print("[Heroine] YUI died — game continues but information analysis is reduced")

func make_present() -> void:
	_state["present"] = true
	if _eb:
		_eb.heroine_state_changed.emit("present", false, true)
	_sync_to_gs()

## --- State access ---
func get_state() -> Dictionary:
	return _state.duplicate(true)

func get_state_for_ui() -> Dictionary:
	return {
		"name": _state.get("name", "水城ユイ"),
		"affection_band": get_affection_band_label(),
		"interaction_total": _state.get("interactionTotal", 0),
		"interaction_recent": _state.get("interactionRecent", 0),
		"trust": _state.get("trust", 0),
		"fear": _state.get("fear", 0),
		"dependence": _state.get("dependence", 0),
		"current_emotion": get_dominant_emotion(),
		"emotions": get_emotions(),
		"alive": _state.get("alive", true),
		"present": _state.get("present", true),
		"next_action": str(_state.get("currentAction", "IDLE")),
	}

## --- Save/Load ---
func serialize() -> Dictionary:
	return {"state": _state.duplicate(true)}

func deserialize(data: Dictionary) -> void:
	if data.has("state"):
		_state = data["state"].duplicate(true)
		_sync_to_gs()
