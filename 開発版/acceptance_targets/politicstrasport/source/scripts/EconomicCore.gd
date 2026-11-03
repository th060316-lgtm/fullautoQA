class_name EconomicCore
extends RefCounted

## Orchestrator for Issues #4–#7 and #15 diagnostic backend.
## Designed to be owned/called from EconomySystem or GameController
## without replacing the existing transport pipeline.

var world: WorldState
var registry: CargoRegistry
var diagnostics: EconomicDiagnostics

var facilities: Array = []           # Array of IndustryFacility
var industry_companies: Array = []   # Array of IndustryCompany
var markets: Dictionary = {}         # key "sid_cid" -> MarketDemand
var regional: Dictionary = {}        # settlement_id -> RegionalEconomy
var external_facility_ids: Dictionary = {} # Work facility id -> EconomicCore facility id
var prepared_day: int = -1
var completed_day: int = -1

var next_facility_id: int = 1
var next_industry_company_id: int = 1

# Config knobs
var enable_industry_split: bool = true
var shipper_profit_share: float = 0.35  # fraction of transport revenue that accrues to shipper/facility

func _init(p_world: WorldState):
	world = p_world
	registry = CargoRegistry.new()
	diagnostics = EconomicDiagnostics.new()

func key_market(settlement_id: int, cargo_id: int) -> String:
	return "%d_%d" % [settlement_id, cargo_id]

func get_or_create_market(settlement_id: int, cargo_id: int) -> MarketDemand:
	var k = key_market(settlement_id, cargo_id)
	if not markets.has(k):
		markets[k] = MarketDemand.new(settlement_id, cargo_id)
	return markets[k]

func get_or_create_regional(settlement_id: int) -> RegionalEconomy:
	if not regional.has(settlement_id):
		regional[settlement_id] = RegionalEconomy.new(settlement_id)
	return regional[settlement_id]

func get_facility(id: int) -> IndustryFacility:
	for f in facilities:
		if f.id == id:
			return f
	return null

func get_industry_company(id: int) -> IndustryCompany:
	for c in industry_companies:
		if c.id == id:
			return c
	return null

func facilities_at(settlement_id: int) -> Array:
	var out: Array = []
	for f in facilities:
		if f.active and f.settlement_id == settlement_id:
			out.append(f)
	return out

## Bootstrap: create industry facilities from existing settlement supply capacities
## so legacy worlds keep working and new cargo can be produced.
func bootstrap_from_settlements() -> void:
	for s in world.settlements:
		if not s.active:
			continue
		get_or_create_regional(s.id)
		# Legacy food/fuel supply -> facilities
		if s.food_supply_capacity > 0.5:
			_ensure_primary_facility(s, CargoRegistry.CargoKind.FOOD, s.food_supply_capacity, "食料生産")
		if s.fuel_supply_capacity > 0.5:
			_ensure_primary_facility(s, CargoRegistry.CargoKind.FUEL, s.fuel_supply_capacity, "燃料生産")
		# Deterministic resource/industry seeding keeps every run reproducible.
		if s.population >= 18.0 and s.economy >= 15.0 and s.id % 2 == 0:
			if not _has_cargo_production(s.id, CargoRegistry.CargoKind.WOOD):
				_ensure_primary_facility(s, CargoRegistry.CargoKind.WOOD, 3.0 + s.population * 0.05, "林業")
		if s.economy >= 16.0 and s.id % 3 == 1:
			_ensure_primary_facility(s, CargoRegistry.CargoKind.COAL, 2.0 + s.economy * 0.04, "石炭業")
		if s.economy >= 18.0 and s.id % 3 == 2:
			_ensure_primary_facility(s, CargoRegistry.CargoKind.ORE, 2.0 + s.economy * 0.04, "鉱業")
		if s.economy >= 22.0 and s.population >= 24.0:
			if not _has_cargo_production(s.id, CargoRegistry.CargoKind.INDUSTRIAL):
				var fac = _ensure_primary_facility(s, CargoRegistry.CargoKind.INDUSTRIAL, 2.5 + s.economy * 0.04, "軽工業")
				if fac:
					fac.facility_type = CargoRegistry.CargoCategory.SECONDARY
		if s.economy >= 38.0:
			var luxury = _ensure_primary_facility(s, CargoRegistry.CargoKind.LUXURY, 1.0 + s.economy * 0.02, "高級品工房")
			if luxury:
				luxury.facility_type = CargoRegistry.CargoCategory.TERTIARY

func ensure_contextual_facility(settlement_id: int, cargo_id: int, capacity: float,
		label: String, category: int = CargoRegistry.CargoCategory.SECONDARY) -> int:
	var s = world.get_settlement(settlement_id)
	if s == null or not s.active or s.is_supply_base:
		return -1
	var fac = _ensure_primary_facility(s, cargo_id, capacity, label)
	if fac == null:
		return -1
	fac.facility_type = category
	return fac.id

func apply_facility_damage(settlement_id: int, magnitude: float) -> int:
	var affected := 0
	for fac in facilities_at(settlement_id):
		fac.apply_war_damage(magnitude)
		affected += 1
		if fac.war_damage > 0.25:
			diagnostics.add_event(EconomicDiagnostics.ReasonCategory.WAR_DISRUPTION,
				"%sが戦災で生産低下（損傷%.0f%%）" % [fac.name, fac.war_damage * 100.0],
				{"facility_id": fac.id, "settlement_id": settlement_id, "damage": fac.war_damage})
	return affected

func repair_facility_damage(settlement_id: int, amount: float) -> int:
	var affected := 0
	for fac in facilities_at(settlement_id):
		if fac.war_damage > 0.0:
			fac.repair_war_damage(amount)
			affected += 1
	return affected

func _has_cargo_production(settlement_id: int, cargo_id: int) -> bool:
	for f in facilities_at(settlement_id):
		if f.production_capacity.has(cargo_id):
			return true
	return false

func _ensure_primary_facility(s: Settlement, cargo_id: int, capacity: float, label: String) -> IndustryFacility:
	for f in facilities_at(s.id):
		if f.production_capacity.has(cargo_id):
			f.set_production(cargo_id, max(f.production_capacity[cargo_id], capacity))
			return f
	var company = _ensure_company_for_settlement(s)
	var fac = IndustryFacility.new(next_facility_id, "%s-%s" % [s.name, label], s.id, company.id)
	next_facility_id += 1
	fac.set_production(cargo_id, capacity)
	if cargo_id == CargoRegistry.CargoKind.INDUSTRIAL:
		fac.facility_type = CargoRegistry.CargoCategory.SECONDARY
	else:
		fac.facility_type = CargoRegistry.CargoCategory.PRIMARY
	facilities.append(fac)
	company.add_facility(fac.id)
	diagnostics.add_event(EconomicDiagnostics.ReasonCategory.NEW_FACILITY,
		"%sに%s施設が稼働" % [s.name, registry.get_name(cargo_id)],
		{"settlement_id": s.id, "facility_id": fac.id, "cargo_id": cargo_id})
	return fac

func _ensure_company_for_settlement(s: Settlement) -> IndustryCompany:
	for c in industry_companies:
		if c.active and c.home_settlement_id == s.id:
			return c
	var c = IndustryCompany.new(next_industry_company_id, "%s産業" % s.name, s.id)
	next_industry_company_id += 1
	industry_companies.append(c)
	return c

## Daily production tick for all facilities
func process_production() -> void:
	for f in facilities:
		if f.active:
			f.begin_day()
			f.produce_day()

## Update market capacities from regional / settlement state
func update_markets() -> void:
	for s in world.settlements:
		if not s.active:
			continue
		var reg = get_or_create_regional(s.id)
		var boom = reg.cycle_multiplier()
		var ind_scale = 0.0
		for f in facilities_at(s.id):
			ind_scale += f.production_level
		reg.industry_scale = max(0.5, ind_scale)
		for cid in registry.all_cargo_ids():
			if registry.is_destination_specific(cid) and cid != CargoRegistry.CargoKind.PASSENGER:
				continue  # passenger handled by legacy paths mostly
			var m = get_or_create_market(s.id, cid)
			m.update_capacity(s.population, s.economy, reg.industry_scale, boom)
			# Industrial goods proxy construction materials/machinery and military manufacturing.
			if cid == CargoRegistry.CargoKind.INDUSTRIAL:
				var shock_mult: float = 1.0 + minf(2.5,
					float(s.reconstruction_demand) * 0.045 + float(s.military_demand) * 0.035)
				m.market_capacity *= shock_mult
			m.reset_day()

## Called when general cargo is delivered to a settlement.
## Returns effective unit revenue (base_price * multiplier) for the transport company share.
## Also credits shipper profit and regional scores.
func on_general_cargo_delivered(
		settlement_id: int,
		cargo_id: int,
		amount: float,
		base_unit_price: float,
		route_id: int = -1,
		source_facility_id: int = -1
	) -> float:
	if amount <= 0.0:
		return 0.0
	var m = get_or_create_market(settlement_id, cargo_id)
	var mult = m.record_delivery(amount)
	var effective_price = base_unit_price * mult
	var total_value = effective_price * amount

	# Diagnostics
	if mult <= m.price_floor_ratio * 1.05:
		diagnostics.tag_route_reason(route_id, EconomicDiagnostics.ReasonCategory.PRICE_FLOOR)
		diagnostics.add_event(EconomicDiagnostics.ReasonCategory.PRICE_FLOOR,
			"%s向け%sが再流通フロア付近 (x%.2f)" % [
				_settlement_name(settlement_id), registry.get_name(cargo_id), mult],
			{"settlement_id": settlement_id, "cargo_id": cargo_id, "mult": mult})
	elif mult < 0.75:
		diagnostics.tag_route_reason(route_id, EconomicDiagnostics.ReasonCategory.SATURATION)
		diagnostics.add_event(EconomicDiagnostics.ReasonCategory.SATURATION,
			"%sの%s需要飽和 (x%.2f)" % [
				_settlement_name(settlement_id), registry.get_name(cargo_id), mult],
			{"settlement_id": settlement_id, "cargo_id": cargo_id, "mult": mult, "sat": m.last_saturation})

	# Regional: goods supply -> pop; profit -> economy
	var reg = get_or_create_regional(settlement_id)
	var is_ps = registry.is_primary(cargo_id) or registry.is_secondary(cargo_id)
	reg.record_goods_delivery(amount, is_ps)
	# Shipper side profit (not transport company money)
	var shipper = total_value * shipper_profit_share
	reg.record_profit_inflow(shipper)
	if source_facility_id >= 0:
		var fac = get_facility(source_facility_id)
		if fac:
			fac.add_shipper_profit(shipper)
			var ic = get_industry_company(fac.company_id)
			if ic:
				ic.register_profit(shipper)
	else:
		# Attribute to any local producer of this cargo
		for f in facilities_at(settlement_id):
			if f.production_capacity.has(cargo_id):
				f.add_shipper_profit(shipper * 0.5)
				break

	return effective_price

## Transport revenue helper for legacy FOOD/FUEL path: apply saturation then return revenue.
func compute_saturated_revenue(
		to_settlement_id: int,
		cargo_id: int,
		amount: float,
		mode: int,
		route_id: int = -1,
		source_facility_id: int = -1
	) -> float:
	var base = registry.unit_price(cargo_id, mode)
	var unit = on_general_cargo_delivered(to_settlement_id, cargo_id, amount, base, route_id, source_facility_id)
	return unit * amount

func process_industry_reinvestment() -> void:
	for f in facilities:
		if not f.active or not f.is_primary_or_secondary():
			continue
		var changed = f.apply_reinvestment()
		if changed:
			var cat = EconomicDiagnostics.ReasonCategory.INDUSTRY_EXPAND
			if f.stagnation_days > 0 or f.production_level < 1.0:
				cat = EconomicDiagnostics.ReasonCategory.INDUSTRY_CONTRACT
			diagnostics.add_event(cat,
				"%sの生産水準が%.2fに変化" % [f.name, f.production_level],
				{"facility_id": f.id, "level": f.production_level})
			diagnostics.flag_settlement(f.settlement_id, cat, f.name)

func process_industry_splits(rng: RandomNumberGenerator) -> void:
	if not enable_industry_split:
		return
	var to_add: Array = []
	for c in industry_companies:
		c.days_since_split += 1
		if not c.can_split():
			continue
		if rng.randf() > 0.12:
			continue
		# Split off one facility into a new company
		if c.facility_ids.size() < 2:
			continue
		var split_fid = c.facility_ids[c.facility_ids.size() - 1]
		var fac = get_facility(split_fid)
		if fac == null:
			continue
		var new_c = IndustryCompany.new(next_industry_company_id, "%s分社" % c.name, fac.settlement_id)
		next_industry_company_id += 1
		new_c.parent_company_id = c.id
		new_c.capital = c.capital * 0.35
		c.capital *= 0.65
		c.remove_facility(split_fid)
		c.days_since_split = 0
		new_c.add_facility(split_fid)
		fac.company_id = new_c.id
		to_add.append(new_c)
		diagnostics.add_event(EconomicDiagnostics.ReasonCategory.INDUSTRY_SPLIT,
			"%sが分裂し%sが独立 (施設 %s)" % [c.name, new_c.name, fac.name],
			{"parent_id": c.id, "new_id": new_c.id, "facility_id": fac.id})
		diagnostics.flag_settlement(fac.settlement_id,
			EconomicDiagnostics.ReasonCategory.INDUSTRY_SPLIT, new_c.name)
	for nc in to_add:
		industry_companies.append(nc)

func process_regional_growth() -> void:
	for s in world.settlements:
		if not s.active or s.is_supply_base:
			continue
		var reg = get_or_create_regional(s.id)
		reg.stability = min(1.0, reg.stability + 0.002)
		# Keep legacy economy_state roughly in sync
		reg.sync_from_legacy_economy_state(s.economy_state)
		var deltas = reg.apply_daily_growth(s)
		reg.push_legacy_economy_state(s)
		if abs(deltas.get("pop_delta", 0.0)) > 0.8 or abs(deltas.get("eco_delta", 0.0)) > 0.8:
			# notable growth/decline already reflected in scores
			pass
		if world.rng and reg.maybe_shift_cycle(world.rng, 0.0 if not world.war_active else 0.25):
			diagnostics.add_event(EconomicDiagnostics.ReasonCategory.CYCLE_SHIFT,
				"%sが%sへ移行" % [s.name, reg.cycle_name()],
				{"settlement_id": s.id, "cycle": reg.business_cycle})
			diagnostics.flag_settlement(s.id, EconomicDiagnostics.ReasonCategory.CYCLE_SHIFT, reg.cycle_name())

	# Soft regen of legacy supply capacities from facilities (compat)
	for s in world.settlements:
		if not s.active:
			continue
		var food_cap = 0.0
		var fuel_cap = 0.0
		for f in facilities_at(s.id):
			food_cap += f.effective_production(CargoRegistry.CargoKind.FOOD) + float(f.stock.get(CargoRegistry.CargoKind.FOOD, 0.0)) * 0.1
			fuel_cap += f.effective_production(CargoRegistry.CargoKind.FUEL) + float(f.stock.get(CargoRegistry.CargoKind.FUEL, 0.0)) * 0.1
		if food_cap > 0.0:
			s.food_supply_capacity = max(s.food_supply_capacity, food_cap)
		if fuel_cap > 0.0:
			s.fuel_supply_capacity = max(s.fuel_supply_capacity, fuel_cap)

## Prepare production and price capacity before the single transport pass.
func process_pre_transport() -> void:
	if prepared_day == world.day:
		return
	diagnostics.clear_day(world.day)
	process_production()
	update_markets()
	prepared_day = world.day

## Consume today's delivery results after transport; never calls transport itself.
func process_post_transport() -> void:
	if completed_day == world.day:
		return
	if prepared_day != world.day:
		process_pre_transport()
	process_industry_reinvestment()
	process_industry_splits(world.rng)
	process_regional_growth()
	completed_day = world.day

## Compatibility full step for external callers.
func process_day() -> void:
	process_pre_transport()
	process_post_transport()

func _settlement_name(sid: int) -> String:
	var s = world.get_settlement(sid)
	return s.name if s else ("都市%d" % sid)

## Available general cargo stock at settlement for transport (sum of facility stocks)
func available_stock(settlement_id: int, cargo_id: int) -> float:
	var total = 0.0
	for f in facilities_at(settlement_id):
		total += float(f.stock.get(cargo_id, 0.0))
	# Legacy fallback
	var s = world.get_settlement(settlement_id)
	if s:
		if cargo_id == CargoRegistry.CargoKind.FOOD:
			total = max(total, s.food_supply_capacity)
		elif cargo_id == CargoRegistry.CargoKind.FUEL:
			total = max(total, s.fuel_supply_capacity)
	return total

func take_stock_from_settlement(settlement_id: int, cargo_id: int, amount: float) -> float:
	return float(take_stock_with_source(settlement_id, cargo_id, amount).get("amount", 0.0))

func take_stock_with_source(settlement_id: int, cargo_id: int, amount: float) -> Dictionary:
	var remaining = amount
	var taken = 0.0
	var source_facility_id := -1
	for f in facilities_at(settlement_id):
		if remaining <= 0.0:
			break
		var t = f.take_stock(cargo_id, remaining)
		if t > 0.0 and source_facility_id < 0:
			source_facility_id = f.id
		taken += t
		remaining -= t
	# Legacy drain
	var s = world.get_settlement(settlement_id)
	if s and remaining > 0.0:
		if cargo_id == CargoRegistry.CargoKind.FOOD:
			var t2 = min(remaining, s.food_supply_capacity)
			s.food_supply_capacity -= t2
			taken += t2
		elif cargo_id == CargoRegistry.CargoKind.FUEL:
			var t2 = min(remaining, s.fuel_supply_capacity)
			s.fuel_supply_capacity -= t2
			taken += t2
	return {"amount": taken, "source_facility_id": source_facility_id}

func estimate_pair_extended_demand(a_id: int, b_id: int) -> Dictionary:
	var result: Dictionary = {}
	for cargo_id in registry.all_cargo_ids():
		var cid := int(cargo_id)
		if cid <= CargoRegistry.CargoKind.FUEL or not registry.is_general(cid):
			continue
		var a_to_b: float = minf(available_stock(a_id, cid) * 0.45,
			get_or_create_market(b_id, cid).remaining_soft_capacity())
		var b_to_a: float = minf(available_stock(b_id, cid) * 0.45,
			get_or_create_market(a_id, cid).remaining_soft_capacity())
		var total: float = maxf(0.0, a_to_b + b_to_a)
		if total > 0.01:
			result[cid] = total
	return result

## Work/Grok bridge contract -------------------------------------------------
func get_demand_multiplier(settlement_id: int, cargo_key: String) -> float:
	var cargo_id := CargoRegistry.CargoKind.PASSENGER
	match cargo_key:
		"food": cargo_id = CargoRegistry.CargoKind.FOOD
		"fuel": cargo_id = CargoRegistry.CargoKind.FUEL
		"construction": cargo_id = CargoRegistry.CargoKind.INDUSTRIAL
		"military": cargo_id = CargoRegistry.CargoKind.WAR_SUPPLY
		_: cargo_id = CargoRegistry.CargoKind.PASSENGER
	var market = get_or_create_market(settlement_id, cargo_id)
	return clamp(market.effective_multiplier(), 0.65, 1.25)

func notify_regional_shock(settlement_id: int, category: String, magnitude: float) -> void:
	var reg = get_or_create_regional(settlement_id)
	reg.stability = clamp(reg.stability - abs(magnitude) * 0.15, 0.25, 1.0)
	diagnostics.add_event(EconomicDiagnostics.ReasonCategory.WAR_DISRUPTION,
		"%s: %s shock %.2f" % [_settlement_name(settlement_id), category, magnitude],
		{"settlement_id": settlement_id, "category": category, "magnitude": magnitude})

func choose_facility_operator(settlement_id: int, _facility_type: String) -> String:
	var s = world.get_settlement(settlement_id)
	if s == null:
		return ""
	var company = _ensure_company_for_settlement(s)
	return "industry_company_%d" % company.id

func register_player_built_facility(data: Dictionary) -> void:
	var external_id := int(data.get("id", -1))
	if external_id >= 0 and external_facility_ids.has(external_id):
		return
	var settlement_id := int(data.get("settlement_id", -1))
	var s = world.get_settlement(settlement_id)
	if s == null:
		return
	var company = _ensure_company_for_settlement(s)
	var kind := str(data.get("type", "general"))
	var cargo_id := CargoRegistry.CargoKind.INDUSTRIAL
	if kind.contains("food"):
		cargo_id = CargoRegistry.CargoKind.FOOD
	elif kind.contains("fuel"):
		cargo_id = CargoRegistry.CargoKind.FUEL
	elif kind.contains("wood"):
		cargo_id = CargoRegistry.CargoKind.WOOD
	elif kind.contains("ore"):
		cargo_id = CargoRegistry.CargoKind.ORE
	var fac = IndustryFacility.new(next_facility_id, "%s-%s" % [s.name, kind], s.id, company.id)
	next_facility_id += 1
	fac.set_production(cargo_id, 6.0 + s.economy * 0.03)
	fac.facility_type = CargoRegistry.CargoCategory.SECONDARY
	facilities.append(fac)
	company.add_facility(fac.id)
	if external_id >= 0:
		external_facility_ids[external_id] = fac.id
	diagnostics.add_event(EconomicDiagnostics.ReasonCategory.NEW_FACILITY,
		"%sのプレイヤー建設施設を%sへ移管" % [s.name, company.name],
		{"facility_id": fac.id, "external_id": external_id, "player_owned": false})

func get_diagnostics_snapshot() -> Dictionary:
	return diagnostic_snapshot()

func diagnostic_snapshot() -> Dictionary:
	var snapshot := diagnostics.build_ui_snapshot()
	snapshot["source"] = "grok_economic_core_integrated"
	snapshot["cargo_registry_connected"] = true
	snapshot["facility_count"] = facilities.size()
	snapshot["industry_company_count"] = industry_companies.size()
	var damaged_facilities := 0
	for fac in facilities:
		if fac.active and fac.war_damage > 0.01:
			damaged_facilities += 1
	snapshot["damaged_facility_count"] = damaged_facilities
	return snapshot

func to_dict() -> Dictionary:
	var facs = []
	for f in facilities:
		facs.append(f.to_dict())
	var cos = []
	for c in industry_companies:
		cos.append(c.to_dict())
	var mkts = {}
	for k in markets.keys():
		mkts[k] = markets[k].to_dict()
	var regs = {}
	for k in regional.keys():
		regs[str(k)] = regional[k].to_dict()
	return {
		"facilities": facs,
		"industry_companies": cos,
		"markets": mkts,
		"regional": regs,
		"next_facility_id": next_facility_id,
		"next_industry_company_id": next_industry_company_id
	}

