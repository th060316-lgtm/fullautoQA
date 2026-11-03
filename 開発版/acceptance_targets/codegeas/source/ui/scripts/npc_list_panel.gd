# ui/scripts/npc_list_panel.gd
# NPC list panel — shows all NPCs with status
# NOTE: Does NOT display internal affection truth values in normal UI

extends Control

var _nm: Node
var _hs: Node

@onready var list_container: VBoxContainer = $MarginContainer/ScrollContainer/VBoxContainer
@onready var search_box: LineEdit = $MarginContainer/SearchBar/SearchEdit

func _ready() -> void:
	_nm = get_node_or_null("/root/NpcManager")
	_hs = get_node_or_null("/root/HeroineSystem")
	_refresh_list()

func _refresh_list(filter_text: String = "") -> void:
	# Clear existing items
	for child in list_container.get_children():
		child.queue_free()

	var npc_ids = _nm.get_npc_ids() if _nm else []
	for npc_id in npc_ids:
		var npc = _nm.get_npc(npc_id) if _nm else {}
		if npc.is_empty():
			continue

		var name = npc.get("name", npc_id)
		if filter_text != "" and filter_text.to_lower() not in name.to_lower():
			continue

		var row = _create_npc_row(npc_id, npc)
		list_container.add_child(row)

func _create_npc_row(npc_id: String, npc: Dictionary) -> HBoxContainer:
	var row = HBoxContainer.new()
	row.set("custom_constants/separation", 8)

	# Status indicator (color-coded, no numbers)
	var status_label = Label.new()
	var alive = npc.get("alive", true)
	var present = npc.get("present", true)
	if not alive:
		status_label.text = "[×]"
		status_label.add_theme_color_override("font_color", Color(0.6, 0.1, 0.1))
	elif not present:
		status_label.text = "[?]"
		status_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.2))
	else:
		status_label.text = "[○]"
		status_label.add_theme_color_override("font_color", Color(0.2, 0.7, 0.3))
	row.add_child(status_label)

	# Name
	var name_label = Label.new()
	name_label.text = npc.get("name", npc_id)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	# Affiliation
	var aff_label = Label.new()
	aff_label.text = npc.get("affiliation", "")
	row.add_child(aff_label)

	# Location
	var loc_label = Label.new()
	loc_label.text = npc.get("locationId", "")
	row.add_child(loc_label)

	# Current action
	var action_label = Label.new()
	var action = npc.get("currentAction", "idle")
	var action_labels = {
		"idle": "待機", "guard": "警備", "scavenge": "探索",
		"flee": "逃走", "hostile": "敵対", "work": "作業",
		"search": "搜索", "observe": "観察", "hide": "隠蔽",
		"dead": "死亡", "fled": "脱落"
	}
	action_label.text = action_labels.get(action, action)
	row.add_child(action_label)

	# Emotion
	var emotion_label = Label.new()
	var emotion = npc.get("currentEmotion", "neutral")
	var emotion_labels = {
		"neutral": "普通", "angry": "怒り", "sad": "悲しみ",
		"scared": "恐怖", "hopeful": "希望", "anxious": "不安",
		"hostile": "敵意", "calm": "穏やか", "curious": "関心"
	}
	emotion_label.text = emotion_labels.get(emotion, emotion)
	row.add_child(emotion_label)

	return row

func _on_search_edit_text_changed(text: String) -> void:
	_refresh_list(text)

