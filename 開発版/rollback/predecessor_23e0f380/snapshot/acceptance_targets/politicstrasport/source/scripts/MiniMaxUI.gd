extends Node

var game: Node = null
var company_panel: RichTextLabel = null
var diagnostics_panel: RichTextLabel = null
var change_banner: Label = null
var _buttons: Array = []

func setup() -> void:
	if game == null:
		return
	_create_buttons()
	_create_company_panel()
	_create_diagnostics_panel()
	_create_change_banner()
	if game.has_signal("world_changed"):
		game.world_changed.connect(_refresh_all)

func _create_buttons() -> void:
	var top_bar = game.get_node_or_null("../UI/ActionBar")
	if top_bar == null:
		return
	_add_button(top_bar, "船舶航路(Y)", func(): game.start_build_ship())
	_add_button(top_bar, "航空路(U)", func(): game.start_build_air())
	_add_button(top_bar, "港(P)", func(): game.build_port_selected())
	_add_button(top_bar, "空港(A)", func(): game.build_airport_selected())
	_add_button(top_bar, "都市支援", func(): _support_city())
	_add_button(top_bar, "宣伝", func(): _promote_city())
	_add_button(top_bar, "地域投資", func(): _invest_region())
	_add_button(top_bar, "産業建設", func(): _build_industry())

func _add_button(top_bar: Node, label: String, handler: Callable) -> void:
	var b := Button.new()
	b.text = label
	b.focus_mode = Control.FOCUS_NONE
	top_bar.add_child(b)
	var separator = top_bar.get_node_or_null("TestSeparator")
	if separator != null:
		top_bar.move_child(b, separator.get_index())
	b.pressed.connect(handler)
	_buttons.append(b)

func _create_company_panel() -> void:
	var right_panel = game.get_node_or_null("../UI/RightPanel")
	if right_panel == null:
		return
	company_panel = RichTextLabel.new()
	company_panel.name = "CompanyPanel"
	company_panel.bbcode_enabled = true
	company_panel.scroll_active = true
	company_panel.custom_minimum_size = Vector2(0, 165)
	right_panel.add_child(company_panel)
	_refresh_company_panel()

func _create_change_banner() -> void:
	var ui = game.get_node_or_null("../UI")
	if ui == null:
		return
	change_banner = Label.new()
	change_banner.name = "WorldChangeBanner"
	change_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	change_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	change_banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	change_banner.set_anchors_preset(Control.PRESET_TOP_WIDE)
	change_banner.offset_left = 80.0
	change_banner.offset_right = -340.0
	change_banner.offset_top = 74.0
	change_banner.offset_bottom = 106.0
	change_banner.add_theme_font_size_override("font_size", 17)
	change_banner.add_theme_constant_override("outline_size", 5)
	change_banner.add_theme_color_override("font_color", Color(1.0, 0.94, 0.55))
	change_banner.add_theme_color_override("font_outline_color", Color(0.08, 0.08, 0.10, 0.92))
	ui.add_child(change_banner)
	_refresh_change_banner()


func _refresh_change_banner() -> void:
	if change_banner == null or game == null or game.world == null:
		return
	var w: WorldState = game.world
	var message := ""
	if game.world_dynamics != null:
		var important: Array = game.world_dynamics.diagnostics.recent(2, 1)
		if not important.is_empty():
			var item: Dictionary = important[0]
			message = "世界変化 D%d｜%s" % [int(item.get("day", w.day)), str(item.get("message", ""))]
	if message == "" and not w.event_log.is_empty():
		message = str(w.event_log[0])
	change_banner.text = message


func _create_diagnostics_panel() -> void:
	var right_panel = game.get_node_or_null("../UI/RightPanel")
	if right_panel == null:
		return
	diagnostics_panel = RichTextLabel.new()
	diagnostics_panel.name = "WorldDiagnosticsPanel"
	diagnostics_panel.bbcode_enabled = true
	diagnostics_panel.scroll_active = true
	diagnostics_panel.custom_minimum_size = Vector2(0, 150)
	right_panel.add_child(diagnostics_panel)
	_refresh_diagnostics_panel()

func _refresh_all() -> void:
	_refresh_company_panel()
	_refresh_diagnostics_panel()
	_refresh_change_banner()

func _refresh_company_panel() -> void:
	if company_panel == null or game == null or game.world == null:
		return
	var w: WorldState = game.world
	var text := "[b]輸送会社[/b]\n"
	for c in w.companies:
		if not c.active:
			continue
		var tag: String = "[color=#%s]■[/color] " % str(c.color.to_html(false))
		var relation := " 子会社" if c.parent_company_id >= 0 else ""
		text += "%s%s%s 資金%.0f 路線%d 損益%+.1f\n" % [tag, c.company_name, relation,
			c.money, c.get_connection_count(), c.last_day_revenue - c.last_day_expense]
	text += "\n[b]路線一覧[/b]\n"
	var shown := 0
	for r in w.routes:
		if not r.active:
			continue
		var comp = w.get_company(r.company_id)
		var a = w.get_settlement(r.from_id)
		var b = w.get_settlement(r.to_id)
		text += "%s %s↔%s 株%.0f%% 損益%+.1f\n" % [r.get_type_name(),
			a.name if a else "?", b.name if b else "?", r.market_share * 100.0, r.profit]
		text += "  %s / %s\n" % [comp.company_name if comp else "?", r.profit_change_reason]
		shown += 1
		if shown >= 6:
			break
	company_panel.text = text

func _refresh_diagnostics_panel() -> void:
	if diagnostics_panel == null or game == null or game.world == null:
		return
	var w: WorldState = game.world
	var text := "[b]世界・経済地図凡例[/b]\n赤破線=遮断 赤丸=戦災 橙=占領 水色=復興 黄=避難民\n"
	if game.world_dynamics != null:
		text += "前線: %+.0f%%  国家:%d 企業:%d\n" % [game.world_dynamics.front.get_front_progress() * 100.0,
			game.world_dynamics.nations.active_nation_count(), game.world_dynamics.companies.active_company_count()]
		text += "[b]主要変化[/b]\n"
		for item in game.world_dynamics.diagnostics.recent(1, 5):
			text += "D%d [%s] %s\n" % [item.day, item.category, item.message]
	if w.economic_core != null:
		var economic_snapshot: Dictionary = w.economic_core.diagnostic_snapshot()
		text += "[b]産業市場[/b] 施設%d 産業会社%d\n" % [
			int(economic_snapshot.get("facility_count", 0)),
			int(economic_snapshot.get("industry_company_count", 0))]
		var economic_events: Array = economic_snapshot.get("recent_events", [])
		for i in range(mini(3, economic_events.size())):
			var event: Dictionary = economic_events[i]
			text += "D%d [%s] %s\n" % [int(event.get("day", 0)),
				str(event.get("category_name", "経済")), str(event.get("message", ""))]
	if game.selected_route_id >= 0 and w.diagnostics != null:
		text += "[b]選択路線の急変理由[/b] %s\n" % w.diagnostics.get_route_reason(game.selected_route_id)
		if w.economic_core != null:
			var reasons: Array = w.economic_core.diagnostics.get_route_reason_names(game.selected_route_id)
			if not reasons.is_empty():
				text += "市場要因: %s\n" % ", ".join(reasons)
	diagnostics_panel.text = text

func _support_city() -> void:
	if game.selected_settlement_id < 0:
		game.world.add_event("都市支援: 都市を選択してください")
		return
	if game.support_selected_city(100.0):
		game.emit_signal("world_changed")

func _promote_city() -> void:
	if game.selected_settlement_id < 0:
		game.world.add_event("宣伝: 都市を選択してください")
		return
	if game.promote_selected_city(60.0):
		game.emit_signal("world_changed")

func _invest_region() -> void:
	if game.selected_settlement_id < 0:
		game.world.add_event("地域投資: 都市を選択してください")
		return
	if game.world_dynamics != null and game.world_dynamics.intervention.invest_region(
			game.selected_settlement_id, 80.0):
		game.emit_signal("world_changed")

func _build_industry() -> void:
	if game.selected_settlement_id < 0:
		game.world.add_event("産業建設: 都市を選択してください")
		return
	if game.build_selected_industry("general") >= 0:
		game.emit_signal("world_changed")
