extends Camera2D
## Expedition専用の低リスクCamera adapter。MainのCameraManagerは変更しない。

const MAP_RECT := Rect2(0, 0, 1280, 800)

var controller
var target_position := Vector2.ZERO

func _ready() -> void:
	controller = get_parent()
	enabled = true
	position_smoothing_enabled = true
	position_smoothing_speed = 6.0
	limit_left = int(MAP_RECT.position.x)
	limit_top = int(MAP_RECT.position.y)
	limit_right = int(MAP_RECT.end.x)
	limit_bottom = int(MAP_RECT.end.y)
	limit_smoothed = true
	if controller != null and controller.get("state") != null:
		target_position = _selected_position()
		position = target_position

func _process(delta: float) -> void:
	if controller == null or controller.get("state") == null:
		return
	target_position = _selected_position()
	var desired := target_position + Vector2(115.0, 0.0)
	position = position.lerp(desired, clampf(delta * 6.0, 0.0, 1.0))
	var actor = _selected_actor()
	var desired_zoom := Vector2(0.84, 0.84) if actor != null and actor.kind == "kmf" else Vector2.ONE
	if controller.auto_pause.paused:
		desired_zoom = Vector2(0.82, 0.82)
	zoom = zoom.lerp(desired_zoom, clampf(delta * 4.0, 0.0, 1.0))

func _selected_actor():
	var actor = controller.state.actors.get(controller.state.selected_id)
	if actor != null and actor.kind == "human":
		var kmf_id := str(actor.meta.get("inside_kmf", ""))
		if not kmf_id.is_empty():
			return controller.state.actors.get(kmf_id)
	return actor

func _selected_position() -> Vector2:
	var actor = _selected_actor()
	return Vector2(640, 400) if actor == null else actor.position

func is_selected_visible() -> bool:
	var viewport_size := get_viewport_rect().size / zoom
	var safe_rect := Rect2(position - viewport_size * 0.5 + Vector2(40, 60), viewport_size - Vector2(360, 150))
	return safe_rect.has_point(_selected_position())
