extends RefCounted
class_name ExpeditionAreaKnowledge

const CELL_SIZE := 64.0
const STALE_AFTER := 45.0

var explored_cells: Dictionary = {}
var clear_areas: Dictionary = {}
var sim_time := 0.0

func reset() -> void:
	explored_cells.clear()
	clear_areas.clear()
	sim_time = 0.0

func set_time(value: float) -> void:
	sim_time = value

func _cell_for(point: Vector2) -> Vector2i:
	return Vector2i(int(floor(point.x / CELL_SIZE)), int(floor(point.y / CELL_SIZE)))

func mark_explored(center: Vector2, radius: float) -> void:
	var min_cell := _cell_for(center - Vector2(radius, radius))
	var max_cell := _cell_for(center + Vector2(radius, radius))
	for x in range(min_cell.x, max_cell.x + 1):
		for y in range(min_cell.y, max_cell.y + 1):
			var cell := Vector2i(x, y)
			var cell_center := Vector2((x + 0.5) * CELL_SIZE, (y + 0.5) * CELL_SIZE)
			if cell_center.distance_to(center) <= radius + CELL_SIZE * 0.75:
				explored_cells[cell] = sim_time

func explored_ratio(rect: Rect2) -> float:
	if rect.size == Vector2.ZERO:
		return 0.0
	var min_cell := _cell_for(rect.position)
	var max_cell := _cell_for(rect.end)
	var total := 0
	var known := 0
	for x in range(min_cell.x, max_cell.x + 1):
		for y in range(min_cell.y, max_cell.y + 1):
			total += 1
			if explored_cells.has(Vector2i(x, y)):
				known += 1
	return 0.0 if total == 0 else float(known) / float(total)

func set_clear_progress(area_id: String, rect: Rect2, progress: float, checked_time: float = -1.0) -> Dictionary:
	var now := sim_time if checked_time < 0.0 else checked_time
	var p := clampf(progress, 0.0, 1.0)
	var status := "clear" if p >= 0.999 else "checking"
	var row := {
		"id": area_id,
		"rect": rect,
		"progress": p,
		"status": status,
		"last_checked": now,
	}
	clear_areas[area_id] = row
	return row.duplicate(true)

func update_decay(current_time: float = -1.0) -> void:
	if current_time >= 0.0:
		sim_time = current_time
	for area_id in clear_areas.keys():
		var row: Dictionary = clear_areas[area_id]
		if str(row.get("status", "")) == "clear" and sim_time - float(row.get("last_checked", sim_time)) > STALE_AFTER:
			row["status"] = "uncertain"
			row["progress"] = minf(float(row.get("progress", 1.0)), 0.65)
			clear_areas[area_id] = row

func get_area(area_id: String) -> Dictionary:
	return clear_areas.get(area_id, {}).duplicate(true)

func status_for_point(point: Vector2) -> String:
	for row in clear_areas.values():
		if row is Dictionary and (row.get("rect", Rect2()) as Rect2).has_point(point):
			return str(row.get("status", "unknown"))
	return "unknown"

func snapshot() -> Dictionary:
	var areas := {}
	for id in clear_areas.keys():
		areas[id] = (clear_areas[id] as Dictionary).duplicate(true)
	return {"explored_count": explored_cells.size(), "clear_areas": areas}
