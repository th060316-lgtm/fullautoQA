extends Node2D
## LabArena - Lab の描画層 (Phase 0.5 Block 2)
##
## 描画だけを受け持つ。判定・進行は CombatExplorationLab が行う。
## 開発計画 3.4 の「色だけに依存しない識別」を簡易に守るため、
## 敵種別ごとに形とサイズと輪郭を変える。

const ENEMY_COLORS: Dictionary = {
	"infantry": Color(0.85, 0.25, 0.22),
	"light_armor": Color(0.85, 0.55, 0.15),
	"enemy_kmf": Color(0.62, 0.28, 0.78),
}
const PLAYER_COLOR: Color = Color(0.30, 0.90, 0.45)
const KMF_COLOR: Color = Color(0.20, 0.62, 0.95)
const COVER_COLOR: Color = Color(0.30, 0.27, 0.24)
const EXTRACT_COLOR: Color = Color(0.95, 0.85, 0.25)

var _state: Dictionary = {}
var _events: Array = []
var _feedback: Array = []

func _ready() -> void:
	z_index = 0
	set_process(true)

func _process(delta: float) -> void:
	var alive_feedback: Array = []
	for item in _feedback:
		if not (item is Dictionary):
			continue
		var f: Dictionary = item
		f["life"] = float(f.get("life", 0.0)) - delta
		if float(f["life"]) > 0.0:
			alive_feedback.append(f)
	if alive_feedback.size() != _feedback.size():
		_feedback = alive_feedback
		queue_redraw()

func sync_state(state: Dictionary) -> void:
	_state = state
	queue_redraw()

func push_event(event: Dictionary) -> void:
	_events.append(event)
	if _events.size() > 64:
		_events = _events.slice(_events.size() - 64)
	queue_redraw()

func push_feedback(feedback: Dictionary) -> void:
	var f: Dictionary = feedback.duplicate(true)
	f["life"] = 0.6
	_feedback.append(f)
	if _feedback.size() > 48:
		_feedback = _feedback.slice(_feedback.size() - 48)
	queue_redraw()

func _draw() -> void:
	if _state.is_empty():
		return
	var play_area: Rect2 = _state.get("play_area", Rect2(0, 0, 1280, 960))
	draw_rect(play_area, Color(0.13, 0.15, 0.14), true)

	# --- 遮蔽 ---
	for item in _state.get("cover", []):
		if item is Rect2:
			var rect: Rect2 = item
			draw_rect(rect, COVER_COLOR, true)
			draw_rect(rect, Color(0.45, 0.42, 0.38), false, 2.0)

	# --- 離脱点 ---
	var extraction: Vector2 = _state.get("extraction", Vector2(120, 480))
	var radius: float = float(_state.get("extraction_radius", 40.0))
	draw_arc(extraction, radius, 0.0, TAU, 32, EXTRACT_COLOR, 2.0)
	draw_line(extraction + Vector2(-10, 0), extraction + Vector2(10, 0), EXTRACT_COLOR, 2.0)
	draw_line(extraction + Vector2(0, -10), extraction + Vector2(0, 10), EXTRACT_COLOR, 2.0)

	# --- Prototype D: destination/path/threat visualization ---
	if str(_state.get("mode_id", "")) == "command_pause":
		var command_path: Array = _state.get("command_path", [])
		if command_path.size() >= 2:
			var packed := PackedVector2Array()
			for point in command_path:
				packed.append(point)
			draw_polyline(packed, Color(0.35, 0.78, 1.0, 0.95), 3.0)
		var destination: Vector2 = _state.get("command_destination", Vector2.INF)
		if destination.x != INF and destination.y != INF:
			draw_arc(destination, 14.0, 0.0, TAU, 24, Color(0.35, 0.78, 1.0), 3.0)
			draw_line(destination + Vector2(-7, 0), destination + Vector2(7, 0), Color(0.35, 0.78, 1.0), 2.0)
			draw_line(destination + Vector2(0, -7), destination + Vector2(0, 7), Color(0.35, 0.78, 1.0), 2.0)
		for entry in _state.get("enemies", []):
			if not (entry is Dictionary):
				continue
			var threat_combatant = (entry as Dictionary).get("combatant")
			if threat_combatant == null or not bool(threat_combatant.alive):
				continue
			var threat_def: Dictionary = (entry as Dictionary).get("def", {})
			var threat_radius: float = float(threat_def.get("detection_range", 0.0))
			if threat_radius > 0.0:
				draw_arc(threat_combatant.position, threat_radius, 0.0, TAU, 64, Color(1.0, 0.25, 0.20, 0.28), 1.5)

	# --- Prototype E: explicit decision points ---
	if str(_state.get("mode_id", "")) == "decision_point":
		var node_index: int = 1
		for item in _state.get("decision_nodes", []):
			if not (item is Dictionary):
				continue
			var node: Dictionary = item
			var node_pos: Vector2 = node.get("position", Vector2.ZERO)
			var selected: bool = bool(node.get("selected", false))
			var node_color := Color(1.0, 0.86, 0.28) if selected else Color(0.40, 0.85, 0.95)
			draw_circle(node_pos, 18.0 if selected else 14.0, Color(node_color.r, node_color.g, node_color.b, 0.22))
			draw_arc(node_pos, 18.0 if selected else 14.0, 0.0, TAU, 28, node_color, 3.0 if selected else 2.0)
			draw_string(ThemeDB.fallback_font, node_pos + Vector2(20, 5), "%d:%s" % [node_index, str(node.get("label", ""))])
			node_index += 1

	# --- 自機KMF ---
	if bool(_state.get("kmf_owned", false)):
		var kmf_pos: Vector2 = _state.get("kmf_position", Vector2.ZERO)
		draw_rect(Rect2(kmf_pos - Vector2(18, 18), Vector2(36, 36)), KMF_COLOR, true)
		draw_rect(Rect2(kmf_pos - Vector2(18, 18), Vector2(36, 36)), Color(0.85, 0.95, 1.0), false, 2.0)
		draw_line(kmf_pos + Vector2(0, -18), kmf_pos + Vector2(0, -28), KMF_COLOR, 3.0)

	# --- 敵 ---
	for entry in _state.get("enemies", []):
		if not (entry is Dictionary):
			continue
		var e: Dictionary = entry
		var combatant = e.get("combatant")
		if combatant == null:
			continue
		if not bool(combatant.alive):
			# 撃破済みは残骸 (×印) として残す
			var dead_pos: Vector2 = combatant.position
			draw_line(dead_pos + Vector2(-8, -8), dead_pos + Vector2(8, 8), Color(0.4, 0.4, 0.4), 2.0)
			draw_line(dead_pos + Vector2(8, -8), dead_pos + Vector2(-8, 8), Color(0.4, 0.4, 0.4), 2.0)
			continue
		var enemy_type: String = str(e.get("def", {}).get("type", "infantry"))
		var pos: Vector2 = combatant.position
		var color: Color = ENEMY_COLORS.get(enemy_type, Color(0.8, 0.3, 0.3))
		if enemy_type == "enemy_kmf":
			draw_rect(Rect2(pos - Vector2(22, 22), Vector2(44, 44)), color, true)
			draw_rect(Rect2(pos - Vector2(22, 22), Vector2(44, 44)), Color(0.95, 0.85, 1.0), false, 2.0)
		elif enemy_type == "light_armor":
			draw_rect(Rect2(pos - Vector2(16, 16), Vector2(32, 32)), color, true)
			draw_rect(Rect2(pos - Vector2(16, 16), Vector2(32, 32)), Color(1.0, 0.9, 0.7), false, 2.0)
		else:
			draw_rect(Rect2(pos - Vector2(11, 11), Vector2(22, 22)), color, true)
			draw_rect(Rect2(pos - Vector2(11, 11), Vector2(22, 22)), Color(1.0, 0.85, 0.8), false, 2.0)
		# HP バー (部位伤害は別表示)
		var hp: float = float(combatant.hp)
		var max_hp: float = maxf(1.0, float(combatant.max_hp))
		var ratio: float = clampf(hp / max_hp, 0.0, 1.0)
		draw_rect(Rect2(pos + Vector2(-14, -30), Vector2(28, 4)), Color(0, 0, 0, 0.6), true)
		draw_rect(Rect2(pos + Vector2(-14, -30), Vector2(28.0 * ratio, 4)), Color(0.9, 0.3, 0.3), true)

	# --- 主人公 ---
	var player_pos: Vector2 = _state.get("player_position", Vector2.ZERO)
	var is_kmf: bool = str(_state.get("player_mode", "foot")) == "kmf"
	var size: float = 24.0 if is_kmf else 14.0
	draw_rect(Rect2(player_pos - Vector2(size, size) * 0.5, Vector2(size, size)), PLAYER_COLOR, true)
	draw_rect(Rect2(player_pos - Vector2(size, size) * 0.5, Vector2(size, size)), Color(0.9, 1.0, 0.9), false, 2.0)
	if float(_state.get("dodge_flash", 0.0)) > 0.0:
		draw_arc(player_pos, size, 0.0, TAU, 20, Color(1, 1, 1, 0.8), 2.0)

	# --- 弾 ---
	for p in _state.get("projectiles", []):
		if not (p is Dictionary):
			continue
		var proj: Dictionary = p
		var pos2: Vector2 = proj.get("pos", Vector2.ZERO)
		if bool(proj.get("is_player", false)):
			draw_rect(Rect2(pos2 - Vector2(3, 3), Vector2(6, 6)), Color(1.0, 0.85, 0.3), true)
		else:
			draw_rect(Rect2(pos2 - Vector2(3, 3), Vector2(6, 6)), Color(1.0, 0.4, 0.35), true)

	# --- フィードバック ---
	for item in _feedback:
		if not (item is Dictionary):
			continue
		var f: Dictionary = item
		var life: float = float(f.get("life", 0.0))
		var alpha: float = clampf(life / 0.6, 0.0, 1.0)
		var fpos: Vector2 = f.get("position", Vector2.ZERO)
		var kind: String = str(f.get("kind", ""))
		var color := Color(1, 1, 1, alpha)
		match kind:
			"part_destroyed": color = Color(1.0, 0.75, 0.2, alpha)
			"destroyed": color = Color(1.0, 0.35, 0.3, alpha)
			"incapacitated": color = Color(0.6, 0.9, 1.0, alpha)
			_: color = Color(1, 1, 1, alpha)
		draw_arc(fpos, 10.0 + (1.0 - alpha) * 18.0, 0.0, TAU, 20, color, 2.0)
