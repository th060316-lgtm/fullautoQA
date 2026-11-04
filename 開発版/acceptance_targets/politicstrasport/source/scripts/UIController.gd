extends Control

@onready var game: Node = get_node("/root/Main/GameController")
@onready var money_label: Label = $TopBar/MoneyLabel
@onready var day_label: Label = $TopBar/DayLabel
@onready var seed_label: Label = $TopBar/SeedLabel
@onready var info_panel: RichTextLabel = $RightPanel/InfoPanel
@onready var log_panel: RichTextLabel = $RightPanel/LogPanel
@onready var war_label: Label = $TopBar/WarLabel

var jp_font: Font = null

func _ready() -> void:
	_setup_jp_font()
	if game:
		game.day_advanced.connect(_refresh)
		game.world_changed.connect(_refresh)
		game.selection_changed.connect(_refresh)
	_apply_font_to_labels()
	_refresh()

func _setup_jp_font() -> void:
	var sf = SystemFont.new()
	sf.font_names = PackedStringArray([
		"Noto Sans CJK JP",
		"Noto Sans CJK",
		"Source Han Sans",
		"Yu Gothic",
		"YuGothic",
		"Hiragino Sans",
		"Hiragino Kaku Gothic ProN",
		"Meiryo",
		"MS Gothic",
		"IPAGothic",
		"TakaoPGothic",
		"sans-serif"
	])
	jp_font = sf

func _apply_font_to_labels() -> void:
	if jp_font == null:
		return
	for node in [money_label, day_label, seed_label, war_label]:
		if node:
			node.add_theme_font_override("font", jp_font)
	if info_panel:
		info_panel.add_theme_font_override("normal_font", jp_font)
	if log_panel:
		log_panel.add_theme_font_override("normal_font", jp_font)

func _refresh() -> void:
	if not game or not game.world:
		return
	var w: WorldState = game.world
	money_label.text = "資金: %.0f" % w.money
	day_label.text = "Day %d  (x%.0f)" % [w.day, game.time_scale]
	seed_label.text = "Seed: %d" % w.seed_value

	if w.war_active:
		var na = w.get_nation(w.war_nation_a)
		var nb = w.get_nation(w.war_nation_b)
		war_label.text = "戦争中: %s vs %s (残%d日)" % [na.name if na else "?", nb.name if nb else "?", w.war_days_left]
		war_label.modulate = Color(1.0, 0.4, 0.3)
	else:
		war_label.text = "平和"
		war_label.modulate = Color(0.6, 0.9, 0.6)

	_update_info()
	_update_log()

func _update_info() -> void:
	var w: WorldState = game.world
	var text = ""
	if game.build_mode >= 0:
		var mode_names = {0:"道路建設中", 1:"鉄道建設中", 2:"船舶航路選択中", 3:"航空路選択中", 4:"インフラ撤去中"}
		text += "[b]%s[/b]\n" % mode_names.get(game.build_mode, "操作中")
		if game.build_mode in [0, 1, 4]:
			text += "タイルをクリックまたはドラッグで操作\n"
		else:
			text += "都市を2つ選択\n"
		text += "ESCで解除\n"
		if w.ground:
			text += "道路タイル数: %d\n" % w.ground.count_infra(0)
			text += "鉄道タイル数: %d\n" % w.ground.count_infra(1)
		text += "\n"
	if game.selected_settlement_id >= 0:
		var s = w.get_settlement(game.selected_settlement_id)
		if s:
			if s.is_supply_base:
				text += "[b]補給基地[/b]\n"
				text += "食料需要: %.1f\n" % s.food_demand
				text += "燃料需要: %.1f\n" % s.fuel_demand
				var owner = w.get_nation(s.supply_base_owner_nation)
				text += "支援側: %s\n" % (owner.name if owner else "?")
				if w.ground:
					var term = w.ground.get_terminal(s.id)
					text += "ターミナル: (%d,%d)\n" % [term.x, term.y]
			else:
				var nation = w.get_nation(s.nation_id)
				var state_names = ["好況", "平常", "不況"]
				text += "[b]%s[/b]\n" % s.name
				text += "国家: %s\n" % (nation.name if nation else "?")
				text += "人口: %.1f\n" % s.population
				text += "経済: %.1f\n" % s.economy
				text += "景気: %s\n" % state_names[s.economy_state]
				text += "食料需要: %.1f (供給力 %.1f)\n" % [s.food_demand, s.food_supply_capacity]
				text += "燃料需要: %.1f (供給力 %.1f)\n" % [s.fuel_demand, s.fuel_supply_capacity]
				text += "旅客需要: %.1f\n" % s.passenger_demand
				if s.development_support > 0.1 or s.promotion_support > 0.1 or s.investment_support > 0.1:
					text += "\n[b]プレイヤー介入[/b]\n"
					if s.development_support > 0.1:
						text += "都市支援: %.0f\n" % s.development_support
					if s.promotion_support > 0.1:
						text += "宣伝: %.0f\n" % s.promotion_support
					if s.investment_support > 0.1:
						text += "地域投資: %.0f\n" % s.investment_support
				if s.war_damage > 0.01 or s.reconstruction_demand > 0.01 or s.refugee_pressure > 0.01 or s.occupied_by_nation_id >= 0 or s.port_blockaded:
					text += "\n[b]世界変化[/b]\n"
					if s.war_damage > 0.01:
						text += "戦災: %.0f%%\n" % (s.war_damage * 100.0)
					if s.reconstruction_demand > 0.01:
						text += "復興需要: %.1f  復興%.0f%%\n" % [s.reconstruction_demand, s.reconstruction_progress * 100.0]
					if s.refugee_pressure > 0.01:
						text += "避難民圧力: %.1f\n" % s.refugee_pressure
					if s.occupied_by_nation_id >= 0:
						var occupier = w.get_nation(s.occupied_by_nation_id)
						text += "占領: %s\n" % (occupier.name if occupier else "?")
					if s.port_blockaded:
						text += "港湾封鎖中\n"
				var local_facilities: Array = []
				for facility in w.industry_facilities:
					if int(facility.get("settlement_id", -1)) == s.id:
						local_facilities.append(facility)
				if not local_facilities.is_empty():
					text += "\n[b]産業施設[/b]\n"
					for facility in local_facilities:
						var status := str(facility.get("status", "?"))
						var operator := str(facility.get("operator_id", ""))
						text += "%s / %s%s\n" % [str(facility.get("type", "general")), status,
							(" / " + operator) if operator != "" else ""]
				if w.ground:
					var term = w.ground.get_terminal(s.id)
					text += "ターミナル: (%d,%d)\n" % [term.x, term.y]
	elif game.selected_route_id >= 0:
		for r in w.routes:
			if r.id == game.selected_route_id:
				var from_s = w.get_settlement(r.from_id)
				var to_s = w.get_settlement(r.to_id)
				text += "[b]路線 %s[/b]\n" % r.get_type_name()
				text += "%s ↔ %s\n" % [from_s.name if from_s else "?", to_s.name if to_s else "?"]
				text += "容量: %.0f\n" % r.capacity
				text += "今日収益: %.1f\n" % r.last_revenue
				text += "累計輸送: %.0f\n" % r.total_carried
				var endpoints_active = from_s != null and to_s != null and from_s.active and to_s.active
				var route_state = "稼働" if r.active and endpoints_active else ("廃止対象" if r.active else "無効")
				text += "状態: %s\n" % route_state
				if w.ground and (r.type == Route.RouteType.ROAD or r.type == Route.RouteType.RAIL):
					var connected = w.ground.has_settlement_connection(r.from_id, r.to_id, r.type)
					text += "タイル接続: %s\n" % ("あり" if connected else "なし")
				break
	else:
		text += "都市または路線をクリックして選択\n\n"
		text += "[操作 v0.2 タイル敷設]\n"
		text += "道路建設: ボタン or R → タイルをクリック/ドラッグ\n"
		text += "鉄道建設: ボタン or T → タイルをクリック/ドラッグ\n"
		text += "インフラ撤去: X → タイルをクリック（路線選択中は路線撤去）\n"
		text += "船舶: Y → 港のある都市2つ / 港開設: P\n"
		text += "航空: U → 空港のある都市2つ / 空港開設: A\n"
		text += "速度: x1 / x5  強制開戦: テスト用\n"
		text += "ESC: モード解除\n\n"
		text += "道路 %.0f/タイル 低容量 / 鉄道 %.0f/タイル 高容量\n" % [GroundNetwork.ROAD_COST_PER_TILE, GroundNetwork.RAIL_COST_PER_TILE]
		text += "\n国家一覧:\n"
		for n in w.nations:
			text += "- %s  国力%.0f  安定%.2f\n" % [n.name, n.power, n.stability]
		if w.ground:
			text += "\n道路タイル: %d  鉄道タイル: %d\n" % [w.ground.count_infra(0), w.ground.count_infra(1)]

	info_panel.text = text

func _update_log() -> void:
	var w: WorldState = game.world
	var text = ""
	for entry in w.event_log:
		text += entry + "\n"
	log_panel.text = text

func _on_road_pressed() -> void:
	game.start_build_road()

func _on_rail_pressed() -> void:
	game.start_build_rail()

func _on_remove_pressed() -> void:
	if game.selected_route_id >= 0:
		game.remove_selected_route()
	else:
		game.start_remove_infra()

func _on_x1_pressed() -> void:
	game.set_time_scale(1.0)
	_refresh()

func _on_x5_pressed() -> void:
	game.set_time_scale(5.0)
	_refresh()

func _on_pause_pressed() -> void:
	game.toggle_pause()

func _on_force_war_pressed() -> void:
	game.force_war_for_test()
