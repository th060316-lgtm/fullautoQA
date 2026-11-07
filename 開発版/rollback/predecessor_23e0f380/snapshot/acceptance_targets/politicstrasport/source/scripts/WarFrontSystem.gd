class_name WarFrontSystem
extends RefCounted

var world: WorldState
var diagnostics: SimulationDiagnostics
var war_policy: WarSupplyPolicy
var front_progress: float = 0.0
var last_war_pair: String = ""

func _init(p_world: WorldState, p_diagnostics: SimulationDiagnostics, p_policy: WarSupplyPolicy) -> void:
	world = p_world
	diagnostics = p_diagnostics
	war_policy = p_policy

func process_day() -> void:
	_reset_route_disruptions()
	if not world.war_active:
		front_progress = move_toward(front_progress, 0.0, 0.08)
		return
	var pair := "%d:%d" % [world.war_nation_a, world.war_nation_b]
	if pair != last_war_pair:
		front_progress = 0.0
		last_war_pair = pair
	if world.day % 3 == 0:
		_move_front()
	_apply_occupation_and_disruption()

func _move_front() -> void:
	var a = world.get_nation(world.war_nation_a)
	var b = world.get_nation(world.war_nation_b)
	if a == null or b == null:
		return
	var score_a: float = float(a.military_rating) + float(a.war_bonus) * 10.0
	var score_b: float = float(b.military_rating) + float(b.war_bonus) * 10.0
	var drift: float = clampf((score_a - score_b) / maxf(20.0, score_a + score_b), -0.16, 0.16)
	drift += world.rng.randf_range(-0.05, 0.05)
	front_progress = clamp(front_progress + drift, -1.0, 1.0)
	if war_policy != null and war_policy.has_method("relocate_supply_bases"):
		war_policy.relocate_supply_bases(front_progress)
	else:
		_relocate_supply_bases_fallback()
	diagnostics.record("front", "前線移動 %.0f%%" % (front_progress * 100.0), 1,
		{"progress": front_progress})

func _relocate_supply_bases_fallback() -> void:
	var cities_a: Array = []
	var cities_b: Array = []
	for s in world.settlements:
		if not s.active or s.is_supply_base:
			continue
		if s.nation_id == world.war_nation_a:
			cities_a.append(s)
		elif s.nation_id == world.war_nation_b:
			cities_b.append(s)
	if cities_a.is_empty() or cities_b.is_empty():
		return
	var ca := _center(cities_a)
	var cb := _center(cities_b)
	for base_id in world.war_supply_base_ids:
		var base = world.get_settlement(base_id)
		if base == null:
			continue
		if base.support_nation_id == world.war_nation_a:
			base.position = ca.lerp(cb, clamp(0.25 + front_progress * 0.15, 0.08, 0.45))
		elif base.support_nation_id == world.war_nation_b:
			base.position = cb.lerp(ca, clamp(0.25 - front_progress * 0.15, 0.08, 0.45))
	if world.ground != null:
		world.ground.assign_terminals()

func _center(cities: Array) -> Vector2:
	var result := Vector2.ZERO
	for s in cities:
		result += s.position
	return result / float(maxi(1, cities.size()))

func _apply_occupation_and_disruption() -> void:
	var attacker_id := world.war_nation_a if front_progress >= 0.0 else world.war_nation_b
	var defender_id := world.war_nation_b if front_progress >= 0.0 else world.war_nation_a
	var pressure: float = absf(front_progress)
	for s in world.settlements:
		if not s.active or s.is_supply_base:
			continue
		s.transport_disruption = 0.0
		if s.nation_id == defender_id and pressure > 0.35:
			s.occupied_by_nation_id = attacker_id if pressure > 0.72 else -1
			s.transport_disruption = clamp(pressure * 0.75, 0.0, 0.85)
			s.port_blockaded = s.has_port and pressure > 0.55
		else:
			s.occupied_by_nation_id = -1
			s.port_blockaded = false
	for r in world.routes:
		if not r.active:
			continue
		var a = world.get_settlement(r.from_id)
		var b = world.get_settlement(r.to_id)
		if a == null or b == null:
			continue
		var disruption: float = maxf(float(a.transport_disruption), float(b.transport_disruption))
		if r.type == Route.RouteType.SHIP and (a.port_blockaded or b.port_blockaded):
			r.route_value_multiplier = 0.0
			r.disruption_reason = "港湾封鎖"
		elif disruption > 0.0:
			r.route_value_multiplier = clamp(1.0 - disruption, 0.15, 1.0)
			r.disruption_reason = "前線・占領地の交通遮断"

func _reset_route_disruptions() -> void:
	for r in world.routes:
		r.route_value_multiplier = 1.0
		r.disruption_reason = ""
	for s in world.settlements:
		if not world.war_active:
			s.port_blockaded = false
			s.transport_disruption = max(0.0, s.transport_disruption - 0.05)

func get_front_progress() -> float:
	return front_progress

func set_front_progress(value: float) -> void:
	front_progress = clampf(value, -1.0, 1.0)
	last_war_pair = "%d:%d" % [world.war_nation_a, world.war_nation_b]
	_apply_occupation_and_disruption()
