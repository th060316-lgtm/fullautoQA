# ui/scripts/geass_panel.gd
# Geass/World status panel — shows world escalation and active geass effects

extends Control

var _wes: Node
var _geass: Node

@onready var world_container: VBoxContainer = $MarginContainer/TabContainer/World/VBoxContainer
@onready var events_container: VBoxContainer = $MarginContainer/TabContainer/Events/VBoxContainer
@onready var geass_container: VBoxContainer = $MarginContainer/TabContainer/Geass/VBoxContainer

func _ready() -> void:
	_wes = get_node_or_null("/root/WorldEventSystem")
	_geass = get_node_or_null("/root/GeassSystem")
	_refresh()

func _refresh() -> void:
	_refresh_world()
	_refresh_events()
	_refresh_geass()

func _refresh_world() -> void:
	_clear_container(world_container)
	var state = _wes.get_world_state() if _wes else {}

	var indicators = [
		{"key": "socialUnrest", "label": "社会不安", "max": 100},
		{"key": "trafficChaos", "label": "交通混乱", "max": 100},
		{"key": "militaryTension", "label": "軍事緊張", "max": 100},
		{"key": "geassSpread", "label": "ギアス拡散度", "max": 100},
	]

	for ind in indicators:
		var val = state.get(ind["key"], 0)
		var bar = _make_bar(val, ind["max"])
		var row = HBoxContainer.new()
		var lbl = Label.new()
		lbl.text = "%s: " % ind["label"]
		lbl.add_theme_color_override("font_color", Color(0.8, 0.8, 0.6))
		row.add_child(lbl)
		row.add_child(bar)
		world_container.add_child(row)

	var code_region = state.get("codeHolderRegion", "不明")
	var guardian_region = state.get("guardianRegion", "不明")
	var location_row = HBoxContainer.new()
	location_row.add_child(_make_label("コード所持女性推定地域: %s" % code_region))
	location_row.add_child(_make_label("護衛男性推定地域: %s" % guardian_region))
	world_container.add_child(location_row)

func _refresh_events() -> void:
	_clear_container(events_container)
	var triggered = _wes.get_all_triggered_events() if _wes else []
	var upcoming = _wes.get_upcoming_events(7) if _wes else []

	var section1 = Label.new()
	section1.text = "━━ 発火済みイベント ━━"
	section1.add_theme_color_override("font_color", Color(0.7, 0.7, 0.5))
	events_container.add_child(section1)

	if triggered.is_empty():
		events_container.add_child(_make_label("（なし）"))
	else:
		for ev in triggered:
			var row = Label.new()
			row.text = "[日%d] %s" % [ev.get("day", 0), ev.get("description", ev.get("event_id", "?"))]
			events_container.add_child(row)

	var section2 = Label.new()
	section2.text = "━━ 予定イベント ━━"
	section2.add_theme_color_override("font_color", Color(0.7, 0.7, 0.5))
	events_container.add_child(section2)

	if upcoming.is_empty():
		events_container.add_child(_make_label("（なし）"))
	else:
		for ev in upcoming:
			var row = Label.new()
			row.text = "[日%d %02d:%02d] %s" % [ev["day"], ev["hour"], ev["minute"], ev.get("description", ev.get("event_id", "?"))]
			events_container.add_child(row)

func _refresh_geass() -> void:
	_clear_container(geass_container)
	var effects = _geass.get_active_effects() if _geass else []

	if effects.is_empty():
		geass_container.add_child(_make_label("（ギアス効果なし）"))
		return

	for effect in effects:
		var row = Label.new()
		var type_names = {
			0: "記憶改変", 1: "感情増幅", 2: "正感情共鳴",
			3: "感情転導", 4: "ギアス付与", 5: "人間関係変化",
			6: "残響", 7: "社会的震源"
		}
		var t = effect.get("type", 0)
		var tname = type_names.get(t, "不明(%d)" % t)
		var target = effect.get("target_id", "?")
		row.text = "[日%d] %s → %s" % [effect.get("day", 0), tname, target]
		geass_container.add_child(row)

func _make_bar(value: int, max_val: int) -> Label:
	var l = Label.new()
	var filled = int((value * 20) / max_val)
	var empty = 20 - filled
	l.text = "[" + "█".repeat(filled) + "·".repeat(empty) + "] %3d%%" % value
	if value > 70:
		l.add_theme_color_override("font_color", Color(0.9, 0.3, 0.3))
	elif value > 40:
		l.add_theme_color_override("font_color", Color(0.9, 0.8, 0.3))
	else:
		l.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4))
	return l

func _make_label(text: String) -> Label:
	var l = Label.new()
	l.text = text
	return l

func _clear_container(c: Container) -> void:
	for child in c.get_children():
		child.queue_free()

func _on_refresh_pressed() -> void:
	_refresh()

