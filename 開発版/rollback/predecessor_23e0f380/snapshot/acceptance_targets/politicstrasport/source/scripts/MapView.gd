extends Control

@onready var game: Node = get_node("/root/Main/GameController")

var node_radius := 22.0
var jp_font: Font = null
var mouse_down: bool = false

func _ready() -> void:
	_setup_jp_font()
	if game:
		game.world_changed.connect(_on_world_changed)
		game.selection_changed.connect(queue_redraw)
	queue_redraw()

func _setup_jp_font() -> void:
	# Prefer system fonts that commonly include Japanese glyphs.
	# No external download, no paid font, Godot SystemFont only.
	var sf = SystemFont.new()
	sf.font_names = PackedStringArray([
		"Noto Sans CJK JP",
		"Noto Sans CJK",
		"Source Han Sans",
		"Yu Gothic",
		"YuGothic",
		"Hiragino Sans",
		"Hiragino Kaku Gothic ProN",
		"Meiryo",
		"MS Gothic",
		"IPAGothic",
		"TakaoPGothic",
		"sans-serif"
	])
	sf.font_weight = 400
	jp_font = sf

func _font() -> Font:
	if jp_font:
		return jp_font
	return ThemeDB.fallback_font

func _on_world_changed() -> void:
	queue_redraw()

func _draw() -> void:
	if not game or not game.world:
		return
	var w: WorldState = game.world
	var f = _font()

	# Draw nation ownership tint (subtle)
	if w.ground:
		for t in w.ground.tiles.values():
			if t.owner_nation_id < 0:
				continue
			var nation = w.get_nation(t.owner_nation_id)
			if nation == null:
				continue
			var col = nation.color
			col.a = 0.08
			var rect = Rect2(
				w.ground.GRID_ORIGIN + Vector2(t.coord.x * w.ground.TILE_SIZE, t.coord.y * w.ground.TILE_SIZE),
				Vector2(w.ground.TILE_SIZE, w.ground.TILE_SIZE)
			)
			draw_rect(rect, col, true)

		# Draw road / rail tiles
		for t in w.ground.tiles.values():
			var origin = w.ground.GRID_ORIGIN + Vector2(t.coord.x * w.ground.TILE_SIZE, t.coord.y * w.ground.TILE_SIZE)
			var center = origin + Vector2(w.ground.TILE_SIZE * 0.5, w.ground.TILE_SIZE * 0.5)
			if t.has_road:
				# Brownish road rectangle / cross
				var road_col = Color(0.55, 0.38, 0.18, 0.85)
				draw_rect(Rect2(origin + Vector2(4, 14), Vector2(w.ground.TILE_SIZE - 8, 12)), road_col, true)
				draw_rect(Rect2(origin + Vector2(14, 4), Vector2(12, w.ground.TILE_SIZE - 8)), road_col, true)
			if t.has_rail:
				# Darker blue-gray rail thicker
				var rail_col = Color(0.15, 0.2, 0.45, 0.95)
				draw_rect(Rect2(origin + Vector2(6, 16), Vector2(w.ground.TILE_SIZE - 12, 8)), rail_col, true)
				draw_rect(Rect2(origin + Vector2(16, 6), Vector2(8, w.ground.TILE_SIZE - 12)), rail_col, true)
				# Sleepers hint
				draw_line(center + Vector2(-12, -6), center + Vector2(12, -6), Color(0.4, 0.35, 0.25), 1.5)
				draw_line(center + Vector2(-12, 6), center + Vector2(12, 6), Color(0.4, 0.35, 0.25), 1.5)

		# Grid lines (very faint)
		var gcol = Color(0.3, 0.3, 0.35, 0.15)
		for x in range(w.ground.COLS + 1):
			var px = w.ground.GRID_ORIGIN.x + x * w.ground.TILE_SIZE
			draw_line(Vector2(px, w.ground.GRID_ORIGIN.y), Vector2(px, w.ground.GRID_ORIGIN.y + w.ground.ROWS * w.ground.TILE_SIZE), gcol, 1.0)
		for y in range(w.ground.ROWS + 1):
			var py = w.ground.GRID_ORIGIN.y + y * w.ground.TILE_SIZE
			draw_line(Vector2(w.ground.GRID_ORIGIN.x, py), Vector2(w.ground.GRID_ORIGIN.x + w.ground.COLS * w.ground.TILE_SIZE, py), gcol, 1.0)

		# Hover / preview
		if game.build_mode in [0, 1, 4] and game.hover_tile.x >= 0:
			var ht = game.hover_tile
			var horigin = w.ground.GRID_ORIGIN + Vector2(ht.x * w.ground.TILE_SIZE, ht.y * w.ground.TILE_SIZE)
			var pcol = Color(0.9, 0.3, 0.2, 0.35) if game.build_mode == 4 else Color(0.3, 0.9, 0.3, 0.35)
			draw_rect(Rect2(horigin, Vector2(w.ground.TILE_SIZE, w.ground.TILE_SIZE)), pcol, true)
			var cost = 0.0
			if game.build_mode == 0:
				cost = GroundNetwork.ROAD_COST_PER_TILE
			elif game.build_mode == 1:
				cost = GroundNetwork.RAIL_COST_PER_TILE
			if cost > 0:
				draw_string(f, horigin + Vector2(2, -4), "%.0f" % cost, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 0.6))

	# Draw logical routes (thinner overlay connecting terminals when active)
	for r in w.routes:
		if not r.active or (r.type != Route.RouteType.ROAD and r.type != Route.RouteType.RAIL):
			continue
		var from_s = w.get_settlement(r.from_id)
		var to_s = w.get_settlement(r.to_id)
		var p_from: Vector2
		var p_to: Vector2
		if from_s != null and to_s != null:
			p_from = from_s.position
			p_to = to_s.position
		elif r.path_points.size() >= 2:
			p_from = r.path_points[0]
			p_to = r.path_points[r.path_points.size() - 1]
		else:
			continue
		var endpoints_active = from_s != null and to_s != null and from_s.active and to_s.active
		var col = Color(0.55, 0.4, 0.2, 0.55) if r.type == Route.RouteType.ROAD else Color(0.2, 0.25, 0.55, 0.65)
		if not endpoints_active or r.obsolete:
			col = Color(0.55, 0.3, 0.3, 0.65)
		var width = 2.0 if r.type == Route.RouteType.ROAD else 3.5
		if r.id == game.selected_route_id:
			col = Color(1.0, 0.85, 0.2, 0.9)
			width += 2.0
		draw_line(p_from, p_to, col, width)
		if r.last_revenue > 0.1:
			var mid = (p_from + p_to) * 0.5
			draw_string(f, mid + Vector2(0, -8), "%.1f" % r.last_revenue, HORIZONTAL_ALIGNMENT_CENTER, -1, 12, Color(0.9, 0.9, 0.5))

	# Draw settlements (terminals)
	for s in w.settlements:
		if not s.active:
			continue
		var col: Color
		if s.is_supply_base:
			col = Color(0.9, 0.7, 0.2)
		else:
			var nation = w.get_nation(s.nation_id)
			col = nation.color if nation else Color.GRAY
		if s.id == game.selected_settlement_id:
			draw_circle(s.position, node_radius + 6, Color(1, 1, 0.4, 0.5))
		draw_circle(s.position, node_radius, col)
		draw_arc(s.position, node_radius, 0, TAU, 32, Color(0.1, 0.1, 0.1), 2.0)
		# Terminal marker (small square)
		draw_rect(Rect2(s.position - Vector2(6, 6), Vector2(12, 12)), Color(1, 1, 1, 0.7), false, 2.0)
		var label = s.name
		if s.is_supply_base:
			label = "補給基地"
		draw_string(f, s.position + Vector2(-30, node_radius + 14), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color.WHITE)
		draw_string(f, s.position + Vector2(-18, 4), "%.0f" % s.population, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.95, 0.95, 0.95))
		var status_tags: Array[String] = []
		if s.development_support > 0.1:
			status_tags.append("支援")
		if s.promotion_support > 0.1:
			status_tags.append("宣伝")
		if s.investment_support > 0.1:
			status_tags.append("投資")
		if s.port_blockaded:
			status_tags.append("封鎖")
		if s.occupied_by_nation_id >= 0:
			status_tags.append("占領")
		if s.war_damage > 0.05:
			status_tags.append("戦災")
		elif s.reconstruction_demand > 0.1:
			status_tags.append("復興")
		var facility_count := 0
		var building_count := 0
		for facility in w.industry_facilities:
			if int(facility.get("settlement_id", -1)) != s.id:
				continue
			facility_count += 1
			if str(facility.get("status", "")) == "building":
				building_count += 1
		if facility_count > 0:
			status_tags.append("産業%d%s" % [facility_count, ("(建設%d)" % building_count) if building_count > 0 else ""])
		if not status_tags.is_empty():
			draw_string(f, s.position + Vector2(-42, node_radius + 30), " ".join(status_tags),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1.0, 0.92, 0.45))

func _gui_input(event: InputEvent) -> void:
	if not game or not game.world or not game.world.ground:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				mouse_down = true
				_handle_click_or_drag(event.position)
			else:
				mouse_down = false
				game.last_built_tile = Vector2i(-999, -999)
	elif event is InputEventMouseMotion:
		var tile = game.world.ground.world_to_tile(event.position)
		if tile != game.hover_tile:
			game.hover_tile = tile
			queue_redraw()
		if mouse_down and game.build_mode in [0, 1, 4]:
			_handle_click_or_drag(event.position)

func _handle_click_or_drag(pos: Vector2) -> void:
	if not game or not game.world:
		return
	# Build mode: tile first
	if game.build_mode in [0, 1, 4]:
		var tile = game.world.ground.world_to_tile(pos)
		game.try_build_at_tile(tile)
		return
	# Selection: settlements then routes
	for s in game.world.settlements:
		if not s.active:
			continue
		if pos.distance_to(s.position) <= node_radius + 4:
			game.select_settlement(s.id)
			return
	for r in game.world.routes:
		if not r.active:
			continue
		var from_s = game.world.get_settlement(r.from_id)
		var to_s = game.world.get_settlement(r.to_id)
		var p_from: Vector2
		var p_to: Vector2
		if from_s != null and to_s != null:
			p_from = from_s.position
			p_to = to_s.position
		elif r.path_points.size() >= 2:
			p_from = r.path_points[0]
			p_to = r.path_points[r.path_points.size() - 1]
		else:
			continue
		if _dist_to_segment(pos, p_from, p_to) < 8.0:
			game.select_route(r.id)
			return
	# Deselect
	game.selected_settlement_id = -1
	game.selected_route_id = -1
	game.emit_signal("selection_changed")

func _dist_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab = b - a
	var len_sq = ab.length_squared()
	if len_sq < 0.0001:
		return p.distance_to(a)
	var t = clamp(((p - a).dot(ab)) / len_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)
