class_name PoliticalLogisticsSystem
extends RefCounted

var world: WorldState
var bridge: EconomyBridge
var diagnostics: SimulationDiagnostics

func _init(p_world: WorldState, p_bridge: EconomyBridge, p_diagnostics: SimulationDiagnostics) -> void:
	world = p_world
	bridge = p_bridge
	diagnostics = p_diagnostics

func initialize_profiles() -> void:
	for i in range(world.nations.size()):
		var n = world.nations[i]
		n.economic_system = [Nation.EconomicSystem.FREE_MARKET,
			Nation.EconomicSystem.MIXED, Nation.EconomicSystem.PLANNED][i % 3]
		n.logistics_profile = [Nation.LogisticsProfile.INTEGRATION_BLOC,
			Nation.LogisticsProfile.CUSTOMS_UNION, Nation.LogisticsProfile.FRONTIER][i % 3]
		for other in world.nations:
			if other.id != n.id and not n.diplomatic_relations.has(other.id):
				n.set_relation(other.id, 0.1)

func process_day() -> void:
	for n in world.nations:
		if n.active:
			n.recalculate_power(world.settlements)
	if world.day % 45 == 0:
		_roll_policy_shift()
	if world.day % 30 == 0:
		_drift_relations()

func set_economic_system(nation_id: int, system: int) -> bool:
	var n = world.get_nation(nation_id)
	if n == null or not n.active:
		return false
	n.economic_system = clampi(system, Nation.EconomicSystem.FREE_MARKET, Nation.EconomicSystem.FEUDAL)
	diagnostics.record("politics", "%sの経済体制変更で物流需要が変化" % n.name, 2,
		{"nation_id": nation_id, "system": n.economic_system})
	return true

func set_logistics_profile(nation_id: int, profile: int) -> bool:
	var n = world.get_nation(nation_id)
	if n == null or not n.active:
		return false
	n.logistics_profile = clampi(profile, Nation.LogisticsProfile.STANDARD, Nation.LogisticsProfile.FRONTIER)
	diagnostics.record("politics", "%sの政治物流プロファイル変更" % n.name, 2,
		{"nation_id": nation_id, "profile": n.logistics_profile})
	return true

func set_relation(a_id: int, b_id: int, value: float) -> bool:
	var a = world.get_nation(a_id)
	var b = world.get_nation(b_id)
	if a == null or b == null or a_id == b_id:
		return false
	a.set_relation(b_id, value)
	b.set_relation(a_id, value)
	var openness: float = clampf(0.75 + value * 0.35, 0.35, 1.25)
	a.policy_state["trade_openness"] = openness
	b.policy_state["trade_openness"] = openness
	diagnostics.record("diplomacy", "%s・%s間の関係変化が越境物流へ反映" % [a.name, b.name], 2)
	return true

func _roll_policy_shift() -> void:
	var candidates: Array = []
	for n in world.nations:
		if n.active:
			candidates.append(n)
	if candidates.is_empty():
		return
	var n = candidates[world.rng.randi_range(0, candidates.size() - 1)]
	var old := float(n.policy_state.get("trade_openness", 1.0))
	n.policy_state["trade_openness"] = clamp(old + world.rng.randf_range(-0.15, 0.15), 0.55, 1.35)
	if world.rng.randf() < 0.20:
		n.policy_state["construction_support"] = clampf(float(n.policy_state.get("construction_support", 1.0))
			+ world.rng.randf_range(-0.10, 0.12), 0.65, 1.45)
	if world.rng.randf() < 0.15:
		n.policy_state["mail_priority"] = clampf(float(n.policy_state.get("mail_priority", 1.0))
			+ world.rng.randf_range(-0.08, 0.10), 0.70, 1.35)
	diagnostics.record("policy", "%sが物流政策を変更" % n.name, 1, {"nation_id": n.id})

func _drift_relations() -> void:
	for a in world.nations:
		if not a.active:
			continue
		for b in world.nations:
			if b.id <= a.id or not b.active:
				continue
			var next: float = clampf(a.get_relation(b.id) + world.rng.randf_range(-0.04, 0.04), -1.0, 1.0)
			a.set_relation(b.id, next)
			b.set_relation(a.id, next)
