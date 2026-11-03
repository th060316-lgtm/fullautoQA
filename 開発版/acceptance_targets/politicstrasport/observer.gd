extends Node
# Read-only observation of the source game's existing QA adapter.
var elapsed: float = 0.0
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
	state["road_tiles"] = state.get("grid", {}).get("road_tiles", 0)
	state["rail_tiles"] = state.get("grid", {}).get("rail_tiles", 0)
	state["provenance"] = "read_only_existing_qa_adapter"
	var file = FileAccess.open("res://qa_observation.json.tmp", FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(state))
	file.close()
	DirAccess.rename_absolute("res://qa_observation.json.tmp", "res://qa_observation.json")
