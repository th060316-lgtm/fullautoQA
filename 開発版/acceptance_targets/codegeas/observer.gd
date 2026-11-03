extends Node
# Read-only QA instrumentation. No input synthesis or game-state writes.
var elapsed: float = 0.0
var origin: Vector2
var origin_set: bool = false

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed < 0.1:
		return
	elapsed = 0.0
	var state_node = get_node_or_null("/root/GameState")
	var scene = get_tree().current_scene
	if state_node == null or scene == null or not state_node.has_method("get_snapshot"):
		return
	var snapshot: Dictionary = state_node.get_snapshot()
	var player: Dictionary = snapshot.get("player", {})
	var pos: Dictionary = player.get("position", {})
	var position_now := Vector2(float(pos.get("x", 0.0)), float(pos.get("y", 0.0)))
	if not origin_set:
		origin = position_now
		origin_set = true
	var observation: Dictionary = {
		"scene": str(scene.name), "position": pos,
		"distance_from_start": position_now.distance_to(origin),
		"hp": player.get("hp"), "mode": player.get("mode"),
		"game": snapshot,
		"provenance": "read_only_game_state_observer"
	}
	var file = FileAccess.open("res://qa_observation.json.tmp", FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(observation))
	file.close()
	DirAccess.rename_absolute("res://qa_observation.json.tmp", "res://qa_observation.json")
