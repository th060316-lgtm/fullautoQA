extends Control

var game: Node = null

func setup() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if game != null and game.has_signal("world_changed"):
		game.world_changed.connect(queue_redraw)
	queue_redraw()

func _draw() -> void:
	if game == null or game.world == null:
		return
	for s in game.world.settlements:
		if not s.active or s.is_supply_base:
			continue
		if s.port_blockaded:
			draw_arc(s.position, 30.0, 0.0, TAU, 24, Color(0.9, 0.1, 0.1, 0.9), 4.0)
		if s.occupied_by_nation_id >= 0:
			draw_arc(s.position, 35.0, 0.0, TAU, 24, Color(0.9, 0.45, 0.1, 0.85), 3.0)
		if s.war_damage > 0.05:
			draw_circle(s.position + Vector2(20, -20), 5.0 + s.war_damage * 8.0, Color(0.75, 0.15, 0.1, 0.75))
		if s.reconstruction_demand > 0.1:
			draw_arc(s.position, 27.0, -PI * 0.5, -PI * 0.5 + TAU * s.reconstruction_progress,
				24, Color(0.2, 0.9, 0.8, 0.9), 3.0)
		if s.refugee_pressure > 0.1:
			draw_line(s.position + Vector2(-12, 28), s.position + Vector2(12, 28), Color(0.9, 0.85, 0.3), 4.0)
	for r in game.world.routes:
		if not r.active or r.disruption_reason == "":
			continue
		var a = game.world.get_settlement(r.from_id)
		var b = game.world.get_settlement(r.to_id)
		if a != null and b != null:
			draw_dashed_line(a.position, b.position, Color(1.0, 0.2, 0.2, 0.9), 3.0, 10.0)
