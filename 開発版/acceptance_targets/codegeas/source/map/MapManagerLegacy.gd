extends Node2D
## MapManager - 簡易タイルマップ + Fog of War
## 建物/障害物による視線遮蔽、探索済み記録

const CELL_SIZE: int = 32
const MAP_W: int = 40
const MAP_H: int = 30
const FOOT_VISION: float = 120.0
const KMF_VISION: float = 220.0

@onready var tile_layer: Node2D = $TileLayer
@onready var obstacle_layer: Node2D = $ObstacleLayer
@onready var fog_layer: Node2D = $FogLayer

var _obstacles: Dictionary = {}  # "x_y" -> true
var _buildings: Array[Rect2i] = []
var _player: Node2D = null
var _fog_cells: Dictionary = {}  # visual fog ColorRect cache
var _npc_layer: Node2D = null
var _npc_markers: Dictionary = {}

const REGION_PRESENTATION: Dictionary = {
	"base": {"short": "BASE", "name": "拠点", "color": Color(0.25, 0.65, 0.35, 0.22)},
	"hospital": {"short": "HOSPITAL", "name": "病院", "color": Color(0.25, 0.65, 0.85, 0.22)},
	"city_center": {"short": "CITY", "name": "市街中心部", "color": Color(0.75, 0.65, 0.25, 0.20)},
	"industrial_area": {"short": "INDUSTRIAL", "name": "工業地区", "color": Color(0.75, 0.35, 0.22, 0.22)},
	"evacuation_center": {"short": "SHELTER", "name": "避難所", "color": Color(0.55, 0.35, 0.75, 0.22)},
	"maintenance": {"short": "MAINT", "name": "整備区画", "color": Color(0.25, 0.55, 0.75, 0.22)},
	"outskirts": {"short": "OUTSKIRTS", "name": "外縁部", "color": Color(0.25, 0.25, 0.25, 0.16)},
}

func _ready() -> void:
	_generate_simple_map()
	_add_region_markers()
	_npc_layer = Node2D.new()
	_npc_layer.name = "NpcLayer"
	_npc_layer.z_index = 6
	add_child(_npc_layer)
	_player = get_tree().get_first_node_in_group("player")
	# Fog更新を定期
	var timer = Timer.new()
	timer.wait_time = 0.1
	timer.timeout.connect(_update_fog)
	timer.autostart = true
	add_child(timer)

func _generate_simple_map() -> void:
	# 地面
	for x in range(MAP_W):
		for y in range(MAP_H):
			var cell = ColorRect.new()
			cell.size = Vector2(CELL_SIZE, CELL_SIZE)
			cell.position = Vector2(x * CELL_SIZE, y * CELL_SIZE)
			# 簡易地形色
			if x < 3 or y < 3 or x > MAP_W - 4 or y > MAP_H - 4:
				cell.color = Color(0.25, 0.35, 0.2)  # 外縁
			else:
				cell.color = Color(0.35, 0.4, 0.3)
			tile_layer.add_child(cell)

	# 建物・障害物配置（視線遮蔽）
	_add_building(Rect2i(5, 5, 4, 3))
	_add_building(Rect2i(15, 8, 5, 4))
	_add_building(Rect2i(25, 4, 3, 6))
	_add_building(Rect2i(8, 18, 6, 3))
	_add_building(Rect2i(20, 20, 4, 4))
	_add_building(Rect2i(30, 15, 5, 3))
	# 壁状障害
	for i in range(10, 20):
		_add_obstacle(12, i)
		_add_obstacle(i, 12)

	# 拠点マーカー
	var base = ColorRect.new()
	base.size = Vector2(CELL_SIZE * 2, CELL_SIZE * 2)
	base.position = Vector2(1 * CELL_SIZE, 1 * CELL_SIZE)
	base.color = Color(0.5, 0.7, 0.4, 0.8)
	tile_layer.add_child(base)

	# 整備所マーカー
	var hangar = ColorRect.new()
	hangar.size = Vector2(CELL_SIZE * 3, CELL_SIZE * 2)
	hangar.position = Vector2(32 * CELL_SIZE, 2 * CELL_SIZE)
	hangar.color = Color(0.4, 0.5, 0.7, 0.8)
	tile_layer.add_child(hangar)

func _add_building(rect: Rect2i) -> void:
	_buildings.append(rect)
	for x in range(rect.position.x, rect.position.x + rect.size.x):
		for y in range(rect.position.y, rect.position.y + rect.size.y):
			_add_obstacle(x, y)
			var wall = ColorRect.new()
			wall.size = Vector2(CELL_SIZE, CELL_SIZE)
			wall.position = Vector2(x * CELL_SIZE, y * CELL_SIZE)
			wall.color = Color(0.45, 0.35, 0.3)
			obstacle_layer.add_child(wall)
			# 物理衝突
			var body = StaticBody2D.new()
			body.collision_layer = 2
			body.collision_mask = 0
			body.position = Vector2(x * CELL_SIZE + CELL_SIZE / 2.0, y * CELL_SIZE + CELL_SIZE / 2.0)
			var shape = CollisionShape2D.new()
			var rect_shape = RectangleShape2D.new()
			rect_shape.size = Vector2(CELL_SIZE, CELL_SIZE)
			shape.shape = rect_shape
			body.add_child(shape)
			obstacle_layer.add_child(body)

func _add_obstacle(x: int, y: int) -> void:
	_obstacles["%d_%d" % [x, y]] = true

func is_obstacle(cell_x: int, cell_y: int) -> bool:
	return _obstacles.has("%d_%d" % [cell_x, cell_y])

func world_to_cell(pos: Vector2) -> Vector2i:
	return Vector2i(int(pos.x / CELL_SIZE), int(pos.y / CELL_SIZE))

func has_line_of_sight(from: Vector2, to: Vector2) -> bool:
	# 簡易Bresenham視線チェック
	var c0 = world_to_cell(from)
	var c1 = world_to_cell(to)
	var x0 = c0.x
	var y0 = c0.y
	var x1 = c1.x
	var y1 = c1.y
	var dx = absi(x1 - x0)
	var dy = -absi(y1 - y0)
	var sx = 1 if x0 < x1 else -1
	var sy = 1 if y0 < y1 else -1
	var err = dx + dy
	while true:
		if x0 == x1 and y0 == y1:
			return true
		# 途中セルが障害なら遮蔽（終点以外）
		if not (x0 == c0.x and y0 == c0.y) and not (x0 == x1 and y0 == y1):
			if is_obstacle(x0, y0):
				return false
		var e2 = 2 * err
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy
	return true

func _update_fog() -> void:
	if _player == null:
		_player = get_tree().get_first_node_in_group("player")
		if _player == null:
			return
	var vision = FOOT_VISION if GameState.get_player_mode() == "foot" else KMF_VISION
	if _player.has_method("get_vision_radius"):
		vision = _player.get_vision_radius()
	var ppos = _player.global_position
	_update_semantic_location(ppos)
	_update_npc_markers()
	var pcell = world_to_cell(ppos)

	# 探索済み更新
	var r_cells = int(vision / CELL_SIZE) + 1
	for dx in range(-r_cells, r_cells + 1):
		for dy in range(-r_cells, r_cells + 1):
			var cx = pcell.x + dx
			var cy = pcell.y + dy
			if cx < 0 or cy < 0 or cx >= MAP_W or cy >= MAP_H:
				continue
			var cell_center = Vector2(cx * CELL_SIZE + CELL_SIZE / 2.0, cy * CELL_SIZE + CELL_SIZE / 2.0)
			if ppos.distance_to(cell_center) <= vision and has_line_of_sight(ppos, cell_center):
				GameState.mark_explored(cx, cy)

	# Fog描画（簡易: 未探索/現在非可視を黒く）
	# パフォーマンスのため全セル更新は間引くが、最小試作では全更新
	for child in fog_layer.get_children():
		child.queue_free()
	_fog_cells.clear()

	for x in range(MAP_W):
		for y in range(MAP_H):
			var cell_center = Vector2(x * CELL_SIZE + CELL_SIZE / 2.0, y * CELL_SIZE + CELL_SIZE / 2.0)
			var dist = ppos.distance_to(cell_center)
			var visible_now = dist <= vision and has_line_of_sight(ppos, cell_center)
			var explored = GameState.is_explored(x, y)
			if not visible_now:
				var fog = ColorRect.new()
				fog.size = Vector2(CELL_SIZE, CELL_SIZE)
				fog.position = Vector2(x * CELL_SIZE, y * CELL_SIZE)
				if explored:
					fog.color = Color(0.05, 0.05, 0.08, 0.75)  # 探索済みだが現在非可視
				else:
					fog.color = Color(0.0, 0.0, 0.0, 0.95)  # 未探索
				fog_layer.add_child(fog)


## --- Phase A semantic locations / visible NPC markers ---

func _region_rects() -> Dictionary:
	return {
		"base": Rect2i(0, 0, 5, 5),
		"hospital": Rect2i(4, 4, 8, 7),
		"city_center": Rect2i(13, 6, 10, 11),
		"industrial_area": Rect2i(24, 3, 12, 12),
		"evacuation_center": Rect2i(5, 17, 13, 10),
		"maintenance": Rect2i(30, 0, 10, 7),
	}

func _location_from_position(pos: Vector2) -> String:
	var cell := world_to_cell(pos)
	# More specific/edge locations before broad center.
	for location_id in ["base", "maintenance", "hospital", "industrial_area", "evacuation_center", "city_center"]:
		var rect: Rect2i = _region_rects()[location_id]
		if rect.has_point(cell):
			return location_id
	return "outskirts"

func _location_center(location_id: String) -> Vector2:
	var regions = _region_rects()
	if not regions.has(location_id):
		return Vector2(MAP_W * CELL_SIZE * 0.5, MAP_H * CELL_SIZE * 0.5)
	var rect: Rect2i = regions[location_id]
	return Vector2(
		(rect.position.x + rect.size.x * 0.5) * CELL_SIZE,
		(rect.position.y + rect.size.y * 0.5) * CELL_SIZE
	)

func get_navigation_position(location_id: String) -> Vector2:
	return _location_center(location_id)

func get_map_bounds() -> Rect2:
	return Rect2(Vector2.ZERO, Vector2(MAP_W * CELL_SIZE, MAP_H * CELL_SIZE))

func get_location_display_name(location_id: String) -> String:
	return str(REGION_PRESENTATION.get(location_id, REGION_PRESENTATION["outskirts"]).get("name", "外縁部"))

func _update_semantic_location(pos: Vector2) -> void:
	var new_location := _location_from_position(pos)
	var player := GameState.get_section("player")
	var old_location := str(player.get("locationId", "base"))
	if new_location == old_location:
		return
	GameState.set_player_location(new_location)
	# Region transition consumes in-game travel time; KMF is faster.
	var travel_minutes := 5 if GameState.get_player_mode() == "kmf" else 12
	GameState.advance_time(travel_minutes)

func _add_region_markers() -> void:
	for location_id in REGION_PRESENTATION.keys():
		if location_id == "outskirts":
			continue
		var rect: Rect2i = _region_rects()[location_id]
		var presentation: Dictionary = REGION_PRESENTATION[location_id]
		var marker := ColorRect.new()
		marker.name = "Region_" + location_id
		marker.position = Vector2(rect.position.x * CELL_SIZE, rect.position.y * CELL_SIZE)
		marker.size = Vector2(rect.size.x * CELL_SIZE, rect.size.y * CELL_SIZE)
		marker.color = presentation["color"]
		marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tile_layer.add_child(marker)

		var label := Label.new()
		label.text = "%s  %s" % [presentation["short"], presentation["name"]]
		label.position = marker.position + Vector2(6, 5)
		label.add_theme_font_size_override("font_size", 17)
		label.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
		label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.95))
		label.add_theme_constant_override("shadow_offset_x", 2)
		label.add_theme_constant_override("shadow_offset_y", 2)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tile_layer.add_child(label)

func _update_npc_markers() -> void:
	if _npc_layer == null or not has_node("/root/NpcManager"):
		return
	var nm = get_node("/root/NpcManager")
	for child in _npc_layer.get_children():
		child.queue_free()
	_npc_markers.clear()

	var offsets: Dictionary = {}
	for npc_id in nm.get_npc_ids():
		var npc: Dictionary = nm.get_npc(npc_id)
		if not bool(npc.get("alive", true)) or not bool(npc.get("present", true)):
			continue
		var location_id: String = str(npc.get("locationId", "unknown"))
		if not _region_rects().has(location_id):
			continue
		var idx: int = int(offsets.get(location_id, 0))
		offsets[location_id] = idx + 1

		var holder := Node2D.new()
		holder.name = "NPC_" + str(npc_id)
		# Wider two-column placement keeps labels readable when several NPCs share a region.
		holder.position = _location_center(location_id) + Vector2((idx % 2) * 116 - 58, int(idx / 2) * 34 + 28)
		holder.set_meta("npc_id", str(npc_id))
		holder.set_meta("location_id", location_id)

		var body := ColorRect.new()
		body.size = Vector2(12, 12)
		body.position = Vector2(-6, -6)
		body.color = Color(0.95, 0.75, 0.25, 0.95)
		body.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(body)

		var name_label := Label.new()
		name_label.text = "%s｜%s" % [str(npc.get("name", "人物")), _npc_state_label(npc)]
		name_label.position = Vector2(9, -12)
		name_label.add_theme_font_size_override("font_size", 12)
		name_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
		name_label.add_theme_constant_override("shadow_offset_x", 1)
		name_label.add_theme_constant_override("shadow_offset_y", 1)
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(name_label)

		_npc_layer.add_child(holder)
		_npc_markers[str(npc_id)] = holder

func _npc_state_label(npc: Dictionary) -> String:
	if not bool(npc.get("alive", true)):
		return "死亡"
	var action := str(npc.get("currentAction", "idle"))
	var labels := {
		"idle": "待機",
		"wait": "待機",
		"moving": "移動中",
		"brief": "情報共有中",
		"coordinate": "調整中",
		"shelter": "避難対応中",
		"flee": "避難中",
		"fleeing": "避難中",
		"helping": "救助中",
		"injured": "負傷",
		"escort": "護送中",
		"combat": "交戦中",
	}
	return str(labels.get(action, "行動中"))


func refresh_npc_markers() -> void:
	_update_npc_markers()

func get_npc_marker_position(npc_id: String) -> Vector2:
	var holder = _npc_markers.get(npc_id, null)
	if holder == null or not is_instance_valid(holder):
		_update_npc_markers()
		holder = _npc_markers.get(npc_id, null)
	if holder == null or not is_instance_valid(holder):
		return Vector2(-9999, -9999)
	return holder.global_position

func get_nearest_npc_id(world_pos: Vector2, max_distance: float = 72.0) -> String:
	if _npc_markers.is_empty():
		_update_npc_markers()
	var best_id := ""
	var best_distance := max_distance
	for npc_id in _npc_markers.keys():
		var holder = _npc_markers[npc_id]
		if holder == null or not is_instance_valid(holder):
			continue
		var distance := world_pos.distance_to(holder.global_position)
		if distance <= best_distance:
			best_distance = distance
			best_id = str(npc_id)
	return best_id

