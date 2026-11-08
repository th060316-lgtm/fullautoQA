extends PanelContainer

signal command_selected(command: String)

const ACCENT := Color("52e2d2")
const WARNING := Color("f6d25d")
const PANEL_BG := Color(0.02, 0.05, 0.065, 0.97)

var box: VBoxContainer
var last_screen_position := Vector2.ZERO

func _style_box(background: Color, border: Color, radius: int = 7, border_width: int = 1) -> StyleBoxFlat:
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

func _ready() -> void:
	custom_minimum_size = Vector2(238, 0)
	add_theme_stylebox_override("panel", _style_box(PANEL_BG, Color(0.22, 0.48, 0.56, 0.95), 8, 1))
	box = VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	add_child(box)
	visible = false

func _style_button(button: Button) -> void:
	button.custom_minimum_size = Vector2(220, 32)
	button.add_theme_font_size_override("font_size", 12)
	button.add_theme_stylebox_override("normal", _style_box(Color(0.035, 0.08, 0.10, 0.98), Color(0.18, 0.34, 0.40, 0.9), 5, 1))
	button.add_theme_stylebox_override("hover", _style_box(Color(0.055, 0.13, 0.16, 1.0), ACCENT, 5, 1))
	button.add_theme_stylebox_override("pressed", _style_box(Color(0.04, 0.18, 0.18, 1.0), ACCENT, 5, 2))
	button.add_theme_stylebox_override("disabled", _style_box(Color(0.035, 0.045, 0.05, 0.78), Color(0.18, 0.20, 0.21, 0.65), 5, 1))
	button.add_theme_color_override("font_color", Color("e8f2f4"))
	button.add_theme_color_override("font_hover_color", Color.WHITE)
	button.add_theme_color_override("font_disabled_color", Color(0.48, 0.52, 0.53, 0.75))

func show_commands(screen_position: Vector2, commands: Array) -> void:
	for child in box.get_children():
		child.queue_free()
	last_screen_position = screen_position
	position = Vector2(clampf(screen_position.x, 8.0, 1030.0), clampf(screen_position.y - 34.0, 52.0, 466.0))

	var title := Label.new()
	title.text = "TACTICAL COMMAND"
	title.add_theme_font_size_override("font_size", 11)
	title.add_theme_color_override("font_color", Color("8fb7c2"))
	title.custom_minimum_size = Vector2(220, 24)
	box.add_child(title)

	for entry in commands:
		var row: Dictionary = entry if entry is Dictionary else {
			"command": str(entry),
			"action_label": _label(str(entry)),
			"blocked": false,
			"reason": "",
			"hint": ""
		}
		var command := str(row.get("command", ""))
		var button := Button.new()
		button.text = str(row.get("action_label", _label(command)))
		var reason := str(row.get("reason", ""))
		button.disabled = bool(row.get("blocked", false))
		button.tooltip_text = (reason + "
" if not reason.is_empty() else "") + str(row.get("hint", ""))
		_style_button(button)
		button.pressed.connect(func(): command_selected.emit(str(command)); visible = false)
		box.add_child(button)

	if commands.is_empty():
		var empty := Label.new()
		empty.text = "実行可能な行動なし"
		empty.add_theme_color_override("font_color", WARNING)
		empty.custom_minimum_size = Vector2(220, 34)
		box.add_child(empty)
	visible = true

func _label(command: String) -> String:
	var labels := {
		"move": "移動",
		"observe": "観察",
		"attack": "攻撃",
		"suppress": "牽制",
		"target_part": "武器部位狙い",
		"watch": "監視",
		"avoid": "無視/回避",
		"follow": "追従",
		"guard": "援護",
		"heal": "治療",
		"carry": "搬送",
		"board": "搭乗",
		"dismount": "降機",
		"field_repair": "応急修理",
		"inspect": "調査",
		"collect": "回収",
		"use": "使用"
	}
	return str(labels.get(command, command))
