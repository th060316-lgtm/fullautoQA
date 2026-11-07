extends Node

signal day_advanced
signal world_changed
signal selection_changed

var world: WorldState
var economy: EconomySystem
var politics: PoliticalSystem
var war: WarSystem
var transport_system: TransportSystem
var competition: CompetitionResolver
var ship_system: ShipSystem
var air_system: AirSystem
var ai_system: AICompetitionSystem
var war_policy: WarSupplyPolicy
var world_dynamics: WorldDynamicsSystem

var selected_settlement_id: int = -1
var selected_route_id: int = -1
var build_mode: int = -1
var first_pick_id: int = -1
var time_scale: float = 1.0
var tick_accumulator: float = 0.0
const DAY_LENGTH := 1.2
var paused: bool = false
var last_built_tile: Vector2i = Vector2i(-999, -999)
var hover_tile: Vector2i = Vector2i(-1, -1)
var preview_cost: float = 0.0

func _ready() -> void:
	world = WorldState.new(20261026)
	world.create_initial_world()
	world.economic_core = EconomicCore.new(world)
	world.economic_core.bootstrap_from_settlements()
	economy = EconomySystem.new(world)
	politics = PoliticalSystem.new(world)
	war = WarSystem.new(world)
	war_policy = war.war_policy
	ship_system = ShipSystem.new(world)
	air_system = AirSystem.new(world)
	transport_system = TransportSystem.new(world)
	transport_system.war_policy = war_policy
	competition = transport_system.competition
	economy.transport_system = transport_system
	ai_system = AICompetitionSystem.new(world)
	ai_system.setup(ship_system, air_system)
	ai_system.configure_ground_provider(world.ground)
	ai_system.create_ai_companies()
	world_dynamics = WorldDynamicsSystem.new(world, war_policy)
	world_dynamics.set_economy_delegate(world.economic_core)
	_setup_minimax_ui()
	emit_signal("world_changed")

func _setup_minimax_ui() -> void:
	var ui := get_node_or_null("../UI")
	if ui == null:
		return
	var overlay_script = load("res://scripts/TransportOverlay.gd")
	if overlay_script != null:
		var overlay = overlay_script.new()
		overlay.name = "TransportOverlay"
		overlay.game = self
		ui.add_child(overlay)
		ui.move_child(overlay, 1)
	var dynamics_overlay_script = load("res://scripts/WorldDynamicsOverlay.gd")
	if dynamics_overlay_script != null:
		var dynamics_overlay = dynamics_overlay_script.new()
		dynamics_overlay.name = "WorldDynamicsOverlay"
		dynamics_overlay.game = self
		ui.add_child(dynamics_overlay)
		ui.move_child(dynamics_overlay, 1)
		dynamics_overlay.setup()
	var mm_script = load("res://scripts/MiniMaxUI.gd")
	if mm_script != null:
		var mm = mm_script.new()
		mm.name = "MiniMaxUI"
		mm.game = self
		ui.add_child(mm)
		mm.setup()

func _process(delta: float) -> void:
	if paused:
		return
	tick_accumulator += delta * time_scale
	while tick_accumulator >= DAY_LENGTH:
		tick_accumulator -= DAY_LENGTH
		_advance_day()

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("remove_route"):
		_handle_remove_shortcut()
		get_viewport().set_input_as_handled()

func _handle_remove_shortcut() -> void:
	if selected_route_id >= 0:
		remove_selected_route()
	else:
		start_remove_infra()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("build_road"):
		start_build_road()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("build_rail"):
		start_build_rail()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("build_ship"):
		start_build_ship()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("build_air"):
		start_build_air()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("build_port"):
		build_port_selected()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("build_airport"):
		build_airport_selected()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("remove_route"):
		_handle_remove_shortcut()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		cancel_build()
		get_viewport().set_input_as_handled()

func _advance_day() -> void:
	world.day += 1
	if world.ground != null:
		world.ground.refresh_logical_routes()
	# Phase B/C pre-effects alter demand and route availability. This does not transport cargo.
	if world_dynamics != null:
		world_dynamics.process_pre_transport()
	# EconomySystem remains the single owner of exactly one process_transport() call/day.
	economy.process_day()
	politics.process_day()
	war.process_day()
	if world_dynamics != null:
		world_dynamics.process_post_transport()
	if ai_system != null:
		ai_system.process_day()
	emit_signal("day_advanced")
	emit_signal("world_changed")

func set_time_scale(scale: float) -> void:
	time_scale = scale

func toggle_pause() -> void:
	paused = not paused

func select_settlement(id: int) -> void:
	selected_settlement_id = id
	selected_route_id = -1
	if build_mode == 2 or build_mode == 3:
		if first_pick_id < 0:
			first_pick_id = id
		else:
			if first_pick_id != id:
				_create_connection(build_mode, first_pick_id, id)
			first_pick_id = -1
			build_mode = -1
	emit_signal("selection_changed")

func _create_connection(mode: int, from_id: int, to_id: int) -> void:
	var route = null
	if mode == 2:
		route = ship_system.create_ship_connection(WorldState.PLAYER_COMPANY_ID, from_id, to_id)
	elif mode == 3:
		route = air_system.create_air_connection(WorldState.PLAYER_COMPANY_ID, from_id, to_id)
	if route != null:
		emit_signal("world_changed")

func select_route(id: int) -> void:
	selected_route_id = id
	selected_settlement_id = -1
	emit_signal("selection_changed")

func start_build_road() -> void:
	build_mode = 0
	first_pick_id = -1
	last_built_tile = Vector2i(-999, -999)
	world.add_event("道路建設モード: タイルをクリック/ドラッグ (費用%.0f/タイル)" % GroundNetwork.ROAD_COST_PER_TILE)

func start_build_rail() -> void:
	build_mode = 1
	first_pick_id = -1
	last_built_tile = Vector2i(-999, -999)
	world.add_event("鉄道建設モード: タイルをクリック/ドラッグ (費用%.0f/タイル)" % GroundNetwork.RAIL_COST_PER_TILE)

func start_build_ship() -> void:
	build_mode = 2
	first_pick_id = -1
	world.add_event("船舶航路モード: 港のある都市を2つ選択")

func start_build_air() -> void:
	build_mode = 3
	first_pick_id = -1
	world.add_event("航空路モード: 空港のある都市を2つ選択")

func start_remove_infra() -> void:
	build_mode = 4
	first_pick_id = -1
	last_built_tile = Vector2i(-999, -999)
	world.add_event("地上インフラ撤去モード: 道路/鉄道タイルをクリック")

func build_port_selected() -> bool:
	if selected_settlement_id < 0:
		world.add_event("港を開設する都市を選択してください")
		return false
	var ok := ship_system.build_port(selected_settlement_id, WorldState.PLAYER_COMPANY_ID)
	if ok:
		emit_signal("world_changed")
	return ok

func build_airport_selected() -> bool:
	if selected_settlement_id < 0:
		world.add_event("空港を開設する都市を選択してください")
		return false
	var ok := air_system.build_airport(selected_settlement_id, WorldState.PLAYER_COMPANY_ID)
	if ok:
		emit_signal("world_changed")
	return ok

func cancel_build() -> void:
	build_mode = -1
	first_pick_id = -1
	last_built_tile = Vector2i(-999, -999)
	preview_cost = 0.0
	world.add_event("建設モード解除")

func remove_selected_route() -> void:
	if selected_route_id >= 0 and world.remove_route(selected_route_id):
		selected_route_id = -1
		if world.ground != null:
			world.ground.refresh_logical_routes()
		emit_signal("world_changed")
		emit_signal("selection_changed")

func get_selected_settlement() -> Settlement:
	return world.get_settlement(selected_settlement_id)

func force_war_for_test() -> void:
	if not world.war_active and world.nations.size() >= 2:
		war._start_war(0, 1)
		emit_signal("world_changed")

func try_build_at_tile(tile: Vector2i) -> void:
	if world == null or world.ground == null or not world.ground.is_valid_coord(tile):
		return
	if build_mode == 0:
		if tile == last_built_tile:
			return
		var res = world.ground.build_road(tile, false, WorldState.PLAYER_COMPANY_ID)
		if res.get("ok", false):
			last_built_tile = tile
			world.add_event("道路敷設 @(%d,%d) 費用%.0f" % [tile.x, tile.y, res.get("cost", 0.0)])
			_after_infra_change()
		elif res.get("msg", "") != "既に道路あり":
			world.add_event("道路失敗: %s" % res.get("msg", "?"))
	elif build_mode == 1:
		if tile == last_built_tile:
			return
		var res2 = world.ground.build_rail(tile, false, WorldState.PLAYER_COMPANY_ID)
		if res2.get("ok", false):
			last_built_tile = tile
			world.add_event("鉄道敷設 @(%d,%d) 費用%.0f" % [tile.x, tile.y, res2.get("cost", 0.0)])
			_after_infra_change()
		elif res2.get("msg", "") != "既に鉄道あり":
			world.add_event("鉄道失敗: %s" % res2.get("msg", "?"))
	elif build_mode == 4:
		var res3 = world.ground.remove_infra(tile, -1)
		if res3.get("ok", false):
			world.add_event("インフラ撤去 @(%d,%d)" % [tile.x, tile.y])
			_after_infra_change()

func _after_infra_change() -> void:
	if world.ground != null:
		world.ground.refresh_logical_routes()
		_auto_discover_player_connections()
	emit_signal("world_changed")

func _auto_discover_player_connections() -> void:
	if world == null or world.ground == null:
		return
	var ids: Array = []
	for s in world.settlements:
		if s.active:
			ids.append(s.id)
	for i in range(ids.size()):
		for j in range(i + 1, ids.size()):
			for mode in [Route.RouteType.ROAD, Route.RouteType.RAIL]:
				if world.ground.has_settlement_connection(ids[i], ids[j], mode):
					world.ground._ensure_logical_route(ids[i], ids[j], mode, WorldState.PLAYER_COMPANY_ID)

func request_ai_ground_connection(company_id: int, mode: int, origin_id: int, destination_id: int) -> Dictionary:
	if world == null or world.ground == null:
		return {"success": false, "msg": "Ground未初期化"}
	var res = world.ground.request_ai_ground_connection(company_id, mode, origin_id, destination_id)
	if res.get("success", false):
		emit_signal("world_changed")
	return res

# Player economic intervention APIs used by UI/QA. They do not command cities/nations.
func support_selected_city(amount: float = 100.0) -> bool:
	return world_dynamics != null and world_dynamics.intervention.support_city(selected_settlement_id, amount)

func promote_selected_city(amount: float = 60.0) -> bool:
	return world_dynamics != null and world_dynamics.intervention.promote_city(selected_settlement_id, amount)

func build_selected_industry(facility_type: String = "general") -> int:
	if world_dynamics == null:
		return -1
	return world_dynamics.intervention.build_industry_facility(selected_settlement_id, facility_type)

func invest_in_company(target_company_id: int, share: float = 0.10, hostile: bool = false) -> bool:
	return world_dynamics != null and world_dynamics.intervention.invest_transport_company(
		target_company_id, share, hostile)

func acquire_related_business(business_id: int, share: float = 0.51, hostile: bool = false) -> bool:
	return world_dynamics != null and world_dynamics.intervention.acquire_related_business(
		business_id, share, hostile)

func set_subsidiary_directive(child_company_id: int, directive: String, value) -> bool:
	return world_dynamics != null and world_dynamics.intervention.set_subsidiary_directive(
		child_company_id, directive, value)
