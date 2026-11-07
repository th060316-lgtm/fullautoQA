# male_friend_estimator.gd — Male friend (男友人) estimation system
# IMPORTANT: This does NOT directly show the true affection value.
# It provides an ESTIMATED range/estimate with confidence and accuracy variability.
# Accuracy changes based on: observation opportunities, fatigue, injury, memory changes,
# presence of girlfriend NPCs, accompaniment status.

extends Node

var _gs: Node
var _eb: Node
var _rng: Node
var _nm: Node

## Male friend candidates (from NPC definitions)
const MALE_FRIEND_IDS = ["takumi"]  # Can be expanded

## Estimation state per male friend
var _estimations: Dictionary = {}  # male_friend_id -> {estimated_affection, confidence, accuracy, last_updated, observation_quality}

## Observation quality modifiers
## Factors that affect estimation accuracy
const BASE_ACCURACY: float = 0.6
const MAX_ACCURACY: float = 0.95
const MIN_ACCURACY: float = 0.3

func _ready() -> void:
	_gs = get_node_or_null("/root/GameState")
	_eb = get_node_or_null("/root/EventBus")
	_rng = get_node_or_null("/root/RngService")
	_nm = get_node_or_null("/root/NpcManager")

func initialize() -> void:
	# Initialize estimation state for each male friend
	for mf_id in MALE_FRIEND_IDS:
		var npc = _nm.get_npc(mf_id) if _nm else {}
		_estimations[mf_id] = {
			"estimated_affection": npc.get("affection", 0),
			"true_affection": npc.get("affection", 0),
			"confidence": 0.3,  # How sure the estimator is (0..1)
			"accuracy": BASE_ACCURACY,
			"last_updated_day": _gs.get_day() if _gs else 1,
			"observation_count": 0,
			"error_history": [],
			"has_girlfriend": false,
			"is_accompanying": false,
			"observer_fatigue": 0,
			"observer_injury": 0,
			"memory_modified": false,
		}
	print("[MaleFriendEstimator] Initialized for %d candidates" % MALE_FRIEND_IDS.size())

## --- Estimate accuracy calculation ---
func _compute_accuracy(est: Dictionary) -> float:
	var acc = BASE_ACCURACY
	
	# Observation count improves accuracy
	var obs = est.get("observation_count", 0)
	acc += minf(0.2, obs * 0.02)
	
	# Fatigue reduces accuracy
	var fatigue = est.get("observer_fatigue", 0)
	acc -= minf(0.2, fatigue * 0.01)
	
	# Injury reduces accuracy
	var injury = est.get("observer_injury", 0)
	acc -= minf(0.15, injury * 0.05)
	
	# Memory modification reduces accuracy dramatically
	if est.get("memory_modified", false):
		acc -= 0.25
	
	# Girlfriend presence reduces estimation clarity
	if est.get("has_girlfriend", false):
		acc -= 0.1
	
	# Accompaniment reduces observation opportunities
	if est.get("is_accompanying", false):
		acc -= 0.05
	
	# Observation quality
	var quality = est.get("observation_quality", 0.5)
	acc += (quality - 0.5) * 0.3
	
	return clampf(acc, MIN_ACCURACY, MAX_ACCURACY)

## --- Update estimation based on new observation ---
func observe_male_friend(mf_id: String, observation_data: Dictionary) -> void:
	if not _estimations.has(mf_id):
		return
	
	var est = _estimations[mf_id]
	var npc = _nm.get_npc(mf_id) if _nm else {}
	var true_affection = npc.get("affection", 0)
	
	est["observation_count"] = est.get("observation_count", 0) + 1
	est["last_updated_day"] = _gs.get_day() if _gs else 1
	
	# Observation quality from data
	var quality = observation_data.get("quality", 0.5)
	est["observation_quality"] = (est.get("observation_quality", 0.5) * 0.7 + quality * 0.3)
	
	# Update context factors
	est["has_girlfriend"] = observation_data.get("has_girlfriend", false)
	est["is_accompanying"] = observation_data.get("is_accompanying", false)
	est["observer_fatigue"] = observation_data.get("observer_fatigue", 0)
	est["observer_injury"] = observation_data.get("observer_injury", 0)
	est["memory_modified"] = observation_data.get("memory_modified", false)
	
	# Recalculate accuracy
	est["accuracy"] = _compute_accuracy(est)
	
	# Compute estimated value with error
	var error = (1.0 - est["accuracy"]) * 50.0  # Max error ~50
	var estimated = true_affection + _rng.randi_range_seeded(-int(error), int(error)) if _rng else true_affection
	est["estimated_affection"] = clampi(estimated, -100, 100)
	est["true_affection"] = true_affection
	
	# Error history
	var abs_error = abs(est["estimated_affection"] - true_affection)
	est["error_history"].append(abs_error)
	if est["error_history"].size() > 10:
		est["error_history"].pop_front()
	
	# Confidence based on observation count and accuracy
	est["confidence"] = clampf(
		0.2 + est["accuracy"] * 0.5 + minf(0.2, est["observation_count"] * 0.01),
		0.0, 1.0
	)
	
	if _eb:
		_eb.emit_npc_state_changed(mf_id)
	
	print("[MaleFriendEstimator] %s observed: est=%d acc=%.2f conf=%.2f" % [
		mf_id, est["estimated_affection"], est["accuracy"], est["confidence"]])

## --- Get estimated value with range ---
func get_estimation(mf_id: String) -> Dictionary:
	if not _estimations.has(mf_id):
		return {}
	var est = _estimations[mf_id]
	var accuracy = est.get("accuracy", BASE_ACCURACY)
	var error_margin = int((1.0 - accuracy) * 50)
	var est_val = est.get("estimated_affection", 0)
	
	return {
		"npc_id": mf_id,
		"name": (_nm.get_npc(mf_id).get("name", mf_id) if _nm else mf_id),
		"estimated_affection": est_val,
		"range_min": clampi(est_val - error_margin, -100, 100),
		"range_max": clampi(est_val + error_margin, -100, 100),
		"confidence": est["confidence"],
		"confidence_label": _confidence_label(est["confidence"]),
		"accuracy": accuracy,
		"observation_count": est.get("observation_count", 0),
		"last_updated_day": est.get("last_updated_day", 1),
		"has_girlfriend": est.get("has_girlfriend", false),
		"is_accompanying": est.get("is_accompanying", false),
		"memory_modified": est.get("memory_modified", false),
		"average_error": _average_error(est.get("error_history", [])),
		"true_value_hidden": true,  # UI hint: true value not shown
	}

func _confidence_label(confidence: float) -> String:
	if confidence < 0.3: return "不確か"
	elif confidence < 0.5: return "低信頼"
	elif confidence < 0.7: return "中程度"
	elif confidence < 0.85: return "高信頼"
	else: return "高精度"

func _average_error(history: Array) -> float:
	if history.is_empty():
		return 0.0
	var total = 0.0
	for v in history:
		total += v
	return total / history.size()

## --- Update context factors without new observation ---
func update_context(mf_id: String, context: Dictionary) -> void:
	if not _estimations.has(mf_id):
		return
	var est = _estimations[mf_id]
	for key in context:
		est[key] = context[key]
	est["accuracy"] = _compute_accuracy(est)

## --- Get all estimations ---
func get_all_estimations() -> Array:
	var result = []
	for mf_id in _estimations:
		result.append(get_estimation(mf_id))
	return result

## --- Fixed seed reproducibility ---
func set_seed_for_estimations(seed: int) -> void:
	if _rng:
		_rng.set_seed(seed)
		# Re-run initial estimation with fixed seed
		for mf_id in MALE_FRIEND_IDS:
			var npc = _nm.get_npc(mf_id) if _nm else {}
			var true_affection = npc.get("affection", 0)
			_estimations[mf_id] = {
				"estimated_affection": true_affection,
				"true_affection": true_affection,
				"confidence": 0.3,
				"accuracy": BASE_ACCURACY,
				"last_updated_day": 1,
				"observation_count": 0,
				"error_history": [],
				"has_girlfriend": false,
				"is_accompanying": false,
				"observer_fatigue": 0,
				"observer_injury": 0,
				"memory_modified": false,
				"observation_quality": 0.5,
			}

## --- Save/Load ---
func serialize() -> Dictionary:
	return {"estimations": _estimations.duplicate(true)}

func deserialize(data: Dictionary) -> void:
	if data.has("estimations"):
		_estimations = data["estimations"].duplicate(true)
