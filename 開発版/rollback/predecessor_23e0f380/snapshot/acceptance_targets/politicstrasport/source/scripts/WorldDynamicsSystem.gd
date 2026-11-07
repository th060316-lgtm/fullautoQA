class_name WorldDynamicsSystem
extends RefCounted

## Work-owned daily coordinator for Issues #8-#15. It never calls
## TransportSystem.process_transport(); EconomySystem remains its sole owner.

var world: WorldState
var bridge: EconomyBridge
var diagnostics: SimulationDiagnostics
var political: PoliticalLogisticsSystem
var front: WarFrontSystem
var impact: WarImpactSystem
var nations: NationLifecycleSystem
var companies: CompanyLifecycleSystem
var corporate: CorporateSystem
var intervention: PlayerInterventionSystem

func _init(p_world: WorldState, war_policy: WarSupplyPolicy) -> void:
	world = p_world
	bridge = EconomyBridge.new(world)
	diagnostics = SimulationDiagnostics.new(world)
	political = PoliticalLogisticsSystem.new(world, bridge, diagnostics)
	front = WarFrontSystem.new(world, diagnostics, war_policy)
	impact = WarImpactSystem.new(world, bridge, diagnostics)
	nations = NationLifecycleSystem.new(world, diagnostics)
	companies = CompanyLifecycleSystem.new(world, diagnostics)
	corporate = CorporateSystem.new(world, diagnostics)
	intervention = PlayerInterventionSystem.new(world, bridge, diagnostics, corporate)
	political.initialize_profiles()
	world.economy_bridge = bridge
	world.diagnostics = diagnostics

func process_pre_transport() -> void:
	# Demand modifiers must exist before EconomySystem rebuilds and transports demand.
	political.process_day()
	front.process_day()

func process_post_transport() -> void:
	# World consequences and company/capital changes consume today's transport result.
	impact.process_day()
	nations.process_day()
	companies.process_day()
	corporate.process_day()
	intervention.process_day()
	diagnostics.capture_route_changes()
	_validate_finite_state()

func set_economy_delegate(delegate: Object) -> void:
	bridge.set_delegate(delegate)

func _validate_finite_state() -> void:
	# Clamp corrupt values at the boundary and make the reason visible.
	for s in world.settlements:
		if not is_finite(s.population) or not is_finite(s.economy):
			s.population = 5.0
			s.economy = 3.0
			diagnostics.record("integrity", "%sの非有限値を隔離" % s.name, 3)
	for c in world.companies:
		if not is_finite(c.money):
			c.money = 0.0
			diagnostics.record("integrity", "%sの非有限会計値を隔離" % c.company_name, 3)
	world.sync_player_company_money()

func is_finite(value: float) -> bool:
	return not is_nan(value) and not is_inf(value)
