class_name GroundNetwork
extends RefCounted

## Unified ground network for PoliticsTrasport v0.2 integrated candidate.
## Physical road/rail tiles are shared map infrastructure; logical Route ownership is company-specific.

const TILE_SIZE: int = 40
const GRID_ORIGIN := Vector2(0, 0)
const COLS: int = 32
const ROWS: int = 18

const ROAD_COST_PER_TILE: float = 8.0
const RAIL_COST_PER_TILE: float = 25.0

const MODE_ROAD: int = 0
const MODE_RAIL: int = 1

const DIRS8: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)
]

class GroundTileData:
	var coord: Vector2i
	var owner_nation_id: int = -1
	var has_road: bool = false
	var has_rail: bool = false
	var terrain: int = 0

	func _init(c: Vector2i = Vector2i.ZERO):
		coord = c

var tiles: Dictionary = {}
var world: WorldState = null
var terminals: Dictionary = {}  # settlement id -> tile

func _init(p_world: WorldState = null):
	world = p_world

func initialize_grid() -> void:
	tiles.clear()
	for x in range(COLS):
		for y in range(ROWS):
			var c = Vector2i(x, y)
			tiles[c] = GroundTileData.new(c)

func world_to_tile(pos: Vector2) -> Vector2i:
	var local = pos - GRID_ORIGIN
	return Vector2i(
		clampi(int(floor(local.x / float(TILE_SIZE))), 0, COLS - 1),
		clampi(int(floor(local.y / float(TILE_SIZE))), 0, ROWS - 1)
	)

func tile_to_world_center(c: Vector2i) -> Vector2:
	return GRID_ORIGIN + Vector2((c.x + 0.5) * TILE_SIZE, (c.y + 0.5) * TILE_SIZE)

func is_valid_coord(c: Vector2i) -> bool:
	return c.x >= 0 and c.x < COLS and c.y >= 0 and c.y < ROWS

func get_tile(c: Vector2i) -> GroundTileData:
	if not is_valid_coord(c):
		return null
	return tiles.get(c, null)

func ensure_tile(c: Vector2i) -> GroundTileData:
	if not is_valid_coord(c):
		return null
	if not tiles.has(c):
		tiles[c] = GroundTileData.new(c)
	return tiles[c]

func assign_terminals() -> void:
	if world == null:
		return
	terminals.clear()
	for s in world.settlements:
		if not s.active:
			continue
		var c = world_to_tile(s.position)
		terminals[s.id] = c
		var t = ensure_tile(c)
		if t and not s.is_supply_base:
			t.owner_nation_id = s.nation_id

func get_terminal(settlement_id: int) -> Vector2i:
	return terminals.get(settlement_id, Vector2i(-1, -1))

func set_tile_owner(c: Vector2i, nation_id: int) -> void:
	var t = get_tile(c)
	if t:
		t.owner_nation_id = nation_id

func paint_nation_ownership_from_settlements() -> void:
	if world == null:
		return
	for t in tiles.values():
		t.owner_nation_id = -1
	for x in range(COLS):
		for y in range(ROWS):
			var c = Vector2i(x, y)
			var best_d2 = 999999.0
			var best_n = -1
			for s in world.settlements:
				if not s.active or s.is_supply_base:
					continue
				var tc = world_to_tile(s.position)
				var d2 = float((c.x - tc.x) * (c.x - tc.x) + (c.y - tc.y) * (c.y - tc.y))
				if d2 < best_d2:
					best_d2 = d2
					best_n = s.nation_id
			var t = ensure_tile(c)
			if t:
				t.owner_nation_id = best_n

func can_build_on(c: Vector2i) -> bool:
	return is_valid_coord(c)

func _company_can_pay(company_id: int, amount: float) -> bool:
	if world == null:
		return false
	if company_id == WorldState.PLAYER_COMPANY_ID:
		return world.money >= amount
	var c = world.get_company(company_id)
	return c != null and c.money >= amount

func build_road(c: Vector2i, free: bool = false, company_id: int = WorldState.PLAYER_COMPANY_ID) -> Dictionary:
	var t = get_tile(c)
	if t == null or not can_build_on(c):
		return {"ok": false, "cost": 0.0, "msg": "無効座標"}
	if t.has_road:
		return {"ok": false, "cost": 0.0, "msg": "既に道路あり"}
	var cost := 0.0 if free else ROAD_COST_PER_TILE
	if not free and not world.pay_company(company_id, cost):
		return {"ok": false, "cost": cost, "msg": "資金不足"}
	t.has_road = true
	return {"ok": true, "cost": cost, "msg": "道路建設"}

func build_rail(c: Vector2i, free: bool = false, company_id: int = WorldState.PLAYER_COMPANY_ID) -> Dictionary:
	var t = get_tile(c)
	if t == null or not can_build_on(c):
		return {"ok": false, "cost": 0.0, "msg": "無効座標"}
	if t.has_rail:
		return {"ok": false, "cost": 0.0, "msg": "既に鉄道あり"}
	var cost := 0.0 if free else RAIL_COST_PER_TILE
	if not free and not world.pay_company(company_id, cost):
		return {"ok": false, "cost": cost, "msg": "資金不足"}
	t.has_rail = true
	return {"ok": true, "cost": cost, "msg": "鉄道建設"}

func remove_infra(c: Vector2i, mode: int = -1) -> Dictionary:
	var t = get_tile(c)
	if t == null:
		return {"ok": false, "msg": "無効座標"}
	var removed := false
	if (mode == -1 or mode == MODE_ROAD) and t.has_road:
		t.has_road = false
		removed = true
	if (mode == -1 or mode == MODE_RAIL) and t.has_rail:
		t.has_rail = false
		removed = true
	return {"ok": removed, "msg": "撤去" if removed else "インフラなし"}

func has_infra(c: Vector2i, mode: int) -> bool:
	var t = get_tile(c)
	if t == null:
		return false
	if mode == MODE_ROAD:
		return t.has_road
	if mode == MODE_RAIL:
		return t.has_rail
	return false

## Only the actual origin/destination terminals may be used without infrastructure.
## Other settlement terminals no longer create free transit shortcuts.
func has_path(from_c: Vector2i, to_c: Vector2i, mode: int) -> bool:
	if from_c == to_c:
		return true
	if not is_valid_coord(from_c) or not is_valid_coord(to_c):
		return false
	var visited: Dictionary = {}
	visited[from_c] = true
	var q: Array[Vector2i] = [from_c]
	while not q.is_empty():
		var cur: Vector2i = q.pop_front()
		if cur == to_c:
			return true
		for d in DIRS8:
			var nxt = cur + d
			if not is_valid_coord(nxt) or visited.has(nxt):
				continue
			if has_infra(nxt, mode) or nxt == to_c:
				visited[nxt] = true
				q.append(nxt)
	return false

func has_settlement_connection(origin_id: int, dest_id: int, mode: int) -> bool:
	var a = get_terminal(origin_id)
	var b = get_terminal(dest_id)
	if a.x < 0 or b.x < 0:
		return false
	return has_path(a, b, mode)

func path_length(from_c: Vector2i, to_c: Vector2i, mode: int) -> int:
	if from_c == to_c:
		return 0
	if not is_valid_coord(from_c) or not is_valid_coord(to_c):
		return -1
	var visited: Dictionary = {}
	visited[from_c] = true
	var q: Array = [[from_c, 0]]
	while not q.is_empty():
		var item = q.pop_front()
		var cur: Vector2i = item[0]
		var dist: int = item[1]
		if cur == to_c:
			return dist
		for d in DIRS8:
			var nxt = cur + d
			if not is_valid_coord(nxt) or visited.has(nxt):
				continue
			if has_infra(nxt, mode) or nxt == to_c:
				visited[nxt] = true
				q.append([nxt, dist + 1])
	return -1

func _bresenham_line(a: Vector2i, b: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var x0 = a.x
	var y0 = a.y
	var x1 = b.x
	var y1 = b.y
	var dx = abs(x1 - x0)
	var dy = abs(y1 - y0)
	var sx = 1 if x0 < x1 else -1
	var sy = 1 if y0 < y1 else -1
	var err = dx - dy
	while true:
		result.append(Vector2i(x0, y0))
		if x0 == x1 and y0 == y1:
			break
		var e2 = 2 * err
		if e2 > -dy:
			err -= dy
			x0 += sx
		if e2 < dx:
			err += dx
			y0 += sy
	return result

func _missing_tile_count(cells: Array[Vector2i], mode: int) -> int:
	var n := 0
	for c in cells:
		if not has_infra(c, mode):
			n += 1
	return n

func estimate_ground_build_cost(mode: int, origin_id: int, destination_id: int) -> float:
	if mode != MODE_ROAD and mode != MODE_RAIL:
		return INF
	var a = get_terminal(origin_id)
	var b = get_terminal(destination_id)
	if a.x < 0 or b.x < 0:
		return INF
	var cells := _bresenham_line(a, b)
	var per_tile := ROAD_COST_PER_TILE if mode == MODE_ROAD else RAIL_COST_PER_TILE
	return float(_missing_tile_count(cells, mode)) * per_tile

func estimate_ground_length(mode: int, origin_id: int, destination_id: int) -> float:
	var a = get_terminal(origin_id)
	var b = get_terminal(destination_id)
	if a.x < 0 or b.x < 0:
		return 0.0
	return float(_bresenham_line(a, b).size() - 1) * float(TILE_SIZE)

func can_build_ground_connection(company_id: int, mode: int, origin_id: int, destination_id: int) -> bool:
	if mode != MODE_ROAD and mode != MODE_RAIL:
		return false
	if world == null or origin_id == destination_id:
		return false
	var a = world.get_settlement(origin_id)
	var b = world.get_settlement(destination_id)
	if a == null or b == null or not a.active or not b.active:
		return false
	if not terminals.has(origin_id) or not terminals.has(destination_id):
		assign_terminals()
	var cost := estimate_ground_build_cost(mode, origin_id, destination_id)
	return cost != INF and _company_can_pay(company_id, cost)

func build_path_between(from_c: Vector2i, to_c: Vector2i, mode: int, free: bool = false, company_id: int = WorldState.PLAYER_COMPANY_ID) -> Dictionary:
	if not is_valid_coord(from_c) or not is_valid_coord(to_c):
		return {"ok": false, "cost": 0.0, "tiles_built": 0, "distance": -1, "msg": "無効座標"}
	var cells := _bresenham_line(from_c, to_c)
	var per_tile := ROAD_COST_PER_TILE if mode == MODE_ROAD else RAIL_COST_PER_TILE
	var required := float(_missing_tile_count(cells, mode)) * per_tile
	if not free and not _company_can_pay(company_id, required):
		return {"ok": false, "cost": 0.0, "tiles_built": 0, "distance": cells.size() - 1, "msg": "資金不足"}
	var total_cost := 0.0
	var built := 0
	for c in cells:
		if has_infra(c, mode):
			continue
		var res = build_road(c, free, company_id) if mode == MODE_ROAD else build_rail(c, free, company_id)
		if not res.get("ok", false):
			return {"ok": false, "cost": total_cost, "tiles_built": built, "distance": cells.size() - 1, "msg": res.get("msg", "建設失敗")}
		total_cost += float(res.get("cost", 0.0))
		built += 1
	var connected := has_path(from_c, to_c, mode)
	return {"ok": connected, "cost": total_cost, "tiles_built": built, "distance": cells.size() - 1, "msg": "接続成功" if connected else "接続未完了"}

## Adapter contract: success -> logical route id, failure -> -1.
func request_ground_connection(company_id: int, mode: int, origin_id: int, destination_id: int) -> int:
	if not can_build_ground_connection(company_id, mode, origin_id, destination_id):
		return -1
	var from_c = get_terminal(origin_id)
	var to_c = get_terminal(destination_id)
	if not has_path(from_c, to_c, mode):
		var built = build_path_between(from_c, to_c, mode, false, company_id)
		if not built.get("ok", false):
			return -1
	var route = _ensure_logical_route(origin_id, destination_id, mode, company_id)
	return route.id if route != null else -1

## Legacy detailed API retained for Grok-side callers/tests.
func request_ai_ground_connection(company_id: int, mode: int, origin_id: int, destination_id: int) -> Dictionary:
	var before_cost := estimate_ground_build_cost(mode, origin_id, destination_id)
	var before_road := count_infra(mode)
	var rid := request_ground_connection(company_id, mode, origin_id, destination_id)
	return {
		"success": rid >= 0,
		"company_id": company_id,
		"mode": mode,
		"origin_id": origin_id,
		"destination_id": destination_id,
		"connection_id": rid,
		"cost": 0.0 if before_cost == INF else before_cost,
		"distance": estimate_ground_length(mode, origin_id, destination_id),
		"connected": rid >= 0,
		"tiles_built": max(0, count_infra(mode) - before_road),
		"msg": "接続成功" if rid >= 0 else "接続失敗"
	}

func _find_logical_route(from_id: int, to_id: int, mode: int, company_id: int = -1, include_inactive: bool = true) -> Route:
	if world == null:
		return null
	for r in world.routes:
		if not include_inactive and not r.active:
			continue
		if r.type != mode:
			continue
		if company_id >= 0 and r.company_id != company_id:
			continue
		if (r.from_id == from_id and r.to_id == to_id) or (r.from_id == to_id and r.to_id == from_id):
			return r
	return null

func _ensure_logical_route(from_id: int, to_id: int, mode: int, company_id: int = WorldState.PLAYER_COMPANY_ID) -> Route:
	var existing = _find_logical_route(from_id, to_id, mode, company_id, true)
	if existing:
		existing.active = true
		existing.obsolete = false
		existing.path_length = estimate_ground_length(mode, from_id, to_id)
		var ea = world.get_settlement(from_id)
		var eb = world.get_settlement(to_id)
		if ea != null and eb != null:
			existing.path_points = PackedVector2Array([ea.position, eb.position])
		return existing
	if world == null or not has_settlement_connection(from_id, to_id, mode):
		return null
	var route = Route.new(world.next_route_id, from_id, to_id, mode)
	route.company_id = company_id
	route.build_cost = 0.0  # physical tiles were already paid per tile
	route.path_length = estimate_ground_length(mode, from_id, to_id)
	var from_s = world.get_settlement(from_id)
	var to_s = world.get_settlement(to_id)
	if from_s != null and to_s != null:
		route.path_points = PackedVector2Array([from_s.position, to_s.position])
	world.next_route_id += 1
	world.routes.append(route)
	var company = world.get_company(company_id)
	if company != null:
		company.add_connection(route.id)
	world.add_event("%s接続確立: %s ↔ %s (会社:%d / タイル網)" % [
		TransportModeConfig.mode_name(mode), from_s.name if from_s else "?", to_s.name if to_s else "?", company_id])
	return route

func refresh_logical_routes() -> void:
	if world == null:
		return
	for r in world.routes:
		if r.type != MODE_ROAD and r.type != MODE_RAIL:
			continue
		if r.obsolete:
			continue  # keep visible/removable after supply-base retirement
		var connected := has_settlement_connection(r.from_id, r.to_id, r.type)
		if r.active and not connected:
			r.active = false
			world.add_event("接続切断: %s ↔ %s (%s)" % [
				_settlement_name(r.from_id), _settlement_name(r.to_id), r.get_type_name()])
		elif not r.active and connected:
			r.active = true
			world.add_event("接続復旧: %s ↔ %s (%s)" % [
				_settlement_name(r.from_id), _settlement_name(r.to_id), r.get_type_name()])

func _settlement_name(id: int) -> String:
	var s = world.get_settlement(id) if world != null else null
	return s.name if s != null else "?"

func get_cost_preview(mode: int, count: int = 1) -> float:
	return (ROAD_COST_PER_TILE if mode == MODE_ROAD else RAIL_COST_PER_TILE) * count

func count_infra(mode: int) -> int:
	var n := 0
	for t in tiles.values():
		if mode == MODE_ROAD and t.has_road:
			n += 1
		elif mode == MODE_RAIL and t.has_rail:
			n += 1
	return n
