class_name SimulationDiagnostics
extends RefCounted

const MAX_EVENTS := 120
const ROUTE_CHANGE_THRESHOLD := 2.0

var world: WorldState
var events: Array = []
var route_snapshots: Dictionary = {}

func _init(p_world: WorldState) -> void:
	world = p_world

func record(category: String, message: String, severity: int = 1, data: Dictionary = {}) -> void:
	var item := {
		"day": world.day, "category": category, "message": message,
		"severity": severity, "data": data.duplicate(true),
	}
	events.push_front(item)
	if events.size() > MAX_EVENTS:
		events.pop_back()
	if severity >= 2:
		world.add_event("[%s] %s" % [category, message])

func capture_route_changes() -> void:
	for r in world.routes:
		if not r.active:
			continue
		var old_profit := float(route_snapshots.get(r.id, r.profit))
		var delta: float = float(r.profit) - old_profit
		if abs(delta) >= ROUTE_CHANGE_THRESHOLD:
			var reason: String = classify_route_change(r, delta)
			r.profit_change_reason = reason
			record("route_profit", "路線%d 損益%+.1f: %s" % [r.id, delta, reason], 1,
				{"route_id": r.id, "delta": delta, "reason": reason})
		r.previous_profit = old_profit
		route_snapshots[r.id] = r.profit

func classify_route_change(route, delta: float) -> String:
	if route.disruption_reason != "":
		return route.disruption_reason
	var a = world.get_settlement(route.from_id)
	var b = world.get_settlement(route.to_id)
	if (a != null and (a.war_damage > 0.15 or a.reconstruction_demand > 0.1)) \
			or (b != null and (b.war_damage > 0.15 or b.reconstruction_demand > 0.1)):
		return "戦災・復興による需要構成変化"
	if route.market_share < 0.34:
		return "競合進出・市場シェア低下"
	if delta > 0.0:
		return "需要増加または供給改善"
	return "需要低下または運行費負担"

func recent(min_severity: int = 1, limit: int = 8) -> Array:
	var result: Array = []
	for item in events:
		if int(item.severity) >= min_severity:
			result.append(item)
		if result.size() >= limit:
			break
	return result

func get_route_reason(route_id: int) -> String:
	var r = world.get_route(route_id)
	return r.profit_change_reason if r != null else "不明"
