class_name CompanyLifecycleSystem
extends RefCounted

const MAX_ACTIVE_COMPANIES := 8
const MIN_AI_COMPANIES := 2
const ENTRY_INTERVAL := 45
const BANKRUPT_DAYS := 30

var world: WorldState
var diagnostics: SimulationDiagnostics

func _init(p_world: WorldState, p_diagnostics: SimulationDiagnostics) -> void:
	world = p_world
	diagnostics = p_diagnostics

func process_day() -> void:
	_update_solvency()
	if world.day % ENTRY_INTERVAL == 0 and active_ai_count() < MAX_ACTIVE_COMPANIES - 1:
		if active_ai_count() < MIN_AI_COMPANIES or world.rng.randf() < 0.45:
			if world.rng.randf() < 0.35:
				var source_types := ["construction", "vehicle_supply", "maintenance"]
				create_company_from_related_industry(source_types[world.rng.randi_range(0, source_types.size() - 1)])
			else:
				create_company("新規参入")
	if world.day % 60 == 0:
		_maybe_merge()
	if world.day % 90 == 0:
		_maybe_split()

func create_company(origin: String = "transport_startup") -> TransportCompany:
	if active_company_count() >= MAX_ACTIVE_COMPANIES:
		return null
	var id := world.next_company_id()
	var c := TransportCompany.new(id, "新興輸送%d" % id,
		Color.from_hsv(fmod(float(id) * 0.173, 1.0), 0.62, 0.92), false)
	c.money = 650.0 + world.rng.randf_range(0.0, 350.0)
	c.founded_day = world.day
	c.origin_business_type = origin
	c.strategy = world.rng.randi_range(TransportCompany.Strategy.BALANCED, TransportCompany.Strategy.OPPORTUNIST)
	c.mode_bias = {0: world.rng.randf_range(0.8, 1.2), 1: world.rng.randf_range(0.8, 1.2),
		2: world.rng.randf_range(0.8, 1.2), 3: world.rng.randf_range(0.8, 1.2)}
	world.companies.append(c)
	diagnostics.record("company", "%s由来で%sが輸送市場へ参入" % [origin, c.company_name], 2,
		{"company_id": id})
	return c

func create_company_from_related_industry(source_type: String) -> TransportCompany:
	if not source_type in ["construction", "vehicle_supply", "maintenance", "industry"]:
		return null
	var c := create_company(source_type)
	if c == null:
		return null
	c.origin_business_type = source_type
	match source_type:
		"construction":
			c.company_name = "建設系輸送%d" % c.company_id
			c.mode_bias[TransportModeConfig.Mode.ROAD] = 1.20
		"vehicle_supply":
			c.company_name = "車両系輸送%d" % c.company_id
			c.mode_bias[TransportModeConfig.Mode.RAIL] = 1.18
		"maintenance":
			c.company_name = "整備系輸送%d" % c.company_id
			c.strategy = TransportCompany.Strategy.CONSERVATIVE
		_:
			c.company_name = "産業系輸送%d" % c.company_id
	diagnostics.record("company", "%s企業が輸送業へ事業参入: %s" % [source_type, c.company_name], 2,
		{"company_id": c.company_id, "origin_business": source_type})
	return c

func _update_solvency() -> void:
	for c in world.companies.duplicate():
		if c.is_player or not c.active:
			continue
		if c.money <= 1.0 and c.last_day_revenue < c.last_day_expense:
			c.insolvent_days += 1
		else:
			c.insolvent_days = max(0, c.insolvent_days - 1)
		if c.insolvent_days >= BANKRUPT_DAYS:
			bankrupt_company(c.company_id)

func bankrupt_company(company_id: int) -> bool:
	var c = world.get_company(company_id)
	if c == null or c.is_player or not c.active:
		return false
	for r in world.routes.duplicate():
		if r.company_id == company_id:
			world.remove_route(r.id)
	c.active = false
	c.owned_connections.clear()
	diagnostics.record("company", "%sが倒産し路線資産を整理" % c.company_name, 3,
		{"company_id": company_id})
	return true

func merge_companies(acquirer_id: int, target_id: int) -> bool:
	var acquirer = world.get_company(acquirer_id)
	var target = world.get_company(target_id)
	if acquirer == null or target == null or not acquirer.active or not target.active or target.is_player:
		return false
	for r in world.routes:
		if r.company_id == target_id:
			r.company_id = acquirer_id
			acquirer.add_connection(r.id)
	target.owned_connections.clear()
	acquirer.money += max(0.0, target.money)
	target.money = 0.0
	target.active = false
	diagnostics.record("company", "%sが%sを合併" % [acquirer.company_name, target.company_name], 3)
	return true

func _maybe_merge() -> void:
	var candidates: Array = []
	for c in world.companies:
		if c.active and not c.is_player:
			candidates.append(c)
	if candidates.size() < 2:
		return
	candidates.sort_custom(func(a, b): return a.estimated_value() > b.estimated_value())
	var strongest = candidates[0]
	var weakest = candidates[candidates.size() - 1]
	if strongest.estimated_value() > weakest.estimated_value() * 2.5 and world.rng.randf() < 0.35:
		merge_companies(strongest.company_id, weakest.company_id)

func _maybe_split() -> void:
	if active_company_count() >= MAX_ACTIVE_COMPANIES:
		return
	for c in world.companies:
		if c.active and not c.is_player and c.get_connection_count() >= 6 and c.money > 1500.0:
			var child = create_company("%s分社" % c.company_name)
			if child == null:
				return
			child.company_name = "%s地域輸送" % c.company_name
			for r in world.routes:
				if r.company_id == c.company_id and r.id % 2 == 0:
					r.company_id = child.company_id
					c.remove_connection(r.id)
					child.add_connection(r.id)
			child.money = c.money * 0.25
			c.money *= 0.75
			diagnostics.record("company", "%sが地域会社へ分裂" % c.company_name, 2)
			return

func active_company_count() -> int:
	var count := 0
	for c in world.companies:
		if c.active:
			count += 1
	return count

func active_ai_count() -> int:
	var count := 0
	for c in world.companies:
		if c.active and not c.is_player:
			count += 1
	return count
