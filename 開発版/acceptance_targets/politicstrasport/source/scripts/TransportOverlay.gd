extends Control

## MiniMax: 船舶 / 航空 / 港湾 / 空港 のオーバーレイ描画
##
## Grok 管轄の MapView.gd (地上交通の描画) には一切手を入れず、
## 別ノードとして上に重ねて描画する。
## そのため、地上交通の見え方は従来と完全に一致する。

var game: Node = null

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	if game != null and game.has_signal("world_changed"):
		game.world_changed.connect(queue_redraw)

func _draw() -> void:
	if game == null or game.world == null:
		return
	var w: WorldState = game.world

	# 1) 船舶航路 (海上経路)
	for r in w.routes:
		if not r.active or r.type != Route.RouteType.SHIP:
			continue
		var a = w.get_settlement(r.from_id)
		var b = w.get_settlement(r.to_id)
		if a == null or b == null:
			continue
		var col := Color(0.35, 0.78, 0.95, 0.9)
		if r.obsolete:
			col = Color(0.45, 0.45, 0.45, 0.8)
		elif r.company_id != WorldState.PLAYER_COMPANY_ID:
			var comp = w.get_company(r.company_id)
			if comp != null:
				col = comp.color
				col.a = 0.9
		if r.path_points.size() >= 2:
			draw_polyline(r.path_points, col, 3.0)
		else:
			draw_line(a.position, b.position, col, 3.0)
		_draw_mode_tag((a.position + b.position) * 0.5, "船", col)

	# 2) 航空路 (直行・破線)
	for r in w.routes:
		if not r.active or r.type != Route.RouteType.AIR:
			continue
		var a = w.get_settlement(r.from_id)
		var b = w.get_settlement(r.to_id)
		if a == null or b == null:
			continue
		var col: Color = Color(1.0, 0.95, 0.55, 0.95)
		if r.obsolete:
			col = Color(0.45, 0.45, 0.45, 0.8)
		elif r.company_id != WorldState.PLAYER_COMPANY_ID:
			var comp = w.get_company(r.company_id)
			if comp != null:
				col = comp.color
				col.a = 0.95
		_draw_dashed_line(a.position, b.position, col, 2.0)
		_draw_mode_tag((a.position + b.position) * 0.5, "空", col)

	# 3) 港湾 / 空港マーカー
	for s in w.settlements:
		if not s.active:
			continue
		if s.has_port:
			var p: Vector2 = s.position + Vector2(0, -34)
			draw_rect(Rect2(p - Vector2(6, 6), Vector2(12, 12)), Color(0.25, 0.6, 0.95), true)
			draw_rect(Rect2(p - Vector2(6, 6), Vector2(12, 12)), Color.WHITE, false, 1.5)
		if s.has_airport:
			var q: Vector2 = s.position + Vector2(20, -22)
			draw_colored_polygon(PackedVector2Array([
				q + Vector2(0, -8), q + Vector2(7, 6), q + Vector2(-7, 6),
			]), Color(0.95, 0.85, 0.35))
			draw_polyline(PackedVector2Array([
				q + Vector2(0, -8), q + Vector2(7, 6), q + Vector2(-7, 6), q + Vector2(0, -8),
			]), Color.WHITE, 1.5)

	# 4) 戦後不要connection の取り消し印
	for r in w.routes:
		if not r.active or not r.obsolete:
			continue
		var a = w.get_settlement(r.from_id)
		var b = w.get_settlement(r.to_id)
		var mid: Vector2
		if a != null and b != null:
			mid = (a.position + b.position) * 0.5
		elif r.path_points.size() >= 2:
			mid = (r.path_points[0] + r.path_points[r.path_points.size() - 1]) * 0.5
		else:
			continue
		draw_line(mid + Vector2(-7, -7), mid + Vector2(7, 7), Color(1.0, 0.35, 0.3), 2.5)
		draw_line(mid + Vector2(7, -7), mid + Vector2(-7, 7), Color(1.0, 0.35, 0.3), 2.5)

func _draw_dashed_line(from: Vector2, to: Vector2, col: Color, width: float) -> void:
	var total := from.distance_to(to)
	if total <= 0.001:
		return
	var dir := (to - from) / total
	var dash := 14.0
	var gap := 9.0
	var pos := 0.0
	while pos < total:
		var seg: float = min(dash, total - pos)
		draw_line(from + dir * pos, from + dir * (pos + seg), col, width)
		pos += dash + gap

func _draw_mode_tag(pos: Vector2, text: String, col: Color) -> void:
	draw_string(ThemeDB.fallback_font, pos + Vector2(-8, 4), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, col)
