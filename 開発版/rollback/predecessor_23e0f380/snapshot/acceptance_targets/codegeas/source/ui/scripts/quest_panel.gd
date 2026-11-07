# ui/scripts/quest_panel.gd
# Quest panel

extends Control

var _qm: Node

@onready var available_container: VBoxContainer = $MarginContainer/TabContainer/Available/VBoxContainer
@onready var active_container: VBoxContainer = $MarginContainer/TabContainer/Active/VBoxContainer
@onready var completed_container: VBoxContainer = $MarginContainer/TabContainer/Completed/VBoxContainer
@onready var summary_label: Label = $MarginContainer/TabContainer/Summary/SummaryBox/SummaryText

const STATUS_LABELS = {
	0: "受注可能",
	1: "進行中",
	2: "達成",
	3: "失敗",
	4: "キャンセル",
}

const TYPE_LABELS = {
	"delivery": "輸送",
	"rescue": "救助",
	"investigation": "調査",
	"combat": "戦闘",
	"escort": "護衛",
	"search": "捜索",
	"supply": "補給",
	"survival": "生存",
}

func _ready() -> void:
	_qm = get_node_or_null("/root/QuestManager")
	_refresh()

func _refresh() -> void:
	_clear_container(available_container)
	_clear_container(active_container)
	_clear_container(completed_container)

	var available = _qm.get_available_quests() if _qm else []
	var active = _qm.get_active_quests() if _qm else []
	var completed = _qm.get_completed_quests() if _qm else []

	# MiniMax追加: Day1案件の状態をDay1InformationSystemから取得
	var day1_cases = _get_day1_case_overviews()

	for quest in available:
		available_container.add_child(_create_quest_row(quest, day1_cases))
	if available.is_empty():
		available_container.add_child(_make_label("（受注可能なクエストなし）"))

	for quest in active:
		active_container.add_child(_create_quest_row(quest, day1_cases))
	if active.is_empty():
		active_container.add_child(_make_label("（進行中のクエストなし）"))

	for quest in completed:
		completed_container.add_child(_create_quest_row(quest, day1_cases))
	if completed.is_empty():
		completed_container.add_child(_make_label("（完了したクエストなし）"))

	# Summary
	var summary = _qm.get_quest_summary() if _qm else {}
	var day1_text = ""
	if not day1_cases.is_empty():
		var active_count = day1_cases.filter(func(c): return str(c.get("status", "")) in ["active", "available"]).size()
		day1_text = "  [Day1案件: %d件進行中]" % active_count
	summary_label.text = "完了: %d  失敗: %d  進行中: %d  受注可能: %d%s" % [
		summary.get("completed", 0),
		summary.get("failed", 0),
		summary.get("active", 0),
		summary.get("available", 0),
		day1_text,
	]

func _create_quest_row(quest: Dictionary, day1_cases: Array = []) -> HBoxContainer:
	var row = HBoxContainer.new()
	row.set("custom_constants/separation", 6)

	var quest_id = str(quest.get("id", ""))

	# Day1案件の期限情報を取得
	var deadline_text = ""
	var deadline_color = Color(0.8, 0.8, 0.8, 1.0)
	for case_overview in day1_cases:
		if str(case_overview.get("id", "")) == quest_id:
			deadline_text = " " + str(case_overview.get("remaining_text", ""))
			var status = str(case_overview.get("status", ""))
			if status in ["completed"]:
				deadline_color = Color(0.3, 0.8, 0.3, 1.0)
			elif status in ["failed", "expired"]:
				deadline_color = Color(0.9, 0.3, 0.3, 1.0)
			else:
				var remaining = int(case_overview.get("remaining_minutes", 999))
				if remaining < 0:
					deadline_color = Color(0.9, 0.3, 0.3, 1.0)
				elif remaining < 60:
					deadline_color = Color(0.9, 0.7, 0.2, 1.0)
			break

	var status_label = Label.new()
	status_label.text = STATUS_LABELS.get(quest.get("status", 0), "?")
	var status_colors = {
		0: Color(0.4, 0.8, 0.4),
		1: Color(0.8, 0.8, 0.4),
		2: Color(0.3, 0.7, 0.9),
		3: Color(0.9, 0.3, 0.3),
	}
	status_label.add_theme_color_override("font_color", status_colors.get(quest.get("status", 0), Color.WHITE))
	row.add_child(status_label)

	var name_label = Label.new()
	name_label.text = quest.get("name", "?")
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	var type_label = Label.new()
	var quest_type: String = str(quest.get("type", ""))
	type_label.text = str(TYPE_LABELS.get(quest_type, "任務"))
	row.add_child(type_label)

	var obj_label = Label.new()
	var obj_count = quest.get("objectives", []).size()
	var obj_done = quest.get("completed_objectives", []).size()
	obj_label.text = "目標: %d/%d" % [obj_done, obj_count]
	row.add_child(obj_label)

	# MiniMax追加: 残り時間表示
	if deadline_text != "":
		var deadline_label = Label.new()
		deadline_label.text = deadline_text
		deadline_label.add_theme_color_override("font_color", deadline_color)
		row.add_child(deadline_label)

	return row

func _make_label(text: String) -> Label:
	var l = Label.new()
	l.text = text
	return l

func _clear_container(c: Container) -> void:
	for child in c.get_children():
		child.queue_free()

func _on_refresh_pressed() -> void:
	_refresh()

## MiniMax追加: Day1InformationSystemから案件概要を取得
func _get_day1_case_overviews() -> Array:
	var info = get_tree().root.find_child("Day1InformationSystem", true, false)
	if info and info.has_method("get_known_case_overviews"):
		return info.get_known_case_overviews()
	return []
