class_name EconomySystem
extends RefCounted

var world: WorldState
var transport_system: TransportSystem = null

func _init(p_world: WorldState):
	world = p_world

func process_day() -> void:
	_update_demands()
	_apply_external_demand_modifiers()
	if world.economic_core != null:
		world.economic_core.process_pre_transport()
	if transport_system != null:
		transport_system.process_transport()
	else:
		_process_transport()
	if world.economic_core != null:
		world.economic_core.process_post_transport()
	else:
		_apply_growth()
		_maybe_change_economy_state()

func _update_demands() -> void:
	for s in world.settlements:
		if not s.active or s.is_supply_base:
			continue
		var mult = s.get_economy_multiplier()
		s.food_demand = (4.0 + s.population * 0.18) * mult
		s.fuel_demand = (2.0 + s.economy * 0.15) * mult
		s.passenger_demand = (3.0 + s.population * 0.12) * mult
		var destination_count = max(1, s.passenger_destinations.size())
		var per_destination = s.passenger_demand / float(destination_count)
		for dest_id in s.passenger_destinations.keys():
			var variation = 0.85 + world.rng.randf() * 0.30
			s.passenger_destinations[dest_id] = max(0.5, per_destination * variation)

func _apply_external_demand_modifiers() -> void:
	if world.economy_bridge == null:
		return
	for s in world.settlements:
		if not s.active or s.is_supply_base:
			continue
		s.food_demand *= world.economy_bridge.get_demand_multiplier(s.id, "food")
		s.fuel_demand *= world.economy_bridge.get_demand_multiplier(s.id, "fuel")
		s.passenger_demand *= world.economy_bridge.get_demand_multiplier(s.id, "passenger")
		var count: int = maxi(1, s.passenger_destinations.size())
		var per_destination: float = s.passenger_demand / float(count)
		for dest_id in s.passenger_destinations.keys():
			s.passenger_destinations[dest_id] = max(float(s.passenger_destinations[dest_id]), per_destination)

func _process_transport() -> void:
	# Compatibility fallback: use the same unified engine and still call it once.
	var fallback := TransportSystem.new(world)
	fallback.process_transport()

func _find_direct_route(a: int, b: int) -> Route:
	for r in world.routes:
		if r.is_operational(world) and ((r.from_id == a and r.to_id == b) or (r.from_id == b and r.to_id == a)):
			return r
	return null

func _apply_growth() -> void:
	for s in world.settlements:
		if not s.active or s.is_supply_base:
			continue
		var rate = s.get_growth_rate()
		s.population += s.population * rate * 0.3
		s.economy += s.economy * rate * 0.25
		s.food_supply_capacity = min(s.food_supply_capacity + 1.5 + s.population * 0.02, 40.0 + s.population * 0.5)
		s.fuel_supply_capacity = min(s.fuel_supply_capacity + 0.8 + s.economy * 0.015, 25.0 + s.economy * 0.4)
		s.population = clamp(s.population, 2.0, 200.0)
		s.economy = clamp(s.economy, 1.0, 180.0)

func _maybe_change_economy_state() -> void:
	if world.day % 18 != 0:
		return
	for s in world.settlements:
		if not s.active or s.is_supply_base:
			continue
		var roll = world.rng.randf()
		var old = s.economy_state
		if roll < 0.18:
			s.economy_state = Settlement.EconomyState.BOOM
		elif roll < 0.38:
			s.economy_state = Settlement.EconomyState.RECESSION
		else:
			s.economy_state = Settlement.EconomyState.NORMAL
		if s.economy_state != old:
			world.add_event("%sが%s入り" % [s.name, ["好況", "平常", "不況"][s.economy_state]])
