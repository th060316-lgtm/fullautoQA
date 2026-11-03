class_name MarketDemand
extends RefCounted

## Per-settlement, per-cargo market state (Issue #5)
## Saturation reduces effective unit value; local recirculation floor
## prevents mechanical zero revenue for still-acceptable cargo.

var settlement_id: int = -1
var cargo_id: int = 0

# Rolling / cumulative delivered volume (affects saturation)
var cumulative_delivered: float = 0.0
var day_delivered: float = 0.0
var day_accepted: float = 0.0

# Soft capacity of this market (grows with population / economy / industry)
var market_capacity: float = 20.0
# Floor fraction of base price that always remains (local recirculation)
var price_floor_ratio: float = 0.22
# How strongly recent delivery depresses price (0..1+)
var saturation_sensitivity: float = 0.55

# Last computed effective price multiplier (relative to registry base)
var last_effective_multiplier: float = 1.0
var last_saturation: float = 0.0

func _init(p_settlement_id: int = -1, p_cargo_id: int = 0):
	settlement_id = p_settlement_id
	cargo_id = p_cargo_id

func reset_day() -> void:
	day_delivered = 0.0
	day_accepted = 0.0

## Update capacity from settlement scale / economy (called by RegionalEconomy)
func update_capacity(population: float, economy: float, industry_scale: float = 1.0, boom_mult: float = 1.0) -> void:
	# Base capacity scales with pop + economy + local industry
	var base = 8.0 + population * 0.35 + economy * 0.25 + industry_scale * 6.0
	market_capacity = max(5.0, base * boom_mult)

## Saturation ratio in [0, ~2+]. 0 = empty market, 1 = at capacity
func saturation_ratio() -> float:
	if market_capacity <= 0.001:
		return 2.0
	# Prefer recent day + soft cumulative decay
	var effective = day_delivered + cumulative_delivered * 0.08
	return effective / market_capacity

## Effective price multiplier after saturation (never below floor)
func effective_multiplier() -> float:
	var sat = saturation_ratio()
	last_saturation = sat
	# Smooth diminishing: 1 / (1 + sens * sat^1.2)
	var raw = 1.0 / (1.0 + saturation_sensitivity * pow(max(0.0, sat), 1.2))
	var mult = max(price_floor_ratio, raw)
	last_effective_multiplier = mult
	return mult

## Record a delivery. Returns the revenue multiplier used for this unit volume.
func record_delivery(amount: float) -> float:
	if amount <= 0.0:
		return effective_multiplier()
	var mult = effective_multiplier()
	day_delivered += amount
	day_accepted += amount
	cumulative_delivered += amount
	# Soft decay of cumulative so old deliveries fade
	if cumulative_delivered > market_capacity * 8.0:
		cumulative_delivered *= 0.92
	return mult

## How much more volume this market will still accept today at non-floor prices
func remaining_soft_capacity() -> float:
	var sat = saturation_ratio()
	if sat >= 1.6:
		return market_capacity * 0.15  # still accepts a trickle
	return max(0.0, market_capacity * (1.4 - sat))

func to_dict() -> Dictionary:
	return {
		"settlement_id": settlement_id,
		"cargo_id": cargo_id,
		"cumulative_delivered": cumulative_delivered,
		"day_delivered": day_delivered,
		"market_capacity": market_capacity,
		"price_floor_ratio": price_floor_ratio,
		"last_effective_multiplier": last_effective_multiplier,
		"last_saturation": last_saturation
	}

