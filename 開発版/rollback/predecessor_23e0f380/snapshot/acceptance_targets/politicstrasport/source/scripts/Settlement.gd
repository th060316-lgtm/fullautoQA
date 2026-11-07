class_name Settlement
extends RefCounted

enum EconomyState { BOOM, NORMAL, RECESSION }

var id: int
var name: String
var position: Vector2
var population: float
var economy: float
var nation_id: int
var food_demand: float
var fuel_demand: float
var passenger_demand: float
var economy_state: int = EconomyState.NORMAL
var is_supply_base: bool = false
var food_supply_capacity: float = 0.0
var fuel_supply_capacity: float = 0.0
var active: bool = true
var support_nation_id: int = -1
var has_port: bool = false
var port_owner_id: int = -1
var has_airport: bool = false
var airport_owner_id: int = -1
var passenger_destinations: Dictionary = {}

# Issue #9-#11/#14 state. Values are deliberately aggregate logistics effects.
var occupied_by_nation_id: int = -1
var war_damage: float = 0.0
var infrastructure_damage: float = 0.0
var port_blockaded: bool = false
var transport_disruption: float = 0.0
var refugee_pressure: float = 0.0
var reconstruction_progress: float = 1.0
var military_demand: float = 0.0
var reconstruction_demand: float = 0.0
var development_support: float = 0.0
var promotion_support: float = 0.0
var investment_support: float = 0.0

var supply_base_owner_nation: int:
	get:
		return support_nation_id
	set(value):
		support_nation_id = value

func _init(p_id: int = 0, p_name: String = "", p_pos: Vector2 = Vector2.ZERO):
	id = p_id
	name = p_name
	position = p_pos
	population = 10.0
	economy = 10.0
	nation_id = 0
	food_demand = 5.0
	fuel_demand = 3.0
	passenger_demand = 4.0
	economy_state = EconomyState.NORMAL

func get_economy_multiplier() -> float:
	var mult := 1.0
	match economy_state:
		EconomyState.BOOM: mult = 1.4
		EconomyState.RECESSION: mult = 0.6
	mult *= clamp(1.0 - war_damage * 0.65, 0.25, 1.0)
	mult *= 1.0 + min(0.35, development_support * 0.002)
	return mult

func get_growth_rate() -> float:
	var base := 0.002
	match economy_state:
		EconomyState.BOOM: base = 0.005
		EconomyState.RECESSION: base = 0.0005
	base += min(0.003, development_support * 0.00002)
	base -= war_damage * 0.004
	return base

func is_coastal(max_distance: float) -> bool:
	return WaterMap.is_coastal(position, max_distance)

func to_dict() -> Dictionary:
	return {
		"id": id, "name": name, "pos_x": position.x, "pos_y": position.y,
		"population": population, "economy": economy, "nation_id": nation_id,
		"food_demand": food_demand, "fuel_demand": fuel_demand,
		"passenger_demand": passenger_demand, "economy_state": economy_state,
		"is_supply_base": is_supply_base, "support_nation_id": support_nation_id,
		"supply_base_owner_nation": supply_base_owner_nation,
		"has_port": has_port, "has_airport": has_airport,
		"food_supply_capacity": food_supply_capacity,
		"fuel_supply_capacity": fuel_supply_capacity, "active": active,
		"occupied_by_nation_id": occupied_by_nation_id, "war_damage": war_damage,
		"infrastructure_damage": infrastructure_damage,
		"port_blockaded": port_blockaded, "transport_disruption": transport_disruption,
		"refugee_pressure": refugee_pressure,
		"reconstruction_progress": reconstruction_progress,
		"military_demand": military_demand,
		"reconstruction_demand": reconstruction_demand,
	}
