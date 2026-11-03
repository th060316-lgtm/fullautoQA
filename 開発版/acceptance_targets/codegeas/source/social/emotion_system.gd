# emotion_system.gd — Emotion processing for NPCs and heroine
# Manages emotion vectors (joy, anger, sadness, fear, surprise, disgust, hope, anxiety)
# and emotion decay over time.

extends Node

## Emotion types
const EMOTION_TYPES = ["joy", "anger", "sadness", "fear", "surprise", "disgust", "hope", "anxiety"]

## Emotion intensity range
const EMOTION_MIN: float = 0.0
const EMOTION_MAX: float = 1.0

## Decay rates per game tick (per 60-minute advance)
const DECAY_RATE: float = 0.05

var _gs: Node
var _eb: Node

func _ready() -> void:
	_gs = get_node_or_null("/root/GameState")
	_eb = get_node_or_null("/root/EventBus")

func initialize() -> void:
	pass

## Get emotion vector for an NPC
func get_emotions(npc_data: Dictionary) -> Dictionary:
	return npc_data.get("emotions", {}).duplicate(true)

## Get the dominant emotion
func get_dominant_emotion(emotions: Dictionary) -> String:
	var best = "neutral"
	var best_val = 0.0
	for etype in EMOTION_TYPES:
		var val = emotions.get(etype, 0.0)
		if val > best_val:
			best_val = val
			best = etype
	return best

## Apply emotion change to an NPC's emotion vector
func apply_emotion_change(npc_data: Dictionary, emotion_type: String, delta: float) -> void:
	if not emotion_type in EMOTION_TYPES:
		return
	var emotions = npc_data.get("emotions", {})
	var old_val = emotions.get(emotion_type, 0.0)
	var new_val = clampf(old_val + delta, EMOTION_MIN, EMOTION_MAX)
	emotions[emotion_type] = new_val
	npc_data["emotions"] = emotions
	npc_data["currentEmotion"] = get_dominant_emotion(emotions)
	if _eb:
		_eb.emotion_changed.emit(npc_data.get("id", ""), emotion_type, new_val)

## Set absolute emotion level
func set_emotion(npc_data: Dictionary, emotion_type: String, value: float) -> void:
	if not emotion_type in EMOTION_TYPES:
		return
	var emotions = npc_data.get("emotions", {})
	emotions[emotion_type] = clampf(value, EMOTION_MIN, EMOTION_MAX)
	npc_data["emotions"] = emotions
	npc_data["currentEmotion"] = get_dominant_emotion(emotions)

## Emotion decay — call each time tick
func decay_emotions(npc_data: Dictionary) -> void:
	var emotions = npc_data.get("emotions", {})
	for etype in EMOTION_TYPES:
		var val = emotions.get(etype, 0.0)
		if val > 0:
			emotions[etype] = maxf(0.0, val - DECAY_RATE)
		elif val < 0:
			emotions[etype] = minf(0.0, val + DECAY_RATE)
	npc_data["emotions"] = emotions
	npc_data["currentEmotion"] = get_dominant_emotion(emotions)

## Apply emotion from event
func apply_event_emotion(npc_data: Dictionary, emotion_type: String, intensity: float) -> void:
	apply_emotion_change(npc_data, emotion_type, intensity)

## Combine multiple emotion effects (e.g., from geass amplification)
func amplify_emotions(npc_data: Dictionary, multiplier: float) -> void:
	var emotions = npc_data.get("emotions", {})
	for etype in EMOTION_TYPES:
		var val = emotions.get(etype, 0.0)
		emotions[etype] = clampf(val * multiplier, EMOTION_MIN, EMOTION_MAX)
	npc_data["emotions"] = emotions
	npc_data["currentEmotion"] = get_dominant_emotion(emotions)

## Convert emotion vector to human-readable text
func emotion_to_text(emotions: Dictionary) -> String:
	var dominant = get_dominant_emotion(emotions)
	var val = emotions.get(dominant, 0.0)
	if val < 0.1:
		return "neutral"
	var labels = {
		"joy": "happy", "anger": "angry", "sadness": "sad",
		"fear": "afraid", "surprise": "surprised", "disgust": "disgusted",
		"hope": "hopeful", "anxiety": "anxious"
	}
	return labels.get(dominant, dominant)

## Check if emotions are in dangerous range (used for heroine-specific events)
func has_dangerous_emotions(emotions: Dictionary) -> bool:
	return emotions.get("anger", 0.0) > 0.7 or emotions.get("fear", 0.0) > 0.8

## Save/Load
func serialize() -> Dictionary:
	return {}

func deserialize(_data: Dictionary) -> void:
	pass
