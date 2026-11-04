extends Node
# Read-only observation of the source game's existing QA adapter.
var elapsed: float = 0.0
var previous_paused: Variant = null
var pause_transitions: int = 0
func _process(delta: float) -> void:
	elapsed += delta
	if elapsed < 0.1:
		return
	elapsed = 0.0
	var scene = get_tree().current_scene
	if scene == null:
		return
	var adapter = scene.get_node_or_null("QaAdapter")
	if adapter == null or not adapter.has_method("qa_get_state"):
		return
	var state: Dictionary = adapter.qa_get_state()
	var paused_now: bool = bool(state.get("paused", false))
	if previous_paused != null and bool(previous_paused) != paused_now:
		pause_transitions += 1
	previous_paused = paused_now
	state["observed_pause_transitions"] = pause_transitions
	if DisplayServer.get_name() != "headless":
		var transform: Transform2D = get_viewport().get_screen_transform()
		var client: Vector2i = DisplayServer.window_get_size(get_window().get_window_id())
		state["input_mapping"] = {"xx": transform.x.x, "xy": transform.y.x, "yx": transform.x.y, "yy": transform.y.y, "origin_x": transform.origin.x, "origin_y": transform.origin.y, "client_width": client.x, "client_height": client.y, "source": "observed_viewport_to_window_client_transform"}
	state["road_tiles"] = state.get("grid", {}).get("road_tiles", 0)
	state["rail_tiles"] = state.get("grid", {}).get("rail_tiles", 0)
	state["provenance"] = "read_only_existing_qa_adapter"
	var file = FileAccess.open("res://qa_observation.json.tmp", FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(state))
	file.close()
	DirAccess.rename_absolute("res://qa_observation.json.tmp", "res://qa_observation.json")
