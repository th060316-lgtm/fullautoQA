extends "res://player/PlayerControllerLegacy.gd"
## KMF lifecycle integration from the accepted MiniMax return.
## Work's camera bounds and player-facing notices remain inherited.

const BOARD_RANGE: float = 48.0

func _sync_from_state() -> void:
	super._sync_from_state()
	_on_mode_changed(GameState.get_player_mode())

func _try_board_or_disembark() -> void:
	if GameState.get_player_mode() == "kmf":
		_disembark_kmf()
	else:
		_try_board_kmf()

func _try_board_kmf() -> void:
	var kmf: Dictionary = GameState.get_section("kmf")
	if not bool(kmf.get("owned", false)) or float(kmf.get("durability", 0.0)) <= 0.0:
		_notice("このKMFには搭乗できません")
		return
	var kmf_pos: Vector2 = get_kmf_world_position()
	if global_position.distance_to(kmf_pos) > BOARD_RANGE:
		_notice("KMFへ近づいてEで搭乗")
		return
	GameState.set_player_mode("kmf")
	if GameState.get_player_mode() != "kmf":
		_notice("KMFへの搭乗に失敗しました")
		return
	global_position = GameState.get_player_position()
	_update_visual()
	_record_day1_action("kmf_board", {"mode": "kmf", "noise": 4.0, "visible": true})
	_notice("KMFに搭乗しました")

func _disembark_kmf() -> void:
	# Canonicalize the machine position before switching back to foot mode.
	GameState.set_player_position(global_position)
	GameState.set_player_mode("foot")
	if GameState.get_player_mode() != "foot":
		_notice("KMFから降りられませんでした")
		return
	_update_visual()
	_notice("KMFから降りました")

func get_kmf_world_position() -> Vector2:
	var kmf: Dictionary = GameState.get_section("kmf")
	var pos: Dictionary = kmf.get("position", {})
	return Vector2(float(pos.get("x", 0.0)), float(pos.get("y", 0.0)))

func can_board_kmf() -> bool:
	if GameState.get_player_mode() != "foot":
		return false
	var kmf: Dictionary = GameState.get_section("kmf")
	if not bool(kmf.get("owned", false)) or bool(kmf.get("boarded", false)) or float(kmf.get("durability", 0.0)) <= 0.0:
		return false
	return global_position.distance_to(get_kmf_world_position()) <= BOARD_RANGE

func get_board_range() -> float:
	return BOARD_RANGE

func _notice(message: String) -> void:
	if EventBus.has_signal("player_notice"):
		EventBus.player_notice.emit(message)
	else:
		EventBus.debug_message.emit(message)
