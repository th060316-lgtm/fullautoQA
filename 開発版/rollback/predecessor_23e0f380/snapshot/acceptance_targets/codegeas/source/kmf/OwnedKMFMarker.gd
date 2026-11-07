extends Node2D
## World-space visual of the parked player KMF.
## All coordinates come from the canonical GameState, including after Save/Load.

var _body: ColorRect
var _name_label: Label

func _ready() -> void:
	_body = ColorRect.new()
	_body.name = "ParkedKMF"
	_body.size = Vector2(28, 28)
	_body.position = Vector2(-14, -14)
	_body.color = Color(0.15, 0.65, 1.0, 1.0)
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_body)
	_name_label = Label.new()
	_name_label.name = "ParkedKMFLabel"
	_name_label.text = "自機KMF (E:搭乗)"
	_name_label.position = Vector2(-28, -42)
	_name_label.add_theme_color_override("font_color", Color(0.6, 0.9, 1.0))
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_name_label)
	_refresh_from_state()
	set_process(true)

func _process(_delta: float) -> void:
	_refresh_from_state()

func _refresh_from_state() -> void:
	var kmf: Dictionary = GameState.get_section("kmf")
	visible = bool(kmf.get("owned", false)) and not bool(kmf.get("boarded", false))
	if not visible:
		return
	var pos: Dictionary = kmf.get("position", {})
	global_position = Vector2(float(pos.get("x", 96.0)), float(pos.get("y", 64.0)))
