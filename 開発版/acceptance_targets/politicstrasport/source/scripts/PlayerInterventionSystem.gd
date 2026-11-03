class_name PlayerInterventionSystem
extends RefCounted

const DEVELOPMENT_MIN := 80.0
const PROMOTION_MIN := 40.0
const FACILITY_BASE_COST := 220.0

var world: WorldState
var bridge: EconomyBridge
var diagnostics: SimulationDiagnostics
var corporate: CorporateSystem = null
var pending_facilities: Array = []
var next_facility_id: int = 1

func _init(p_world: WorldState, p_bridge: EconomyBridge, p_diagnostics: SimulationDiagnostics,
		p_corporate: CorporateSystem = null) -> void:
	world = p_world
	bridge = p_bridge
	diagnostics = p_diagnostics
	corporate = p_corporate

func process_day() -> void:
	for s in world.settlements:
		if not s.active or s.is_supply_base:
			continue
		s.development_support = max(0.0, s.development_support * 0.995)
		s.promotion_support = max(0.0, s.promotion_support * 0.985)
		s.investment_support = max(0.0, s.investment_support * 0.997)
	for facility in pending_facilities:
		if str(facility.status) == "building" and world.day >= int(facility.completion_day):
			_complete_facility(facility)

func support_city(settlement_id: int, amount: float) -> bool:
	var s = world.get_settlement(settlement_id)
	if s == null or not s.active or s.is_supply_base or amount < DEVELOPMENT_MIN:
		return false
	if not world.pay_company(WorldState.PLAYER_COMPANY_ID, amount):
		return false
	s.development_support += amount
	s.reconstruction_demand = max(0.0, s.reconstruction_demand - amount * 0.01)
	diagnostics.record("player_intervention", "%sへ都市開発支援%.0f（成長確率へ間接反映）" % [s.name, amount], 2)
	return true

func promote_city(settlement_id: int, amount: float) -> bool:
	var s = world.get_settlement(settlement_id)
	if s == null or not s.active or amount < PROMOTION_MIN:
		return false
	if not world.pay_company(WorldState.PLAYER_COMPANY_ID, amount):
		return false
	s.promotion_support += amount
	for other in world.settlements:
		if other.active and other.id != s.id and not other.is_supply_base:
			other.passenger_destinations[s.id] = float(other.passenger_destinations.get(s.id, 0.0)) + amount * 0.002
	diagnostics.record("player_intervention", "%sの宣伝支援により旅客関心が上昇" % s.name, 2)
	return true

func invest_region(settlement_id: int, amount: float) -> bool:
	var s = world.get_settlement(settlement_id)
	if s == null or not s.active or amount < 50.0:
		return false
	if not world.pay_company(WorldState.PLAYER_COMPANY_ID, amount):
		return false
	s.investment_support += amount
	s.economy += min(2.0, amount * 0.004)
	diagnostics.record("player_intervention", "%sへ地域投資%.0f（企業誘致補正）" % [s.name, amount], 1)
	return true

func invest_transport_company(target_company_id: int, share: float = 0.10, hostile: bool = false) -> bool:
	if corporate == null or target_company_id == WorldState.PLAYER_COMPANY_ID:
		return false
	return corporate.acquire_company(WorldState.PLAYER_COMPANY_ID, target_company_id, share, hostile)

func acquire_related_business(business_id: int, share: float = 0.51, hostile: bool = false) -> bool:
	if corporate == null:
		return false
	return corporate.acquire_related_business(WorldState.PLAYER_COMPANY_ID, business_id, share, hostile)

func set_subsidiary_directive(child_company_id: int, directive: String, value) -> bool:
	if corporate == null:
		return false
	return corporate.set_subsidiary_directive(WorldState.PLAYER_COMPANY_ID, child_company_id, directive, value)

func build_industry_facility(settlement_id: int, facility_type: String, extra_budget: float = 0.0) -> int:
	var s = world.get_settlement(settlement_id)
	if s == null or not s.active or s.is_supply_base or facility_type == "":
		return -1
	var cost: float = FACILITY_BASE_COST + maxf(0.0, extra_budget)
	if not world.pay_company(WorldState.PLAYER_COMPANY_ID, cost):
		return -1
	var facility := {
		"id": next_facility_id, "settlement_id": settlement_id, "type": facility_type,
		"builder_company_id": WorldState.PLAYER_COMPANY_ID, "owner_company_id": -1,
		"operator_id": "", "status": "building", "start_day": world.day,
		"completion_day": world.day + 12, "cost": cost,
	}
	next_facility_id += 1
	pending_facilities.append(facility)
	world.industry_facilities.append(facility)
	diagnostics.record("facility", "%sで%s施設の建設開始" % [s.name, facility_type], 2)
	return int(facility.id)

func _complete_facility(facility: Dictionary) -> void:
	var operator := bridge.choose_facility_operator(int(facility.settlement_id), str(facility.type))
	facility["status"] = "operating"
	facility["operator_id"] = operator
	facility["owner_company_id"] = -1 # Explicitly never player-owned.
	bridge.register_player_built_facility(facility)
	diagnostics.record("facility", "施設%d完成、運営を%sへ即時移管" % [int(facility.id), operator], 3,
		{"facility_id": facility.id, "operator_id": operator, "player_owned": false})

func get_facility(facility_id: int) -> Dictionary:
	for facility in world.industry_facilities:
		if int(facility.id) == facility_id:
			return facility
	return {}
