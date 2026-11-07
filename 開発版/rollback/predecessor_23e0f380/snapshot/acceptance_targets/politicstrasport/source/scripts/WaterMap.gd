class_name WaterMap
extends RefCounted

## MiniMax: 海 / 水上接続の概念と簡易自動経路 (Logic Prototype)
##
## ・世界座標 960x720 の矩形を 12px グリッドに分割し、海水を判定する。
## ・陆地ポリゴン (内側 = 陸) の外側が海。
## ・海は 1 つの連続領域として定義され、港と港の間は水上経路で結ばれる。
## ・地上タイル経路探索 (Grok 管轄) とは独立。水上専用なので競合しない。

const WORLD_RECT := Rect2(0.0, 0.0, 960.0, 720.0)
const CELL_SIZE := 12.0
const COLS := 80
const ROWS := 60
const MAX_ANCHOR_CELLS := 24  # 港から水面セルを探す最大距離 (セル数)

# 内側 = 陸。外周が海岸線。
static var _land_poly: PackedVector2Array = PackedVector2Array()
# 海岸線 (陸側の境界から画面境界を除いた折れ線)
static var _coast_poly: PackedVector2Array = PackedVector2Array()
static var _grid: Array = []
static var _grid_ready: bool = false

static func land_polygon() -> PackedVector2Array:
	if _land_poly.is_empty():
		_land_poly = PackedVector2Array([
			Vector2(0, 0), Vector2(960, 0), Vector2(960, 250), Vector2(880, 250),
			Vector2(945, 330), Vector2(880, 430), Vector2(700, 645), Vector2(520, 600),
			Vector2(385, 560), Vector2(330, 462), Vector2(200, 392), Vector2(0, 428),
		])
	return _land_poly

static func coast_polygon() -> PackedVector2Array:
	if _coast_poly.is_empty():
		_coast_poly = PackedVector2Array([
			Vector2(0, 428), Vector2(200, 392), Vector2(330, 462), Vector2(385, 560),
			Vector2(520, 600), Vector2(700, 645), Vector2(880, 430), Vector2(945, 330),
			Vector2(880, 250), Vector2(960, 250),
		])
	return _coast_poly

static func _point_in_polygon(p: Vector2, poly: PackedVector2Array) -> bool:
	var inside := false
	var n := poly.size()
	if n < 3:
		return false
	var j := n - 1
	for i in range(n):
		var pi := poly[i]
		var pj := poly[j]
		if (pi.y > p.y) != (pj.y > p.y):
			var x_intersect := (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x
			if p.x < x_intersect:
				inside = not inside
		j = i
	return inside

## 指定座標が海 (水面) かどうか
static func is_water(p: Vector2) -> bool:
	if not WORLD_RECT.has_point(p):
		return false
	return not _point_in_polygon(p, land_polygon())

## 海岸線までの最短距離 (px)。内陆・海上どちらからでも算出可能。
static func distance_to_coast(p: Vector2) -> float:
	var poly := coast_polygon()
	var best := 1.0e9
	for i in range(poly.size() - 1):
		var d := _point_segment_distance(p, poly[i], poly[i + 1])
		if d < best:
			best = d
	return best

## 港を建設できる海岸度合いか
static func is_coastal(p: Vector2, max_distance: float) -> bool:
	return distance_to_coast(p) <= max_distance

static func _point_segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var denom := ab.length_squared()
	if denom <= 0.000001:
		return p.distance_to(a)
	var t: float = clamp(((p - a).dot(ab)) / denom, 0.0, 1.0)
	return p.distance_to(a + ab * t)

static func _cell_center(c: Vector2i) -> Vector2:
	return Vector2((c.x + 0.5) * CELL_SIZE, (c.y + 0.5) * CELL_SIZE)

static func _get_grid() -> Array:
	if _grid_ready:
		return _grid
	_grid = []
	var poly := land_polygon()
	for cy in range(ROWS):
		var row: Array = []
		for cx in range(COLS):
			var p := _cell_center(Vector2i(cx, cy))
			row.append(not _point_in_polygon(p, poly))
		_grid.append(row)
	_grid_ready = true
	return _grid

## 最も近い水面セルを探す (見つからない場合は (-1,-1))
static func nearest_water_cell(p: Vector2) -> Vector2i:
	var grid := _get_grid()
	var best := Vector2i(-1, -1)
	var best_d := 1.0e9
	for cy in range(ROWS):
		for cx in range(COLS):
			if not grid[cy][cx]:
				continue
			var c := Vector2i(cx, cy)
			var d: float = _cell_center(c).distance_to(p)
			if d < best_d:
				best_d = d
				best = c
	return best

## 2点間の水上経路 (セル中心の折れ線) を BFS で求める。
## 経路が無い場合は空配列を返す。
static func find_sea_path(from_pos: Vector2, to_pos: Vector2) -> PackedVector2Array:
	var grid := _get_grid()
	var a := nearest_water_cell(from_pos)
	var b := nearest_water_cell(to_pos)
	if a.x < 0 or b.x < 0:
		return PackedVector2Array()
	if a == b:
		var one := PackedVector2Array()
		one.append(_cell_center(a))
		return one
	var prev := {a: Vector2i(-1, -1)}
	var queue: Array = [a]
	var head := 0
	var found := false
	while head < queue.size():
		var cur: Vector2i = queue[head]
		head += 1
		if cur == b:
			found = true
			break
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if dx == 0 and dy == 0:
					continue
				var n := Vector2i(cur.x + dx, cur.y + dy)
				if n.x < 0 or n.y < 0 or n.x >= COLS or n.y >= ROWS:
					continue
				if not grid[n.y][n.x]:
					continue
				if prev.has(n):
					continue
				prev[n] = cur
				queue.append(n)
	if not found:
		return PackedVector2Array()
	var cells: Array = []
	var walk := b
	while walk.x >= 0:
		cells.push_front(walk)
		walk = prev[walk]
	var pts := PackedVector2Array()
	for c in cells:
		var cc: Vector2i = c
		pts.append(_cell_center(cc))
	return pts

## 折れ線の長さ (px)
static func path_length(pts: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(pts.size() - 1):
		total += pts[i].distance_to(pts[i + 1])
	return total
