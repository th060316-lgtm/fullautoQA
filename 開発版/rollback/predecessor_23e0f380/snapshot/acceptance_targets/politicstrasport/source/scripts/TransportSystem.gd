class_name TransportSystem
extends RefCounted

## MiniMax: 輸送実行引擎 (Competition 統合)
##
## ROAD / RAIL / SHIP / AIR の全モードの貨物移動を一括で処理する。
## 地上の「経路探索・タイル敷設・建設UI」は Grok 管轄で、ここでは扱わない。
## このクラスが扱うのは:
##   ・需要更新後の輸送量計算
##   ・競合による需要配分 (CompetitionResolver)
##   ・収益 / 運行費の計上 (会社別)
##   ・戦争補給 (WarSupplyPolicy へ委譲)
##
## 統合方針: EconomySystem.process_day() から 1 回だけ process_transport() を呼ぶ。
## (Grok 側が EconomySystem を置き換える場合は同等の呼び出し hooks が必要)

const MIN_PASSENGER := 0.1
const MIN_FOOD := 0.3
const MIN_FUEL := 0.2

var world: WorldState
var competition: CompetitionResolver
var war_policy: WarSupplyPolicy
var process_call_count: int = 0

func _init(p_world: WorldState) -> void:
	world = p_world
	competition = CompetitionResolver.new(world)
	war_policy = WarSupplyPolicy.new(world)
	war_policy.resolver = competition

func _begin_day_accounting() -> void:
	for c in world.companies:
		c.begin_day()

# ------------------------------------------------------------------
# 1日分の輸送
# ------------------------------------------------------------------

func process_transport() -> void:
	if world == null:
		return
	process_call_count += 1
	_begin_day_accounting()
	_reset_ticks()
	competition.refresh_scores()
	competition.compute_connection_shares()
	var pairs := competition.build_market_index()
	_process_passengers(pairs)
	_process_goods(pairs, TransportModeConfig.Cargo.FOOD)
	_process_goods(pairs, TransportModeConfig.Cargo.FUEL)
	war_policy.process_supply()
	_process_extended_goods(pairs)
	_apply_operating_costs()
	_accumulate()
	_update_reputation()

func _reset_ticks() -> void:
	for r in world.routes:
		if r.is_operational(world):
			r.reset_tick()
			r.daily_revenue = 0.0
			r.daily_operating_cost = 0.0
			r.market_share = 0.0

# ------------------------------------------------------------------
# 旅客 (方向あり)
# ------------------------------------------------------------------

func _process_passengers(pairs: Dictionary) -> void:
	for key in pairs:
		var info: Dictionary = pairs[key]
		var a = world.get_settlement(info.a)
		var b = world.get_settlement(info.b)
		if a == null or b == null or not a.active or not b.active:
			continue
		if a.is_supply_base or b.is_supply_base:
			continue
		_transport_passenger(a, b, info.routes)
		_transport_passenger(b, a, info.routes)

func _transport_passenger(src: Settlement, dst: Settlement, routes: Array) -> void:
	var demand: float = float(src.passenger_destinations.get(dst.id, 0.0))
	if demand <= MIN_PASSENGER:
		return
	var moves := competition.distribute(routes, demand, TransportModeConfig.Cargo.PASSENGER)
	for m in moves:
		var route = m[0]
		var moved: float = m[1]
		if moved <= 0.0:
			continue
		route.carried_passenger += moved
		var residual: float = float(src.passenger_destinations.get(dst.id, 0.0))
		src.passenger_destinations[dst.id] = max(0.0, residual - moved * 0.7)
		var revenue: float = moved * TransportModeConfig.unit_price(TransportModeConfig.Cargo.PASSENGER, route.type)
		_credit(route, revenue)
		dst.population += moved * 0.015
		dst.economy += moved * 0.01

# ------------------------------------------------------------------
# 食料 / 燃料 (供給側 → 需要側)
# ------------------------------------------------------------------

func _process_goods(pairs: Dictionary, cargo: int) -> void:
	for key in pairs:
		var info: Dictionary = pairs[key]
		var a = world.get_settlement(info.a)
		var b = world.get_settlement(info.b)
		if a == null or b == null or not a.active or not b.active:
			continue
		if a.is_supply_base or b.is_supply_base:
			continue
		# 方向は「供給都市 → 需要都市」。どちらの都市も供給役/需要役を兼ねるので両方向を評価する。
		_transport_goods(b, a, info.routes, cargo)
		_transport_goods(a, b, info.routes, cargo)

func _transport_goods(consumer: Settlement, producer: Settlement, routes: Array, cargo: int) -> void:
	var is_food: bool = cargo == TransportModeConfig.Cargo.FOOD
	if is_food:
		if consumer.food_demand <= 0.5 or producer.food_supply_capacity <= 0.5:
			return
	else:
		if consumer.fuel_demand <= 0.3 or producer.fuel_supply_capacity <= 0.3:
			return
	var demand: float = 0.0
	if is_food:
		demand = min(consumer.food_demand * 0.6, producer.food_supply_capacity * 0.4)
	else:
		demand = min(consumer.fuel_demand * 0.5, producer.fuel_supply_capacity * 0.35)
	if demand <= 0.0:
		return
	var moves := competition.distribute(routes, demand, cargo)
	for m in moves:
		var route = m[0]
		var moved: float = m[1]
		if is_food and moved < MIN_FOOD:
			continue
		if (not is_food) and moved < MIN_FUEL:
			continue
		if is_food:
			route.carried_food += moved
			consumer.food_demand = max(0.0, consumer.food_demand - moved)
			producer.food_supply_capacity = max(0.0, producer.food_supply_capacity - moved * 0.3)
		else:
			route.carried_fuel += moved
			consumer.fuel_demand = max(0.0, consumer.fuel_demand - moved)
			producer.fuel_supply_capacity = max(0.0, producer.fuel_supply_capacity - moved * 0.25)
		var revenue: float
		if world.economic_core != null:
			var source_facility_id := -1
			for facility in world.economic_core.facilities_at(producer.id):
				if facility.production_capacity.has(cargo):
					source_facility_id = facility.id
					break
			revenue = world.economic_core.compute_saturated_revenue(
				consumer.id, cargo, moved, route.type, route.id, source_facility_id)
		else:
			revenue = moved * TransportModeConfig.unit_price(cargo, route.type)
		_credit(route, revenue)
		if is_food:
			consumer.population += moved * 0.02
			consumer.economy += moved * 0.015
			producer.economy += moved * 0.01
		else:
			consumer.economy += moved * 0.02
			producer.economy += moved * 0.012

# ------------------------------------------------------------------
# Grok economic core: general cargo (wood/coal/ore/industrial/luxury)
# ------------------------------------------------------------------

func _process_extended_goods(pairs: Dictionary) -> void:
	if world.economic_core == null:
		return
	for cargo_key in world.economic_core.registry.all_cargo_ids():
		var cargo := int(cargo_key)
		if cargo <= CargoRegistry.CargoKind.FUEL or not world.economic_core.registry.is_general(cargo):
			continue
		for key in pairs:
			var info: Dictionary = pairs[key]
			var a = world.get_settlement(info.a)
			var b = world.get_settlement(info.b)
			if a == null or b == null or not a.active or not b.active:
				continue
			if a.is_supply_base or b.is_supply_base:
				continue
			_transport_extended_goods(a, b, info.routes, cargo)
			_transport_extended_goods(b, a, info.routes, cargo)

func _transport_extended_goods(producer: Settlement, consumer: Settlement, routes: Array, cargo: int) -> void:
	var stock: float = world.economic_core.available_stock(producer.id, cargo)
	if stock <= 0.05:
		return
	var market = world.economic_core.get_or_create_market(consumer.id, cargo)
	var demand: float = min(stock * 0.45, market.remaining_soft_capacity())
	if demand <= 0.05:
		return
	var moves := competition.distribute(routes, demand, cargo)
	for move in moves:
		var route = move[0]
		var requested: float = float(move[1])
		var taken: Dictionary = world.economic_core.take_stock_with_source(producer.id, cargo, requested)
		var moved: float = float(taken.get("amount", 0.0))
		if moved <= 0.01:
			continue
		route.carried_general[cargo] = float(route.carried_general.get(cargo, 0.0)) + moved
		var revenue: float = world.economic_core.compute_saturated_revenue(
			consumer.id, cargo, moved, route.type, route.id,
			int(taken.get("source_facility_id", -1)))
		_credit(route, revenue)

# ------------------------------------------------------------------
# 収益 / 運行費
# ------------------------------------------------------------------

func _credit(route, revenue: float) -> void:
	route.last_revenue += revenue
	route.daily_revenue += revenue
	world.add_company_revenue(route.company_id, revenue)

func _apply_operating_costs() -> void:
	for r in world.routes:
		if not r.is_operational(world):
			continue
		var op: float = r.operating_cost
		r.daily_operating_cost = op
		r.profit = r.daily_revenue - op
		world.pay_operating_cost(r.company_id, op)
	world.sync_player_company_money()

func _accumulate() -> void:
	for r in world.routes:
		if r.is_operational(world):
			var general_total := 0.0
			for amount in r.carried_general.values():
				general_total += float(amount)
			r.total_carried += r.carried_passenger + r.carried_food + r.carried_fuel + general_total

func _update_reputation() -> void:
	for c in world.companies:
		var profit: float = float(c.last_day_revenue) - float(c.last_day_expense)
		var ratio: float = 0.0
		if float(c.last_day_revenue) > 0.001:
			ratio = profit / float(c.last_day_revenue)
		c.update_reputation(ratio)

# ------------------------------------------------------------------
# 診断用
# ------------------------------------------------------------------

## テスト用: 指定connection の直近市场份额
func get_connection_share(route_id: int) -> float:
	for r in world.routes:
		if r.id == route_id:
			return r.market_share
	return 0.0

