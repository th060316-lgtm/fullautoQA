class_name Nation
extends RefCounted

enum EconomicSystem { FREE_MARKET, MIXED, PLANNED, FEUDAL }
enum LogisticsProfile {
	STANDARD,
	FEUDAL_CENTER,
	VASSAL,
	COLONIAL,
	TRIBUTARY,
	SILK_ROAD,
	INTEGRATION_BLOC,
	INTERNATIONAL_ORG,
	MILITARY_ALLIANCE,
	CUSTOMS_UNION,
	FRONTIER
}
enum Scale { CITY_STATE, SMALL, MEDIUM, GREAT_POWER, EMPIRE }

var id: int
var name: String
var color: Color
var stability: float = 0.7
var power: float = 0.0
var war_bonus: float = 0.0
var is_at_war: bool = false
var war_opponent_id: int = -1

# Issue #8/#11: politics are logistics modifiers, not player commands.
var active: bool = true
var economic_system: int = EconomicSystem.MIXED
var logistics_profile: int = LogisticsProfile.STANDARD
var scale: int = Scale.SMALL
var population_size: float = 0.0
var economy_size: float = 0.0
var military_rating: float = 0.0
var policy_state: Dictionary = {}
var diplomatic_relations: Dictionary = {}
var parent_nation_id: int = -1
var founded_day: int = 1
var last_rebellion_day: int = -999

func _init(p_id: int = 0, p_name: String = "", p_color: Color = Color.WHITE):
	id = p_id
	name = p_name
	color = p_color
	stability = 0.7
	war_bonus = 0.0
	policy_state = {
		"tariff": 0.10,
		"trade_openness": 1.0,
		"construction_support": 1.0,
		"passenger_mobility": 1.0,
		"military_priority": 1.0,
		"mail_priority": 1.0,
		"high_value_trade": 1.0,
	}

func recalculate_power(settlements: Array) -> void:
	population_size = 0.0
	economy_size = 0.0
	for s in settlements:
		if s.nation_id == id and s.active and not s.is_supply_base:
			population_size += s.population
			economy_size += s.economy
	power = max(population_size * 0.6 + economy_size * 0.4, 1.0)
	military_rating = max(1.0, power * (0.45 + stability * 0.35))
	_update_scale()

func _update_scale() -> void:
	if power < 22.0:
		scale = Scale.CITY_STATE
	elif power < 55.0:
		scale = Scale.SMALL
	elif power < 115.0:
		scale = Scale.MEDIUM
	elif power < 210.0:
		scale = Scale.GREAT_POWER
	else:
		scale = Scale.EMPIRE

func set_relation(other_id: int, value: float) -> void:
	diplomatic_relations[other_id] = clamp(value, -1.0, 1.0)

func get_relation(other_id: int) -> float:
	return float(diplomatic_relations.get(other_id, 0.0))

func logistics_multiplier(cargo_key: String) -> float:
	var mult := 1.0
	match economic_system:
		EconomicSystem.FREE_MARKET:
			mult = 1.12 if cargo_key != "military" else 0.90
		EconomicSystem.PLANNED:
			mult = 1.18 if cargo_key in ["fuel", "construction", "military"] else 0.88
		EconomicSystem.FEUDAL:
			mult = 0.72 if cargo_key in ["passenger", "mail"] else 0.92
		_:
			mult = 1.0
	if cargo_key == "passenger":
		mult *= float(policy_state.get("passenger_mobility", 1.0))
	elif cargo_key == "construction":
		mult *= float(policy_state.get("construction_support", 1.0))
	elif cargo_key == "military":
		mult *= float(policy_state.get("military_priority", 1.0))
	else:
		mult *= float(policy_state.get("trade_openness", 1.0))

	# Political form is expressed only as logistics demand/route pressure.
	match logistics_profile:
		LogisticsProfile.FEUDAL_CENTER:
			if cargo_key in ["food", "mail", "passenger"]:
				mult *= 1.15
			elif cargo_key in ["industrial", "luxury"]:
				mult *= 0.88
		LogisticsProfile.VASSAL:
			if cargo_key in ["mail", "luxury", "military"]:
				mult *= 1.18
		LogisticsProfile.COLONIAL:
			if cargo_key in ["food", "fuel", "wood", "ore", "industrial"]:
				mult *= 1.16
		LogisticsProfile.TRIBUTARY:
			if cargo_key in ["mail", "luxury", "event"]:
				mult *= 1.24
		LogisticsProfile.SILK_ROAD:
			if cargo_key in ["passenger", "mail", "luxury", "industrial"]:
				mult *= 1.28
		LogisticsProfile.INTEGRATION_BLOC:
			if cargo_key != "military":
				mult *= 1.22
		LogisticsProfile.INTERNATIONAL_ORG:
			if cargo_key in ["passenger", "mail", "event"]:
				mult *= 1.32
		LogisticsProfile.MILITARY_ALLIANCE:
			if cargo_key in ["military", "fuel", "food"]:
				mult *= 1.30
		LogisticsProfile.CUSTOMS_UNION:
			if cargo_key not in ["passenger", "military"]:
				mult *= 1.20
		LogisticsProfile.FRONTIER:
			if cargo_key in ["construction", "industrial", "food", "passenger"]:
				mult *= 1.25
		_:
			pass
	if cargo_key == "mail":
		mult *= float(policy_state.get("mail_priority", 1.0))
	elif cargo_key in ["luxury", "event"]:
		mult *= float(policy_state.get("high_value_trade", 1.0))
	return clamp(mult, 0.25, 3.5)
