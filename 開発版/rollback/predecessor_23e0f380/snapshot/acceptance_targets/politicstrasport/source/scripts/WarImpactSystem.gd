class_name WarImpactSystem
extends RefCounted

var world: WorldState
var bridge: EconomyBridge
var diagnostics: SimulationDiagnostics

func _init(p_world: WorldState, p_bridge: EconomyBridge, p_diagnostics: SimulationDiagnostics) -> void:
	world = p_world
	bridge = p_bridge
	diagnostics = p_diagnostics

func process_day() -> void:
	if world.war_active:
		_apply_wartime_demand()
		if world.day % 6 == 0:
			_apply_war_damage()
	else:
		_process_reconstruction()
	_decay_refugee_pressure()

func _apply_wartime_demand() -> void:
	for s in world.settlements:
		if not s.active or s.is_supply_base:
			continue
		if s.nation_id in [world.war_nation_a, world.war_nation_b]:
			s.military_demand = min(30.0, s.military_demand + 0.8)
			s.food_demand += 0.25 * bridge.get_demand_multiplier(s.id, "military")
			s.fuel_demand += 0.20 * bridge.get_demand_multiplier(s.id, "military")
			if world.economic_core != null and s.military_demand >= 4.0:
				world.economic_core.ensure_contextual_facility(
					s.id, CargoRegistry.CargoKind.INDUSTRIAL,
					2.0 + s.military_demand * 0.08, "軍需工業",
					CargoRegistry.CargoCategory.SECONDARY)

func _apply_war_damage() -> void:
	var candidates: Array = []
	for s in world.settlements:
		if s.active and not s.is_supply_base and s.nation_id in [world.war_nation_a, world.war_nation_b]:
			candidates.append(s)
	if candidates.is_empty():
		return
	var target = candidates[world.rng.randi_range(0, candidates.size() - 1)]
	var damage := world.rng.randf_range(0.04, 0.12)
	target.war_damage = clamp(target.war_damage + damage, 0.0, 0.9)
	target.infrastructure_damage = clamp(target.infrastructure_damage + damage * 0.8, 0.0, 0.9)
	target.reconstruction_progress = 1.0 - target.war_damage
	var displaced: float = maxf(0.0, float(target.population) * damage * 0.18)
	target.population = max(2.0, target.population - displaced)
	target.economy = max(1.0, target.economy * (1.0 - damage * 0.4))
	target.reconstruction_demand = min(40.0, target.reconstruction_demand + damage * 25.0)
	_send_refugees(target, displaced)
	if world.economic_core != null:
		world.economic_core.apply_facility_damage(target.id, damage * 1.4)
	bridge.notify_regional_shock(target.id, "war_damage", damage)
	diagnostics.record("war_damage", "%sで略奪・施設被害、避難民%.1f" % [target.name, displaced], 2,
		{"settlement_id": target.id, "damage": damage, "displaced": displaced})

func _send_refugees(origin, amount: float) -> void:
	if amount <= 0.0:
		return
	var destinations: Array = []
	for s in world.settlements:
		if s.active and not s.is_supply_base and s.id != origin.id and s.war_damage < origin.war_damage:
			destinations.append(s)
	if destinations.is_empty():
		return
	var dst = destinations[world.rng.randi_range(0, destinations.size() - 1)]
	dst.refugee_pressure += amount
	dst.passenger_destinations[origin.id] = float(dst.passenger_destinations.get(origin.id, 0.0)) + amount

func _process_reconstruction() -> void:
	for s in world.settlements:
		if not s.active or s.is_supply_base:
			continue
		if s.war_damage <= 0.001:
			s.military_demand = max(0.0, s.military_demand - 0.25)
			continue
		var pace: float = 0.003 + minf(0.006, float(s.reconstruction_demand) * 0.00025)
		s.war_damage = max(0.0, s.war_damage - pace)
		s.infrastructure_damage = max(0.0, s.infrastructure_damage - pace * 0.8)
		s.reconstruction_progress = 1.0 - s.war_damage
		s.reconstruction_demand = max(0.0, s.reconstruction_demand - pace * 2.0)
		s.food_demand += 0.05
		s.fuel_demand += 0.08
		if world.economic_core != null:
			# Industrial cargo represents construction materials/machinery in this Logic Prototype.
			world.economic_core.repair_facility_damage(s.id, pace * 0.65)
		if world.day % 20 == 0:
			diagnostics.record("reconstruction", "%sの長期復興が進展" % s.name, 1,
				{"settlement_id": s.id, "progress": s.reconstruction_progress})

func _decay_refugee_pressure() -> void:
	for s in world.settlements:
		if s.refugee_pressure > 0.0:
			var settled: float = minf(float(s.refugee_pressure), 0.08)
			s.refugee_pressure -= settled
			s.population += settled * 0.25
