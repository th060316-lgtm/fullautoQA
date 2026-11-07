extends CanvasLayer
## HUD - 常時表示
## EXT-20261019-010: help / objective / deadline / result 追加
## 内部好感度真値は通常HUDへ出さない
## Q/O 強制進行は通常系から除去し、Debug専用に隔離
##
## MiniMax担当追加 (DAY1-REPAIR-20261019-5TO5):
## - KMFレポート集約通知（digest）
## - 案件期限・残時間・移動予測UI
## - Day1終了画面（day1_feedback）
## - ユイ会話結果通知

@onready var hp_label: Label = $Panel/HPLabel
@onready var fatigue_label: Label = $Panel/FatigueLabel
@onready var time_label: Label = $Panel/TimeLabel
@onready var loc_label: Label = $Panel/LocLabel
@onready var kmf_label: Label = $Panel/KMFLabel
@onready var heroine_label: Label = $Panel/HeroineLabel
@onready var help_label: Label = $Panel/HelpLabel
@onready var objective_label: Label = $Panel/ObjectiveLabel
@onready var deadline_label: Label = $Panel/DeadlineLabel
@onready var result_label: Label = $Panel/ResultLabel
@onready var debug_label: Label = $Panel/DebugLabel
@onready var panel_container: Control = $PanelContainer  # MiniMax panel UI 追加用コンテナ

# --- Phase 0.5 Block 1: HUD Safe Area / インタラクション表示 ---
var _interaction_service: Node = null
var _prompt_panel: PanelContainer = null
var _prompt_label: Label = null
var _compact: bool = true
var _occlusion_alert: bool = false
var _last_prompt_text: String = ""

var _day1: Node = null
var _info: Node = null
var _gs: Node = null
var _presentation: Node = null
var _debug_tools_enabled: bool = false

## --- MiniMax追加: KMF digest通知 ---
var _kmf_digest_label: Label = null
var _kmf_digest_panel: PanelContainer = null
var _kmf_digest_timer: Timer = null

## --- MiniMax追加: 案件期限UI ---
var _case_deadline_panel: PanelContainer = null
var _case_deadline_vbox: VBoxContainer = null
var _case_deadline_timer: Timer = null

## --- MiniMax追加: ユイ会話結果通知 ---
var _yui_notification_label: Label = null
var _yui_notification_timer: Timer = null

## --- MiniMax追加: Day1終了画面 ---
var _day1_end_screen: Control = null
var _day1_end_visible: bool = false
var _navigation_label: Label = null

func _ready() -> void:
	_gs = get_node_or_null("/root/GameState")
	_debug_tools_enabled = bool(ProjectSettings.get_setting("day1_debug/tools_enabled", false))
	EventBus.player_hp_changed.connect(_on_hp)
	EventBus.player_fatigue_changed.connect(_on_fatigue)
	EventBus.time_advanced.connect(func(_m): _refresh())
	EventBus.player_mode_changed.connect(func(_m): _refresh())
	EventBus.kmf_state_changed.connect(_refresh)
	EventBus.debug_message.connect(_on_debug)
	EventBus.player_notice.connect(_on_notice)
	EventBus.save_completed.connect(func(_s): _on_notice("セーブしました"))
	EventBus.load_completed.connect(func(_s): _on_notice("ロードしました"))
	debug_label.visible = _debug_tools_enabled

	# Day1Controller 参照（Main直下想定）
	_day1 = get_tree().root.find_child("Day1Controller", true, false)
	_presentation = get_tree().root.find_child("Day1PresentationAdapter", true, false)
	_info = get_tree().root.find_child("Day1InformationSystem", true, false)

	# MiniMax追加: EventBus信号接続
	_connect_minimax_signals()

	# MiniMax追加: KMF digest通知UI構築
	_build_kmf_digest_ui()

	# MiniMax追加: 案件期限UI構築
	_build_case_deadline_ui()

	# MiniMax追加: ユイ通知UI構築
	_build_yui_notification_ui()

	# MiniMax追加: Day1終了画面構築
	_build_day1_end_screen()
	_build_navigation_hint()

	# Phase 0.5 Block 1: インタラクション表示 + Safe Area 対応
	_build_interaction_prompt_ui()
	_interaction_service = get_tree().root.find_child("InteractionService", true, false)
	if _interaction_service != null and _interaction_service.has_signal("prompt_changed"):
		_interaction_service.connect("prompt_changed", _on_interaction_prompt)
	add_to_group("hud")
	_apply_compact_state()

	_refresh()
	set_process_unhandled_input(true)

func _connect_minimax_signals() -> void:
	if EventBus.has_signal("kmf_digest_ready"):
		EventBus.kmf_digest_ready.connect(_on_kmf_digest_ready)
	if EventBus.has_signal("day1_feedback_ready"):
		EventBus.day1_feedback_ready.connect(_on_day1_feedback_ready)
	if EventBus.has_signal("day1_case_state_changed"):
		EventBus.day1_case_state_changed.connect(_on_case_state_changed)
	if EventBus.has_signal("heroine_state_changed"):
		EventBus.heroine_state_changed.connect(_on_heroine_state_changed)
	if EventBus.has_signal("day1_action_committed"):
		EventBus.day1_action_committed.connect(_on_day1_action_committed_hud)
	if EventBus.has_signal("day1_case_discovered"):
		EventBus.day1_case_discovered.connect(_on_case_discovered)

## ============================================================
## MiniMax追加: KMF digest通知UI
## ============================================================

func _build_kmf_digest_ui() -> void:
	# パネルの作成
	_kmf_digest_panel = PanelContainer.new()
	_kmf_digest_panel.name = "KMFDigestPanel"
	_kmf_digest_panel.anchors_preset = Control.PRESET_TOP_RIGHT
	_kmf_digest_panel.anchor_left = 1.0
	_kmf_digest_panel.anchor_top = 0.0
	_kmf_digest_panel.anchor_right = 1.0
	_kmf_digest_panel.anchor_bottom = 0.0
	_kmf_digest_panel.offset_left = -320.0
	_kmf_digest_panel.offset_top = 8.0
	_kmf_digest_panel.offset_right = -8.0
	_kmf_digest_panel.offset_bottom = 80.0
	_kmf_digest_panel.z_index = 50
	_kmf_digest_panel.visible = false

	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.1, 0.05, 0.05, 0.9)
	panel_style.set_border_width_all(1)
	panel_style.border_color = Color(0.7, 0.3, 0.1, 1.0)
	panel_style.set_corner_radius_all(4)
	panel_style.set_content_margin_all(8)
	_kmf_digest_panel.add_theme_stylebox_override("panel", panel_style)

	var vbox = VBoxContainer.new()
	vbox.name = "VBox"
	_kmf_digest_panel.add_child(vbox)

	var title = Label.new()
	title.name = "Title"
	title.text = "【KMF目撃情報】"
	title.add_theme_color_override("font_color", Color(0.9, 0.6, 0.2, 1.0))
	vbox.add_child(title)

	_kmf_digest_label = Label.new()
	_kmf_digest_label.name = "Content"
	_kmf_digest_label.text = ""
	_kmf_digest_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_kmf_digest_label.add_theme_color_override("font_color", Color(0.9, 0.8, 0.7, 1.0))
	vbox.add_child(_kmf_digest_label)

	add_child(_kmf_digest_panel)

	# 自動非表示タイマー
	_kmf_digest_timer = Timer.new()
	_kmf_digest_timer.name = "KMFDigestTimer"
	_kmf_digest_timer.one_shot = true
	_kmf_digest_timer.timeout.connect(_hide_kmf_digest)
	add_child(_kmf_digest_timer)

func _show_kmf_digest(digest: Dictionary) -> void:
	if not is_instance_valid(_kmf_digest_label):
		return

	var short = str(digest.get("short", ""))
	var content = str(digest.get("content", ""))
	var importance = str(digest.get("importance", "low"))
	var count = int(digest.get("total_reports", 0))

	var color = Color(0.7, 0.8, 0.7, 1.0)
	if importance == "high":
		color = Color(0.9, 0.3, 0.2, 1.0)
	elif importance == "medium":
		color = Color(0.9, 0.7, 0.2, 1.0)

	_kmf_digest_label.text = "%s (%d件の報告を集約)" % [content, count]
	_kmf_digest_label.add_theme_color_override("font_color", color)

	_kmf_digest_panel.visible = true

	# 5秒後に自動非表示
	_kmf_digest_timer.stop()
	_kmf_digest_timer.start(5.0)

	_on_debug("KMF目撃: %s" % importance)

func _hide_kmf_digest() -> void:
	if is_instance_valid(_kmf_digest_panel):
		_kmf_digest_panel.visible = false

func _on_kmf_digest_ready(digest: Dictionary) -> void:
	_show_kmf_digest(digest)

## ============================================================
## MiniMax追加: 案件期限・残時間・移動予測UI
## ============================================================

func _build_case_deadline_ui() -> void:
	_case_deadline_panel = PanelContainer.new()
	_case_deadline_panel.name = "CaseDeadlinePanel"
	_case_deadline_panel.anchors_preset = Control.PRESET_CENTER_TOP
	_case_deadline_panel.anchor_left = 0.5
	_case_deadline_panel.anchor_top = 0.0
	_case_deadline_panel.anchor_right = 0.5
	_case_deadline_panel.anchor_bottom = 0.0
	_case_deadline_panel.offset_left = -280.0
	_case_deadline_panel.offset_top = 8.0
	_case_deadline_panel.offset_right = 280.0
	_case_deadline_panel.offset_bottom = 180.0
	_case_deadline_panel.z_index = 40
	_case_deadline_panel.visible = false

	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.05, 0.08, 0.12, 0.85)
	panel_style.set_border_width_all(1)
	panel_style.border_color = Color(0.3, 0.5, 0.7, 0.8)
	panel_style.set_corner_radius_all(4)
	panel_style.set_content_margin_all(6)
	_case_deadline_panel.add_theme_stylebox_override("panel", panel_style)

	var scroll = ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_case_deadline_panel.add_child(scroll)

	_case_deadline_vbox = VBoxContainer.new()
	_case_deadline_vbox.name = "VBox"
	_case_deadline_vbox.add_theme_constant_override("separation", 4)
	scroll.add_child(_case_deadline_vbox)

	add_child(_case_deadline_panel)

	# 更新タイマー
	_case_deadline_timer = Timer.new()
	_case_deadline_timer.name = "CaseDeadlineTimer"
	_case_deadline_timer.one_shot = false
	_case_deadline_timer.wait_time = 30.0
	_case_deadline_timer.timeout.connect(_refresh_case_deadlines)
	add_child(_case_deadline_timer)
	_case_deadline_timer.start()

func _refresh_case_deadlines() -> void:
	if not is_instance_valid(_case_deadline_vbox):
		return

	# 子のクリア
	for child in _case_deadline_vbox.get_children():
		child.queue_free()

	# Day1InformationSystemから案件概要を取得
	var overviews: Array = []
	if _info and _info.has_method("get_known_case_overviews"):
		overviews = _info.get_known_case_overviews()
	elif _day1 and _day1.has_method("get_known_cases"):
		# フォールバック
		overviews = _get_case_overviews_fallback()

	if overviews.is_empty():
		_case_deadline_panel.visible = false
		return

	_case_deadline_panel.visible = true

	# ヘッダー
	var header = Label.new()
	header.text = "【案件一覧】"
	header.add_theme_color_override("font_color", Color(0.5, 0.7, 0.9, 1.0))
	_case_deadline_vbox.add_child(header)

	for overview in overviews:
		var row = _create_case_deadline_row(overview)
		_case_deadline_vbox.add_child(row)

func _create_case_deadline_row(overview: Dictionary) -> HBoxContainer:
	var row = HBoxContainer.new()
	row.set("custom_constants/separation", 6)

	var name = str(overview.get("name", "?"))
	var status = str(overview.get("status", "active"))
	var remaining_text = str(overview.get("remaining_text", "?"))
	var travel = overview.get("travel_estimate", {})
	var deadline_text = str(overview.get("deadline_text", "?"))

	# ステータス色
	var status_color = Color(0.8, 0.8, 0.8, 1.0)
	var bg_color = Color(0.1, 0.1, 0.1, 0.0)
	match status:
		"completed":
			status_color = Color(0.3, 0.8, 0.3, 1.0)
			bg_color = Color(0.0, 0.15, 0.0, 0.5)
		"failed", "expired":
			status_color = Color(0.8, 0.2, 0.2, 1.0)
			bg_color = Color(0.15, 0.0, 0.0, 0.5)
		"active", "available":
			var remaining = int(overview.get("remaining_minutes", 999))
			if remaining < 0:
				status_color = Color(0.8, 0.2, 0.2, 1.0)
			elif remaining < 60:
				status_color = Color(0.9, 0.7, 0.2, 1.0)

	# 案件名
	var name_label = Label.new()
	name_label.text = "・%s" % name
	name_label.add_theme_color_override("font_color", status_color)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	# 残り時間
	var remaining_label = Label.new()
	remaining_label.text = remaining_text
	remaining_label.add_theme_color_override("font_color", status_color)
	row.add_child(remaining_label)

	# 移動予測（activeな案件のみ）
	if status in ["active", "available"] and travel is Dictionary:
		var est_minutes = int(travel.get("estimated_minutes", 0))
		var mode = str(travel.get("mode", "foot"))
		var mode_str = "徒" if mode == "foot" else "KMF"
		var travel_label = Label.new()
		travel_label.text = "→%s %d分" % [mode_str, est_minutes]
		travel_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6, 1.0))
		row.add_child(travel_label)

	return row

func _get_case_overviews_fallback() -> Array:
	## Day1InformationSystemがない場合のフォールバック
	var overviews: Array = []
	if _day1 == null:
		return overviews

	var day1 = _gs.get_section("day1") if _gs else {}
	var known_cases: Array = day1.get("known_cases", [])
	var case_states: Dictionary = day1.get("case_states", {})
	var now_minute = _gs.get_minute_of_day() if _gs else 0
	var player_loc = str(_gs.get_section("player").get("locationId", "base") if _gs else "base")
	var mode = str(_gs.get_section("player").get("mode", "foot") if _gs else "foot")

	var case_defs: Dictionary = {
		"quest_hospital_medicine": {"name": "病院医薬品輸送", "loc": "hospital"},
		"quest_evacuation_rescue": {"name": "避難民救助", "loc": "evacuation_center"},
		"quest_supply_depot": {"name": "食料倉庫確保", "loc": "industrial_area"},
	}

	for case_id in known_cases:
		var state = case_states.get(case_id, {})
		var def = case_defs.get(case_id, {})
		var deadline = int(state.get("deadline_abs_minute", 0))
		var remaining = deadline - now_minute
		var status = str(state.get("status", "active"))

		var overview = {
			"name": str(def.get("name", case_id)),
			"status": status,
			"remaining_minutes": remaining,
			"remaining_text": _format_remaining_fallback(remaining),
			"deadline_text": _format_minute_fallback(deadline),
			"travel_estimate": _get_travel_estimate_fallback(player_loc, str(def.get("loc", "")), mode),
		}
		overviews.append(overview)

	return overviews

func _format_remaining_fallback(minutes: int) -> String:
	if minutes < 0: return "期限切れ"
	elif minutes < 30: return "残り%d分(至急!)" % minutes
	elif minutes < 60: return "残り%d分" % minutes
	else: return "残り%d時間%d分" % [minutes / 60, minutes % 60]

func _format_minute_fallback(minute: int) -> String:
	return "%02d:%02d" % [minute / 60, minute % 60]

func _get_travel_estimate_fallback(from: String, to: String, mode: String) -> Dictionary:
	var foot_times: Dictionary = {
		"base->hospital": 20, "base->city_center": 25,
		"hospital->base": 20, "hospital->city_center": 15,
		"city_center->base": 25, "city_center->hospital": 15,
	}
	var kmf_times: Dictionary = {
		"base->hospital": 5, "base->city_center": 8,
		"hospital->base": 5, "hospital->city_center": 4,
		"city_center->base": 8, "city_center->hospital": 4,
	}
	var key = "%s->%s" % [from, to]
	var foot = int(foot_times.get(key, 30))
	var kmf = int(kmf_times.get(key, 10))
	return {
		"estimated_minutes": kmf if mode == "kmf" else foot,
		"foot_minutes": foot, "kmf_minutes": kmf, "mode": mode,
		"is_estimate": true,
	}

func _on_case_state_changed(case_id: String, old_status: String, new_status: String) -> void:
	_refresh_case_deadlines()

func _on_case_discovered(case_id: String, source: Dictionary) -> void:
	_refresh_case_deadlines()

## ============================================================
## MiniMax追加: ユイ会話結果通知
## ============================================================

func _build_yui_notification_ui() -> void:
	_yui_notification_label = Label.new()
	_yui_notification_label.name = "YuiNotification"
	_yui_notification_label.anchors_preset = Control.PRESET_CENTER
	_yui_notification_label.anchor_left = 0.5
	_yui_notification_label.anchor_top = 0.5
	_yui_notification_label.anchor_right = 0.5
	_yui_notification_label.anchor_bottom = 0.5
	_yui_notification_label.offset_left = -300.0
	_yui_notification_label.offset_top = -60.0
	_yui_notification_label.offset_right = 300.0
	_yui_notification_label.offset_bottom = -20.0
	_yui_notification_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_yui_notification_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_yui_notification_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_yui_notification_label.z_index = 100
	_yui_notification_label.visible = false
	_yui_notification_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.6, 1.0))
	add_child(_yui_notification_label)

	_yui_notification_timer = Timer.new()
	_yui_notification_timer.name = "YuiNotificationTimer"
	_yui_notification_timer.one_shot = true
	_yui_notification_timer.timeout.connect(_hide_yui_notification)
	add_child(_yui_notification_timer)

func _show_yui_notification(text: String, duration: float = 3.0) -> void:
	if not is_instance_valid(_yui_notification_label):
		return
	_yui_notification_label.text = text
	_yui_notification_label.visible = true
	_yui_notification_timer.stop()
	_yui_notification_timer.start(duration)

func _hide_yui_notification() -> void:
	if is_instance_valid(_yui_notification_label):
		_yui_notification_label.visible = false

func _on_heroine_state_changed(field: String, old_val, new_val) -> void:
	if field == "affection":
		var band = _get_affection_band_label(int(new_val))
		_show_yui_notification("ユイの反応が変わった… %s" % band, 3.0)
	elif field == "trust":
		if int(new_val) > int(old_val):
			_show_yui_notification("ユイがあなたを信頼し始めている。", 2.5)
		elif int(new_val) < int(old_val):
			_show_yui_notification("ユイの信頼が揺らいでいる。", 2.5)
	elif field == "fear":
		if int(new_val) > 50:
			_show_yui_notification("ユイは恐怖を感じている。行動に注意が必要です。", 3.0)

func _on_day1_action_committed_hud(action: Dictionary) -> void:
	var action_type = str(action.get("type", ""))
	var mode = str(action.get("mode", ""))

	# ユイ会話結果通知
	if action_type == "talk" and str(action.get("npc", "")) == "yui":
		var topic = str(action.get("topic", ""))
		match topic:
			"briefing":
				_show_yui_notification("ユイ「状況を確認するわ。優先順位をつけて行動して。」", 3.5)
			"advice":
				_show_yui_notification("ユイ「方法は選べる。自分で決めて。」", 3.0)
			"return_report":
				_show_yui_notification("ユイ「お疲れ様。報告を受け取るわ。」", 3.0)
			_:
				_show_yui_notification("ユイと会話した。", 2.5)

	# KMF使用通知（ユイの反応）
	elif mode == "kmf":
		var hs = get_node_or_null("/root/HeroineSystem")
		if hs:
			var fear = int(hs.get_state().get("fear", 0))
			if fear > 30:
				_show_yui_notification("ユイがKMFの使用に不安を感じている。", 3.0)

func _get_affection_band_label(affection: int) -> String:
	if affection <= -81: return "敵対確定"
	elif affection <= -51: return "敵対の可能性"
	elif affection <= -11: return "負の危険域"
	elif affection <= 10: return "未決定（最大不確実性）"
	elif affection <= 50: return "正の危険域"
	elif affection <= 80: return "友好"
	else: return "献身"

## ============================================================
## MiniMax追加: Day1終了画面（day1_feedback）
## ============================================================

func _build_day1_end_screen() -> void:
	_day1_end_screen = Control.new()
	_day1_end_screen.name = "Day1EndScreen"
	_day1_end_screen.anchors_preset = Control.PRESET_FULL_RECT
	_day1_end_screen.visible = false
	_day1_end_screen.z_index = 200

	# 背景_overlay
	var overlay = ColorRect.new()
	overlay.name = "Overlay"
	overlay.anchors_preset = Control.PRESET_FULL_RECT
	overlay.color = Color(0.0, 0.0, 0.0, 0.8)
	_day1_end_screen.add_child(overlay)

	# メインパネル
	var panel = PanelContainer.new()
	panel.name = "Panel"
	panel.anchors_preset = Control.PRESET_CENTER
	panel.anchor_left = 0.5
	panel.anchor_top = 0.5
	panel.anchor_right = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -360.0
	panel.offset_top = -300.0
	panel.offset_right = 360.0
	panel.offset_bottom = 300.0

	var panel_style = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.05, 0.05, 0.1, 0.95)
	panel_style.set_border_width_all(2)
	panel_style.border_color = Color(0.3, 0.5, 0.8, 1.0)
	panel_style.set_corner_radius_all(6)
	panel_style.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", panel_style)
	_day1_end_screen.add_child(panel)

	var main_vbox = VBoxContainer.new()
	main_vbox.name = "MainVBox"
	main_vbox.add_theme_constant_override("separation", 8)
	panel.add_child(main_vbox)

	# タイトル
	var title = Label.new()
	title.name = "Title"
	title.text = "━━━ Day 1 結果 ━━━"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", Color(0.7, 0.9, 1.0, 1.0))
	title.add_theme_font_size_override("font_size", 20)
	main_vbox.add_child(title)

	# 内容スクロール
	var scroll = ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	main_vbox.add_child(scroll)

	var content_vbox = VBoxContainer.new()
	content_vbox.name = "ContentVBox"
	content_vbox.add_theme_constant_override("separation", 6)
	scroll.add_child(content_vbox)

	# --- 案件結果 ---
	var cases_header = Label.new()
	cases_header.name = "CasesHeader"
	cases_header.text = "【案件】"
	cases_header.add_theme_color_override("font_color", Color(0.5, 0.7, 0.9, 1.0))
	content_vbox.add_child(cases_header)

	var cases_label = Label.new()
	cases_label.name = "CasesLabel"
	cases_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cases_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8, 1.0))
	content_vbox.add_child(cases_label)

	# --- 生存者 ---
	var npcs_header = Label.new()
	npcs_header.name = "NpcsHeader"
	npcs_header.text = "【生存者】"
	npcs_header.add_theme_color_override("font_color", Color(0.5, 0.9, 0.6, 1.0))
	content_vbox.add_child(npcs_header)

	var npcs_label = Label.new()
	npcs_label.name = "NpcsLabel"
	npcs_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	npcs_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8, 1.0))
	content_vbox.add_child(npcs_label)

	# --- KMF状態 ---
	var kmf_header = Label.new()
	kmf_header.name = "KmfHeader"
	kmf_header.text = "【KMF露出】"
	kmf_header.add_theme_color_override("font_color", Color(0.9, 0.7, 0.3, 1.0))
	content_vbox.add_child(kmf_header)

	var kmf_label2 = Label.new()
	kmf_label2.name = "KmfLabel"
	kmf_label2.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8, 1.0))
	content_vbox.add_child(kmf_label2)

	# --- 確定情報 ---
	var info_header = Label.new()
	info_header.name = "InfoHeader"
	info_header.text = "【確定事実】"
	info_header.add_theme_color_override("font_color", Color(0.7, 0.8, 0.9, 1.0))
	content_vbox.add_child(info_header)

	var info_label = Label.new()
	info_label.name = "InfoLabel"
	info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7, 1.0))
	content_vbox.add_child(info_label)

	# --- 続行ボタン ---
	var button = Button.new()
	button.name = "ContinueButton"
	button.text = "Day 2 へ進む"
	button.pressed.connect(_on_day1_end_continue)
	button.alignment = HORIZONTAL_ALIGNMENT_CENTER
	main_vbox.add_child(button)

	add_child(_day1_end_screen)

func _on_day1_feedback_ready(feedback: Dictionary) -> void:
	_show_day1_end_screen(feedback)

func _show_day1_end_screen(feedback: Dictionary) -> void:
	if not is_instance_valid(_day1_end_screen):
		return

	_day1_end_visible = true

	var panel = _day1_end_screen.get_node_or_null("Panel")
	if not panel:
		return

	var main_vbox = panel.get_node_or_null("MainVBox")
	if not main_vbox:
		return

	var scroll = main_vbox.get_node_or_null("Scroll")
	if not scroll:
		return

	var content = scroll.get_node_or_null("ContentVBox")
	if not content:
		return

	var cases_label = content.get_node_or_null("CasesLabel")
	var npcs_label = content.get_node_or_null("NpcsLabel")
	var kmf_label2 = content.get_node_or_null("KmfLabel")
	var info_label = content.get_node_or_null("InfoLabel")

	# 案件結果テキスト
	var case_lines: Array = []
	var completed = feedback.get("completed_cases", []) as Array
	var failed = feedback.get("failed_cases", []) as Array
	var expired = feedback.get("expired_cases", []) as Array
	var active = feedback.get("active_cases", []) as Array

	if not completed.is_empty():
		for c in completed:
			case_lines.append("  ○ %s [達成]" % str(c.get("name", "?")))
	if not expired.is_empty():
		for c in expired:
			case_lines.append("  △ %s [期限切れ]" % str(c.get("name", "?")))
	if not failed.is_empty():
		for c in failed:
			case_lines.append("  × %s [失敗]" % str(c.get("name", "?")))
	if not active.is_empty():
		for c in active:
			case_lines.append("  … %s [進行中]" % str(c.get("name", "?")))
	if case_lines.is_empty():
		case_lines.append("  （案件なし）")

	if cases_label:
		cases_label.text = "\n".join(case_lines)

	# NPC状態テキスト
	var npc_lines: Array = []
	var rescued = feedback.get("rescued_npcs", []) as Array
	var lost = feedback.get("lost_npcs", []) as Array
	var departed = feedback.get("departed_npcs", []) as Array

	if not rescued.is_empty():
		npc_lines.append("  救助・生存:")
		for n in rescued:
			npc_lines.append("    ○ %s" % str(n.get("name", "?")))
	if not departed.is_empty():
		npc_lines.append("  離脱:")
		for n in departed:
			npc_lines.append("    … %s" % str(n.get("name", "?")))
	if not lost.is_empty():
		npc_lines.append("  喪失:")
		for n in lost:
			npc_lines.append("    × %s" % str(n.get("name", "?")))
	if npc_lines.is_empty():
		npc_lines.append("  （該当なし）")

	if npcs_label:
		npcs_label.text = "\n".join(npc_lines)

	# KMF露出テキスト
	var kmf_exp = float(feedback.get("kmf_exposure", 0.0))
	var kmf_count = int(feedback.get("kmf_use_count", 0))
	var kmf_lines: Array = []
	kmf_lines.append("  露出度: %.1f" % kmf_exp)
	kmf_lines.append("  使用回数: %d回" % kmf_count)
	if kmf_exp > 50.0:
		kmf_lines.append("  住民の警戒が非常に高い状態が続いている。")
	elif kmf_exp > 25.0:
		kmf_lines.append("  一部住民が警戒を感じている。")
	else:
		kmf_lines.append("  大きな影響は確認されていない。")

	if kmf_label2:
		kmf_label2.text = "\n".join(kmf_lines)

	# 確定情報テキスト
	var confirmed = feedback.get("confirmed_info", []) as Array
	var info_lines: Array = []
	if not confirmed.is_empty():
		for c in confirmed.slice(0, 5):
			var loc = str(c.get("location", "?"))
			var content_str = str(c.get("content", ""))
			if content_str.length() > 40:
				content_str = content_str.substr(0, 40) + "..."
			info_lines.append("  [%s] %s" % [loc, content_str])
	if info_lines.is_empty():
		info_lines.append("  （直接確認した事実はなし）")

	if info_label:
		info_label.text = "\n".join(info_lines)

	_day1_end_screen.visible = true
	_on_debug("Day 1 結果画面を表示")

func _on_day1_end_continue() -> void:
	if is_instance_valid(_day1_end_screen):
		_day1_end_screen.visible = false
	_day1_end_visible = false
	_on_debug("Day 2 へ続行")

## ============================================================
## Phase 0.5 Block 1: インタラクション表示 / HUD Safe Area
## ============================================================

func _build_interaction_prompt_ui() -> void:
	_prompt_panel = PanelContainer.new()
	_prompt_panel.name = "InteractionPrompt"
	_prompt_panel.anchor_left = 0.5
	_prompt_panel.anchor_top = 1.0
	_prompt_panel.anchor_right = 0.5
	_prompt_panel.anchor_bottom = 1.0
	_prompt_panel.offset_left = -300.0
	_prompt_panel.offset_top = -132.0
	_prompt_panel.offset_right = 300.0
	_prompt_panel.offset_bottom = -76.0
	_prompt_panel.z_index = 30
	_prompt_panel.visible = false
	_prompt_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.05, 0.07, 0.10, 0.78)
	style.set_border_width_all(1)
	style.border_color = Color(0.45, 0.60, 0.75, 0.85)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(6)
	_prompt_panel.add_theme_stylebox_override("panel", style)
	add_child(_prompt_panel)

	_prompt_label = Label.new()
	_prompt_label.name = "Text"
	_prompt_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_prompt_label.add_theme_color_override("font_color", Color(0.95, 0.97, 1.0))
	_prompt_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompt_panel.add_child(_prompt_label)

func _on_interaction_prompt(prompt: Dictionary) -> void:
	if _prompt_label == null:
		return
	if not bool(prompt.get("has_target", false)):
		_prompt_panel.visible = false
		_last_prompt_text = ""
		return
	var text: String = _format_prompt(prompt)
	_last_prompt_text = text
	_prompt_label.text = text
	_prompt_panel.visible = true

## 対象名 / 可能な行動 / 必要キー / 現在距離 / 必要なモード / 不足条件 を必ず出す。
func _format_prompt(prompt: Dictionary) -> String:
	var lines: Array = []
	lines.append("対象: %s" % str(prompt.get("target_name", "?")))
	var action_label: String = str(prompt.get("action_label", ""))
	var key_label: String = str(prompt.get("key_label", "F"))
	if bool(prompt.get("blocked", false)):
		lines.append("行動: %s (現在不可)" % action_label)
		lines.append("必要キー: %s" % key_label)
		lines.append("距離: %.1fm" % (float(prompt.get("distance", 0.0)) / 10.0))
		lines.append("不足: %s" % str(prompt.get("reason", "要件を満たしていない")))
	else:
		lines.append("行動: %s" % action_label)
		lines.append("必要キー: %s" % key_label)
		lines.append("距離: %.1fm" % (float(prompt.get("distance", 0.0)) / 10.0))
		lines.append("必要なモード: %s" % _mode_text(str(prompt.get("required_mode", "any"))))
		var hint: String = str(prompt.get("hint", ""))
		if not hint.is_empty():
			lines.append(hint)
	var secondary: String = str(prompt.get("secondary", ""))
	if not secondary.is_empty():
		lines.append(secondary)
	return "\n".join(lines)

func _mode_text(mode_id: String) -> String:
	match mode_id:
		"foot": return "徒歩"
		"kmf": return "KMF"
		_: return "どちらでも"

## HUD がプレイ領域を恒常的に塞がないための機構。
## 1) 既定はコンパクト表示 (重要な行だけ)
## 2) プレイヤーが隠れているときは透過度を下げる
## 3) H キーでフル表示へ切り替え
func _apply_compact_state() -> void:
	var keep: Array = ["HPLabel", "TimeLabel", "LocLabel", "KMFLabel", "ObjectiveLabel", "ResultLabel"]
	for child in $Panel.get_children():
		if not (child is Label):
			continue
		var label := child as Label
		if label.name == "NavigationHint":
			label.visible = true
			continue
		if label.name == "DebugLabel":
			# デバッグ表示は既存方針を維持する。
			label.visible = _debug_tools_enabled
			continue
		# compact=false のときは既存HUDラベルをすべて復帰させる。
		label.visible = (not _compact) or keep.has(label.name)
	if _navigation_label != null:
		_navigation_label.visible = true

func _toggle_compact() -> void:
	_compact = not _compact
	_apply_compact_state()
	_refresh()

## カメラから呼ばれる: プレイヤーが HUD の裏に隠れているか。
func set_occlusion_alert(active: bool) -> void:
	if _occlusion_alert == active:
		return
	_occlusion_alert = active
	var alpha: float = 0.45 if active else 1.0
	if $Panel != null:
		$Panel.modulate = Color(1.0, 1.0, 1.0, alpha)
	if _prompt_panel != null:
		_prompt_panel.modulate = Color(1.0, 1.0, 1.0, alpha)

## カメラから呼ばれる: 恒常的に画面を塞ぐ HUD 領域 (screen space)。
func get_hud_occlusion_rects() -> Array:
	var rects: Array = []
	var panel := $Panel
	if panel != null and panel.visible:
		rects.append(panel.get_global_rect())
	if panel_container != null and panel_container.visible:
		var info := panel_container.get_node_or_null("InfoPanels")
		if info == null or info.visible:
			rects.append(panel_container.get_global_rect())
	var deadline := get_node_or_null("CaseDeadlinePanel")
	if deadline != null and deadline.visible:
		rects.append(deadline.get_global_rect())
	var digest := get_node_or_null("KMFDigestPanel")
	if digest != null and digest.visible:
		rects.append(digest.get_global_rect())
	return rects

## 既存の F キー処理は InteractionService 経由に一本化する。
func _perform_primary_interaction() -> bool:
	if _interaction_service == null or not is_instance_valid(_interaction_service):
		return false
	if not _interaction_service.has_method("execute_primary"):
		return false
	var result: Variant = _interaction_service.call("execute_primary")
	if result is Dictionary:
		var dict: Dictionary = result
		if bool(dict.get("executed", false)):
			_refresh()
			return true
	return false

## ============================================================
## 既存HUD処理
## ============================================================

func _unhandled_input(event: InputEvent) -> void:
	if _debug_tools_enabled and event.is_action_pressed("debug_dump"):
		print(GameState.dump_state())
		_on_debug("State dumped to console. Seed=" + str(RngService.get_seed()))
	if event.is_action_pressed("save_game"):
		var sm = get_node_or_null("/root/SaveManager")
		if sm == null:
			sm = get_tree().root.find_child("SaveManager", true, false)
		if sm:
			sm.save_game()
	if event.is_action_pressed("load_game"):
		var sm = get_tree().root.find_child("SaveManager", true, false)
		if sm:
			sm.load_game()
	if event.is_action_pressed("hud_toggle"):
		_toggle_compact()
		return
	if event.is_action_pressed("interact"):
		# 実行は InteractionService が一括で持つ (二重実行を避ける)。
		if _perform_primary_interaction():
			return
		if _day1 and _day1.has_method("try_interact"):
			var ok = _day1.try_interact("")
			if ok:
				_refresh()
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_I:
			var info_panels = panel_container.get_node_or_null("InfoPanels") if panel_container else null
			if info_panels and info_panels.has_method("toggle"):
				info_panels.toggle()


func _build_navigation_hint() -> void:
	_navigation_label = Label.new()
	_navigation_label.name = "NavigationHint"
	_navigation_label.custom_minimum_size = Vector2(260, 0)
	_navigation_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_navigation_label.add_theme_color_override("font_color", Color(1.0, 0.91, 0.50))
	$Panel.add_child(_navigation_label)
	var timer := Timer.new()
	timer.name = "NavigationUpdateTimer"
	timer.wait_time = 0.3
	timer.timeout.connect(_refresh_navigation_hint)
	add_child(timer)
	timer.start()
	_refresh_navigation_hint()

func _refresh_navigation_hint() -> void:
	if _navigation_label == null:
		return
	var player_pos: Vector2 = GameState.get_player_position()
	var map_manager: Node = get_parent().get_node_or_null("MapManager")
	if _presentation == null:
		_presentation = get_tree().root.find_child("Day1PresentationAdapter", true, false)
	var view: Dictionary = _presentation.get_snapshot(_day1, map_manager) if _presentation and _presentation.has_method("get_snapshot") else {}
	var target_name := str(view.get("objective", "次の行動を選ぶ"))
	var destination_name := str(view.get("destination_name", "拠点"))
	var target_pos: Vector2 = view.get("destination_position", player_pos)
	var direction: String = _direction_arrow(player_pos, target_pos)
	var target_dist: int = int(round(player_pos.distance_to(target_pos)))
	var message := "現在目的: %s\n目的地: %s  %s %dm" % [target_name, destination_name, direction, int(round(target_dist / 10.0))]
	var kmf: Dictionary = GameState.get_section("kmf")
	if bool(kmf.get("boarded", false)):
		message += "\n自機KMF: 搭乗中"
	elif bool(kmf.get("owned", false)):
		var stored: Dictionary = kmf.get("position", {})
		var kmf_pos := Vector2(float(stored.get("x", 96.0)), float(stored.get("y", 64.0)))
		var distance: float = player_pos.distance_to(kmf_pos)
		if distance < 48.0:
			message += "\n自機KMF: すぐ近く・Eで搭乗"
		else:
			message += "\n自機KMF: %s 約%dm（水色マーカー）" % [_direction_arrow(player_pos, kmf_pos), int(round(distance / 10.0))]
	else:
		message += "\n自機KMF: 使用不能"
	message += "\nI:情報一覧（ほかの案件も選択可能）"
	_navigation_label.text = message

func _direction_arrow(from_pos: Vector2, to_pos: Vector2) -> String:
	var delta: Vector2 = to_pos - from_pos
	if delta.length() < 24.0:
		return "◎"
	var x: String = "→" if delta.x > 0.0 else "←"
	var y: String = "↓" if delta.y > 0.0 else "↑"
	if absf(delta.x) > absf(delta.y) * 1.6:
		return x
	if absf(delta.y) > absf(delta.x) * 1.6:
		return y
	return y + x

func _refresh() -> void:
	var player = GameState.get_section("player")
	var kmf = GameState.get_section("kmf")
	var heroine = GameState.get_section("heroine")
	var map_manager: Node = get_parent().get_node_or_null("MapManager")
	hp_label.text = "HP: %.0f / %.0f" % [float(player.get("hp", 0)), float(player.get("max_hp", 100))]
	fatigue_label.text = "疲労: %.0f" % float(player.get("fatigue", 0))
	time_label.text = GameState.get_time_string()
	var location_id := str(player.get("locationId", "outskirts"))
	var location_name: String = str(map_manager.get_location_display_name(location_id)) if map_manager and map_manager.has_method("get_location_display_name") else "現在地不明"
	var mode_name := "KMF搭乗" if str(player.get("mode", "foot")) == "kmf" else "徒歩"
	loc_label.text = "現在地: %s / %s" % [location_name, mode_name]
	if bool(kmf.get("boarded", false)):
		kmf_label.text = "KMF: 耐久%.0f エナジー%.0f 弾薬%d" % [
			float(kmf.get("durability", 0)), float(kmf.get("energy", 0)),
			int(kmf.get("ammo", 0))
		]
	else:
		kmf_label.text = "KMF: %s / 耐久%.0f" % ["駐機中" if bool(kmf.get("owned", false)) else "使用不能", float(kmf.get("durability", 0))]

	# ヒロイン: 生存/同行のみ。好感度真値は出さない
	var h_status = "生存" if bool(heroine.get("alive", true)) else "死亡"
	var h_present = "同行" if bool(heroine.get("present", true)) else "不在"
	heroine_label.text = "ヒロイン: %s / %s" % [h_status, h_present]

	# Day1 HUD
	if _day1 == null:
		_day1 = get_tree().root.find_child("Day1Controller", true, false)
	if _day1 and _day1.has_method("is_initialized") and _day1.is_initialized():
		var view: Dictionary = _presentation.get_snapshot(_day1, map_manager) if _presentation and _presentation.has_method("get_snapshot") else {}
		if help_label:
			help_label.text = _day1.get_help_text() if _day1.has_method("get_help_text") else "操作: WASD / F:インタラクト"
		if objective_label:
			objective_label.text = "目的: " + str(view.get("objective", "次の行動を選ぶ"))
		if deadline_label:
			deadline_label.text = _day1.get_deadline_text() if _day1.has_method("get_deadline_text") else "期限: ---"
		if result_label:
			result_label.text = "結果: " + (_day1.get_result_summary() if _day1.has_method("get_result_summary") else "---")
	else:
		if help_label:
			help_label.text = "操作: WASD / F:インタラクト / E:KMF / Space:射撃"
		if objective_label:
			objective_label.text = "目的: Day1未初期化"
		if deadline_label:
			deadline_label.text = "期限: ---"
		if result_label:
			result_label.text = "結果: ---"

	# MiniMax追加: 案件期限UI定期更新
	_refresh_case_deadlines()
	_refresh_navigation_hint()

func _on_hp(_hp: float, _max: float) -> void:
	_refresh()

func _on_fatigue(_f: float) -> void:
	_refresh()

func _on_debug(msg: String) -> void:
	if not _debug_tools_enabled:
		return
	debug_label.text = msg
	get_tree().create_timer(3.0).timeout.connect(func(): debug_label.text = "")

func _on_notice(msg: String) -> void:
	result_label.text = msg
	get_tree().create_timer(3.0).timeout.connect(func(): _refresh())

