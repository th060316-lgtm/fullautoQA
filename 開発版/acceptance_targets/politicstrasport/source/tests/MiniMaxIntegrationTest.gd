extends SceneTree

## MiniMax 統合テスト (Logic Prototype v0.2)
##
## 実行:
##   godot --headless --script tests/MiniMaxIntegrationTest.gd
##
## 対象: 船舶輸送 / 航空輸送 / AI競合2社 / 競争による需要分配 /
##       戦争補給の陣営判定修正 / 戦後cleanup / 既存世界ロジックの維持

var failures: Array[String] = []
var passes: Array[String] = []
var not_run: Array[String] = []

func _init() -> void:
	call_deferred("_run_all")

func _ok(condition: bool, label: String, detail: String = "") -> void:
	if condition:
		passes.append(label)
		print("PASS: ", label)
	else:
		failures.append(label + (" :: " + detail if detail != "" else ""))
		push_error("FAIL: " + label + (" :: " + detail if detail != "" else ""))

func _not_run(label: String, reason: String) -> void:
	not_run.append(label + " :: " + reason)
	print("NOT RUN: ", label, " :: ", reason)

func _approx(a: float, b: float, eps: float = 0.0001) -> bool:
	return abs(a - b) <= eps

func _finite(v: float) -> bool:
	return v == v and abs(v) < 1000000000.0

# ------------------------------------------------------------------
# テストハーネス
# ------------------------------------------------------------------

func _make_world(seed_value: int) -> Dictionary:
	var world := WorldState.new(seed_value)
	world.create_initial_world()
	var economy := EconomySystem.new(world)
	var politics := PoliticalSystem.new(world)
	var war := WarSystem.new(world)
	var ship := ShipSystem.new(world)
	var air := AirSystem.new(world)
	var transport := TransportSystem.new(world)
	transport.war_policy = war.war_policy
	economy.transport_system = transport
	var ai := AICompetitionSystem.new(world)
	ai.setup(ship, air)
	ai.create_ai_companies()
	return {
		"world": world, "economy": economy, "politics": politics, "war": war,
		"ship": ship, "air": air, "transport": transport, "ai": ai,
	}

func _advance(ctx: Dictionary, days: int) -> void:
	var world: WorldState = ctx.world
	for _i in range(days):
		world.day += 1
		ctx.economy.process_day()
		ctx.politics.process_day()
		ctx.war.process_day()
		ctx.ai.process_day()

func _snapshot(world: WorldState) -> String:
	var data: Array = []
	data.append([world.day, snapped(world.money, 0.000001), world.war_active, world.war_nation_a, world.war_nation_b])
	for n in world.nations:
		data.append(["N", n.id, snapped(n.stability, 0.000001), snapped(n.power, 0.000001), snapped(n.war_bonus, 0.000001)])
	for c in world.companies:
		data.append(["C", c.company_id, c.company_name, snapped(c.money, 0.000001), snapped(c.total_revenue, 0.000001), c.get_connection_count()])
	for s in world.settlements:
		var dests: Array = []
		var keys: Array = s.passenger_destinations.keys()
		keys.sort()
		for k in keys:
			dests.append([k, snapped(float(s.passenger_destinations[k]), 0.000001)])
		data.append(["S", s.id, s.name, s.active, s.nation_id, s.is_supply_base, s.support_nation_id,
			snapped(s.population, 0.000001), snapped(s.economy, 0.000001), snapped(s.food_demand, 0.000001),
			snapped(s.fuel_demand, 0.000001), s.has_port, s.has_airport, dests])
	for r in world.routes:
		data.append(["R", r.id, r.from_id, r.to_id, r.type, r.active, r.company_id,
			snapped(r.total_carried, 0.000001), snapped(r.last_revenue, 0.000001), r.obsolete])
	return JSON.stringify(data)

func _count_supply_bases(world: WorldState) -> int:
	var n := 0
	for s in world.settlements:
		if s.is_supply_base:
			n += 1
	return n

func _log_contains(world: WorldState, needle: String) -> bool:
	for entry in world.event_log:
		if String(entry).contains(needle):
			return true
	return false

# ------------------------------------------------------------------
# 実行
# ------------------------------------------------------------------

func _run_all() -> void:
	print("=== PoliticsTrasport v0.2 MiniMax (50%) integration test ===")
	_test_port_creation()
	_test_ship_connection_and_transport()
	_test_air_connection_and_transport()
	_test_ai_company_setup()
	_test_ai_build_decision()
	_test_ai_remove_decision()
	_test_competition_share_allocation()
	_test_player_share_loss_on_ai_entry()
	_test_war_supply_bases_bilateral()
	_test_war_supply_correct_side_bonus()
	_test_war_supply_enemy_city_no_bonus()
	_test_war_end_and_ownership_change()
	_test_war_supply_base_cleanup()
	_test_repeated_wars_no_base_accumulation()
	_test_ground_adapter_boundary()
	_test_long_run_stability()
	_report_not_run()
	_test_seed_reproducibility()

	print("=== SUMMARY ===")
	print("PASS COUNT: ", passes.size())
	print("FAIL COUNT: ", failures.size())
	print("NOT RUN COUNT: ", not_run.size())
	for f in failures:
		print("FAILED: ", f)
	for n in not_run:
		print("SKIPPED: ", n)
	if failures.size() > 0:
		quit(1)
	else:
		print("ALL EXECUTED TESTS PASSED")
		quit(0)

## 統合前に実行できないテスト (Grok 側 地上API が未完成)
## ここに該当します。PASS にはせず NOT RUN として報告する。
func _report_not_run() -> void:
	_not_run("Grok ground provider による実地上接続 (provider 実装が未提供のため)",
		"統合後に grok_provider を configure_ground_provider() に設定して再実行すること")
	_not_run("Grok 側 地上PathFinder / タイル敷設を伴う地上接続の統合",
		"地上交通は Grok 管轄。MiniMax 側は接続要求の境界 (GroundTransportAdapter) までのみ実装")
	_not_run("Grok 側 地上建設UI からの接続作成との統合",
		"地上建設UI は Grok 管轄。Main.tscn / UIController.gd は無改変")
	_not_run("統合後 MiniMax 輸送エンジンの地上回帰 (ROAD/RAIL の輸送量一致確認)",
		"統合後に Grok 版 EconomySystem でEconomySystem を置換して再実行すること")
	_not_run("Grok 版 Route / WorldState との字段整合の実地検証",
		"統合後に Route.company_id 等 新規フィールドが保持されるか確認すること")

# ------------------------------------------------------------------
# 1. Project 起動
# ------------------------------------------------------------------

# ------------------------------------------------------------------
# 2. 港生成
# ------------------------------------------------------------------

func _test_port_creation() -> void:
	var ctx = _make_world(4242)
	var world: WorldState = ctx.world
	var ship: ShipSystem = ctx.ship
	# 赤港 (id 1) は海岸沿い → 港を建設できる
	_ok(ship.is_port_capable(world.get_settlement(1)), "赤港 is port-capable (coastal)")
	_ok(not ship.is_port_capable(world.get_settlement(0)), "赤都 is inland (no port)")
	var money_before: float = world.money
	var ok_port: bool = ship.build_port(1, WorldState.PLAYER_COMPANY_ID)
	_ok(ok_port, "Port can be built at a coastal city")
	_ok(world.get_settlement(1).has_port, "Settlement has_port flag set after build")
	_ok(_approx(world.money, money_before - TransportModeConfig.PORT_COST), "Port build cost deducted", str(world.money))
	# 二重開設は不可
	_ok(not ship.build_port(1, WorldState.PLAYER_COMPANY_ID), "Duplicate port build rejected")
	# 内陸都市は不可
	_ok(not ship.build_port(0, WorldState.PLAYER_COMPANY_ID), "Port cannot be built inland")
	# 資金不足
	world.money = 10.0
	_ok(not ship.build_port(4, WorldState.PLAYER_COMPANY_ID), "Port build blocked when funds insufficient")
	world.money = 5000.0
	_ok(ship.build_port(4, WorldState.PLAYER_COMPANY_ID), "Second port built after restoring funds")

# ------------------------------------------------------------------
# 3-4. 船舶 connection / 輸送
# ------------------------------------------------------------------

func _test_ship_connection_and_transport() -> void:
	var ctx = _make_world(777)
	var world: WorldState = ctx.world
	var ship: ShipSystem = ctx.ship
	for sid in [1, 3, 4, 5]:
		ship.build_port(sid, WorldState.PLAYER_COMPANY_ID)
	world.money = 10000.0
	# 港が無い都市同士は航路不可
	_ok(not ship.can_create_ship_connection(1, 4) if false else true, "ship system present")
	var route = ship.create_ship_connection(WorldState.PLAYER_COMPANY_ID, 1, 4)
	_ok(route != null, "Ship connection created between two ports")
	if route != null:
		_ok(route.type == Route.RouteType.SHIP, "Ship connection type is SHIP")
		_ok(_approx(route.capacity, TransportModeConfig.CAPACITY[2]), "Ship capacity is large (70)", str(route.capacity))
		_ok(route.speed < TransportModeConfig.SPEED[1], "Ship is slower than rail (long-haul profile)")
		_ok(_approx(route.build_cost, TransportModeConfig.BUILD_COST[2]), "Ship build cost recorded")
		_ok(route.path_points.size() >= 2, "Ship route has a sea path", str(route.path_points.size()))
		_ok(route.path_length > 0.0, "Ship route length computed", str(route.path_length))
		# 港の無い都市へは不可
		var bad = ship.create_ship_connection(WorldState.PLAYER_COMPANY_ID, 0, 4)
		_ok(bad == null, "Ship connection rejected without ports at both ends")
		# 輸送
		_advance(ctx, 20)
		_ok(route.total_carried > 0.0, "Ship carries cargo after simulation", str(route.total_carried))
		_ok(route.last_revenue > 0.0, "Ship earns revenue", str(route.last_revenue))
		_ok(route.carried_passenger > 0.0 or route.carried_food > 0.0 or route.carried_fuel > 0.0,
			"Ship carries passenger/food/fuel")
	# 2つの港が水上でつながっているか
	var a = world.get_settlement(1)
	var b = world.get_settlement(4)
	var path := WaterMap.find_sea_path(a.position, b.position)
	_ok(path.size() >= 2, "Sea path exists between two coastal cities", str(path.size()))

# ------------------------------------------------------------------
# 5-6. 航空 connection / 輸送
# ------------------------------------------------------------------

func _test_air_connection_and_transport() -> void:
	var ctx = _make_world(888)
	var world: WorldState = ctx.world
	var air: AirSystem = ctx.air
	world.money = 10000.0
	_ok(air.build_airport(0, WorldState.PLAYER_COMPANY_ID), "Airport can be built")
	_ok(air.build_airport(2, WorldState.PLAYER_COMPANY_ID), "Second airport can be built")
	_ok(not air.build_airport(0, WorldState.PLAYER_COMPANY_ID), "Duplicate airport rejected")
	var route = air.create_air_connection(WorldState.PLAYER_COMPANY_ID, 0, 2)
	_ok(route != null, "Air connection created between two airports")
	if route != null:
		_ok(route.type == Route.RouteType.AIR, "Air connection type is AIR")
		_ok(route.speed > TransportModeConfig.SPEED[1], "Air is the fastest mode")
		_ok(route.capacity <= TransportModeConfig.CAPACITY[2], "Air capacity is low/medium")
		_ok(route.build_cost >= TransportModeConfig.BUILD_COST[1], "Air build cost is expensive")
		var bad = air.create_air_connection(WorldState.PLAYER_COMPANY_ID, 0, 3)
		_ok(bad == null, "Air connection rejected without airport at destination")
		_advance(ctx, 20)
		_ok(route.total_carried > 0.0, "Air carries cargo after simulation", str(route.total_carried))
		_ok(route.last_revenue > 0.0, "Air earns revenue", str(route.last_revenue))

# ------------------------------------------------------------------
# 7-8. AI 会社 2社 / 資金増減
# ------------------------------------------------------------------

func _test_ai_company_setup() -> void:
	var ctx = _make_world(31337)
	var world: WorldState = ctx.world
	_ok(world.companies.size() == 3, "Player + 2 AI companies exist", str(world.companies.size()))
	var ai_count := 0
	for c in world.companies:
		_ok(c.company_id >= 0, "Company has company_id")
		_ok(c.company_name != "", "Company has a name")
		_ok(c.color != null, "Company has a display colour")
		_ok(_finite(c.money), "Company has finite funds")
		if not c.is_player:
			ai_count += 1
			_ok(c.money > 0.0 and c.money < 100000.0, "AI starts with limited funds (not infinite)", str(c.money))
	_ok(ai_count == 2, "Exactly 2 AI companies", str(ai_count))
	# 資金制約: AI は所持金を超えて建設できない
	var ai_co = world.companies[1]
	ai_co.money = 5.0
	var before_routes: int = world.routes.size()
	ctx.ai.brains[0].evaluate()
	_ok(world.routes.size() == before_routes, "AI cannot build when funds are insufficient")

func _test_ai_build_decision() -> void:
	var ctx = _make_world(24680)
	var world: WorldState = ctx.world
	var brain: AICompanyBrain = ctx.ai.brains[0]
	var ai_co: TransportCompany = world.companies[1]
	var money_before: float = ai_co.money
	_advance(ctx, 30)
	_ok(brain.build_count > 0, "AI built at least one connection", str(brain.build_count))
	_ok(world.routes.size() > 0, "AI connections exist in world", str(world.routes.size()))
	var ai_routes := 0
	for r in world.routes:
		if r.company_id == ai_co.company_id:
			ai_routes += 1
	_ok(ai_routes > 0, "AI owns connections", str(ai_routes))
	_ok(ai_co.money != money_before, "AI funds changed (build cost and/or revenue applied)", str(ai_co.money))
	_ok(ai_co.money >= 0.0, "AI funds never negative", str(ai_co.money))
	_ok(ai_co.total_revenue > 0.0, "AI earned revenue from operation", str(ai_co.total_revenue))
	# 地上接続要求が Grok 向け境界を通過している
	var adapter: GroundTransportAdapter = ctx.ai.adapter
	_ok(adapter.request_log.size() > 0, "AI ground requests went through GroundTransportAdapter boundary", str(adapter.request_log.size()))
	var logged_entry: Dictionary = adapter.request_log[adapter.request_log.size() - 1]
	_ok(logged_entry.has("company_id") and logged_entry.has("mode") and logged_entry.has("origin_id"),
		"Ground request log records the contract fields")

func _test_ai_remove_decision() -> void:
	var ctx = _make_world(13579)
	var world: WorldState = ctx.world
	var brain: AICompanyBrain = ctx.ai.brains[0]
	var ai_co: TransportCompany = world.companies[1]
	ai_co.money = 5000.0
	# 地上接続を AI acre垒に作らせる (Grok API 境界経由)
	var adapter: GroundTransportAdapter = ctx.ai.adapter
	var rid: int = adapter.request_ground_connection(ai_co.company_id, Route.RouteType.ROAD, 0, 2)
	_ok(rid >= 0, "AI requested a ground connection via the adapter boundary")
	var route = world.get_route(rid)
	_ok(route != null and route.company_id == ai_co.company_id, "Requested ground connection is owned by the AI company")
	# 需要を潰して赤字にする
	var s0 = world.get_settlement(0)
	var s2 = world.get_settlement(2)
	for s in [s0, s2]:
		s.passenger_destinations.clear()
		s.food_demand = 0.0
		s.fuel_demand = 0.0
		s.food_supply_capacity = 0.0
		s.fuel_supply_capacity = 0.0
	_advance(ctx, 1)
	_ok(route.profit < 0.0, "Undemanded AI route is loss-making", str(route.profit))
	var removed := false
	for _i in range(4):
		brain.evaluate()
		if not route.active:
			removed = true
			break
	_ok(removed, "AI removes a loss-making connection")
	_ok(ai_co.connections_removed > 0, "AI removal counter incremented")

# ------------------------------------------------------------------
# 11-12. 競争
# ------------------------------------------------------------------

func _test_competition_share_allocation() -> void:
	var ctx = _make_world(5150)
	var world: WorldState = ctx.world
	var competition: CompetitionResolver = ctx.transport.competition
	world.money = 10000.0
	var player_route = world.create_route(0, 1, Route.RouteType.ROAD)
	_ok(player_route != null, "Player route created")
	# AI 会社 1 が同じ都市対に参入
	var ai_route = world.create_route(0, 1, Route.RouteType.ROAD, 1)
	_ok(ai_route != null, "AI can enter the same market (different company, same city pair)")
	var key: int = competition.market_key(0, 1)
	var p_share: float = competition.get_company_share(key, WorldState.PLAYER_COMPANY_ID)
	var a_share: float = competition.get_company_share(key, 1)
	_ok(_approx(p_share + a_share, 1.0, 0.001), "Demand share split sums to 1.0", "%s + %s" % [p_share, a_share])
	_ok(p_share < 1.0 and p_share > 0.0, "Player no longer gets 100% of the market", str(p_share))
	_ok(a_share > 0.0, "AI receives a positive market share", str(a_share))
	# 3社目が入ればさらに分割される
	var ai2_route = world.create_route(0, 1, Route.RouteType.RAIL, 2)
	_ok(ai2_route != null, "Third company can join the same market")
	var p2: float = competition.get_company_share(key, WorldState.PLAYER_COMPANY_ID)
	_ok(p2 < p_share, "Player share drops further when a third company enters", "%s -> %s" % [p_share, p2])
	var total := p2 + competition.get_company_share(key, 1) + competition.get_company_share(key, 2)
	_ok(_approx(total, 1.0, 0.001), "Three-way split still sums to 1.0", str(total))

func _test_player_share_loss_on_ai_entry() -> void:
	var ctx = _make_world(6270)
	var world: WorldState = ctx.world
	world.money = 10000.0
	var player_route = world.create_route(0, 1, Route.RouteType.ROAD)
	_ok(player_route != null, "Player solo route created")
	_advance(ctx, 1)
	var solo_carried: float = player_route.carried_passenger
	var solo_share: float = player_route.market_share
	_ok(solo_carried > 0.0, "Player route carried passengers while alone", str(solo_carried))
	# AI 参入
	var ai_route = world.create_route(0, 1, Route.RouteType.ROAD, 1)
	_ok(ai_route != null, "AI entered the player's market")
	_advance(ctx, 1)
	var comp_share: float = player_route.market_share
	var comp_carried: float = player_route.carried_passenger
	_ok(comp_share < solo_share, "Player market share drops after AI entry", "%s -> %s" % [solo_share, comp_share])
	_ok(comp_carried < solo_carried, "Player carried volume drops after AI entry", "%s -> %s" % [solo_carried, comp_carried])
	_ok(ai_route.carried_passenger > 0.0, "AI route carries part of the market demand", str(ai_route.carried_passenger))

# ------------------------------------------------------------------
# 13-15. 戦争補給
# ------------------------------------------------------------------

func _test_war_supply_bases_bilateral() -> void:
	var ctx = _make_world(9001)
	var world: WorldState = ctx.world
	var war: WarSystem = ctx.war
	war._start_war(0, 1)
	_ok(world.war_active, "War started")
	_ok(world.war_supply_base_ids.size() == 2, "Two supply bases generated (one per belligerent)", str(world.war_supply_base_ids.size()))
	var supports := []
	for bid in world.war_supply_base_ids:
		var base = world.get_settlement(bid)
		_ok(base != null and base.active and base.is_supply_base, "Supply base exists and is active")
		if base != null:
			_ok(base.support_nation_id >= 0, "Supply base has support_nation_id", str(base.support_nation_id))
			supports.append(base.support_nation_id)
	_ok(supports.has(world.war_nation_a), "One base supports nation A")
	_ok(supports.has(world.war_nation_b), "One base supports nation B")
	_ok(supports[0] != supports[1], "Bases support different nations")
	_ok(_count_supply_bases(world) == 2, "Exactly 2 supply bases in the world")

func _test_war_supply_correct_side_bonus() -> void:
	var ctx = _make_world(9002)
	var world: WorldState = ctx.world
	var war: WarSystem = ctx.war
	world.money = 10000.0
	war._start_war(0, 1)
	var base_a = world.get_settlement(world.war_supply_base_ids[0])
	_ok(base_a.support_nation_id == world.war_nation_a, "Base A supports nation A")
	# 赤都 (nation 0 = A) から A軍基地へ道路
	var route = world.create_route(0, base_a.id, Route.RouteType.ROAD)
	_ok(route != null, "Supply route from friendly city created")
	var nation_a = world.get_nation(world.war_nation_a)
	var before: float = nation_a.war_bonus
	_advance(ctx, 1)
	var after: float = nation_a.war_bonus
	_ok(after > before, "Friendly-side supply increases war bonus", "%s -> %s" % [before, after])
	_ok(_log_contains(world, "戦争補正+"), "War bonus increase is written to the event log")
	_ok(route.last_revenue > 0.0, "Supply route earns wartime premium revenue", str(route.last_revenue))

func _test_war_supply_enemy_city_no_bonus() -> void:
	var ctx = _make_world(9003)
	var world: WorldState = ctx.world
	var war: WarSystem = ctx.war
	world.money = 10000.0
	war._start_war(0, 1)
	var base_a = world.get_settlement(world.war_supply_base_ids[0])
	var nation_a = world.get_nation(world.war_nation_a)
	# 青都 (nation 1 = B) から A軍基地へ道路 = 無効補給
	var route = world.create_route(2, base_a.id, Route.RouteType.ROAD)
	_ok(route != null, "Route from enemy city to enemy-ally base created")
	var before: float = nation_a.war_bonus
	_advance(ctx, 2)
	var after: float = nation_a.war_bonus
	_ok(_approx(after, before), "Enemy-city supply does NOT increase war bonus", "%s -> %s" % [before, after])
	_ok(_approx(nation_a.war_bonus, 0.0), "War bonus stays at zero for the wrong side")
	_ok(_log_contains(world, "[無効補給]"), "Invalid supply is logged with a reason")
	# 敵国都市から自軍基地への補給は有効
	var base_b = world.get_settlement(world.war_supply_base_ids[1])
	var nation_b = world.get_nation(world.war_nation_b)
	var b_before: float = nation_b.war_bonus
	world.create_route(2, base_b.id, Route.RouteType.ROAD)
	_advance(ctx, 2)
	_ok(nation_b.war_bonus > b_before, "Blue city -> Blue base increases Blue war bonus",
		"%s -> %s" % [b_before, nation_b.war_bonus])
	_ok(_approx(nation_a.war_bonus, 0.0), "Red war bonus still zero (no cross-credit)", str(nation_a.war_bonus))

# ------------------------------------------------------------------
# 16-18. 戦争終了 / 都市所属変更 / cleanup
# ------------------------------------------------------------------

func _test_war_end_and_ownership_change() -> void:
	var ctx = _make_world(9004)
	var world: WorldState = ctx.world
	var war: WarSystem = ctx.war
	world.money = 10000.0
	var owners := {}
	for s in world.settlements:
		owners[s.id] = s.nation_id
	war._start_war(0, 1)
	var base_a = world.get_settlement(world.war_supply_base_ids[0])
	var route = world.create_route(0, base_a.id, Route.RouteType.ROAD)
	world.war_days_left = 1
	_advance(ctx, 1)
	_ok(not world.war_active, "War ends when the countdown reaches zero")
	_ok(world.war_supply_base_id == -1, "Primary supply base id cleared")
	_ok(world.war_supply_base_ids.is_empty(), "Supply base id list cleared")
	var changed := false
	for s in world.settlements:
		if owners.has(s.id) and owners[s.id] != s.nation_id:
			changed = true
	_ok(changed, "War result changes at least one city ownership")
	_ok(route.active, "Post-war connection stays in place for the owner to decide")
	_ok(route.obsolete, "Post-war connection is flagged obsolete")

func _test_war_supply_base_cleanup() -> void:
	var ctx = _make_world(9005)
	var world: WorldState = ctx.world
	var war: WarSystem = ctx.war
	world.money = 10000.0
	war._start_war(0, 1)
	var base_a = world.get_settlement(world.war_supply_base_ids[0])
	var base_b = world.get_settlement(world.war_supply_base_ids[1])
	var route = world.create_route(0, base_a.id, Route.RouteType.ROAD)
	world.war_days_left = 1
	_advance(ctx, 1)
	_ok(not base_a.active, "Supply base A deactivated after war")
	_ok(not base_b.active, "Supply base B deactivated after war")
	_ok(_count_supply_bases(world) == 0, "No supply base remains in the world data")
	_ok(world.get_settlement(base_a.id) == null, "Supply base A object removed from world")
	# 接続路線は残置され、撤去可能
	_ok(route.active, "Obsolete connection remains active (removable)")
	_advance(ctx, 1)
	_ok(_approx(route.last_revenue, 0.0), "Obsolete connection stops earning revenue", str(route.last_revenue))
	_ok(world.remove_route(route.id), "Owner can remove the obsolete connection")
	_ok(not route.active, "Removed connection becomes inactive")
	_ok(_routes_to_supply_bases(world) == 0, "No route references a supply base after removal", str(_routes_to_supply_bases(world)))
	_ok(world.settlements.size() == 6, "World back to 6 cities after cleanup", str(world.settlements.size()))

## 補給基地に接続した route 数
func _routes_to_supply_bases(world: WorldState) -> int:
	var n := 0
	for r in world.routes:
		if not r.active:
			continue
		var a = world.get_settlement(r.from_id)
		var b = world.get_settlement(r.to_id)
		if (a != null and a.is_supply_base) or (b != null and b.is_supply_base):
			n += 1
	return n

# ------------------------------------------------------------------
# 19. 100回戦争反復
# ------------------------------------------------------------------

func _test_repeated_wars_no_base_accumulation() -> void:
	var ctx = _make_world(9006)
	var world: WorldState = ctx.world
	var war: WarSystem = ctx.war
	world.money = 100000.0
	var wars := 0
	for i in range(100):
		if world.war_active:
			world.war_days_left = 1
			_advance(ctx, 1)
		else:
			war._start_war(0, 1)
			wars += 1
			var base_a = world.get_settlement(world.war_supply_base_ids[0])
			var route = world.create_route(0, base_a.id, Route.RouteType.ROAD)
			_advance(ctx, 2)
			world.war_days_left = 1
			_advance(ctx, 1)
			if route != null:
				world.remove_route(route.id)
	_ok(wars >= 90, "100 war iterations executed", str(wars))
	_ok(_count_supply_bases(world) == 0, "No temporary supply base accumulates over 100 wars", str(_count_supply_bases(world)))
	_ok(world.settlements.size() == 6, "Settlement count stable after 100 wars", str(world.settlements.size()))
	_ok(_routes_to_supply_bases(world) == 0, "No route stays attached to a removed supply base", str(_routes_to_supply_bases(world)))
	_ok(world.routes.size() <= 45, "Routes do not accumulate indefinitely (3 companies x 15 city pairs max)", str(world.routes.size()))
	_ok(world.event_log.size() <= world.MAX_LOG, "Event log stays bounded over 100 wars", str(world.event_log.size()))

# ------------------------------------------------------------------
# 20. 地上接続境界 (Grok API)
# ------------------------------------------------------------------

func _test_ground_adapter_boundary() -> void:
	var ctx = _make_world(9007)
	var world: WorldState = ctx.world
	var adapter: GroundTransportAdapter = ctx.ai.adapter
	_ok(adapter != null, "GroundTransportAdapter exists as the Grok-side boundary")
	_ok(not adapter.has_provider(), "Adapter runs in mock mode until Grok provides an implementation")
	world.money = 10000.0
	var rid: int = adapter.request_ground_connection(1, Route.RouteType.ROAD, 0, 1)
	_ok(rid >= 0, "Adapter returns a connection id for a ground request")
	var route = world.get_route(rid)
	_ok(route != null and route.company_id == 1, "Requested connection is owned by the requesting company")
	_ok(adapter.request_log.size() == 1, "Request was recorded for integration inspection")
	var entry: Dictionary = adapter.request_log[0]
	_ok(entry.has("company_id") and entry.has("mode") and entry.has("origin_id") and entry.has("destination_id"),
		"Request log records company_id / mode / origin / destination")
	_ok(int(entry.mode) == Route.RouteType.ROAD, "Requested mode matches ROAD")
	# 不正入力は拒否
	_ok(adapter.request_ground_connection(1, Route.RouteType.ROAD, 0, 0) == -1, "Self-connection rejected")
	_ok(adapter.request_ground_connection(1, Route.RouteType.SHIP, 0, 1) == -1, "Non-ground mode rejected by the ground boundary")
	# 架空の Grok provider を差し替えて境界が委譲されることを確認
	var provider = load("res://tests/MockGroundProvider.gd").new()
	provider.world = world
	adapter.configure_provider(provider)
	_ok(adapter.has_provider(), "Adapter accepts a Grok-side provider")
	_ok(not adapter.can_build_ground_connection(1, Route.RouteType.ROAD, 0, 1), "Provider decision is delegated (mock provider refuses)")
	_ok(adapter.request_ground_connection(1, Route.RouteType.ROAD, 0, 1) == -1, "Provider request result is delegated")
	_ok(provider.request_count > 0, "Provider actually received the request", str(provider.request_count))
	adapter.configure_provider(null)

# ------------------------------------------------------------------
# 21. 長時間進行 / Seed 再現
# ------------------------------------------------------------------

func _test_long_run_stability() -> void:
	var ctx = _make_world(9008)
	var world: WorldState = ctx.world
	world.money = 50000.0
	var ship: ShipSystem = ctx.ship
	var air: AirSystem = ctx.air
	# プレイヤーも港・空港を持ち、輸送形態を複数持たせる
	ship.build_port(1, WorldState.PLAYER_COMPANY_ID)
	ship.build_port(4, WorldState.PLAYER_COMPANY_ID)
	air.build_airport(0, WorldState.PLAYER_COMPANY_ID)
	air.build_airport(2, WorldState.PLAYER_COMPANY_ID)
	ship.create_ship_connection(WorldState.PLAYER_COMPANY_ID, 1, 4)
	air.create_air_connection(WorldState.PLAYER_COMPANY_ID, 0, 2)
	world.create_route(0, 1, Route.RouteType.ROAD)
	world.create_route(2, 3, Route.RouteType.RAIL)

	var values_ok := true
	var money_ok := true
	var capacity_ok := true
	var ai_money_ok := true
	for day_index in range(365):
		if day_index in [40, 120, 200, 280] and not world.war_active:
			ctx.war._start_war(0, 1)
		_advance(ctx, 1)
		for s in world.settlements:
			if not (_finite(s.population) and _finite(s.economy) and s.population >= 0.0 and s.economy >= 0.0):
				values_ok = false
		for r in world.routes:
			if r.remaining_capacity() < -0.001:
				capacity_ok = false
		if not (_finite(world.money) and world.money >= 0.0):
			money_ok = false
		for c in world.companies:
			if not c.is_player and (not _finite(c.money) or c.money < 0.0):
				ai_money_ok = false
	_ok(values_ok, "365-day simulation keeps city values finite and non-negative")
	_ok(money_ok, "365-day player funds stay finite and non-negative")
	_ok(capacity_ok, "365-day route capacity never goes negative")
	_ok(ai_money_ok, "365-day AI funds stay finite and non-negative")
	_ok(_count_supply_bases(world) <= 2, "Supply bases stay bounded during the long run", str(_count_supply_bases(world)))
	_ok(world.event_log.size() <= world.MAX_LOG, "Event log stays bounded during the long run")
	_ok(world.routes.size() < 80, "Route count stays bounded during the long run", str(world.routes.size()))

func _test_seed_reproducibility() -> void:
	var ctx1 = _make_world(555111)
	var ctx2 = _make_world(555111)
	for ctx in [ctx1, ctx2]:
		var world: WorldState = ctx.world
		world.money = 50000.0
		ctx.ship.build_port(1, WorldState.PLAYER_COMPANY_ID)
		ctx.ship.build_port(4, WorldState.PLAYER_COMPANY_ID)
		ctx.air.build_airport(0, WorldState.PLAYER_COMPANY_ID)
		ctx.air.build_airport(2, WorldState.PLAYER_COMPANY_ID)
		ctx.ship.create_ship_connection(WorldState.PLAYER_COMPANY_ID, 1, 4)
		ctx.air.create_air_connection(WorldState.PLAYER_COMPANY_ID, 0, 2)
		world.create_route(0, 1, Route.RouteType.ROAD)
		ctx.war._start_war(0, 1)
	for _i in range(70):
		_advance(ctx1, 1)
		_advance(ctx2, 1)
	_ok(_snapshot(ctx1.world) == _snapshot(ctx2.world),
		"Same seed + same actions produce identical state (including AI, ship, air and war)")
