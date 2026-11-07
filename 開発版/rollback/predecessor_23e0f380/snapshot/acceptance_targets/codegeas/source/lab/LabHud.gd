extends CanvasLayer
## LabHud - Lab の表示 (Phase 0.5 Block 2 / Block 3)
##
## 目的:
##   - 現在の方式 / 目的 / 状態 / メトリクスを常時見えるようにする。
##   - 3方式の比較表を同じ画面に置き、Human Playtest で比較できるようにする。
##   - HUD がプレイ領域を塞がないよう、情報は画面端に寄せる。

const PANEL_BG: Color = Color(0.05, 0.06, 0.08, 0.82)
const ACCENT: Color = Color(0.55, 0.78, 0.95)
const WARN: Color = Color(0.95, 0.72, 0.30)
const GOOD: Color = Color(0.45, 0.90, 0.55)

var _info_panel: PanelContainer
var _info_label: Label
var _metrics_panel: PanelContainer
var _metrics_label: Label
var _compare_panel: PanelContainer
var _compare_label: Label
var _help_label: Label
var _message_label: Label
var _results: Array = []

func _ready() -> void:
	layer = 10
	_build_ui()
	set_process(true)

func _build_ui() -> void:
	# --- 左上: 方式 / 目的 / 状態 ---
	_info_panel = PanelContainer.new()
	_info_panel.name = "InfoPanel"
	_info_panel.anchor_left = 0.0
	_info_panel.anchor_top = 0.0
	_info_panel.anchor_right = 0.0
	_info_panel.anchor_bottom = 0.0
	_info_panel.offset_left = 8.0
	_info_panel.offset_top = 8.0
	_info_panel.offset_right = 396.0
	_info_panel.offset_bottom = 285.0
	_info_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info_panel.add_theme_stylebox_override("panel", _make_style(PANEL_BG))
	add_child(_info_panel)

	_info_label = Label.new()
	_info_label.name = "Info"
	_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_label.add_theme_color_override("font_color", ACCENT)
	_info_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info_panel.add_child(_info_label)

	# --- 右上: メトリクス ---
	_metrics_panel = PanelContainer.new()
	_metrics_panel.name = "MetricsPanel"
	_metrics_panel.anchor_left = 1.0
	_metrics_panel.anchor_top = 0.0
	_metrics_panel.anchor_right = 1.0
	_metrics_panel.anchor_bottom = 0.0
	_metrics_panel.offset_left = -300.0
	_metrics_panel.offset_top = 8.0
	_metrics_panel.offset_right = -8.0
	_metrics_panel.offset_bottom = 330.0
	_metrics_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_metrics_panel.add_theme_stylebox_override("panel", _make_style(PANEL_BG))
	add_child(_metrics_panel)

	_metrics_label = Label.new()
	_metrics_label.name = "Metrics"
	_metrics_label.add_theme_color_override("font_color", Color(0.88, 0.90, 0.92))
	_metrics_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_metrics_panel.add_child(_metrics_label)

	# --- 右下: 方式比較表 ---
	_compare_panel = PanelContainer.new()
	_compare_panel.name = "ComparePanel"
	_compare_panel.anchor_left = 1.0
	_compare_panel.anchor_top = 1.0
	_compare_panel.anchor_right = 1.0
	_compare_panel.anchor_bottom = 1.0
	_compare_panel.offset_left = -470.0
	_compare_panel.offset_top = -230.0
	_compare_panel.offset_right = -8.0
	_compare_panel.offset_bottom = -8.0
	_compare_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_compare_panel.add_theme_stylebox_override("panel", _make_style(PANEL_BG))
	add_child(_compare_panel)

	_compare_label = Label.new()
	_compare_label.name = "Compare"
	_compare_label.add_theme_color_override("font_color", Color(0.85, 0.90, 0.95))
	_compare_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_compare_panel.add_child(_compare_label)

	# --- 左下: 操作 ---
	_help_label = Label.new()
	_help_label.name = "Help"
	_help_label.anchor_left = 0.0
	_help_label.anchor_top = 1.0
	_help_label.anchor_right = 0.0
	_help_label.anchor_bottom = 1.0
	_help_label.offset_left = 8.0
	_help_label.offset_top = -190.0
	_help_label.offset_right = 420.0
	_help_label.offset_bottom = -8.0
	_help_label.add_theme_color_override("font_color", Color(0.80, 0.82, 0.70))
	_help_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_help_label.add_theme_constant_override("shadow_offset_x", 1)
	_help_label.add_theme_constant_override("shadow_offset_y", 1)
	_help_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_help_label.text = "操作:\nWASD 移動 / 左クリック 射撃 / Q 部位指定 / Space 回避\nE 搭乗・降機 / X 退避指示 / P 戦術ポーズ開始・再開\nWEGO: planning中にWASD/左クリックで指示 → Enterで1ターン実行\nTab 方式切替 / R リセット"
	add_child(_help_label)

	# --- 中央下: メッセージ ---
	_message_label = Label.new()
	_message_label.name = "Message"
	_message_label.anchor_left = 0.5
	_message_label.anchor_top = 1.0
	_message_label.anchor_right = 0.5
	_message_label.anchor_bottom = 1.0
	_message_label.offset_left = -300.0
	_message_label.offset_top = -190.0
	_message_label.offset_right = 300.0
	_message_label.offset_bottom = -160.0
	_message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message_label.add_theme_color_override("font_color", WARN)
	_message_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_message_label.add_theme_constant_override("shadow_offset_x", 1)
	_message_label.add_theme_constant_override("shadow_offset_y", 1)
	_message_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_message_label)

func _make_style(bg: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.set_border_width_all(1)
	style.border_color = Color(0.35, 0.45, 0.55, 0.8)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	return style

func refresh_lab(view: Dictionary) -> void:
	if _info_label == null:
		return
	var lines: Array = []
	lines.append("=== Combat & Exploration Lab ===")
	lines.append("方式: %s" % str(view.get("mode_name", "")))
	lines.append(str(view.get("mode_description", "")))
	lines.append("")
	lines.append(str(view.get("objective", "")))
	lines.append(str(view.get("retreat_hint", "")))
	lines.append("移動: %s" % ("KMF" if str(view.get("player_mode", "foot")) == "kmf" else "徒歩"))
	for status in view.get("status_lines", []):
		lines.append(str(status))
	lines.append("実行中: %s" % ("yes" if bool(view.get("run_active", false)) else "no"))
	_info_label.text = "\n".join(lines)

	_metrics_label.text = _format_metrics(view.get("metrics", {}))

	var message: String = str(view.get("message", ""))
	_message_label.text = message
	_message_label.visible = not message.is_empty()

	_compare_label.text = _format_comparison(view.get("results", []))

	var help_text: String = str(view.get("help_text", ""))
	if not help_text.is_empty():
		_help_label.text = help_text

func _format_metrics(m: Dictionary) -> String:
	if m.is_empty():
		return ""
	var lines: Array = []
	lines.append("--- 現在のラン ---")
	lines.append("戦闘時間   %.1f s" % float(m.get("combat_time", 0.0)))
	lines.append("操作量     %d" % int(m.get("action_count", 0)))
	lines.append("判断回数   %d" % int(m.get("decision_count", 0)))
	lines.append("判断頻度   %.2f /s" % float(m.get("decision_frequency", 0.0)))
	lines.append("被ダメージ %.1f" % float(m.get("damage_received", 0.0)))
	lines.append("KMF損傷    %.1f" % float(m.get("kmf_damage", 0.0)))
	lines.append("射撃数     %d (徒歩%d / KMF%d)" % [int(m.get("shots_fired", 0)), int(m.get("foot_shots", 0)), int(m.get("kmf_shots", 0))])
	lines.append("命中数     %d (命中率 %.0f%%)" % [int(m.get("hits", 0)), float(m.get("hit_rate", 0.0)) * 100.0])
	lines.append("部位命中   %d (破壊 %d)" % [int(m.get("part_hits", 0)), int(m.get("part_destroys", 0))])
	lines.append("撃破       %d / 無力化 %d" % [int(m.get("enemies_destroyed", 0)), int(m.get("enemies_neutralized", 0))])
	lines.append("pause      %d" % int(m.get("pause_count", 0)))
	lines.append("planning   %d" % int(m.get("planning_count", 0)))
	lines.append("撤退       %s" % ("成功" if bool(m.get("retreat_success", false)) else "-"))
	lines.append("主人公死亡 %s" % ("あり" if bool(m.get("player_dead", false)) else "なし"))
	return "\n".join(lines)

func _format_comparison(results: Array) -> String:
	var lines: Array = []
	lines.append("--- 今回のセッション比較 ---")
	if results.is_empty():
		lines.append("(まだ完走したランがありません)")
		return "\n".join(lines)
	lines.append("方式 | 結果 | 戦闘s | 操作 | 判断 | 被ダメージ | 撃破 | 撤退")
	for item in results:
		if not (item is Dictionary):
			continue
		var row: Dictionary = item
		lines.append("%s | %s | %s | %s | %s | %s | %s | %s" % [
			str(row.get("方式", "?")),
			str(row.get("結果", "?")),
			str(row.get("戦闘時間", "-")),
			str(row.get("操作量", "-")),
			str(row.get("判断回数", "-")),
			str(row.get("被ダメージ", "-")),
			str(row.get("撃破数", "-")),
			str(row.get("撤退成否", "-")),
		])
	return "\n".join(lines)

func push_result(row: Dictionary) -> void:
	_results.append(row)
