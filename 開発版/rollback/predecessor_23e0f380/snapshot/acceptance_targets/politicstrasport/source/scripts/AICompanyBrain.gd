class_name AICompanyBrain
extends RefCounted

## MiniMax: AI 輸送会社 1社分の意思決定
##
## 行動:
##   1) 市場評価: 儲かりそうな都市対を洗い出す
##   2) 手段選択: ROAD / RAIL / SHIP / AIR
##   3) 建設: 自社資金から建設費を支付 (無限資金・無料建設はしない)
##   4) 運行: 運行して収益を得る (TransportSystem 共有処理)
##   5) 撤去: 赤字/無価値な路線を撤去する (戦後不要connection も撤去)
##
## 地上接続 (ROAD/RAIL) の要求は Grok 側 API を GroundTransportAdapter 経由でのみ行う。
## MiniMax 側は独自の地上 PathFinder を持たない。

const EVALUATION_INTERVAL := 5          # 何日ごとに評価するか
const UNPROFITABLE_LIMIT := 3           # 連続赤字日数で撤去
const MIN_RESERVE_RATIO := 0.15         # 現金.reserve を残す比率
const COMPETITION_DISCOUNT := 0.7       # 競合を見込んだ収益係数
const MIN_DAILY_PROFIT := 0.5           # これ未満なら建設しない
const REFUND_RATE := 0.4                # 撤去時の返还率
const MAX_ROUTES_PER_COMPANY := 6       # 1社が同時にもてる接続数の上限
const MAX_PER_MODE := 3                 # 同一手段の接続数上限 (分散のため)

var company: TransportCompany
var world: WorldState
var adapter: GroundTransportAdapter
var ship_system: ShipSystem
var air_system: AirSystem

var last_build_day: int = -999
var last_remove_day: int = -999
var build_count: int = 0
var remove_count: int = 0

func _init(p_company: TransportCompany, p_world: WorldState) -> void:
	company = p_company
	world = p_world

func setup(p_adapter: GroundTransportAdapter, p_ship: ShipSystem, p_air: AirSystem) -> void:
	adapter = p_adapter
	ship_system = p_ship
	air_system = p_air

func should_evaluate() -> bool:
	if company == null:
		return false
	return (world.day - last_build_day) >= EVALUATION_INTERVAL or last_build_day < 0

# ------------------------------------------------------------------
# 1) 市場評価 → 2) 手段選択 → 3) 建設
# ------------------------------------------------------------------

func evaluate() -> void:
	if company == null:
		return
	last_build_day = world.day
	_consider_build()
	_consider_remove()

func _consider_build() -> void:
	var settlements := _active_cities()
	if settlements.size() < 2:
		return
	if _company_route_count() >= MAX_ROUTES_PER_COMPANY:
		return  # 既に上限接続数: 余分に広げない
	var reserve: float = company.money * MIN_RESERVE_RATIO
	var best_score := -1.0e9
	var best_action := {}

	for i in range(settlements.size()):
		for j in range(i + 1, settlements.size()):
			var a: Settlement = settlements[i]
			var b: Settlement = settlements[j]
			var demand := _estimate_pair_demand(a, b)
			if demand.total <= 0.01:
				continue
			for mode: int in [TransportModeConfig.Mode.ROAD, TransportModeConfig.Mode.RAIL,
					TransportModeConfig.Mode.SHIP, TransportModeConfig.Mode.AIR]:
				if _company_mode_count(mode) >= MAX_PER_MODE:
					continue  # 同一手段に偏らないよう分散する
				if _company_has_mode_connection(a.id, b.id, mode):
					continue
				var action := _evaluate_option(a, b, mode, demand, reserve)
				if action.is_empty():
					continue
				if action.score > best_score:
					best_score = action.score
					best_action = action

	if best_action.is_empty():
		return
	_execute_build(best_action)

## 都市対Signature需要見積り
func _estimate_pair_demand(a: Settlement, b: Settlement) -> Dictionary:
	var pax: float = float(a.passenger_destinations.get(b.id, 0.0)) + float(b.passenger_destinations.get(a.id, 0.0))
	var food: float = 0.0
	var fuel: float = 0.0
	if a.food_supply_capacity > 0.5 and b.food_demand > 0.5:
		food += min(b.food_demand * 0.6, a.food_supply_capacity * 0.4)
	if b.food_supply_capacity > 0.5 and a.food_demand > 0.5:
		food += min(a.food_demand * 0.6, b.food_supply_capacity * 0.4)
	if a.fuel_supply_capacity > 0.3 and b.fuel_demand > 0.3:
		fuel += min(b.fuel_demand * 0.5, a.fuel_supply_capacity * 0.35)
	if b.fuel_supply_capacity > 0.3 and a.fuel_demand > 0.3:
		fuel += min(a.fuel_demand * 0.5, b.fuel_supply_capacity * 0.35)
	var extended: Dictionary = {}
	var extended_total := 0.0
	if world.economic_core != null:
		extended = world.economic_core.estimate_pair_extended_demand(a.id, b.id)
		for amount in extended.values():
			extended_total += float(amount)
	return {"passenger": pax, "food": food, "fuel": fuel, "extended": extended,
		"total": pax + food + fuel + extended_total}

## モード別の採算を評価
func _evaluate_option(a: Settlement, b: Settlement, mode: int, demand: Dictionary, reserve: float) -> Dictionary:
	var infra_cost := 0.0
	var feasible := false
	var ground_cost := 0.0

	match mode:
		TransportModeConfig.Mode.ROAD, TransportModeConfig.Mode.RAIL:
			if adapter == null:
				return {}
			if not adapter.can_build_ground_connection(company.company_id, mode, a.id, b.id):
				return {}
			feasible = true
			ground_cost = adapter.estimate_ground_build_cost(mode, a.id, b.id)
		TransportModeConfig.Mode.SHIP:
			if ship_system == null or air_system == null:
				return {}
			# 港が無い場合は港の開設費を含めて評価する
			if not a.has_port:
				if not ship_system.is_port_capable(a):
					return {}
				infra_cost += TransportModeConfig.PORT_COST
			if not b.has_port:
				if not ship_system.is_port_capable(b):
					return {}
				infra_cost += TransportModeConfig.PORT_COST
			feasible = true
		TransportModeConfig.Mode.AIR:
			if air_system == null:
				return {}
			if not a.has_airport:
				infra_cost += TransportModeConfig.AIRPORT_COST
			if not b.has_airport:
				infra_cost += TransportModeConfig.AIRPORT_COST
			feasible = true
	if not feasible:
		return {}

	# 収益見積り (競合を見込む)
	var revenue: float = 0.0
	revenue += min(demand.passenger, TransportModeConfig.daily_cap(TransportModeConfig.Cargo.PASSENGER, mode)) * TransportModeConfig.unit_price(TransportModeConfig.Cargo.PASSENGER, mode)
	revenue += min(demand.food, TransportModeConfig.daily_cap(TransportModeConfig.Cargo.FOOD, mode)) * TransportModeConfig.unit_price(TransportModeConfig.Cargo.FOOD, mode)
	revenue += min(demand.fuel, TransportModeConfig.daily_cap(TransportModeConfig.Cargo.FUEL, mode)) * TransportModeConfig.unit_price(TransportModeConfig.Cargo.FUEL, mode)
	if world.economic_core != null:
		var extended: Dictionary = demand.get("extended", {})
		for cargo_key in extended.keys():
			var cargo := int(cargo_key)
			var volume: float = min(float(extended[cargo_key]), TransportModeConfig.daily_cap(cargo, mode))
			var market_a = world.economic_core.get_or_create_market(a.id, cargo)
			var market_b = world.economic_core.get_or_create_market(b.id, cargo)
			var market_mult: float = (market_a.effective_multiplier() + market_b.effective_multiplier()) * 0.5
			revenue += volume * world.economic_core.registry.unit_price(cargo, mode) * market_mult
	revenue *= COMPETITION_DISCOUNT

	var build_cost: float = ground_cost if mode != TransportModeConfig.Mode.SHIP and mode != TransportModeConfig.Mode.AIR else TransportModeConfig.build_cost(mode)
	var total_cost: float = build_cost + infra_cost
	var operating: float = TransportModeConfig.operating_cost(mode)
	var profit: float = revenue - operating
	if profit < MIN_DAILY_PROFIT:
		return {}
	if company.money - total_cost < reserve:
		return {}   # 資金制約: 現金が足りないなら作らない

	var payback: float = total_cost / max(profit, 0.01)
	# 遠距離ほど有利 (SHIP/AIR は長距離で有利)
	var dist: float = a.position.distance_to(b.position)
	var distance_bonus := 1.0
	if mode == TransportModeConfig.Mode.SHIP and dist > 300.0:
		distance_bonus = 1.25
	if mode == TransportModeConfig.Mode.AIR and dist > 250.0:
		distance_bonus = 1.15
	if mode == TransportModeConfig.Mode.RAIL and dist > 250.0:
		distance_bonus = 1.05
	# 会社ごとの手段バイアス (AI 2社を差別化: 陸運寄り / 国際輸送寄り)
	var bias: float = 1.0
	if company != null and company.mode_bias.has(mode):
		bias = float(company.mode_bias[mode])
	var directive_bias := 1.0
	var preferred_mode = company.management_directives.get("preferred_mode", -1)
	if int(preferred_mode) == mode:
		directive_bias *= 1.22
	var preferred_nation = int(company.management_directives.get("preferred_nation", -1))
	if preferred_nation >= 0 and (a.nation_id == preferred_nation or b.nation_id == preferred_nation):
		directive_bias *= 1.18
	var growth_posture := str(company.management_directives.get("growth_posture", ""))
	if growth_posture == "aggressive":
		directive_bias *= 1.12
	elif growth_posture == "conservative":
		directive_bias *= 0.90
	var strategy_bias := 1.0
	match company.strategy:
		TransportCompany.Strategy.GROWTH:
			strategy_bias = 1.10
		TransportCompany.Strategy.CONSERVATIVE:
			strategy_bias = 0.92
		TransportCompany.Strategy.COOPERATIVE:
			strategy_bias = 1.06 if company.cooperation_group_id >= 0 else 0.98
		TransportCompany.Strategy.OPPORTUNIST:
			strategy_bias = 1.08 if profit > MIN_DAILY_PROFIT * 3.0 else 0.96
		_:
			pass
	var score: float = profit * 40.0 * distance_bonus * bias * directive_bias * strategy_bias \
		- total_cost * 0.15 - payback * 0.2

	return {
		"mode": mode,
		"a": a,
		"b": b,
		"build_cost": build_cost,
		"infra_cost": infra_cost,
		"total_cost": total_cost,
		"expected_profit": profit,
		"score": score,
	}

func _execute_build(action: Dictionary) -> void:
	var a: Settlement = action.a
	var b: Settlement = action.b
	var mode: int = action.mode
	var money_before: float = company.money

	# インフラ (港 / 空港) が要るなら先に開く
	if mode == TransportModeConfig.Mode.SHIP:
		if not a.has_port:
			if not ship_system.build_port(a.id, company.company_id):
				return
		if not b.has_port:
			if not ship_system.build_port(b.id, company.company_id):
				return
	elif mode == TransportModeConfig.Mode.AIR:
		if not a.has_airport:
			if not air_system.build_airport(a.id, company.company_id):
				return
		if not b.has_airport:
			if not air_system.build_airport(b.id, company.company_id):
				return

	var route = null
	if mode == TransportModeConfig.Mode.SHIP:
		route = ship_system.create_ship_connection(company.company_id, a.id, b.id)
	elif mode == TransportModeConfig.Mode.AIR:
		route = air_system.create_air_connection(company.company_id, a.id, b.id)
	else:
		var route_id: int = adapter.request_ground_connection(company.company_id, mode, a.id, b.id)
		if route_id >= 0:
			route = world.get_route(route_id)

	if route == null:
		return
	company.add_connection(route.id)
	company.connections_built += 1
	build_count += 1
	# pay_company / GroundNetwork already recorded the actual expense exactly once.
	var actual_cost: float = max(0.0, money_before - company.money)
	world.add_event("%sが%sを開設: %s ↔ %s (費用%.0f)" % [
		company.company_name, TransportModeConfig.mode_name(mode), a.name, b.name, actual_cost])

# ------------------------------------------------------------------
# 5) 撤去判断
# ------------------------------------------------------------------

func _consider_remove() -> void:
	for r in world.routes.duplicate():
		if not r.active or r.company_id != company.company_id:
			continue
		if r.obsolete:
			_remove_route(r, "戦後不要")
			continue
		if r.disruption_reason != "" and r.route_value_multiplier <= 0.20:
			r.unprofitable_days += 1
			if r.unprofitable_days >= 6:
				_remove_route(r, "長期遮断")
			continue
		if r.profit < 0.0:
			r.unprofitable_days += 1
			if r.unprofitable_days >= UNPROFITABLE_LIMIT:
				_remove_route(r, "赤字")
		else:
			r.unprofitable_days = 0

func _remove_route(route, reason: String) -> void:
	var refund: float = TransportModeConfig.build_cost(route.type) * REFUND_RATE
	company.money += refund
	company.register_expense(-refund)
	company.remove_connection(route.id)
	company.connections_removed += 1
	remove_count += 1
	world.remove_route(route.id)
	world.add_event("%sが%sを撤去: %s ↔ %s (理由:%s, 返還%.0f)" % [
		company.company_name, TransportModeConfig.mode_name(route.type),
		_settlement_name(route.from_id), _settlement_name(route.to_id), reason, refund])

func _settlement_name(id: int) -> String:
	var s = world.get_settlement(id)
	return s.name if s != null else "?"

# ------------------------------------------------------------------
# 補助
# ------------------------------------------------------------------

func _active_cities() -> Array:
	var result: Array = []
	for s in world.settlements:
		if s.active and not s.is_supply_base:
			result.append(s)
	return result

func _company_mode_count(mode: int) -> int:
	var n := 0
	for r in world.routes:
		if r.active and r.company_id == company.company_id and r.type == mode:
			n += 1
	return n

func _company_route_count() -> int:
	var n := 0
	for r in world.routes:
		if r.active and r.company_id == company.company_id:
			n += 1
	return n

func _company_has_mode_connection(a_id: int, b_id: int, mode: int) -> bool:
	for r in world.routes:
		if not r.active or r.company_id != company.company_id or r.type != mode:
			continue
		if (r.from_id == a_id and r.to_id == b_id) or (r.from_id == b_id and r.to_id == a_id):
			return true
	return false

