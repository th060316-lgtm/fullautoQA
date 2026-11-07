class_name IndustryFacility
extends RefCounted

## Independent industry facility (Issue #4 / #7)
## Not embedded solely in Settlement food/fuel_supply_capacity.
## Owns production capacity per cargo, belongs to an IndustryCompany,
## located at a settlement (or supply base / military site that has people).

var id: int = 0
var name: String = ""
var settlement_id: int = -1
var company_id: int = -1          # IndustryCompany id (not TransportCompany)
var active: bool = true
var war_damage: float = 0.0

# cargo_id -> production capacity per day (base)
var production_capacity: Dictionary = {}
# cargo_id -> current stock available for transport
var stock: Dictionary = {}
# cargo_id -> consumption demand (for secondary / tertiary)
var consumption_demand: Dictionary = {}

# Production level multiplier (expanded by transport profits, Issue #7)
var production_level: float = 1.0
var max_production_level: float = 3.0
var min_production_level: float = 0.25

# Accumulated shipper-side profit from transported goods (reinvestment pool)
var accumulated_profit: float = 0.0
# Recent days of positive transport revenue for this facility's goods
var recent_transport_days: int = 0
var stagnation_days: int = 0
var had_transport_today: bool = false

# Category hint (primary / secondary / tertiary)
var facility_type: int = CargoRegistry.CargoCategory.PRIMARY

# Generates passenger/mail when people are present
var generates_passenger_mail: bool = true

func _init(p_id: int = 0, p_name: String = "", p_settlement_id: int = -1, p_company_id: int = -1):
	id = p_id
	name = p_name
	settlement_id = p_settlement_id
	company_id = p_company_id

func set_production(cargo_id: int, capacity: float) -> void:
	production_capacity[cargo_id] = max(0.0, capacity)
	if not stock.has(cargo_id):
		stock[cargo_id] = 0.0

func set_consumption(cargo_id: int, demand: float) -> void:
	consumption_demand[cargo_id] = max(0.0, demand)

func effective_production(cargo_id: int) -> float:
	var base = float(production_capacity.get(cargo_id, 0.0))
	return base * production_level * clampf(1.0 - war_damage, 0.05, 1.0)

func apply_war_damage(amount: float) -> void:
	war_damage = clampf(war_damage + maxf(0.0, amount), 0.0, 0.95)

func repair_war_damage(amount: float) -> void:
	war_damage = maxf(0.0, war_damage - maxf(0.0, amount))

func produce_day() -> void:
	if not active:
		return
	for cid in production_capacity.keys():
		var produced = effective_production(cid)
		# Bounded inventory prevents an unused cargo from growing without limit.
		var stock_limit: float = maxf(20.0, float(production_capacity[cid]) * production_level * 30.0)
		stock[cid] = min(stock_limit, float(stock.get(cid, 0.0)) + produced)

func begin_day() -> void:
	had_transport_today = false

func take_stock(cargo_id: int, amount: float) -> float:
	var available = float(stock.get(cargo_id, 0.0))
	var taken = min(available, max(0.0, amount))
	stock[cargo_id] = available - taken
	return taken

func add_shipper_profit(amount: float) -> void:
	if amount > 0.0:
		had_transport_today = true
		accumulated_profit += amount
		recent_transport_days += 1
		stagnation_days = 0
	else:
		stagnation_days += 1
		recent_transport_days = max(0, recent_transport_days - 1)

## Issue #7: expand/contract production from transport success
func apply_reinvestment(threshold: float = 15.0, expand_rate: float = 0.04, contract_rate: float = 0.02) -> bool:
	var changed := false
	if not had_transport_today:
		stagnation_days += 1
		recent_transport_days = max(0, recent_transport_days - 1)
	if accumulated_profit >= threshold and production_level < max_production_level:
		var steps = int(accumulated_profit / threshold)
		var gain = expand_rate * float(steps)
		production_level = min(max_production_level, production_level + gain)
		accumulated_profit -= threshold * float(steps)
		changed = true
	elif stagnation_days > 20 and production_level > min_production_level:
		production_level = max(min_production_level, production_level - contract_rate)
		stagnation_days = 0
		changed = true
	return changed

func is_primary_or_secondary() -> bool:
	return facility_type == CargoRegistry.CargoCategory.PRIMARY \
		or facility_type == CargoRegistry.CargoCategory.SECONDARY

func to_dict() -> Dictionary:
	return {
		"id": id,
		"name": name,
		"settlement_id": settlement_id,
		"company_id": company_id,
		"active": active,
		"war_damage": war_damage,
		"production_capacity": production_capacity.duplicate(),
		"stock": stock.duplicate(),
		"consumption_demand": consumption_demand.duplicate(),
		"production_level": production_level,
		"accumulated_profit": accumulated_profit,
		"facility_type": facility_type,
		"generates_passenger_mail": generates_passenger_mail
	}

static func from_dict(d: Dictionary) -> IndustryFacility:
	var f = IndustryFacility.new(
		int(d.get("id", 0)),
		str(d.get("name", "")),
		int(d.get("settlement_id", -1)),
		int(d.get("company_id", -1))
	)
	f.active = bool(d.get("active", true))
	f.war_damage = float(d.get("war_damage", 0.0))
	f.production_capacity = d.get("production_capacity", {}).duplicate()
	f.stock = d.get("stock", {}).duplicate()
	f.consumption_demand = d.get("consumption_demand", {}).duplicate()
	f.production_level = float(d.get("production_level", 1.0))
	f.accumulated_profit = float(d.get("accumulated_profit", 0.0))
	f.facility_type = int(d.get("facility_type", CargoRegistry.CargoCategory.PRIMARY))
	f.generates_passenger_mail = bool(d.get("generates_passenger_mail", true))
	return f

