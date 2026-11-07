extends CanvasLayer

const ContextCommandMenu = preload("res://expedition_lab/ui/ContextCommandMenu.gd")
const UnitStatusPanel = preload("res://expedition_lab/ui/UnitStatusPanel.gd")
const TacticalMiniMap = preload("res://expedition_lab/ui/TacticalMiniMap.gd")

const FRIENDLY := Color("52e2d2")
const ENEMY := Color("ff5f64")
const ESTIMATED := Color("efa64c")
const INTEL := Color("ffd35a")
const LOOT := Color("b8d957")
const RESCUE := Color("4fe0a4")
const EXTRACTION := Color("84d9ff")
const PAUSE := Color("f6d25d")
const PANEL_BG := Color(0.025, 0.055, 0.075, 0.9)
const PANEL_BORDER := Color(0.20, 0.38, 0.46, 0.86)
const TEXT_MAIN := Color("e6f0f3")
const TEXT_MUTED := Color("9db0b7")

var controller
var top_label: Label
var control_hint: Label
var pause_panel: Panel
var pause_banner: Label
var danger_label: Label
var intel_label: Label
var objective_label: Label
var feedback_label: Label
var route_label: Label
var debug_label: Label
var status_panel
var context_menu
var mini_map
var role_buttons: Array[Button] = []
var intent_buttons: Array[Button] = []
var prep_panel: Panel
var prep_scout: CheckBox
var prep_medic: CheckBox
var prep_kmf: CheckBox
var prep_preset: OptionButton
var speed_buttons: Array[Button] = []
var speed_values := [0.0, 1.0, 4.0, 8.0]

func _ready() -> void:
	controller = get_parent()
	_build_ui()
	controller.state_changed.connect(refresh)
	controller.context_menu_requested.connect(_show_context_menu)
	refresh()

func _style_box(background: Color, border: Color, radius: int = 8, border_width: int = 1) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.border_width_left = border_width
	style.border_width_top = border_width
	style.border_width_right = border_width
	style.border_width_bottom = border_width
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	return style

func _panel(position: Vector2, size: Vector2, background: Color = PANEL_BG, border: Color = PANEL_BORDER) -> Panel:
	var panel := Panel.new()
	panel.position = position
	panel.size = size
	panel.add_theme_stylebox_override("panel", _style_box(background, border))
	add_child(panel)
	return panel

func _button_style(button: Button, accent: Color = FRIENDLY, danger: bool = false) -> void:
	var normal_border := Color(0.21, 0.37, 0.43, 0.86) if not danger else Color(0.55, 0.24, 0.19, 0.9)
	button.add_theme_stylebox_override("normal", _style_box(Color(0.035, 0.08, 0.105, 0.94), normal_border, 6, 1))
	button.add_theme_stylebox_override("hover", _style_box(Color(0.055, 0.12, 0.15, 0.98), accent, 6, 1))
	button.add_theme_stylebox_override("pressed", _style_box(Color(accent.r * 0.16, accent.g * 0.16, accent.b * 0.16, 0.98), accent, 6, 2))
	button.add_theme_stylebox_override("disabled", _style_box(Color(0.035, 0.05, 0.06, 0.62), Color(0.18, 0.22, 0.23, 0.55), 6, 1))
	button.add_theme_color_override("font_color", TEXT_MAIN)
	button.add_theme_color_override("font_hover_color", Color.WHITE)
	button.add_theme_color_override("font_pressed_color", Color.WHITE)
	button.add_theme_color_override("font_disabled_color", Color(0.46, 0.52, 0.54, 0.8))
	button.add_theme_font_size_override("font_size", 12)
	button.custom_minimum_size = Vector2(70, 34)

func _make_text_label(parent: Node, position: Vector2, size: Vector2, font_size: int = 13, color: Color = TEXT_MAIN) -> Label:
	var label := Label.new()
	label.position = position
	label.size = size
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	return label

func _build_ui() -> void:
	var top := _panel(Vector2.ZERO, Vector2(1280, 46), Color(0.015, 0.04, 0.055, 0.96), Color(0.14, 0.32, 0.39, 0.94))
	top_label = _make_text_label(top, Vector2(16, 6), Vector2(760, 22), 14)
	top_label.add_theme_color_override("font_color", Color.WHITE)
	control_hint = _make_text_label(top, Vector2(780, 7), Vector2(484, 20), 11, TEXT_MUTED)
	control_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	var objective_panel := _panel(Vector2(14, 58), Vector2(318, 116))
	objective_label = _make_text_label(objective_panel, Vector2(12, 9), Vector2(294, 98), 14)
	objective_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	var contact_panel := _panel(Vector2(952, 58), Vector2(314, 246))
	intel_label = _make_text_label(contact_panel, Vector2(12, 9), Vector2(290, 104), 12)
	intel_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	mini_map = TacticalMiniMap.new()
	mini_map.position = Vector2(12, 138)
	mini_map.size = Vector2(290, 94)
	mini_map.set_controller(controller)
	contact_panel.add_child(mini_map)

	pause_panel = _panel(Vector2(414, 56), Vector2(452, 38), Color(0.08, 0.075, 0.025, 0.94), Color(PAUSE.r, PAUSE.g, PAUSE.b, 0.9))
	pause_banner = _make_text_label(pause_panel, Vector2(8, 7), Vector2(436, 24), 16, PAUSE)
	pause_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	danger_label = Label.new()
	danger_label.position = Vector2(382, 102)
	danger_label.size = Vector2(516, 30)
	danger_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	danger_label.add_theme_color_override("font_color", Color("ffd47a"))
	danger_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	danger_label.add_theme_constant_override("shadow_offset_x", 1)
	danger_label.add_theme_constant_override("shadow_offset_y", 1)
	danger_label.add_theme_font_size_override("font_size", 14)
	add_child(danger_label)

	status_panel = UnitStatusPanel.new()
	status_panel.position = Vector2(976, 492)
	status_panel.size = Vector2(290, 150)
	add_child(status_panel)

	feedback_label = Label.new()
	feedback_label.position = Vector2(270, 604)
	feedback_label.size = Vector2(680, 32)
	feedback_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	feedback_label.add_theme_color_override("font_color", Color("a8efff"))
	feedback_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.92))
	feedback_label.add_theme_constant_override("shadow_offset_x", 1)
	feedback_label.add_theme_constant_override("shadow_offset_y", 1)
	feedback_label.add_theme_font_size_override("font_size", 14)
	add_child(feedback_label)

	route_label = Label.new()
	route_label.position = Vector2(16, 604)
	route_label.size = Vector2(238, 38)
	route_label.add_theme_color_override("font_color", Color("bfefff"))
	route_label.add_theme_font_size_override("font_size", 12)
	add_child(route_label)

	context_menu = ContextCommandMenu.new()
	context_menu.z_index = 50
	context_menu.command_selected.connect(_execute_context)
	add_child(context_menu)

	var bottom := _panel(Vector2(0, 654), Vector2(1280, 66), Color(0.015, 0.04, 0.055, 0.97), Color(0.14, 0.32, 0.39, 0.96))
	var speed_box := HBoxContainer.new()
	speed_box.position = Vector2(14, 14)
	speed_box.add_theme_constant_override("separation", 6)
	for i in range(speed_values.size()):
		var value: float = speed_values[i]
		var button := Button.new()
		button.text = "PAUSE" if value == 0.0 else "%dx" % int(value)
		button.toggle_mode = true
		button.tooltip_text = "時間停止 Space/P" if value == 0.0 else "シミュレーション速度 %dx" % int(value)
		_button_style(button, PAUSE if value == 0.0 else FRIENDLY)
		button.custom_minimum_size = Vector2(66, 34)
		button.pressed.connect(func(): controller.set_time_scale(value); refresh())
		speed_box.add_child(button)
		speed_buttons.append(button)
	bottom.add_child(speed_box)

	var action_box := HBoxContainer.new()
	action_box.position = Vector2(316, 14)
	action_box.add_theme_constant_override("separation", 4)
	for intent in ["MOVE", "SCOUT", "CLEAR", "ASSAULT", "FIRE_POSITION"]:
		var intent_button := Button.new()
		intent_button.text = "FIRE POS" if intent == "FIRE_POSITION" else intent
		intent_button.toggle_mode = true
		intent_button.tooltip_text = {
			"MOVE":"指定地点へ通常移動",
			"SCOUT":"探索しながら情報を増やす",
			"CLEAR":"区域の角・死角を順に確認",
			"ASSAULT":"交戦しながら前進",
			"FIRE_POSITION":"射線・遮蔽・武器射程を考えて射撃位置を取る"
		}.get(intent, intent)
		_button_style(intent_button, FRIENDLY)
		intent_button.custom_minimum_size = Vector2(82, 34)
		intent_button.pressed.connect(func(): controller.set_intent_mode(intent); refresh())
		action_box.add_child(intent_button)
		intent_buttons.append(intent_button)

	var confirm_button := Button.new()
	confirm_button.text = "CONFIRM"
	confirm_button.tooltip_text = "現在のPreviewを確定  Enter"
	confirm_button.pressed.connect(func(): controller.confirm_intent(); refresh())
	_button_style(confirm_button, Color("72e7ff"))
	confirm_button.custom_minimum_size = Vector2(86, 34)
	action_box.add_child(confirm_button)

	var cancel_button := Button.new()
	cancel_button.text = "CANCEL"
	cancel_button.tooltip_text = "Previewを取消  Esc"
	cancel_button.pressed.connect(func(): controller.cancel_intent_draft(); refresh())
	_button_style(cancel_button, PAUSE)
	cancel_button.custom_minimum_size = Vector2(76, 34)
	action_box.add_child(cancel_button)

	var prep_button := Button.new()
	prep_button.text = "PREP"
	prep_button.tooltip_text = "最初のIntent確定前に編成・装備方針を変更"
	prep_button.pressed.connect(func(): _set_prep_visible(true))
	_button_style(prep_button, Color("b8d957"))
	prep_button.custom_minimum_size = Vector2(64, 34)
	action_box.add_child(prep_button)

	var retreat_button := Button.new()
	retreat_button.text = "撤退"
	retreat_button.pressed.connect(func(): controller.start_retreat(); refresh())
	_button_style(retreat_button, Color("efa64c"), true)
	retreat_button.custom_minimum_size = Vector2(60, 34)
	action_box.add_child(retreat_button)

	var extract_button := Button.new()
	extract_button.text = "離脱"
	extract_button.pressed.connect(func(): controller.evaluate_extraction(false); refresh())
	_button_style(extract_button, EXTRACTION)
	extract_button.custom_minimum_size = Vector2(60, 34)
	action_box.add_child(extract_button)
	bottom.add_child(action_box)

	# Legacy role controls remain as a hidden advanced-policy compatibility surface.
	# The player-facing primary row stays Intent-only; tests/plugins can still reach role_buttons.
	var advanced_role_box := HBoxContainer.new()
	advanced_role_box.visible = false
	for role in ["Follow", "Scout", "Guard", "Medic", "Repair", "HoldFire"]:
		var role_button := Button.new()
		role_button.text = role
		role_button.toggle_mode = true
		role_button.pressed.connect(func(): controller.set_role(controller.state.selected_id, role); refresh())
		advanced_role_box.add_child(role_button)
		role_buttons.append(role_button)
	add_child(advanced_role_box)

	prep_panel = _panel(Vector2(385, 170), Vector2(510, 330), Color(0.018,0.045,0.06,0.985), Color("b8d957"))
	prep_panel.z_index = 60
	prep_panel.visible = false
	var prep_title := _make_text_label(prep_panel, Vector2(18, 14), Vector2(474, 28), 18, Color.WHITE)
	prep_title.text = "EXPEDITION PREPARATION"
	var prep_desc := _make_text_label(prep_panel, Vector2(18, 48), Vector2(474, 56), 12, TEXT_MUTED)
	prep_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	prep_desc.text = "誰を連れて行くか、装備方針を決める。最初のIntent確定後は変更不可。"
	prep_scout = CheckBox.new()
	prep_scout.position = Vector2(24, 112); prep_scout.text = "Scoutを同行"; prep_scout.button_pressed = true
	prep_panel.add_child(prep_scout)
	prep_medic = CheckBox.new()
	prep_medic.position = Vector2(24, 146); prep_medic.text = "Medicを同行"; prep_medic.button_pressed = true
	prep_panel.add_child(prep_medic)
	prep_kmf = CheckBox.new()
	prep_kmf.position = Vector2(24, 180); prep_kmf.text = "KMFを投入（強いが騒音・目立つ）"; prep_kmf.button_pressed = true
	prep_panel.add_child(prep_kmf)
	var preset_label := _make_text_label(prep_panel, Vector2(250, 112), Vector2(230, 22), 12, TEXT_MUTED)
	preset_label.text = "LOADOUT POLICY"
	prep_preset = OptionButton.new()
	prep_preset.position = Vector2(250, 140); prep_preset.size = Vector2(220, 36)
	prep_preset.add_item("Balanced")
	prep_preset.add_item("Stealth")
	prep_preset.add_item("Heavy")
	prep_panel.add_child(prep_preset)
	var prep_apply := Button.new()
	prep_apply.position = Vector2(250, 196); prep_apply.size = Vector2(105, 38); prep_apply.text = "APPLY"
	_button_style(prep_apply, Color("b8d957"))
	prep_apply.pressed.connect(_apply_preparation_from_ui)
	prep_panel.add_child(prep_apply)
	var prep_close := Button.new()
	prep_close.position = Vector2(365, 196); prep_close.size = Vector2(105, 38); prep_close.text = "CLOSE"
	_button_style(prep_close, TEXT_MUTED)
	prep_close.pressed.connect(func(): _set_prep_visible(false))
	prep_panel.add_child(prep_close)
	var prep_hint := _make_text_label(prep_panel, Vector2(24, 250), Vector2(446, 58), 12, TEXT_MUTED)
	prep_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	prep_hint.text = "Balanced: 汎用 / Stealth: 低騒音・短射程 / Heavy: 制圧・盾重視。PREPは戦闘前のリスク選択。"


	debug_label = Label.new()
	debug_label.position = Vector2(350, 180)
	debug_label.size = Vector2(560, 360)
	debug_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	debug_label.add_theme_color_override("font_color", Color("b9ffc6"))
	debug_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	debug_label.add_theme_constant_override("shadow_offset_x", 2)
	debug_label.add_theme_constant_override("shadow_offset_y", 2)
	add_child(debug_label)

func refresh() -> void:
	if controller == null:
		return
	var model: Dictionary = controller.get_hud_model()
	var controls: Dictionary = model.get("controls", {})
	top_label.text = "HOSPITAL DISTRICT   選択: %s   INTENT: %s   TIME: %sx" % [
		str(model.get("selected_name", "なし")),
		str(model.get("intent_mode", "MOVE")),
		str(model.get("time_scale", 1.0))
	]
	control_hint.text = "左: Unit選択   右: Preview   Shift+右: Waypoint   Ctrl+右: Facing   Enter: 確定"

	pause_panel.visible = controller.auto_pause.paused
	pause_banner.text = "TACTICAL PAUSE  —  " + str(model.get("auto_pause_reason", "状況確認中"))

	objective_label.text = "CURRENT OBJECTIVES
%s

Intel %d   Loot %d   Rescue %d" % [
		str(model.get("objective", "")),
		controller.state.acquired_intel.size(),
		controller.state.acquired_loot.size(),
		int(controller.state.metrics.get("rescues", 0))
	]
	danger_label.text = str(model.get("danger", ""))
	feedback_label.text = str(model.get("feedback", ""))

	var preview: Dictionary = model.get("intent_preview", {})
	var route: Dictionary = model.get("route", {})
	if not preview.is_empty() and bool(preview.get("ok", false)):
		route_label.text = "%s  ETA %.1fs  RISK %.0f%%  INFO +%.0f%%" % [str(preview.get("intent","")), float(preview.get("eta",0.0)), float(preview.get("risk",0.0))*100.0, float(preview.get("info_gain",0.0))*100.0]
	else:
		route_label.text = "" if route.is_empty() else "ROUTE  %.0f%%   残り %.1f秒" % [
			float(route.get("progress", 0.0)) * 100.0,
			float(route.get("remaining", 0.0))
		]

	var lines: Array[String] = ["CONTACTS"]
	for contact in model.get("contacts", []):
		var status := str(contact.get("status", "unknown"))
		var status_label: String = str({
			"signal": "反応のみ",
			"estimated": "推定位置",
			"confirmed": "確認済み",
			"lost_contact": "接触喪失"
		}.get(status, "不明"))
		lines.append("• %s  /  %s" % [_contact_label(str(contact.get("id", "?")), status), status_label])
	if lines.size() == 1:
		lines.append("• まだ接触なし")
		lines.append("  Scoutを北へ移動し観察")
	intel_label.text = "
".join(lines)

	var selected_actor = controller.state.actors.get(controller.state.selected_id)
	status_panel.update_actor(selected_actor)
	mini_map.refresh()

	var companion_role_allowed: bool = selected_actor != null and selected_actor.team == "player" and selected_actor.kind == "human" and selected_actor.id != "hero" and not selected_actor.incapacitated and str(selected_actor.meta.get("inside_kmf", "")).is_empty()
	for role_button in role_buttons:
		role_button.disabled = not companion_role_allowed
		role_button.button_pressed = companion_role_allowed and role_button.text == str(selected_actor.meta.get("role", ""))
		role_button.tooltip_text = ("詳細Policy: " + role_button.text) if companion_role_allowed else "仲間Unit用の詳細Policy"

	for button in intent_buttons:
		var intent_name := "FIRE_POSITION" if button.text == "FIRE POS" else button.text
		button.button_pressed = intent_name == str(model.get("intent_mode","MOVE"))
	var prep: Dictionary = model.get("preparation", {})
	if prep_panel != null and not prep_panel.visible:
		prep_scout.button_pressed = bool(prep.get("scout",true))
		prep_medic.button_pressed = bool(prep.get("medic",true))
		prep_kmf.button_pressed = bool(prep.get("kmf",true))
		var preset := str(prep.get("preset","balanced"))
		prep_preset.select(0 if preset=="balanced" else (1 if preset=="stealth" else 2))
	if prep_panel != null:
		prep_scout.disabled = bool(model.get("preparation_locked",false))
		prep_medic.disabled = bool(model.get("preparation_locked",false))
		prep_kmf.disabled = bool(model.get("preparation_locked",false))
		prep_preset.disabled = bool(model.get("preparation_locked",false))

	var current_scale := float(model.get("time_scale", 1.0))
	for i in range(speed_buttons.size()):
		speed_buttons[i].button_pressed = is_equal_approx(current_scale, speed_values[i])

	debug_label.visible = bool(model.get("debug", false))
	debug_label.text = "DEBUG / Hで閉じる
phase=%s sim=%.1f
metrics=%s
contacts(raw)=%s\narea=%s" % [
		str(model.get("phase", "")),
		controller.state.sim_time,
		str(model.get("metrics", {})),
		str(model.get("contacts", [])),
		str(model.get("area_knowledge", {}))
	]

func _contact_label(id: String, status: String) -> String:
	if status != "confirmed":
		return "不明接触"
	var actor = controller.state.actors.get(id)
	return id if actor == null else actor.display_name

func _show_context_menu(screen_position: Vector2, commands: Array) -> void:
	context_menu.show_commands(screen_position, commands)

func _execute_context(command: String) -> void:
	var result: Dictionary = controller.execute_context_command(command)
	if str(result.get("reason", "")) == "part_selection_required":
		context_menu.show_commands(context_menu.last_screen_position, controller.get_part_presentations(str(controller.context_target.get("id", ""))))
	refresh()


func _set_prep_visible(value: bool) -> void:
	if prep_panel != null:
		prep_panel.visible = value

func _apply_preparation_from_ui() -> void:
	var preset: String = str(["balanced","stealth","heavy"][prep_preset.selected])
	var result: Dictionary = controller.apply_preparation({
		"scout":prep_scout.button_pressed,
		"medic":prep_medic.button_pressed,
		"kmf":prep_kmf.button_pressed,
		"preset":preset,
	})
	if bool(result.get("ok",false)):
		_set_prep_visible(false)
	refresh()
