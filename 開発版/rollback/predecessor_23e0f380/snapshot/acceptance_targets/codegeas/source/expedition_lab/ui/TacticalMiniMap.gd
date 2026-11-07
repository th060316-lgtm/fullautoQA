extends Control
## Tactical minimap. Uses player-visible knowledge only; never reads enemy truth.

const Fixture = preload("res://expedition_lab/ExpeditionFixture.gd")

const FRIENDLY := Color("52e2d2")
const ENEMY := Color("ff5f64")
const ESTIMATED := Color("efa64c")
const INTEL := Color("ffd35a")
const LOOT := Color("b8d957")
const RESCUE := Color("4fe0a4")
const EXTRACTION := Color("84d9ff")

var controller

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(286, 92)
	queue_redraw()

func set_controller(value) -> void:
	controller = value
	queue_redraw()

func refresh() -> void:
	queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.025, 0.055, 0.07, 0.88), true)
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.22, 0.42, 0.49, 0.72), false, 1.0)
	if size.x <= 0.0 or size.y <= 0.0:
		return

	# Abstract road structure for orientation only.
	_draw_map_rect(Rect2(0, 252, 1280, 168), Color(0.16, 0.22, 0.24, 0.9))
	_draw_map_rect(Rect2(804, 0, 174, 800), Color(0.16, 0.22, 0.24, 0.9))
	_draw_map_rect(Rect2(0, 520, 760, 132), Color(0.16, 0.22, 0.24, 0.9))
	_draw_map_rect(Rect2(490, 35, 350, 200), Color(0.25, 0.31, 0.33, 0.9))

	for rect in Fixture.build().get("cover", []):
		_draw_map_rect(rect, Color(0.42, 0.46, 0.44, 0.55))

	_dot(Fixture.EXTRACTION_PRIMARY, EXTRACTION, 3.5)
	_dot(Fixture.EXTRACTION_BACKUP, EXTRACTION, 3.5)

	if controller == null or controller.get("state") == null:
		return
	var state = controller.state

	for id in state.loot.keys():
		var row: Dictionary = state.loot[id]
		if not bool(row.get("taken", false)):
			_dot(row.get("position", Vector2.ZERO), LOOT, 2.6)
	for id in state.intel_sources.keys():
		var row: Dictionary = state.intel_sources[id]
		if not bool(row.get("examined", false)):
			_dot(row.get("position", Vector2.ZERO), INTEL, 2.6)
	for id in state.rescue_targets.keys():
		var row: Dictionary = state.rescue_targets[id]
		if str(row.get("status", "")) != "extracted":
			_dot(row.get("position", Vector2.ZERO), RESCUE, 2.6)

	for actor in state.actors.values():
		if actor.team == "enemy":
			continue
		if actor.kind == "human" and not str(actor.meta.get("inside_kmf", "")).is_empty():
			continue
		_dot(actor.position, FRIENDLY, 3.1 if actor.kind == "kmf" else 2.5)

	for contact in state.knowledge.visible_contacts():
		var status := str(contact.get("status", "unknown"))
		var p: Vector2 = contact.get("estimated_position", Vector2.ZERO)
		var mapped := _map_point(p)
		if status == "confirmed":
			draw_circle(mapped, 3.0, ENEMY)
		elif status == "estimated":
			draw_circle(mapped, 3.2, Color(ESTIMATED.r, ESTIMATED.g, ESTIMATED.b, 0.18))
			draw_arc(mapped, 3.2, 0, TAU, 16, ESTIMATED, 1.4)
		elif status == "lost_contact":
			draw_arc(mapped, 3.2, 0, TAU, 16, Color(ESTIMATED.r, ESTIMATED.g, ESTIMATED.b, 0.4), 1.0)
		else:
			draw_circle(mapped, 2.0, Color(0.45, 0.87, 0.95, 0.76))

	var controlled_id: String = controller.get_controlled_actor_id(state.selected_id)
	var selected = state.actors.get(controlled_id)
	if selected != null:
		var selected_p := _map_point(selected.position)
		draw_arc(selected_p, 5.2, 0, TAU, 20, Color.WHITE, 1.2)

func _map_point(world: Vector2) -> Vector2:
	return Vector2(
		clampf(world.x / Fixture.MAP_RECT.size.x, 0.0, 1.0) * size.x,
		clampf(world.y / Fixture.MAP_RECT.size.y, 0.0, 1.0) * size.y
	)

func _map_rect(world: Rect2) -> Rect2:
	return Rect2(_map_point(world.position), Vector2(world.size.x / Fixture.MAP_RECT.size.x * size.x, world.size.y / Fixture.MAP_RECT.size.y * size.y))

func _draw_map_rect(world: Rect2, color: Color) -> void:
	draw_rect(_map_rect(world), color, true)

func _dot(world: Vector2, color: Color, radius: float) -> void:
	draw_circle(_map_point(world), radius, color)
