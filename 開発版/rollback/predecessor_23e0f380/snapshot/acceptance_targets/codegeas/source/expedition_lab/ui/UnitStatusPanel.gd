extends PanelContainer

const FRIENDLY := Color("52e2d2")
const HEALTHY := Color("4fe0a4")
const WARNING := Color("efa64c")
const DANGER := Color("ff5f64")

var name_label: Label
var hp_bar: ProgressBar
var hp_label: Label
var detail_label: Label
var damage_label: Label

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

func _ready() -> void:
	custom_minimum_size = Vector2(290, 150)
	add_theme_stylebox_override("panel", _style_box(Color(0.025, 0.055, 0.075, 0.93), Color(0.20, 0.40, 0.48, 0.92), 8, 1))

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 9)
	margin.add_theme_constant_override("margin_bottom", 9)
	add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	margin.add_child(box)

	name_label = Label.new()
	name_label.add_theme_font_size_override("font_size", 14)
	name_label.add_theme_color_override("font_color", Color.WHITE)
	box.add_child(name_label)

	var hp_row := HBoxContainer.new()
	hp_row.add_theme_constant_override("separation", 8)
	box.add_child(hp_row)

	hp_bar = ProgressBar.new()
	hp_bar.custom_minimum_size = Vector2(176, 13)
	hp_bar.show_percentage = false
	hp_bar.add_theme_stylebox_override("background", _style_box(Color(0.08, 0.12, 0.13, 0.95), Color(0.16, 0.24, 0.26, 0.7), 4, 1))
	hp_row.add_child(hp_bar)

	hp_label = Label.new()
	hp_label.custom_minimum_size = Vector2(78, 18)
	hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hp_label.add_theme_font_size_override("font_size", 11)
	hp_row.add_child(hp_label)

	detail_label = Label.new()
	detail_label.add_theme_font_size_override("font_size", 11)
	detail_label.add_theme_color_override("font_color", Color("bed0d5"))
	box.add_child(detail_label)

	damage_label = Label.new()
	damage_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	damage_label.add_theme_font_size_override("font_size", 11)
	damage_label.add_theme_color_override("font_color", Color("aabcc1"))
	box.add_child(damage_label)

func update_actor(actor) -> void:
	if actor == null:
		name_label.text = "SELECTED UNIT  /  なし"
		hp_bar.max_value = 100.0
		hp_bar.value = 0.0
		hp_label.text = "--"
		detail_label.text = "ユニットを選択してください"
		damage_label.text = ""
		return

	var effects: Dictionary = actor.get_effects()
	var kind_label := "KMF" if actor.kind == "kmf" else "HUMAN"
	name_label.text = "%s  /  %s" % [actor.display_name, kind_label]

	hp_bar.max_value = maxf(float(actor.max_hp), 1.0)
	hp_bar.value = float(actor.hp)
	hp_label.text = "%.0f / %.0f" % [actor.hp, actor.max_hp]

	var ratio := float(actor.hp) / maxf(float(actor.max_hp), 1.0)
	var hp_color := HEALTHY if ratio > 0.55 else (WARNING if ratio > 0.25 else DANGER)
	hp_bar.add_theme_stylebox_override("fill", _style_box(Color(hp_color.r, hp_color.g, hp_color.b, 0.9), hp_color, 4, 0))
	hp_label.add_theme_color_override("font_color", hp_color)

	var weapon_state := "使用不能" if bool(effects.get("weapon_disabled", false)) else "使用可能"
	detail_label.text = "移動 x%.2f   索敵 x%.2f   武装 %s" % [
		float(effects.get("mobility_multiplier", 1.0)),
		float(effects.get("detection_multiplier", 1.0)),
		weapon_state
	]

	var destroyed = effects.get("destroyed_parts", [])
	damage_label.text = "損傷部位  %s" % ("なし" if destroyed.is_empty() else str(destroyed))
	damage_label.add_theme_color_override("font_color", Color("aabcc1") if destroyed.is_empty() else WARNING)
