extends SceneTree

var failures: Array[String] = []
var passes: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func _ok(condition: bool, label: String) -> void:
	if condition:
		passes.append(label)
		print("PASS: ", label)
	else:
		failures.append(label)
		push_error("FAIL: " + label)

func _run() -> void:
	var world := WorldState.new(20261031)
	world.create_initial_world()
	world.economic_core = EconomicCore.new(world)
	world.economic_core.bootstrap_from_settlements()
	var economy := EconomySystem.new(world)
	var politics := PoliticalSystem.new(world)
	var war := WarSystem.new(world)
	var transport := TransportSystem.new(world)
	transport.war_policy = war.war_policy
	economy.transport_system = transport
	var ship := ShipSystem.new(world)
	var air := AirSystem.new(world)
	var ai := AICompetitionSystem.new(world)
	ai.setup(ship, air)
	ai.configure_ground_provider(world.ground)
	ai.create_ai_companies()
	var dynamics := WorldDynamicsSystem.new(world, war.war_policy)
	dynamics.set_economy_delegate(world.economic_core)
	_ok(world.economy_bridge.diagnostic_snapshot().get("cargo_registry_connected", false), "#4 economic core connected through stable bridge")

	# Phase B: politics/profile, company lifecycle/capital, player intervention.
	var before_food := dynamics.bridge.get_demand_multiplier(0, "food")
	dynamics.political.set_economic_system(0, Nation.EconomicSystem.PLANNED)
	var after_food := dynamics.bridge.get_demand_multiplier(0, "food")
	_ok(after_food != before_food, "#8 economic system changes logistics demand")
	dynamics.political.set_relation(0, 1, -0.8)
	_ok(world.get_nation(0).policy_state.trade_openness < 1.0, "#8 diplomacy changes trade profile")

	var entrant := dynamics.companies.create_company("test")
	_ok(entrant != null and world.get_company(entrant.company_id) == entrant, "#12 dynamic company entry")
	var entrant2 := dynamics.companies.create_company("test")
	_ok(dynamics.companies.merge_companies(entrant.company_id, entrant2.company_id), "#12 company merger preserves registry")
	_ok(not entrant2.active, "#12 merged company exits active market")
	_ok(dynamics.corporate.create_cooperation(1, entrant.company_id), "#12 cooperative transport relationship")

	world.money = 5000.0
	world.sync_player_company_money()
	var cost_before := world.money
	_ok(dynamics.intervention.support_city(0, 100.0), "#14 city support accepted")
	_ok(is_equal_approx(world.money, cost_before - 100.0), "#14 intervention charged exactly once")
	var facility_id := dynamics.intervention.build_industry_facility(0, "food_processing")
	_ok(facility_id > 0, "#14 player may build industry facility")
	for i in range(13):
		world.day += 1
		dynamics.intervention.process_day()
	var facility := dynamics.intervention.get_facility(facility_id)
	_ok(facility.status == "operating" and int(facility.owner_company_id) == -1, "#14 completed facility transferred, never player-owned")
	_ok(str(facility.operator_id) != "", "#14 local operator automatically assigned")
	_ok(world.economic_core.external_facility_ids.has(facility_id), "#14 transferred facility becomes economic production entity")

	# Phase C: front/blockade, destruction/reconstruction and nation lifecycle.
	war._start_war(0, 1)
	var route := Route.new(world.next_route_id, 0, 2, Route.RouteType.SHIP)
	world.next_route_id += 1
	route.company_id = 0
	world.routes.append(route)
	world.get_settlement(0).has_port = true
	world.get_settlement(2).has_port = true
	dynamics.front.set_front_progress(0.85)
	world.day = 16
	dynamics.front.process_day()
	_ok(route.route_value_multiplier < 1.0 or route.disruption_reason != "", "#9 front/blockade changes route value")
	var base_before = world.get_settlement(world.war_supply_base_ids[0]).position
	world.day = 18
	dynamics.front.process_day()
	var base_after = world.get_settlement(world.war_supply_base_ids[0]).position
	_ok(base_before != base_after, "#9 moving front relocates supply base")

	var pop_before := world.get_settlement(0).population + world.get_settlement(1).population + world.get_settlement(2).population + world.get_settlement(3).population
	dynamics.impact._apply_war_damage()
	var damaged := false
	for s in world.settlements:
		if not s.is_supply_base and s.war_damage > 0.0:
			damaged = true
	_ok(damaged, "#10 war creates city/facility damage")
	var pop_after := world.get_settlement(0).population + world.get_settlement(1).population + world.get_settlement(2).population + world.get_settlement(3).population
	_ok(pop_after <= pop_before, "#10 destruction displaces population")
	war._end_war_cleanup()
	for i in range(30):
		world.day += 1
		dynamics.impact.process_day()
	var reconstruction_seen := false
	for s in world.settlements:
		if not s.is_supply_base and s.reconstruction_progress > 0.1:
			reconstruction_seen = true
	_ok(reconstruction_seen, "#10 long reconstruction state persists")

	var new_nation := dynamics.nations.force_split(0)
	_ok(new_nation >= 0 and world.get_nation(new_nation) != null, "#11 rebellion creates new nation")
	var refs_ok := true
	for s in world.settlements:
		if not s.is_supply_base and world.get_nation(s.nation_id) == null:
			refs_ok = false
	_ok(refs_ok, "#11 settlement nation references remain valid")

	# #13 accounting: dividend is one child debit and one parent credit.
	var child = world.get_company(1)
	child.parent_company_id = 0
	child.money = 1000.0
	child.last_day_revenue = 100.0
	child.last_day_expense = 0.0
	var player_before := world.money
	var child_before: float = float(child.money)
	world.day = 60
	dynamics.corporate.process_day()
	var paid: float = child_before - float(child.money)
	_ok(paid > 0.0 and is_equal_approx(world.money - player_before, paid), "#13 dividend cash transfer balances exactly")

	# 365-day destructive profile, preserving exactly one transport pass per loop.
	var transport_calls_before := transport.process_call_count
	for i in range(365):
		world.day += 1
		dynamics.process_pre_transport()
		economy.process_day()
		politics.process_day()
		war.process_day()
		dynamics.process_post_transport()
		ai.process_day()
	_ok(transport.process_call_count - transport_calls_before == 365, "TransportSystem.process_transport remains exactly once per simulated day")
	var finite := true
	for s in world.settlements:
		finite = finite and not is_nan(s.population) and not is_inf(s.population) and not is_nan(s.economy) and not is_inf(s.economy)
	for c in world.companies:
		finite = finite and not is_nan(c.money) and not is_inf(c.money)
	_ok(finite, "300+ days has no NaN/Inf")
	_ok(dynamics.companies.active_company_count() <= CompanyLifecycleSystem.MAX_ACTIVE_COMPANIES, "300+ days has bounded company count")
	_ok(dynamics.nations.active_nation_count() <= NationLifecycleSystem.MAX_ACTIVE_NATIONS, "300+ days has bounded nation count")
	_ok(world.diagnostics != null and world.diagnostics.events.size() > 0, "#15 diagnostics exposes major change reasons")

	print("PASS COUNT: ", passes.size(), " FAIL COUNT: ", failures.size())
	quit(1 if failures.size() > 0 else 0)
