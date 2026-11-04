class_name NationLifecycleSystem
extends RefCounted

const MAX_ACTIVE_NATIONS := 12
const MIN_REBELLION_INTERVAL := 90

var world: WorldState
var diagnostics: SimulationDiagnostics

func _init(p_world: WorldState, p_diagnostics: SimulationDiagnostics) -> void:
	world = p_world
	diagnostics = p_diagnostics

func process_day() -> void:
	if world.day % 15 != 0:
		return
	_cleanup_relations()
	if active_nation_count() < MAX_ACTIVE_NATIONS:
		for n in world.nations.duplicate():
			if n.active and _should_rebel(n):
				_split_nation(n)
				break
	if world.day % 120 == 0:
		_maybe_integrate_nations()

func _should_rebel(nation) -> bool:
	if nation.stability >= 0.34 or world.day - nation.last_rebellion_day < MIN_REBELLION_INTERVAL:
		return false
	var city_count := 0
	for s in world.settlements:
		if s.active and not s.is_supply_base and s.nation_id == nation.id:
			city_count += 1
	return city_count >= 2 and world.rng.randf() < 0.45

func force_split(nation_id: int) -> int:
	var n = world.get_nation(nation_id)
	if n == null or not n.active or active_nation_count() >= MAX_ACTIVE_NATIONS:
		return -1
	return _split_nation(n)

func _split_nation(parent) -> int:
	var cities: Array = []
	for s in world.settlements:
		if s.active and not s.is_supply_base and s.nation_id == parent.id:
			cities.append(s)
	if cities.size() < 2:
		return -1
	var capital = cities[cities.size() - 1]
	var id := world.next_nation_id
	world.next_nation_id += 1
	var col: Color = parent.color.lightened(0.22)
	var rebel := Nation.new(id, "%s自由国" % capital.name, col)
	rebel.parent_nation_id = parent.id
	rebel.founded_day = world.day
	rebel.stability = 0.52
	rebel.economic_system = parent.economic_system
	rebel.policy_state = parent.policy_state.duplicate(true)
	world.nations.append(rebel)
	capital.nation_id = id
	parent.last_rebellion_day = world.day
	parent.stability = min(0.55, parent.stability + 0.08)
	for n in world.nations:
		if n.id != id and n.active:
			rebel.set_relation(n.id, -0.15 if n.id == parent.id else 0.0)
			n.set_relation(id, rebel.get_relation(n.id))
	parent.recalculate_power(world.settlements)
	rebel.recalculate_power(world.settlements)
	if world.ground != null:
		world.ground.paint_nation_ownership_from_settlements()
	diagnostics.record("nation", "%sで反乱、新国家%sが成立" % [parent.name, rebel.name], 3,
		{"old_nation_id": parent.id, "new_nation_id": id, "settlement_id": capital.id})
	return id

func integrate_nations(winner_id: int, absorbed_id: int) -> bool:
	var winner = world.get_nation(winner_id)
	var absorbed = world.get_nation(absorbed_id)
	if winner == null or absorbed == null or not winner.active or not absorbed.active or winner_id == absorbed_id:
		return false
	for s in world.settlements:
		if s.nation_id == absorbed_id:
			s.nation_id = winner_id
		if s.support_nation_id == absorbed_id:
			s.support_nation_id = winner_id
	absorbed.active = false
	absorbed.is_at_war = false
	absorbed.war_opponent_id = -1
	winner.recalculate_power(world.settlements)
	if world.ground != null:
		world.ground.paint_nation_ownership_from_settlements()
	diagnostics.record("nation", "%sが%sを統合、所属参照を再接続" % [winner.name, absorbed.name], 3,
		{"winner": winner_id, "absorbed": absorbed_id})
	return true

func _maybe_integrate_nations() -> void:
	var active: Array = []
	for n in world.nations:
		if n.active:
			active.append(n)
	for a in active:
		for b in active:
			if b.id <= a.id:
				continue
			if a.get_relation(b.id) > 0.9 and min(a.power, b.power) < max(a.power, b.power) * 0.35:
				integrate_nations(a.id if a.power >= b.power else b.id, b.id if a.power >= b.power else a.id)
				return

func _cleanup_relations() -> void:
	var valid: Dictionary = {}
	for n in world.nations:
		if n.active:
			valid[n.id] = true
	for n in world.nations:
		for other_id in n.diplomatic_relations.keys():
			if not valid.has(other_id):
				n.diplomatic_relations.erase(other_id)

func active_nation_count() -> int:
	var count := 0
	for n in world.nations:
		if n.active:
			count += 1
	return count
