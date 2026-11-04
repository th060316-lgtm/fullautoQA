class_name RegionalEconomy
extends RefCounted

## Composite urban / regional growth model (Issue #6)
## Separates:
##   - Goods supply contribution -> population growth
##   - Profit / capital accumulation -> economy / firm attraction / scale-up
## Settlement scale stages: HAMLET -> VILLAGE -> TOWN -> CITY -> METROPOLIS

enum ScaleStage {
	HAMLET = 0,    # 集落
	VILLAGE = 1,   # 村
	TOWN = 2,      # 町
	CITY = 3,      # 都市
	METROPOLIS = 4 # 大都市
}

enum BusinessCycle {
	PANIC = 0,       # 恐慌
	RECESSION = 1,   # 不況
	NORMAL = 2,      # 平常
	PROSPERITY = 3,  # 好況
	BOOM = 4         # 大好況
}

const STAGE_NAMES := ["集落", "村", "町", "都市", "大都市"]
const CYCLE_NAMES := ["恐慌", "不況", "平常", "好況", "大好況"]

# Thresholds (population-ish) for stage up/down
const STAGE_UP_POP := [18.0, 40.0, 80.0, 140.0]
const STAGE_DOWN_POP := [12.0, 28.0, 55.0, 100.0]

var settlement_id: int = -1
var scale_stage: int = ScaleStage.HAMLET
var business_cycle: int = BusinessCycle.NORMAL

# Separate accumulators
var goods_supply_score: float = 0.0      # from product deliveries (pop growth)
var profit_attraction_score: float = 0.0 # from transport profits / capital (economy / firms)
var transport_adequacy: float = 0.5       # 0..1 how well connected / supplied
var stability: float = 1.0               # war / disaster damage

# Industry scale in region (sum of production levels nearby)
var industry_scale: float = 1.0

# Day counters for gradual change
var days_in_cycle: int = 0

func _init(p_settlement_id: int = -1):
	settlement_id = p_settlement_id

func stage_name() -> String:
	return STAGE_NAMES[clamp(scale_stage, 0, 4)]

func cycle_name() -> String:
	return CYCLE_NAMES[clamp(business_cycle, 0, 4)]

func cycle_multiplier() -> float:
	match business_cycle:
		BusinessCycle.PANIC:
			return 0.45
		BusinessCycle.RECESSION:
			return 0.70
		BusinessCycle.NORMAL:
			return 1.0
		BusinessCycle.PROSPERITY:
			return 1.25
		BusinessCycle.BOOM:
			return 1.55
	return 1.0

func record_goods_delivery(amount: float, is_primary_or_secondary: bool = true) -> void:
	if amount <= 0.0:
		return
	var weight = 1.0 if is_primary_or_secondary else 0.4
	goods_supply_score += amount * weight * 0.12

func record_profit_inflow(amount: float) -> void:
	if amount <= 0.0:
		return
	profit_attraction_score += amount * 0.08

func record_transport_activity(volume: float, capacity_proxy: float) -> void:
	if capacity_proxy <= 0.01:
		transport_adequacy = max(0.1, transport_adequacy * 0.98)
		return
	var ratio = clamp(volume / capacity_proxy, 0.0, 2.0)
	transport_adequacy = clamp(transport_adequacy * 0.9 + ratio * 0.1, 0.1, 1.5)

## Apply daily composite growth to a Settlement (mutates pop / economy)
## Returns dict of deltas for diagnostics
func apply_daily_growth(settlement: Settlement) -> Dictionary:
	var pop0 = settlement.population
	var eco0 = settlement.economy
	var cm = cycle_multiplier() * stability

	# Goods -> population (Issue #6 separation)
	var pop_delta = goods_supply_score * 0.35 * cm
	# Natural + stage-dependent baseline
	var natural = settlement.population * 0.0015 * cm
	pop_delta += natural

	# Profit attraction -> economy / firm draw
	var eco_delta = profit_attraction_score * 0.40 * cm
	eco_delta += settlement.economy * 0.0012 * cm

	# Transport adequacy soft effect
	pop_delta *= (0.7 + 0.3 * clamp(transport_adequacy, 0.0, 1.2))
	eco_delta *= (0.75 + 0.25 * clamp(transport_adequacy, 0.0, 1.2))

	# Industry scale helps economy more than raw pop
	eco_delta += industry_scale * 0.015 * cm

	# Soft decay of accumulators
	goods_supply_score *= 0.82
	profit_attraction_score *= 0.80

	settlement.population = clamp(settlement.population + pop_delta, 3.0, 350.0)
	settlement.economy = clamp(settlement.economy + eco_delta, 2.0, 300.0)

	_update_scale_stage(settlement)
	days_in_cycle += 1

	return {
		"pop_delta": settlement.population - pop0,
		"eco_delta": settlement.economy - eco0,
		"stage": scale_stage,
		"cycle": business_cycle,
		"goods_score": goods_supply_score,
		"profit_score": profit_attraction_score
	}

func _update_scale_stage(settlement: Settlement) -> void:
	var pop = settlement.population
	# Up
	while scale_stage < ScaleStage.METROPOLIS and pop >= STAGE_UP_POP[scale_stage]:
		scale_stage += 1
	# Down
	while scale_stage > ScaleStage.HAMLET and pop < STAGE_DOWN_POP[scale_stage - 1]:
		scale_stage -= 1

## Map legacy 3-state economy_state into expanded cycle (compat)
func sync_from_legacy_economy_state(legacy: int) -> void:
	match legacy:
		0:  # BOOM
			business_cycle = BusinessCycle.BOOM
		2:  # RECESSION
			business_cycle = BusinessCycle.RECESSION
		_:
			business_cycle = BusinessCycle.NORMAL

func push_legacy_economy_state(settlement: Settlement) -> void:
	match business_cycle:
		BusinessCycle.BOOM, BusinessCycle.PROSPERITY:
			settlement.economy_state = Settlement.EconomyState.BOOM
		BusinessCycle.RECESSION, BusinessCycle.PANIC:
			settlement.economy_state = Settlement.EconomyState.RECESSION
		_:
			settlement.economy_state = Settlement.EconomyState.NORMAL

func maybe_shift_cycle(rng: RandomNumberGenerator, war_pressure: float = 0.0) -> bool:
	if days_in_cycle < 12:
		return false
	var roll = rng.randf() + war_pressure * 0.15
	var old = business_cycle
	if roll < 0.08:
		business_cycle = clamp(business_cycle - 1, BusinessCycle.PANIC, BusinessCycle.BOOM)
	elif roll > 0.92:
		business_cycle = clamp(business_cycle + 1, BusinessCycle.PANIC, BusinessCycle.BOOM)
	if business_cycle != old:
		days_in_cycle = 0
		return true
	return false

func to_dict() -> Dictionary:
	return {
		"settlement_id": settlement_id,
		"scale_stage": scale_stage,
		"business_cycle": business_cycle,
		"goods_supply_score": goods_supply_score,
		"profit_attraction_score": profit_attraction_score,
		"transport_adequacy": transport_adequacy,
		"stability": stability,
		"industry_scale": industry_scale,
		"days_in_cycle": days_in_cycle
	}

