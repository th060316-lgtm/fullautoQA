class_name WorldState
extends RefCounted

const PLAYER_COMPANY_ID := 0

var settlements: Array = []
var routes: Array = []
var nations: Array = []
var companies: Array = []
var industry_facilities: Array = []
var money: float = 500.0
var day: int = 1
var seed_value: int = 12345
var rng: RandomNumberGenerator
var next_settlement_id: int = 0
var next_route_id: int = 0
var next_nation_id: int = 0
var ground: GroundNetwork = null

# Optional cross-package hooks. Assigned by WorldDynamicsSystem.
var economy_bridge: EconomyBridge = null
var diagnostics: SimulationDiagnostics = null
var economic_core: EconomicCore = null

var war_active: bool = false
var war_nation_a: int = -1
var war_nation_b: int = -1
var war_days_left: int = 0
var war_supply_base_id: int = -1
var war_supply_base_ids: Array = []
var war_supply_log_cooldown: Dictionary = {}

var event_log: Array = []
const MAX_LOG = 40

func _init(p_seed: int = 12345):
	seed_value = p_seed
	rng = RandomNumberGenerator.new()
	rng.seed = seed_value
	ground = GroundNetwork.new(self)

func add_event(msg: String) -> void:
	var entry = "D%d: %s" % [day, msg]
	event_log.push_front(entry)
	if event_log.size() > MAX_LOG:
		event_log.pop_back()

func get_settlement(id: int) -> Settlement:
	for s in settlements:
		if s.id == id:
			return s
	return null

func get_nation(id: int) -> Nation:
	for n in nations:
		if n.id == id:
			return n
	return null

func get_route(id: int) -> Route:
	for r in routes:
		if r.id == id:
			return r
	return null

func get_routes_for(settlement_id: int) -> Array:
	var result: Array = []
	for r in routes:
		if r.active and (r.from_id == settlement_id or r.to_id == settlement_id):
			result.append(r)
	return result

func get_company(company_id: int) -> TransportCompany:
	for c in companies:
		if c.company_id == company_id:
			return c
	return null

func get_player_company() -> TransportCompany:
	return get_company(PLAYER_COMPANY_ID)

func next_company_id() -> int:
	var next := 0
	for c in companies:
		next = maxi(next, c.company_id + 1)
	return next

func pay_company(company_id: int, amount: float) -> bool:
	if amount <= 0.0:
		return true
	if company_id == PLAYER_COMPANY_ID:
		if money < amount:
			return false
		money -= amount
		var player_company = get_player_company()
		if player_company != null:
			player_company.register_expense(amount)
	else:
		var c = get_company(company_id)
		if c == null or not c.active or c.money < amount:
			return false
		c.money -= amount
		c.register_expense(amount)
	sync_player_company_money()
	return true

func pay_operating_cost(company_id: int, amount: float) -> void:
	if amount <= 0.0:
		return
	if company_id == PLAYER_COMPANY_ID:
		money = max(0.0, money - amount)
		var player_company = get_player_company()
		if player_company != null:
			player_company.register_expense(amount)
	else:
		var c = get_company(company_id)
		if c != null and c.active:
			c.money = max(0.0, c.money - amount)
			c.register_expense(amount)
	sync_player_company_money()

func add_company_revenue(company_id: int, amount: float) -> void:
	if amount == 0.0:
		return
	if company_id == PLAYER_COMPANY_ID:
		money += amount
		var player_company = get_player_company()
		if player_company != null:
			player_company.register_revenue(amount)
	else:
		var c = get_company(company_id)
		if c != null and c.active:
			c.money += amount
			c.register_revenue(amount)
	sync_player_company_money()

func sync_player_company_money() -> void:
	var pc = get_player_company()
	if pc != null:
		pc.money = money

func create_initial_world() -> void:
	var n0 = Nation.new(0, "赤国", Color(0.85, 0.25, 0.25))
	var n1 = Nation.new(1, "青国", Color(0.25, 0.45, 0.9))
	var n2 = Nation.new(2, "緑国", Color(0.25, 0.7, 0.35))
	n0.stability = 0.65 + rng.randf() * 0.25
	n1.stability = 0.65 + rng.randf() * 0.25
	n2.stability = 0.65 + rng.randf() * 0.25
	nations = [n0, n1, n2]
	next_nation_id = 3

	var cities_data = [
		{"name": "赤都", "pos": Vector2(180, 200), "nation": 0, "pop": 28, "eco": 22, "food_sup": 18, "fuel_sup": 4},
		{"name": "赤港", "pos": Vector2(320, 320), "nation": 0, "pop": 18, "eco": 16, "food_sup": 6, "fuel_sup": 12},
		{"name": "青都", "pos": Vector2(700, 180), "nation": 1, "pop": 30, "eco": 25, "food_sup": 15, "fuel_sup": 5},
		{"name": "青鎮", "pos": Vector2(850, 340), "nation": 1, "pop": 16, "eco": 14, "food_sup": 8, "fuel_sup": 8},
		{"name": "緑都", "pos": Vector2(420, 480), "nation": 2, "pop": 24, "eco": 20, "food_sup": 20, "fuel_sup": 3},
		{"name": "緑谷", "pos": Vector2(600, 520), "nation": 2, "pop": 14, "eco": 12, "food_sup": 10, "fuel_sup": 6},
	]
	for i in range(cities_data.size()):
		var d = cities_data[i]
		var s = Settlement.new(i, d.name, d.pos)
		s.nation_id = d.nation
		s.population = d.pop
		s.economy = d.eco
		s.food_supply_capacity = d.food_sup
		s.fuel_supply_capacity = d.fuel_sup
		s.food_demand = 4.0 + d.pop * 0.15
		s.fuel_demand = 2.0 + d.eco * 0.12
		s.passenger_demand = 3.0 + d.pop * 0.1
		for j in range(cities_data.size()):
			if j != i:
				s.passenger_destinations[j] = 1.0 + rng.randf() * 2.5
		settlements.append(s)
	next_settlement_id = 6
	for n in nations:
		n.recalculate_power(settlements)
	if ground != null:
		ground.initialize_grid()
		ground.assign_terminals()
		ground.paint_nation_ownership_from_settlements()
	create_companies()
	add_event("世界が生成されました。Seed=%d" % seed_value)
	add_event("3国家・6都市が配置されています。")

func create_companies() -> void:
	companies.clear()
	var player_c := TransportCompany.new(PLAYER_COMPANY_ID, "プレイヤー輸送", Color(0.96, 0.84, 0.25), true)
	player_c.money = money
	player_c.founded_day = day
	companies.append(player_c)

func create_route(from_id: int, to_id: int, route_type: int, p_company_id: int = PLAYER_COMPANY_ID) -> Route:
	if from_id == to_id or not TransportModeConfig.is_valid_mode(route_type):
		return null
	var from_s = get_settlement(from_id)
	var to_s = get_settlement(to_id)
	var owner = get_company(p_company_id)
	if from_s == null or to_s == null or not from_s.active or not to_s.active or owner == null or not owner.active:
		return null
	for r in routes:
		if r.active and r.company_id == p_company_id and r.type == route_type \
				and ((r.from_id == from_id and r.to_id == to_id) or (r.from_id == to_id and r.to_id == from_id)):
			return null
	if TransportModeConfig.is_ground(route_type):
		if ground == null or not ground.has_settlement_connection(from_id, to_id, route_type):
			return null
	else:
		if not pay_company(p_company_id, TransportModeConfig.build_cost(route_type)):
			return null
	var route = Route.new(next_route_id, from_id, to_id, route_type)
	next_route_id += 1
	route.company_id = p_company_id
	route.cooperation_group = owner.cooperation_group_id
	if TransportModeConfig.is_ground(route_type):
		route.build_cost = 0.0
		route.path_length = ground.estimate_ground_length(route_type, from_id, to_id)
	routes.append(route)
	owner.add_connection(route.id)
	var suffix := "" if owner.is_player else " [%s]" % owner.company_name
	add_event("%s接続を登録: %s ↔ %s%s" % [TransportModeConfig.mode_name(route_type), from_s.name, to_s.name, suffix])
	return route

func remove_route(route_id: int) -> bool:
	for r in routes.duplicate():
		if r.id == route_id:
			r.active = false
			var from_s = get_settlement(r.from_id)
			var to_s = get_settlement(r.to_id)
			add_event("路線撤去: %s ↔ %s (%s)" % [from_s.name if from_s else "?", to_s.name if to_s else "?", r.get_type_name()])
			routes.erase(r)
			var company = get_company(r.company_id)
			if company != null:
				company.remove_connection(r.id)
			cleanup_inactive_supply_base_if_orphaned(r.from_id)
			cleanup_inactive_supply_base_if_orphaned(r.to_id)
			return true
	return false

func cleanup_inactive_supply_base_if_orphaned(settlement_id: int) -> void:
	var s = get_settlement(settlement_id)
	if s == null or not s.is_supply_base or s.active:
		return
	for r in routes:
		if r.active and (r.from_id == settlement_id or r.to_id == settlement_id):
			return
	settlements.erase(s)

func purge_inactive_supply_bases() -> int:
	var removed := 0
	for s in settlements.duplicate():
		if s.is_supply_base and not s.active:
			settlements.erase(s)
			removed += 1
	return removed
