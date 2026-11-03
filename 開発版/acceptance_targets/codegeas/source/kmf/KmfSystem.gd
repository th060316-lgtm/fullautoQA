extends "res://kmf/KmfSystemLegacy.gd"
## Canonical parked-KMF helpers accepted from the MiniMax return.

const BOARD_RANGE: float = 48.0

func _ready() -> void:
	super._ready()
	add_to_group("kmf_system")

func get_kmf_position() -> Vector2:
	var kmf: Dictionary = GameState.get_section("kmf")
	var pos: Dictionary = kmf.get("position", {})
	return Vector2(float(pos.get("x", 0.0)), float(pos.get("y", 0.0)))

func is_boarded() -> bool:
	return bool(GameState.get_section("kmf").get("boarded", false))

func can_board(player_position: Vector2) -> bool:
	var kmf: Dictionary = GameState.get_section("kmf")
	return bool(kmf.get("owned", false)) and not bool(kmf.get("boarded", false)) and float(kmf.get("durability", 0.0)) > 0.0 and player_position.distance_to(get_kmf_position()) <= BOARD_RANGE

func get_board_range() -> float:
	return BOARD_RANGE

func set_parked_position(pos: Vector2) -> bool:
	var kmf: Dictionary = GameState.get_section("kmf")
	if bool(kmf.get("boarded", false)):
		return false
	kmf["position"] = {"x": pos.x, "y": pos.y}
	GameState.set_section("kmf", kmf)
	return true
