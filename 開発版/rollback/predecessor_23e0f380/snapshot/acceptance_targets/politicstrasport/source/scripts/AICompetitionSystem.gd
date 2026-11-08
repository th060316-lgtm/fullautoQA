class_name AICompetitionSystem
extends RefCounted

const AI_COMPANY_COUNT := 2
const AI_STARTING_MONEY := [1200.0, 1100.0]
const AI_NAMES := ["東邦航空", "銀河海運"]
const AI_MODE_BIAS := [
	{0: 0.95, 1: 1.00, 2: 0.75, 3: 1.70},
	{0: 0.90, 1: 0.85, 2: 1.50, 3: 0.95},
]
const AI_COLORS := [Color(0.92, 0.52, 0.16), Color(0.62, 0.40, 0.92)]
const EVALUATION_INTERVAL := 5

var world: WorldState
var adapter: GroundTransportAdapter
var ship_system: ShipSystem
var air_system: AirSystem
var brains: Array = []
var last_evaluation_day: int = -999

func _init(p_world: WorldState) -> void:
	world = p_world
	adapter = GroundTransportAdapter.new(world)

func setup(p_ship: ShipSystem, p_air: AirSystem) -> void:
	ship_system = p_ship
	air_system = p_air
	for brain in brains:
		brain.setup(adapter, ship_system, air_system)

func configure_ground_provider(provider: Object) -> void:
	adapter.configure_provider(provider)

func create_ai_companies() -> Array:
	var created: Array = []
	for i in range(AI_COMPANY_COUNT):
		var company_id := world.next_company_id()
		var c := TransportCompany.new(company_id, str(AI_NAMES[i]), AI_COLORS[i], false)
		c.money = AI_STARTING_MONEY[i]
		c.mode_bias = AI_MODE_BIAS[i % AI_MODE_BIAS.size()]
		c.strategy = TransportCompany.Strategy.GROWTH if i == 0 else TransportCompany.Strategy.COOPERATIVE
		c.founded_day = world.day
		world.companies.append(c)
		created.append(c)
	_sync_brains()
	return created

func process_day() -> void:
	_sync_brains()
	if brains.is_empty() or world.day - last_evaluation_day < EVALUATION_INTERVAL:
		return
	last_evaluation_day = world.day
	for brain in brains:
		if brain.company != null and brain.company.active:
			brain.evaluate()

func _sync_brains() -> void:
	for c in world.companies:
		if c.is_player or not c.active or _has_brain(c.company_id):
			continue
		var brain := AICompanyBrain.new(c, world)
		brain.setup(adapter, ship_system, air_system)
		brains.append(brain)
	for brain in brains.duplicate():
		if brain.company == null or not brain.company.active:
			brains.erase(brain)

func _has_brain(company_id: int) -> bool:
	for brain in brains:
		if brain.company != null and brain.company.company_id == company_id:
			return true
	return false

func get_ai_companies() -> Array:
	var result: Array = []
	for c in world.companies:
		if not c.is_player and c.active:
			result.append(c)
	return result
