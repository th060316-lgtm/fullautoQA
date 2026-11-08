# ui/scripts/rumor_panel.gd
# Information / Rumor panel
# CRITICAL: Separates confirmed facts from uncertain information
# Confirmed systemFacts shown separately from reports with confidence markers

extends Control

var _mem: Node

@onready var tabs: TabContainer = $MarginContainer/TabContainer
@onready var confirmed_list: VBoxContainer = $MarginContainer/TabContainer/ConfirmedFacts/VBoxContainer
@onready var report_list: VBoxContainer = $MarginContainer/TabContainer/Reports/VBoxContainer
@onready var uncertain_list: VBoxContainer = $MarginContainer/TabContainer/UncertainInfo/VBoxContainer

const CONFIDENCE_LABELS = {
	3: "【確認済】",
	2: "【有力】",
	1: "【噂】",
	0: "【矛盾】",
}

func _ready() -> void:
	_mem = get_node_or_null("/root/MemorySystem")
	_refresh()

func _refresh() -> void:
	_refresh_confirmed()
	_refresh_reports()
	_refresh_uncertain()

func _refresh_confirmed() -> void:
	for child in confirmed_list.get_children():
		child.queue_free()

	var facts = _mem.get_all_system_facts_sorted() if _mem else []
	if facts.is_empty():
		var empty = Label.new()
		empty.text = "（確定事実なし）"
		confirmed_list.add_child(empty)
		return

	for fact in facts:
		var row = _create_fact_row(fact)
		confirmed_list.add_child(row)

func _create_fact_row(fact: Dictionary) -> HBoxContainer:
	var row = HBoxContainer.new()
	var day_label = Label.new()
	day_label.text = "[日%d]" % fact.get("timestamp", 1)
	day_label.add_theme_color_override("font_color", Color(0.7, 0.9, 0.7))
	row.add_child(day_label)

	var desc_label = Label.new()
	desc_label.text = fact.get("description", "")
	desc_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(desc_label)
	return row

func _refresh_reports() -> void:
	for child in report_list.get_children():
		child.queue_free()

	var reports = _mem.get_reports() if _mem else []
	reports.sort_custom(func(a, b):
		if a["confidence"] != b["confidence"]:
			return a["confidence"] > b["confidence"]
		if a["day"] != b["day"]:
			return a["day"] < b["day"]
		return a.get("id", "") < b.get("id", "")
	)

	if reports.is_empty():
		var empty = Label.new()
		empty.text = "（証言・分析なし）"
		report_list.add_child(empty)
		return

	var current_cat = -1
	for report in reports:
		var cat = report["category"]
		if cat != current_cat:
			current_cat = cat
			var cat_label = Label.new()
			cat_label.text = _category_name(cat)
			cat_label.add_theme_color_override("font_color", Color(0.9, 0.8, 0.5))
			report_list.add_child(cat_label)

		var row = _create_report_row(report)
		report_list.add_child(row)

func _create_report_row(report: Dictionary) -> HBoxContainer:
	var row = HBoxContainer.new()

	var conf_label = Label.new()
	conf_label.text = CONFIDENCE_LABELS.get(report["confidence"], "【?】")
	var conf_color = Color(0.8, 0.8, 0.8)
	if report["confidence"] >= 3:
		conf_color = Color(0.4, 0.9, 0.4)
	elif report["confidence"] >= 2:
		conf_color = Color(0.8, 0.9, 0.4)
	elif report["confidence"] <= 0:
		conf_color = Color(0.9, 0.3, 0.3)
	conf_label.add_theme_color_override("font_color", conf_color)
	row.add_child(conf_label)

	var day_label = Label.new()
	day_label.text = "[日%d]" % report.get("day", 1)
	day_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	row.add_child(day_label)

	var source_label = Label.new()
	source_label.text = "<%s>" % report.get("sourceId", "?")
	row.add_child(source_label)

	var content_label = Label.new()
	content_label.text = report.get("content", "")
	content_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(content_label)

	return row

func _refresh_uncertain() -> void:
	for child in uncertain_list.get_children():
		child.queue_free()

	var uncertain = _mem.get_uncertain_reports() if _mem else []
	if uncertain.is_empty():
		var empty = Label.new()
		empty.text = "（未確定情報なし）"
		uncertain_list.add_child(empty)
		return

	for report in uncertain:
		var row = _create_report_row(report)
		uncertain_list.add_child(row)

func _category_name(cat: int) -> String:
	var names = {
		0: "━━ 証言 ━━",
		1: "━━ 噂 ━━",
		2: "━━ ヒロイン分析 ━━",
		3: "━━ 男友人推定 ━━",
		4: "━━ 矛盾情報 ━━",
		5: "━━ 未確認 ━━",
	}
	return names.get(cat, "━━ 種別不明 ━━")

func _on_refresh_pressed() -> void:
	_refresh()

