class_name Route
extends RefCounted

enum RouteType { ROAD, RAIL, SHIP, AIR }

var id: int
var from_id: int
var to_id: int
var type: int = RouteType.ROAD
var capacity: float = 5.0
var build_cost: float = 50.0
var active: bool = true
var last_revenue: float = 0.0
var total_carried: float = 0.0
var carried_passenger: float = 0.0
var carried_food: float = 0.0
var carried_fuel: float = 0.0
var carried_general: Dictionary = {}
var company_id: int = 0
var speed: float = 120.0
var operating_cost: float = 1.5
var service_score: float = 0.0
var market_share: float = 0.0
var daily_revenue: float = 0.0
var daily_operating_cost: float = 0.0
var profit: float = 0.0
var unprofitable_days: int = 0
var obsolete: bool = false
var path_length: float = 0.0
var path_points: PackedVector2Array = PackedVector2Array()

# Issue #9/#15: temporary world shocks never destroy the route contract.
var route_value_multiplier: float = 1.0
var disruption_reason: String = ""
var blocked_until_day: int = -1
var previous_profit: float = 0.0
var profit_change_reason: String = "平常運行"
var cooperation_group: int = -1

func _init(p_id: int = 0, p_from: int = -1, p_to: int = -1, p_type: int = RouteType.ROAD):
	id = p_id
	from_id = p_from
	to_id = p_to
	type = p_type
	capacity = TransportModeConfig.capacity(type)
	build_cost = TransportModeConfig.build_cost(type)
	speed = TransportModeConfig.speed(type)
	operating_cost = TransportModeConfig.operating_cost(type)

func get_type_name() -> String:
	return TransportModeConfig.mode_name(type)

func is_operational(world: WorldState = null) -> bool:
	if not active or obsolete or route_value_multiplier <= 0.001:
		return false
	if world == null:
		return true
	if blocked_until_day >= world.day:
		return false
	var a = world.get_settlement(from_id)
	var b = world.get_settlement(to_id)
	if a == null or b == null:
		return false
	return a.active and b.active

func remaining_capacity() -> float:
	var general_total := 0.0
	for amount in carried_general.values():
		general_total += float(amount)
	return max(0.0, capacity * route_value_multiplier - (carried_passenger + carried_food + carried_fuel + general_total))

func reset_tick() -> void:
	carried_passenger = 0.0
	carried_food = 0.0
	carried_fuel = 0.0
	carried_general.clear()
	last_revenue = 0.0
