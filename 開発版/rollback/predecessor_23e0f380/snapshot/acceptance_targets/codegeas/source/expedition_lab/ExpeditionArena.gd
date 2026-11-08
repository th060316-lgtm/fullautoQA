extends Node2D
## State-driven presentation. Sprites are views only; ExpeditionState remains authoritative.

const Fixture = preload("res://expedition_lab/ExpeditionFixture.gd")
const FRIENDLY_HUMAN := preload("res://expedition_lab/assets/actors/friendly_human.svg")
const HOSTILE_HUMAN := preload("res://expedition_lab/assets/actors/hostile_human.svg")
const FRIENDLY_KMF := preload("res://expedition_lab/assets/kmf/friendly_kmf.svg")
const HOSTILE_KMF := preload("res://expedition_lab/assets/kmf/hostile_kmf.svg")
const LOOT_ICON := preload("res://expedition_lab/assets/ui/loot.svg")
const INTEL_ICON := preload("res://expedition_lab/assets/ui/intel.svg")
const RESCUE_ICON := preload("res://expedition_lab/assets/ui/medical_rescue.svg")
const EXTRACTION_ICON := preload("res://expedition_lab/assets/ui/extraction.svg")
const ESTIMATED_ICON := preload("res://expedition_lab/assets/ui/estimated.svg")
const SIGNAL_ICON := preload("res://expedition_lab/assets/ui/sensor.svg")
const LOST_ICON := preload("res://expedition_lab/assets/ui/unknown.svg")
const HOSPITAL_ART := preload("res://expedition_lab/assets/environment/hospital.svg")
const RUBBLE_ART := preload("res://expedition_lab/assets/environment/rubble.svg")

const FRIENDLY := Color("52e2d2")
const ENEMY := Color("ff5f64")
const ESTIMATED := Color("efa64c")
const ROUTE_CORE := Color("72e7ff")
const ROUTE_EDGE := Color(0.02, 0.09, 0.12, 0.94)
const HOVER := Color("f6d25d")
const GROUND := Color("263238")
const ROAD := Color("2f3d43")
const SIDEWALK := Color("4b575c")
const CURB := Color("69777c")

var layers: Dictionary = {}
var actor_views: Dictionary = {}
var object_views: Dictionary = {}
var contact_views: Dictionary = {}
var hovered_key := ""

func _ready() -> void:
	for layer_name in ["terrain", "buildings", "interactables", "actors", "contacts", "fx"]:
		var layer := Node2D.new()
		layer.name = str(layer_name).capitalize()
		layer.z_index = layers.size()
		add_child(layer)
		layers[layer_name] = layer
	_add_static_sprite("hospital", HOSPITAL_ART, Vector2(665, 137), "buildings")
	_add_static_sprite("rubble", RUBBLE_ART, Vector2(595, 367), "terrain")
	_add_static_sprite("extract_primary", EXTRACTION_ICON, Fixture.EXTRACTION_PRIMARY, "interactables", Vector2(1.35, 1.35))
	_add_static_sprite("extract_backup", EXTRACTION_ICON, Fixture.EXTRACTION_BACKUP, "interactables", Vector2(1.35, 1.35))

func _process(_delta: float) -> void:
	_sync_state_views()
	hovered_key = _find_hovered_key(get_global_mouse_position())
	queue_redraw()

func _draw() -> void:
	var controller = get_parent()
	if controller == null or controller.get("state") == null:
		return
	var state = controller.state
	_draw_environment_base()
	_draw_area_knowledge(controller)
	_draw_intent_preview(controller)
	_draw_confirmed_contact_warning(state)
	_draw_active_route(state)
	_draw_contact_uncertainty(state)
	_draw_selection(state)
	_draw_feedback(controller)

func _draw_environment_base() -> void:
	# Camera pause overview zooms beyond the authored map, so keep a generous dark overscan.
	draw_rect(Rect2(-360, -280, 2000, 1400), Color("0c171c"), true)
	draw_rect(Fixture.MAP_RECT, GROUND, true)

	# Readable urban road network. These are presentation-only and do not alter navigation.
	var main_road := Rect2(0, 252, 1280, 168)
	var east_road := Rect2(804, 0, 174, 800)
	var south_road := Rect2(0, 520, 760, 132)
	for road in [main_road, east_road, south_road]:
		draw_rect(road, ROAD, true)
		draw_rect(road, CURB, false, 3.0)

	# Sidewalk / hospital apron.
	draw_rect(Rect2(470, 18, 388, 214), SIDEWALK, true)
	draw_rect(Rect2(470, 18, 388, 214), Color("7c8a8f"), false, 2.0)
	draw_rect(Rect2(0, 226, 1280, 24), Color("3b494e"), true)
	draw_rect(Rect2(0, 422, 1280, 20), Color("3b494e"), true)

	# Lane markings stay subdued so tactical overlays remain dominant.
	for x in range(36, 1260, 86):
		draw_rect(Rect2(x, 332, 46, 3), Color(0.67, 0.71, 0.66, 0.38), true)
	for y in range(32, 790, 78):
		draw_rect(Rect2(888, y, 3, 40), Color(0.67, 0.71, 0.66, 0.34), true)
	for x in range(28, 740, 82):
		draw_rect(Rect2(x, 584, 42, 3), Color(0.67, 0.71, 0.66, 0.28), true)

	# Cracks and repair seams give the district texture without requiring baked raster art.
	var cracks := [
		[Vector2(90, 290), Vector2(126, 311), Vector2(115, 338)],
		[Vector2(260, 385), Vector2(298, 364), Vector2(331, 386)],
		[Vector2(1015, 280), Vector2(1048, 311), Vector2(1029, 353)],
		[Vector2(845, 604), Vector2(883, 578), Vector2(916, 598)],
		[Vector2(126, 566), Vector2(162, 548), Vector2(194, 570)],
		[Vector2(744, 448), Vector2(776, 469), Vector2(764, 498)],
	]
	for crack in cracks:
		draw_polyline(PackedVector2Array(crack), Color(0.04, 0.07, 0.08, 0.55), 2.0, true)

	# Existing cover/blocked areas are emphasized visually but geometry is untouched.
	for rect in Fixture.build().get("cover", []):
		draw_rect(rect, Color(0.18, 0.23, 0.25, 0.82), true)
		draw_rect(rect, Color(0.47, 0.53, 0.55, 0.72), false, 2.0)
		for stripe_x in range(int(rect.position.x) + 8, int(rect.end.x) - 8, 26):
			draw_line(Vector2(stripe_x, rect.position.y + 6), Vector2(stripe_x + 18, rect.position.y + 20), Color(0.66, 0.55, 0.28, 0.26), 2.0)

	# Soft vignette-style edge blocks protect HUD contrast during camera movement.
	draw_rect(Rect2(0, 0, 1280, 20), Color(0, 0, 0, 0.18), true)
	draw_rect(Rect2(0, 780, 1280, 20), Color(0, 0, 0, 0.22), true)

func _sync_state_views() -> void:
	var controller = get_parent()
	if controller == null or controller.get("state") == null:
		return
	var state = controller.state
	var active_actors: Array[String] = []
	for actor in state.actors.values():
		if actor.team == "enemy":
			continue
		if actor.kind == "human" and not str(actor.meta.get("inside_kmf", "")).is_empty():
			continue
		active_actors.append(actor.id)
		var texture = FRIENDLY_KMF if actor.kind == "kmf" else FRIENDLY_HUMAN
		var sprite := _ensure_view(actor_views, actor.id, texture, layers["actors"])
		sprite.position = actor.position
		sprite.scale = Vector2(0.62, 0.62) if actor.kind == "kmf" else Vector2(0.72, 0.72)
		sprite.modulate = Color("6d7478") if actor.incapacitated or actor.destroyed else Color.WHITE
	_remove_stale(actor_views, active_actors)

	var active_objects: Array[String] = ["extract_primary", "extract_backup"]
	for id in state.loot.keys():
		var row: Dictionary = state.loot[id]
		if bool(row.get("taken", false)):
			continue
		var key := "loot:" + str(id)
		active_objects.append(key)
		var sprite := _ensure_view(object_views, key, LOOT_ICON, layers["interactables"])
		sprite.position = row.get("position", Vector2.ZERO)
	for id in state.intel_sources.keys():
		var row: Dictionary = state.intel_sources[id]
		if bool(row.get("examined", false)):
			continue
		var key := "intel:" + str(id)
		active_objects.append(key)
		var sprite := _ensure_view(object_views, key, INTEL_ICON, layers["interactables"])
		sprite.position = row.get("position", Vector2.ZERO)
	for id in state.rescue_targets.keys():
		var row: Dictionary = state.rescue_targets[id]
		if str(row.get("status", "")) == "extracted":
			continue
		var key := "rescue:" + str(id)
		active_objects.append(key)
		var sprite := _ensure_view(object_views, key, RESCUE_ICON, layers["interactables"])
		sprite.position = row.get("position", Vector2.ZERO)
	_remove_stale(object_views, active_objects)

	var active_contacts: Array[String] = []
	for contact in state.knowledge.visible_contacts():
		var id := str(contact.get("id", ""))
		var status := str(contact.get("status", "unknown"))
		var key := "contact:" + id
		active_contacts.append(key)
		var texture = SIGNAL_ICON
		if status == "estimated":
			texture = ESTIMATED_ICON
		elif status == "lost_contact":
			texture = LOST_ICON
		elif status == "confirmed":
			var enemy = state.actors.get(id)
			texture = HOSTILE_KMF if enemy != null and enemy.kind == "kmf" else HOSTILE_HUMAN
		var sprite := _ensure_view(contact_views, key, texture, layers["contacts"])
		# Only player knowledge determines placement. enemy_truth is deliberately never read.
		sprite.position = contact.get("estimated_position", Vector2.ZERO)
		sprite.scale = Vector2(0.62, 0.62) if status == "confirmed" else Vector2.ONE
		sprite.modulate = Color(1, 1, 1, 0.5) if status == "lost_contact" else Color.WHITE
	_remove_stale(contact_views, active_contacts)

func _add_static_sprite(key: String, texture: Texture2D, at: Vector2, layer_name: String, view_scale: Vector2 = Vector2.ONE) -> void:
	var sprite := _ensure_view(object_views, key, texture, layers[layer_name])
	sprite.position = at
	sprite.scale = view_scale

func _ensure_view(registry: Dictionary, key: String, texture: Texture2D, parent: Node2D) -> Sprite2D:
	if registry.has(key) and is_instance_valid(registry[key]):
		var existing: Sprite2D = registry[key]
		if existing.texture != texture:
			existing.texture = texture
		return existing
	var sprite := Sprite2D.new()
	sprite.name = key.replace(":", "_")
	sprite.texture = texture
	parent.add_child(sprite)
	registry[key] = sprite
	return sprite

func _remove_stale(registry: Dictionary, active: Array[String]) -> void:
	for key in registry.keys():
		if str(key) in active or str(key) in ["hospital", "rubble", "extract_primary", "extract_backup"]:
			continue
		var node = registry[key]
		if is_instance_valid(node):
			node.queue_free()
		registry.erase(key)

func get_route_view() -> Dictionary:
	var state = get_parent().state
	var controlled_id: String = get_parent().get_controlled_actor_id(state.selected_id)
	var actor = state.actors.get(controlled_id)
	if actor == null:
		return {}
	var order: Dictionary = state.orders.peek(controlled_id)
	if str(order.get("kind", "")) != "move":
		return {}
	var meta: Dictionary = order.get("meta", {})
	var path: Array = meta.get("path", [])
	var index := int(meta.get("path_index", 0))
	var points: Array[Vector2] = [actor.position]
	for i in range(index, path.size()):
		points.append(path[i])
	var eta := float(order.get("eta", 0.0))
	var remaining := float(order.get("remaining", 0.0))
	return {
		"points": points,
		"destination": order.get("target", actor.position),
		"eta": eta,
		"remaining": remaining,
		"progress": 1.0 if eta <= 0.0 else clampf(1.0 - remaining / eta, 0.0, 1.0)
	}

func _draw_active_route(_state) -> void:
	var view := get_route_view()
	if view.is_empty():
		return
	var points: Array = view.get("points", [])
	if points.size() >= 2:
		var packed := PackedVector2Array(points)
		draw_polyline(packed, ROUTE_EDGE, 10.0, true)
		draw_polyline(packed, ROUTE_CORE, 4.0, true)
		_draw_route_chevrons(points)
	var destination: Vector2 = view.get("destination", Vector2.ZERO)
	draw_circle(destination, 18, Color(0.45, 0.91, 1.0, 0.1))
	draw_arc(destination, 18, 0, TAU, 32, Color.WHITE, 3.0)
	draw_arc(destination, 13, 0, TAU, 32, ROUTE_CORE, 2.0)
	draw_line(destination - Vector2(8, 0), destination + Vector2(8, 0), ROUTE_CORE, 2.0)
	draw_line(destination - Vector2(0, 8), destination + Vector2(0, 8), ROUTE_CORE, 2.0)

func _draw_route_chevrons(points: Array) -> void:
	for i in range(points.size() - 1):
		var a: Vector2 = points[i]
		var b: Vector2 = points[i + 1]
		var delta := b - a
		var length := delta.length()
		if length < 42.0:
			continue
		var direction := delta / length
		var normal := Vector2(-direction.y, direction.x)
		var distance := 36.0
		while distance < length - 18.0:
			var center := a + direction * distance
			var tip := center + direction * 7.0
			var left := center - direction * 7.0 + normal * 5.0
			var right := center - direction * 7.0 - normal * 5.0
			draw_line(left, tip, Color(0.75, 0.96, 1.0, 0.9), 2.0, true)
			draw_line(right, tip, Color(0.75, 0.96, 1.0, 0.9), 2.0, true)
			distance += 58.0

func _draw_confirmed_contact_warning(state) -> void:
	# The current model has no authoritative enemy facing/range for HUD use.
	# Use a non-directional warning aura around confirmed knowledge only.
	for contact in state.knowledge.visible_contacts():
		if str(contact.get("status", "")) != "confirmed":
			continue
		var p: Vector2 = contact.get("estimated_position", Vector2.ZERO)
		draw_circle(p, 54.0, Color(1.0, 0.23, 0.27, 0.08))
		draw_arc(p, 54.0, 0, TAU, 40, Color(1.0, 0.37, 0.39, 0.34), 2.0)

func _draw_contact_uncertainty(state) -> void:
	for contact in state.knowledge.visible_contacts():
		var status := str(contact.get("status", "unknown"))
		if status not in ["signal", "estimated", "lost_contact"]:
			continue
		var p: Vector2 = contact.get("estimated_position", Vector2.ZERO)
		var radius := float(contact.get("uncertainty_radius", 60.0))
		var alpha := 0.055 if status == "lost_contact" else 0.09
		draw_circle(p, radius, Color(ESTIMATED.r, ESTIMATED.g, ESTIMATED.b, alpha))
		draw_arc(p, radius, 0, TAU, 48, Color(ESTIMATED.r, ESTIMATED.g, ESTIMATED.b, 0.42), 2.0)

func _draw_selection(state) -> void:
	var selected = state.actors.get(get_parent().get_controlled_actor_id(state.selected_id))
	if selected != null:
		var radius := 32.0 if selected.kind == "kmf" else 25.0
		draw_circle(selected.position, radius + 4.0, Color(0.32, 0.89, 0.82, 0.055))
		draw_arc(selected.position, radius + 3.0, 0, TAU, 40, Color.WHITE, 3.0)
		draw_arc(selected.position, radius - 2.0, 0, TAU, 40, FRIENDLY, 2.0)
	if not hovered_key.is_empty():
		draw_arc(_position_for_key(hovered_key), 27, 0, TAU, 32, HOVER, 2.0)

func _draw_feedback(controller) -> void:
	if controller.last_feedback_position == Vector2.ZERO or controller.last_feedback_age > 1.4:
		return
	var alpha: float = 1.0 - float(controller.last_feedback_age) / 1.4
	var radius: float = 18.0 + float(controller.last_feedback_age) * 14.0
	draw_arc(controller.last_feedback_position, radius, 0, TAU, 28, Color(0.45, 0.91, 1.0, alpha), 3.0)
	draw_arc(controller.last_feedback_position, radius + 7.0, 0, TAU, 28, Color(1, 1, 1, alpha * 0.45), 1.0)

func _find_hovered_key(point: Vector2) -> String:
	var best := ""
	var best_distance := 30.0
	for registry in [actor_views, object_views, contact_views]:
		for key in registry.keys():
			if str(key) in ["hospital", "rubble"]:
				continue
			var node = registry[key]
			if not is_instance_valid(node):
				continue
			var distance: float = node.position.distance_to(point)
			if distance < best_distance:
				best_distance = distance
				best = str(key)
	return best

func _position_for_key(key: String) -> Vector2:
	for registry in [actor_views, object_views, contact_views]:
		if registry.has(key) and is_instance_valid(registry[key]):
			return registry[key].position
	return Vector2.ZERO


func _draw_intent_preview(controller) -> void:
	var preview: Dictionary = controller.get_intent_preview()
	if preview.is_empty() or not bool(preview.get("ok", false)):
		return
	var intent := str(preview.get("intent","MOVE"))
	var path: Array = preview.get("path", [])
	if path.size() >= 1:
		var points: Array[Vector2] = []
		var actor = controller.state.actors.get(str(preview.get("actor_id","")))
		if actor != null:
			points.append(actor.position)
		for p in path:
			points.append(p)
		if points.size() >= 2:
			var packed := PackedVector2Array(points)
			draw_polyline(packed, Color(0.02,0.08,0.1,0.95), 12.0, true)
			draw_polyline(packed, Color("f6d25d") if intent in ["SCOUT","CLEAR"] else Color("72e7ff"), 4.0, true)
	var destination: Vector2 = preview.get("destination", Vector2.ZERO)
	draw_circle(destination, 20.0, Color(0.45,0.91,1.0,0.08))
	draw_arc(destination, 20.0, 0, TAU, 32, Color("f6d25d"), 3.0)
	for waypoint in preview.get("waypoints", []):
		var p: Vector2 = waypoint
		draw_circle(p, 7.0, Color("f6d25d"))
		draw_arc(p, 12.0, 0, TAU, 20, Color(1,1,1,0.75), 2.0)
	var area: Rect2 = preview.get("area", Rect2())
	if area.size != Vector2.ZERO:
		var fill := Color(0.32,0.89,0.82,0.055) if intent == "SCOUT" else Color(0.96,0.82,0.36,0.055)
		var edge := Color("52e2d2") if intent == "SCOUT" else Color("f6d25d")
		draw_rect(area, fill, true)
		draw_rect(area, Color(edge.r,edge.g,edge.b,0.65), false, 2.0)
	var facing := float(preview.get("facing",0.0))
	var direction := Vector2.RIGHT.rotated(facing)
	draw_line(destination, destination + direction * 44.0, Color.WHITE, 3.0, true)
	var tip := destination + direction * 44.0
	var normal := Vector2(-direction.y,direction.x)
	draw_line(tip, tip-direction*10.0+normal*6.0, Color.WHITE, 3.0, true)
	draw_line(tip, tip-direction*10.0-normal*6.0, Color.WHITE, 3.0, true)

func _draw_area_knowledge(controller) -> void:
	if controller.area_knowledge == null:
		return
	for row in controller.area_knowledge.clear_areas.values():
		if not row is Dictionary:
			continue
		var rect: Rect2 = row.get("rect", Rect2())
		if rect.size == Vector2.ZERO:
			continue
		var status := str(row.get("status","checking"))
		var progress := float(row.get("progress",0.0))
		var color := Color("4fe0a4") if status == "clear" else (Color("efa64c") if status == "uncertain" else Color("72e7ff"))
		draw_rect(rect, Color(color.r,color.g,color.b,0.035 + progress*0.04), true)
		draw_rect(rect, Color(color.r,color.g,color.b,0.35 + progress*0.35), false, 2.0)
