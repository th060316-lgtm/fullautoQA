# ui/scripts/male_friend_panel.gd
# Male Friend Estimation panel
# CRITICAL: Shows ESTIMATED range, NOT true affection value
# Shows confidence level and accuracy factors

extends Control

var _mfe: Node

@onready var container: VBoxContainer = $MarginContainer/ScrollContainer/VBoxContainer

func _ready() -> void:
	_mfe = get_node_or_null("/root/MaleFriendEstimator")
	_refresh()

func _refresh() -> void:
	for child in container.get_children():
		child.queue_free()

	var estimations = _mfe.get_all_estimations() if _mfe else []

	if estimations.is_empty():
		var empty = Label.new()
		empty.text = "（男友人候補がいません）"
		container.add_child(empty)
		return

	for est in estimations:
		var card = _create_estimation_card(est)
		container.add_child(card)

func _create_estimation_card(est: Dictionary) -> VBoxContainer:
	var card = VBoxContainer.new()

	# Name and confidence
	var header = Label.new()
	header.text = "◆ %s" % est.get("name", est.get("npc_id", "?"))
	header.add_theme_color_override("font_color", Color(0.8, 0.8, 0.6))
	card.add_child(header)

	# Estimation range (NOT true value)
	var range_label = Label.new()
	var rmin = est.get("range_min", 0)
	var rmax = est.get("range_max", 0)
	var conf_label = est.get("confidence_label", "?")
	range_label.text = "推定好意度範囲: %+d ～ %+d  （信頼度: %s）" % [rmin, rmax, conf_label]
	card.add_child(range_label)

	# Accuracy factors
	var acc_label = Label.new()
	var factors = []
	if est.get("has_girlfriend", false):
		factors.append("彼女NPCあり")
	if est.get("is_accompanying", false):
		factors.append("同行中")
	if est.get("memory_modified", false):
		factors.append("記憶変化")
	if factors.is_empty():
		factors.append("良好")
	var acc_pct = int(est.get("accuracy", 0.6) * 100)
	acc_label.text = "推定精度: %d%% （%s）" % [acc_pct, " / ".join(factors))
	card.add_child(acc_label)

	# Observation count
	var obs_label = Label.new()
	obs_label.text = "観察回数: %d  最終更新: 日%d" % [
		est.get("observation_count", 0), est.get("last_updated_day", 1)]
	card.add_child(obs_label)

	# Note
	var note = Label.new()
	note.text = "※ この値は推定であり、真値とは異なります"
	note.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	card.add_child(note)

	# Separator
	var sep = Label.new()
	sep.text = "────────────────"
	sep.add_theme_color_override("font_color", Color(0.3, 0.3, 0.3))
	card.add_child(sep)

	return card

func _on_refresh_pressed() -> void:
	_refresh()

