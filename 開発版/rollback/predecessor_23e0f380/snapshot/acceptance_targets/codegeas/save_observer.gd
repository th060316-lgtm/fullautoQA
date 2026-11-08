extends "res://save/SaveManager.gd"
# Observe the real method return without changing the underlying load behavior.
func load_game(slot: String = SLOT_NAME) -> bool:
	var success: bool = super.load_game(slot)
	var observer = get_node_or_null("/root/FullAutoQAObserver")
	if observer != null:
		observer.record_load_result(success)
	return success
