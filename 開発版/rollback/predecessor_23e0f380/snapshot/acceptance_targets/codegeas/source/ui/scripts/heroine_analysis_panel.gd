# ui/scripts/heroine_analysis_panel.gd
# Heroine analysis panel
# Shows affection band, interaction counts, trust/fear/dependence, emotions
# IMPORTANT: Does NOT show raw numerical affection value directly
# Shows band label instead (most important for gameplay)

extends Control

var _hs: Node
var _nm: Node

@onready var affection_band_label: Label = $MarginContainer/VBox/StatusGrid/AffectionBand
@onready var affection_desc_label: Label = $MarginContainer/VBox/AffectionDesc
@onready var interaction_total_label: Label = $MarginContainer/VBox/StatusGrid/InteractionTotal
@onready var interaction_recent_label: Label = $MarginContainer/VBox/StatusGrid/InteractionRecent
@onready var trust_label: Label = $MarginContainer/VBox/StatusGrid/Trust
@onready var fear_label: Label = $MarginContainer/VBox/StatusGrid/Fear
@onready var dependence_label: Label = $MarginContainer/VBox/StatusGrid/Dependence
@onready var emotion_label: Label = $MarginContainer/VBox/EmotionBox/EmotionText
@onready var action_label: Label = $MarginContainer/VBox/ActionBox/ActionText
@onready var summary_label: Label = $MarginContainer/VBox/SummaryBox/SummaryText

func _ready() -> void:
	_hs = get_node_or_null("/root/HeroineSystem")
	_nm = get_node_or_null("/root/NpcManager")
	_refresh()

func _refresh() -> void:
	var state = _hs.get_state_for_ui() if _hs else {}

	# Affection band (not raw value)
	var band_label = state.get("affection_band", "不明")
	affection_band_label.text = band_label

	# Band color
	var band = _hs.get_affection_band() if _hs else 0
	var band_colors = [
		Color(0.9, 0.2, 0.2),  # hostile certain
		Color(0.9, 0.4, 0.2),  # hostile likely
		Color(0.9, 0.7, 0.2),  # danger neg
		Color(0.9, 0.9, 0.2),  # UNCERTAIN ← most dangerous
		Color(0.7, 0.9, 0.3),  # danger pos
		Color(0.4, 0.9, 0.4),  # friendly
		Color(0.2, 0.7, 0.9),  # devoted
	]
	if band >= 0 and band < band_colors.size():
		affection_band_label.add_theme_color_override("font_color", band_colors[band])

	# Affection band description
	var band_descs = [
		"あなたはユイの明確な敵です。彼女的任何行動が敌対的になる可能性があります。",
		"ユイはあなたに敌対的です。裏切りや攻撃の可能性があります。",
		"あなたはユイに嫌われています。行動に注意が必要です。",
		"ユイはあなたに対して未決定です。協力する動機も敌対する動機も弱いです。\nこの状態が最も予測困難で危険です。",
		"ユイはあなたに好意を持ち始めています。関係改善の可能性が高いです。",
		"ユイはあなたを信頼しています。協力的な行動が期待されます。",
		"ユイはあなた献身的に従っています。最も協力的な状態です。",
	]
	if band >= 0 and band < band_descs.size():
		affection_desc_label.text = band_descs[band]

	# Interaction counts
	interaction_total_label.text = "累積: %d" % state.get("interaction_total", 0)
	interaction_recent_label.text = "直近: %d" % state.get("interaction_recent", 0)

	# Trust / Fear / Dependence (shown as progress bar values)
	trust_label.text = "信頼: %+d" % state.get("trust", 0)
	fear_label.text = "恐怖: %+d" % state.get("fear", 0)
	dependence_label.text = "依存: %+d" % state.get("dependence", 0)

	# Emotion
	var emotion_names = {
		"joy": "喜び", "anger": "怒り", "sadness": "悲しみ",
		"fear": "恐怖", "surprise": "驚き", "disgust": "嫌悪",
		"hope": "希望", "anxiety": "不安", "neutral": "普通"
	}
	var current_emo = state.get("current_emotion", "neutral")
	emotion_label.text = "現在の感情: %s" % emotion_names.get(current_emo, current_emo)

	# Action prediction
	var action_names = {
		"IDLE": "待機", "TALK": "会話", "ANALYZE": "分析",
		"WARN": "警告", "REQUEST": "要求", "FLEE": "逃走",
		"ATTACK": "攻撃", "COOPERATE": "協力", "SHARE_INFO": "情報提供",
		"FOLLOW": "同行"
	}
	var next_action = state.get("next_action", "IDLE")
	action_label.text = "推定行動: %s" % action_names.get(next_action, next_action)

	# Summary
	var summary = "ユイは%s%s。%s"
	var alive = "生存中" if state.get("alive", true) else "死亡"
	var present = "同行中" if state.get("present", true) else "離脱"
	var emo = emotion_names.get(current_emo, current_emo)
	summary_label.text = summary % [alive, present, emo]

func _on_refresh_pressed() -> void:
	_refresh()

