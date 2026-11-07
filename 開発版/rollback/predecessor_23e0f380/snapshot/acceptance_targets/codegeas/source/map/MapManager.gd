extends "res://map/MapManagerLegacy.gd"
## Semantic location changes no longer consume game time.
## Time is charged only by explicit Day1 actions/travel actions.

func _update_semantic_location(pos: Vector2) -> void:
	var new_location: String = _location_from_position(pos)
	var old_location: String = GameState.get_player_location() if GameState.has_method("get_player_location") else str(GameState.get_section("player").get("locationId", "base"))
	if new_location == old_location:
		return
	GameState.set_player_location(new_location)
