class_name CargoRegistry
extends RefCounted

## Data-driven cargo registry (Issue #4)
## Distinguishes destination-specific cargo (PASSENGER, MAIL, WAR_SUPPLY)
## from general cargo (FOOD, FUEL, WOOD, ORE, INDUSTRIAL, LUXURY, etc.)
## Existing PASSENGER=0 / FOOD=1 / FUEL=2 remain compatible.

enum CargoKind {
	PASSENGER = 0,
	FOOD = 1,
	FUEL = 2,
	MAIL = 3,
	WOOD = 4,
	COAL = 5,
	ORE = 6,
	INDUSTRIAL = 7,
	LUXURY = 8,
	WAR_SUPPLY = 9,
	EVENT = 10
}

enum CargoCategory {
	PASSENGER_MAIL,   # people/places generate & accept
	PRIMARY,          # resource extraction
	SECONDARY,        # processing / manufacturing
	TERTIARY,         # consumption / services (mostly demand side)
	WAR,
	SPECIAL
}

# Destination-specific: needs explicit origin->dest demand (passenger style)
# General: supply/demand pools per settlement, can be re-routed / redistributed
enum RoutingType {
	DESTINATION_SPECIFIC,
	GENERAL
}

var _defs: Dictionary = {}  # cargo_id -> Dictionary

func _init() -> void:
	_register_defaults()

func _register_defaults() -> void:
	register(CargoKind.PASSENGER, {
		"name": "旅客",
		"name_en": "PASSENGER",
		"category": CargoCategory.PASSENGER_MAIL,
		"routing": RoutingType.DESTINATION_SPECIFIC,
		"base_price_factor": 1.0,
		"is_war": false,
		"producible_by_industry": false,
		"consumable_by_industry": false,
		"default_unit_prices": {0: 0.8, 1: 1.2, 2: 1.6, 3: 3.0}
	})
	register(CargoKind.FOOD, {
		"name": "食料",
		"name_en": "FOOD",
		"category": CargoCategory.PRIMARY,
		"routing": RoutingType.GENERAL,
		"base_price_factor": 1.0,
		"is_war": false,
		"producible_by_industry": true,
		"consumable_by_industry": true,
		"default_unit_prices": {0: 1.0, 1: 1.5, 2: 1.9, 3: 2.0}
	})
	register(CargoKind.FUEL, {
		"name": "燃料",
		"name_en": "FUEL",
		"category": CargoCategory.PRIMARY,
		"routing": RoutingType.GENERAL,
		"base_price_factor": 1.15,
		"is_war": false,
		"producible_by_industry": true,
		"consumable_by_industry": true,
		"default_unit_prices": {0: 1.2, 1: 1.8, 2: 2.1, 3: 2.2}
	})
	register(CargoKind.MAIL, {
		"name": "郵便",
		"name_en": "MAIL",
		"category": CargoCategory.PASSENGER_MAIL,
		"routing": RoutingType.DESTINATION_SPECIFIC,
		"base_price_factor": 0.7,
		"is_war": false,
		"producible_by_industry": false,
		"consumable_by_industry": false,
		"default_unit_prices": {0: 0.5, 1: 0.8, 2: 1.0, 3: 1.8}
	})
	register(CargoKind.WOOD, {
		"name": "木材",
		"name_en": "WOOD",
		"category": CargoCategory.PRIMARY,
		"routing": RoutingType.GENERAL,
		"base_price_factor": 0.85,
		"is_war": false,
		"producible_by_industry": true,
		"consumable_by_industry": true,
		"default_unit_prices": {0: 0.9, 1: 1.3, 2: 1.6, 3: 1.7}
	})
	register(CargoKind.COAL, {
		"name": "石炭",
		"name_en": "COAL",
		"category": CargoCategory.PRIMARY,
		"routing": RoutingType.GENERAL,
		"base_price_factor": 0.95,
		"is_war": false,
		"producible_by_industry": true,
		"consumable_by_industry": true,
		"default_unit_prices": {0: 1.0, 1: 1.4, 2: 1.7, 3: 1.8}
	})
	register(CargoKind.ORE, {
		"name": "鉱石",
		"name_en": "ORE",
		"category": CargoCategory.PRIMARY,
		"routing": RoutingType.GENERAL,
		"base_price_factor": 1.1,
		"is_war": false,
		"producible_by_industry": true,
		"consumable_by_industry": true,
		"default_unit_prices": {0: 1.1, 1: 1.6, 2: 2.0, 3: 2.1}
	})
	register(CargoKind.INDUSTRIAL, {
		"name": "工業製品",
		"name_en": "INDUSTRIAL",
		"category": CargoCategory.SECONDARY,
		"routing": RoutingType.GENERAL,
		"base_price_factor": 1.4,
		"is_war": false,
		"producible_by_industry": true,
		"consumable_by_industry": true,
		"default_unit_prices": {0: 1.5, 1: 2.2, 2: 2.6, 3: 3.0}
	})
	register(CargoKind.LUXURY, {
		"name": "貴重品",
		"name_en": "LUXURY",
		"category": CargoCategory.TERTIARY,
		"routing": RoutingType.GENERAL,
		"base_price_factor": 2.0,
		"is_war": false,
		"producible_by_industry": true,
		"consumable_by_industry": false,
		"default_unit_prices": {0: 2.0, 1: 3.0, 2: 3.5, 3: 4.5}
	})
	register(CargoKind.WAR_SUPPLY, {
		"name": "戦時補給物資",
		"name_en": "WAR_SUPPLY",
		"category": CargoCategory.WAR,
		"routing": RoutingType.DESTINATION_SPECIFIC,
		"base_price_factor": 1.5,
		"is_war": true,
		"producible_by_industry": true,
		"consumable_by_industry": false,
		"default_unit_prices": {0: 2.0, 1: 2.5, 2: 3.0, 3: 3.5}
	})
	register(CargoKind.EVENT, {
		"name": "イベント指定貨物",
		"name_en": "EVENT",
		"category": CargoCategory.SPECIAL,
		"routing": RoutingType.DESTINATION_SPECIFIC,
		"base_price_factor": 1.2,
		"is_war": false,
		"producible_by_industry": false,
		"consumable_by_industry": false,
		"default_unit_prices": {0: 1.2, 1: 1.8, 2: 2.2, 3: 2.8}
	})

func register(cargo_id: int, def: Dictionary) -> void:
	_defs[cargo_id] = def

func has(cargo_id: int) -> bool:
	return _defs.has(cargo_id)

func get_def(cargo_id: int) -> Dictionary:
	return _defs.get(cargo_id, {})

func get_name(cargo_id: int) -> String:
	var d = get_def(cargo_id)
	return d.get("name", "不明貨物%d" % cargo_id)

func get_name_en(cargo_id: int) -> String:
	var d = get_def(cargo_id)
	return d.get("name_en", "CARGO_%d" % cargo_id)

func is_destination_specific(cargo_id: int) -> bool:
	var d = get_def(cargo_id)
	return d.get("routing", RoutingType.GENERAL) == RoutingType.DESTINATION_SPECIFIC

func is_general(cargo_id: int) -> bool:
	return not is_destination_specific(cargo_id)

func get_category(cargo_id: int) -> int:
	var d = get_def(cargo_id)
	return d.get("category", CargoCategory.SPECIAL)

func is_primary(cargo_id: int) -> bool:
	return get_category(cargo_id) == CargoCategory.PRIMARY

func is_secondary(cargo_id: int) -> bool:
	return get_category(cargo_id) == CargoCategory.SECONDARY

func is_tertiary(cargo_id: int) -> bool:
	return get_category(cargo_id) == CargoCategory.TERTIARY

func base_price_factor(cargo_id: int) -> float:
	var d = get_def(cargo_id)
	return float(d.get("base_price_factor", 1.0))

func unit_price(cargo_id: int, mode: int) -> float:
	var d = get_def(cargo_id)
	var prices: Dictionary = d.get("default_unit_prices", {})
	if prices.has(mode):
		return float(prices[mode])
	# Fallback to TransportModeConfig for legacy 0/1/2
	return TransportModeConfig.unit_price(mini(cargo_id, 2), mode) * base_price_factor(cargo_id)

func all_cargo_ids() -> Array:
	return _defs.keys()

func producible_cargo_ids() -> Array:
	var out: Array = []
	for cid in _defs.keys():
		if _defs[cid].get("producible_by_industry", false):
			out.append(cid)
	return out

func legacy_cargo_ids() -> Array:
	return [CargoKind.PASSENGER, CargoKind.FOOD, CargoKind.FUEL]

