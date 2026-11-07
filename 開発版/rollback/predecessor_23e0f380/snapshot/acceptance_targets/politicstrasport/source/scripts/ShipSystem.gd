class_name ShipSystem
extends RefCounted

## MiniMax: 船舶輸送 (Logic Prototype)
##
## ・港 / 港を持つ都市
## ・海 (WaterMap) を介した水上接続の妥当性確認と簡易自動経路
## ・旅客 / 食料 / 燃料 を輸送 (実輸送は TransportSystem が共有処理)
## ・大容量 / 低速 / 長距離向け
##
## 地上タイル経路探索 (Grok 管轄) は一切持たない。海上専用なので競合しない。

var world: WorldState

func _init(p_world: WorldState) -> void:
	world = p_world

# ------------------------------------------------------------------
# 港
# ------------------------------------------------------------------

## 港を建設できる都市か (海岸線から一定距離以内)
func is_port_capable(settlement: Settlement) -> bool:
	if settlement == null or not settlement.active or settlement.is_supply_base:
		return false
	return WaterMap.is_coastal(settlement.position, TransportModeConfig.PORT_COAST_LIMIT)

## 港を開設する。成功したら true。
func build_port(settlement_id: int, company_id: int) -> bool:
	var s = world.get_settlement(settlement_id)
	if s == null or not s.active or s.is_supply_base:
		world.add_event("港を開設できません (対象都市がありません)")
		return false
	if s.has_port:
		world.add_event("%s には既に港があります" % s.name)
		return false
	if not is_port_capable(s):
		world.add_event("%s は内陸のため港を開設できません" % s.name)
		return false
	var cost: float = TransportModeConfig.PORT_COST
	if not world.pay_company(company_id, cost):
		world.add_event("資金不足のため %s に港を開設できません (必要 %.0f)" % [s.name, cost])
		return false
	s.has_port = true
	s.port_owner_id = company_id
	world.add_event("%s に港を開設 (費用 %.0f)" % [s.name, cost])
	return true

## 港の売却 / 撤去 (AI 撤退判断など)
func remove_port(settlement_id: int, company_id: int) -> bool:
	var s = world.get_settlement(settlement_id)
	if s == null or not s.has_port:
		return false
	s.has_port = false
	s.port_owner_id = -1
	world.add_event("%s の港を撤去" % s.name)
	return true

# ------------------------------------------------------------------
# 航路
# ------------------------------------------------------------------

## 港A → 港B の航路が成立するか (港の存在 + 海上経路の有無)
func can_create_ship_connection(from_id: int, to_id: int) -> bool:
	var a = world.get_settlement(from_id)
	var b = world.get_settlement(to_id)
	if a == null or b == null or not a.active or not b.active:
		return false
	if a.is_supply_base or b.is_supply_base:
		return false
	if not a.has_port or not b.has_port:
		return false
	return get_sea_path(a, b).size() >= 2

## 2都市間の水上経路 (セル中心の折れ線)。成立しない場合は空配列。
func get_sea_path(a: Settlement, b: Settlement) -> PackedVector2Array:
	if a == null or b == null:
		return PackedVector2Array()
	return WaterMap.find_sea_path(a.position, b.position)

## 港A → 港B の船舶connection を作成。失敗時は null。
func create_ship_connection(company_id: int, from_id: int, to_id: int):
	if not can_create_ship_connection(from_id, to_id):
		var a = world.get_settlement(from_id)
		var b = world.get_settlement(to_id)
		if a != null and b != null and (not a.has_port or not b.has_port):
			world.add_event("航路を開設できません: %s ↔ %s には両方の港が必要" % [a.name, b.name])
		else:
			world.add_event("航路を開設できません: %s ↔ %s は海上経路がありません" % [
				a.name if a else "?", b.name if b else "?"])
		return null
	var route = world.create_route(from_id, to_id, Route.RouteType.SHIP, company_id)
	if route == null:
		return null
	var a = world.get_settlement(from_id)
	var b = world.get_settlement(to_id)
	var path := get_sea_path(a, b)
	route.path_points = path
	route.path_length = WaterMap.path_length(path)
	return route

## 輸送所要日数 (_logic prototype: 距離 ÷ 速度)
func estimate_travel_days(route) -> float:
	if route == null:
		return 0.0
	var dist: float = route.path_length if route.path_length > 0.0 else 0.0
	if dist <= 0.0:
		return 1.0
	return dist / TransportModeConfig.speed(Route.RouteType.SHIP)
