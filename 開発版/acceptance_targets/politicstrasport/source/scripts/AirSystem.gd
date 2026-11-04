class_name AirSystem
extends RefCounted

## MiniMax: 航空輸送 (Logic Prototype)
##
## ・空港 / 空港を持つ都市
## ・空港A → 空港B の直行航空路 (タイル航路は不要、航空管制・滑走路設計も対象外)
## ・旅客 + 一部の貨物 (食料/燃料は少量)
## ・高速 / 高費用 / 低〜中容量
##
## 地上タイル経路探索 (Grok 管轄) は一切持たない。

var world: WorldState

func _init(p_world: WorldState) -> void:
	world = p_world

# ------------------------------------------------------------------
# 空港
# ------------------------------------------------------------------

## 空港を開設できる都市か
func is_airport_capable(settlement: Settlement) -> bool:
	if settlement == null or not settlement.active or settlement.is_supply_base:
		return false
	return true

## 空港を開設する。成功したら true。
func build_airport(settlement_id: int, company_id: int) -> bool:
	var s = world.get_settlement(settlement_id)
	if s == null or not s.active or s.is_supply_base:
		world.add_event("空港を開設できません (対象都市がありません)")
		return false
	if s.has_airport:
		world.add_event("%s には既に空港があります" % s.name)
		return false
	if not is_airport_capable(s):
		world.add_event("%s に空港を開設できません" % s.name)
		return false
	var cost: float = TransportModeConfig.AIRPORT_COST
	if not world.pay_company(company_id, cost):
		world.add_event("資金不足のため %s に空港を開設できません (必要 %.0f)" % [s.name, cost])
		return false
	s.has_airport = true
	s.airport_owner_id = company_id
	world.add_event("%s に空港を開設 (費用 %.0f)" % [s.name, cost])
	return true

func remove_airport(settlement_id: int, company_id: int) -> bool:
	var s = world.get_settlement(settlement_id)
	if s == null or not s.has_airport:
		return false
	s.has_airport = false
	s.airport_owner_id = -1
	world.add_event("%s の空港を撤去" % s.name)
	return true

# ------------------------------------------------------------------
# 航空路
# ------------------------------------------------------------------

## 空港A → 空港B の航空路が成立するか
func can_create_air_connection(from_id: int, to_id: int) -> bool:
	var a = world.get_settlement(from_id)
	var b = world.get_settlement(to_id)
	if a == null or b == null or not a.active or not b.active:
		return false
	if a.is_supply_base or b.is_supply_base:
		return false
	if not a.has_airport or not b.has_airport:
		return false
	return true

## 空港A → 空港B の航空connection を作成。失敗時は null。
func create_air_connection(company_id: int, from_id: int, to_id: int):
	if not can_create_air_connection(from_id, to_id):
		var a = world.get_settlement(from_id)
		var b = world.get_settlement(to_id)
		if a != null and b != null:
			world.add_event("航空路を開設できません: %s ↔ %s には両方の空港が必要" % [a.name, b.name])
		return null
	var route = world.create_route(from_id, to_id, Route.RouteType.AIR, company_id)
	if route == null:
		return null
	var a = world.get_settlement(from_id)
	var b = world.get_settlement(to_id)
	if a != null and b != null:
		route.path_length = a.position.distance_to(b.position)
	return route

## 輸送所要日数 (直行)
func estimate_travel_days(route) -> float:
	if route == null:
		return 0.0
	var dist: float = route.path_length if route.path_length > 0.0 else 0.0
	if dist <= 0.0:
		return 1.0
	return dist / TransportModeConfig.speed(Route.RouteType.AIR)
