extends PanelContainer
## Unified production information UI for the integrated prototype.
## MiniMax担当追加 (DAY1-REPAIR-20261019-5TO5):
## - KMF Digest タブ（集約表示）
## - 案件期限・残時間・移動予測タブ
## - 優先通知（priority notification）

var tabs: TabContainer

## MiniMax追加: KMF Digestデータ保持用
var _latest_kmf_digest: Dictionary = {}
var _presentation: Node = null
var _day1: Node = null

func _ready() -> void:
	_presentation = get_tree().root.find_child("Day1PresentationAdapter", true, false)
	_day1 = get_tree().root.find_child("Day1Controller", true, false)
	visible = false
	tabs = TabContainer.new()
	tabs.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(tabs)
	_build_tabs()
	refresh_all()
	EventBus.time_advanced.connect(func(_m): refresh_all())
	EventBus.quest_changed.connect(func(_q): refresh_all())
	EventBus.npc_state_changed.connect(func(_n): refresh_all())
	EventBus.report_added.connect(func(_r, _c): refresh_all())
	EventBus.kmf_digest_ready.connect(_on_kmf_digest_ready)
	EventBus.day1_case_state_changed.connect(func(_c, _o, _n): refresh_all())
	EventBus.day1_feedback_ready.connect(func(_f): refresh_all())

func toggle() -> void:
	visible = not visible
	if visible:
		refresh_all()

func _make_text_tab(name: String) -> RichTextLabel:
	var box := RichTextLabel.new()
	box.name = name
	box.fit_content = false
	box.scroll_active = true
	box.bbcode_enabled = false
	tabs.add_child(box)
	return box

func _build_tabs() -> void:
	for name in ["NPC", "関係", "情報", "ヒロイン", "男友人", "クエスト", "世界", "KMF報告", "案件期限"]:
		_make_text_tab(name)

func _tab(name: String) -> RichTextLabel:
	return tabs.get_node(name) as RichTextLabel

func refresh_all() -> void:
	if not tabs:
		return
	_refresh_npcs()
	_refresh_relations()
	_refresh_information()
	_refresh_heroine()
	_refresh_male_friend()
	_refresh_quests()
	_refresh_world()
	_refresh_kmf_digest()
	_refresh_case_deadlines()

func _refresh_npcs() -> void:
	var lines: Array[String] = []
	for npc_id in NpcManager.get_npc_ids():
		var npc := NpcManager.get_npc(npc_id)
		lines.append("%s [%s] %s / %s" % [npc.get("name", "人物"), npc.get("affiliation", "所属不明"), "生存" if npc.get("alive", true) else "死亡", _npc_action_label(str(npc.get("currentAction", "idle")))])
	_tab("NPC").text = "\n".join(lines)

func _refresh_relations() -> void:
	var lines: Array[String] = ["好感度の内部真値は通常UIでは表示しません。"]
	for npc_id in NpcManager.get_npc_ids():
		var npc := NpcManager.get_npc(npc_id)
		var rel := NpcManager.get_related_npcs(npc_id)
		lines.append("%s: 友好%d / 中立%d / 敵対%d / 信頼%s / 恐怖%s" % [npc.get("name", npc_id), rel.get("positive", []).size(), rel.get("neutral", []).size(), rel.get("negative", []).size(), npc.get("trust", 0), npc.get("fear", 0)])
	_tab("関係").text = "\n".join(lines)

func _refresh_information() -> void:
	var lines: Array[String] = ["【確定事実】"]
	for fact in MemorySystem.get_all_system_facts_sorted():
		lines.append("・%s" % fact.get("description", fact.get("id", "?")))
	lines.append("\n【証言・噂・分析】")
	for report in MemorySystem.get_reports_sorted_by_confidence():
		lines.append("・[%s] %s <%s>" % [report.get("confidence", "?"), report.get("content", ""), report.get("sourceId", "?")])
	_tab("情報").text = "\n".join(lines)

func _refresh_heroine() -> void:
	var h := HeroineSystem.get_state_for_ui()
	_tab("ヒロイン").text = "ユイ\n好感帯: %s\n交流量: 累積%s / 直近%s\n信頼:%s 恐怖:%s 依存:%s\n主要感情:%s\n予測行動:%s\n状態:%s / %s" % [h.get("affection_band", "?"), h.get("interaction_total", 0), h.get("interaction_recent", 0), h.get("trust", 0), h.get("fear", 0), h.get("dependence", 0), h.get("current_emotion", "?"), h.get("next_action", "?"), "生存" if h.get("alive", true) else "死亡", "同行" if h.get("present", true) else "不在"]

func _refresh_male_friend() -> void:
	var lines: Array[String] = ["推定値のみ。内部真値は非表示。"]
	for est in MaleFriendEstimator.get_all_estimations():
		lines.append("%s: %s〜%s / %s" % [est.get("name", est.get("id", "?")), est.get("range_min", "?"), est.get("range_max", "?"), est.get("confidence_label", "不確か")])
	_tab("男友人").text = "\n".join(lines)

func _refresh_quests() -> void:
	var lines: Array[String] = ["【Day1案件】"]
	var rows: Array = _presentation.get_case_rows(_day1) if _presentation and _presentation.has_method("get_case_rows") else []
	if rows.is_empty():
		lines.append("・確認できる案件はありません")
	for row in rows:
		var deadline := int(row.get("deadline", -1))
		var deadline_text := "期限なし" if deadline < 0 else "%02d:%02dまで" % [int(deadline / 60), deadline % 60]
		lines.append("・%s｜%s｜%s" % [row.get("name", "未確認案件"), row.get("status", "確認中"), deadline_text])
	lines.append("\n現地へ移動し、Fで会話・行動します。")
	_tab("クエスト").text = "\n".join(lines)

func _npc_action_label(action: String) -> String:
	return str({
		"idle": "待機中", "moving": "移動中", "flee": "避難中", "fleeing": "避難中",
		"helping": "救助中", "injured": "負傷", "escort": "護送中", "combat": "交戦中",
	}.get(action, "行動中"))

func _refresh_world() -> void:
	var w := GameState.get_world()
	_tab("世界").text = "社会不安:%s\n交通混乱:%s\n軍事緊張:%s\nギアス拡散:%s\nコード所持者推定:%s\n護衛男性推定:%s" % [w.get("socialUnrest", 0), w.get("trafficChaos", 0), w.get("militaryTension", 0), w.get("geassSpread", 0), w.get("codeHolderRegion", "unknown"), w.get("guardianRegion", "unknown")]

## ============================================================
## MiniMax追加: KMF Digest タブ
## ============================================================
## KMF使用に伴う多量のレポートを蓄積・digestとして表示する。
## 60〜80件の生レポートを保持しつつ、凝縮した通知のみを表示。
## systemFactsや証言の出典を混同・改竄しない。

func _on_kmf_digest_ready(digest: Dictionary) -> void:
	_latest_kmf_digest = digest.duplicate(true)
	_refresh_kmf_digest()

func _refresh_kmf_digest() -> void:
	var lines: Array[String] = []

	# 最新digest
	var digest = _latest_kmf_digest
	if not digest.is_empty():
		var importance = str(digest.get("importance", "low"))
		var content = str(digest.get("content", ""))
		var count = int(digest.get("total_reports", 0))
		var locations = digest.get("locations", []) as Array

		var imp_icon = "[低]" if importance == "low" else ("[中]" if importance == "medium" else "[高!]")
		lines.append("%s %s" % [imp_icon, content])
		lines.append("（%d件の報告を集約）" % count)

		if not locations.is_empty():
			lines.append("目撃地点: %s" % ", ".join(locations))

		var total_noise = float(digest.get("total_noise", 0.0))
		lines.append("総合騒音レベル: %.1f" % total_noise)

		var gen_min = int(digest.get("generated_at_minute", 0))
		lines.append("集約時刻: Day %d %02d:%02d" % [int(digest.get("generated_at_day", 1)), gen_min / 60, gen_min % 60])
	else:
		lines.append("（KMF目撃情報なし）")

	lines.append("")
	lines.append("--- KMF露出度 ---")

	# KMF露出度
	var day1 = GameState.get_section("day1")
	var exposure = float(day1.get("kmf_exposure", 0.0))
	var level_str = "低"
	var level_desc = "住民の警戒は低い"
	if exposure > 40.0:
		level_str = "高"
		level_desc = "住民の警戒が非常に高い"
	elif exposure > 20.0:
		level_str = "中"
		level_desc = "一部住民が警戒を感じている"

	lines.append("露出度: %.1f (%s)" % [exposure, level_str])
	lines.append(level_desc)

	lines.append("")
	lines.append("--- KMF使用履歴 ---")

	# KMF使用回数
	var actions = day1.get("actions", []) as Array
	var kmf_count = 0
	for a in actions:
		if str(a.get("mode", "")) == "kmf" or str(a.get("type", "")).begins_with("kmf"):
			kmf_count += 1
	lines.append("KMF使用回数: %d回" % kmf_count)

	# 補足
	lines.append("")
	lines.append("※ 上記は住民の報告を集約した情報です。")
	lines.append("  systemFactsは直接確認した事実のみです。")

	_tab("KMF報告").text = "\n".join(lines)

## ============================================================
## MiniMax追加: 案件期限・残時間・移動予測タブ
## ============================================================

func _refresh_case_deadlines() -> void:
	var lines: Array[String] = []

	# Day1InformationSystemから概要取得
	var overviews: Array = []
	var info = get_tree().root.find_child("Day1InformationSystem", true, false)
	if info and info.has_method("get_known_case_overviews"):
		overviews = info.get_known_case_overviews()
	else:
		overviews = _get_case_overviews_fallback()

	if overviews.is_empty():
		lines.append("（案件なし）")
		_tab("案件期限").text = "\n".join(lines)
		return

	lines.append("【案件一覧】  ※移動時間は目安です。成功保証ではありません。")
	lines.append("")

	var player_loc = str(GameState.get_section("player").get("locationId", "?"))
	var mode = str(GameState.get_section("player").get("mode", "?"))
	lines.append("現在地: %s  移動手段: %s" % [player_loc, "徒歩" if mode == "foot" else "KMF"])
	lines.append("")

	for overview in overviews:
		var name = str(overview.get("name", "?"))
		var status = str(overview.get("status", "?"))
		var remaining_text = str(overview.get("remaining_text", "?"))
		var deadline_text = str(overview.get("deadline_text", "?"))
		var travel = overview.get("travel_estimate", {}) as Dictionary

		# ステータス表示
		var status_icon = "○"
		var status_color_desc = "完了"
		match status:
			"completed":
				status_icon = "○"
				status_color_desc = "達成"
			"failed":
				status_icon = "×"
				status_color_desc = "失敗"
			"expired":
				status_icon = "△"
				status_color_desc = "期限切れ"
			"active":
				status_icon = "進"
				status_color_desc = "進行中"
			_:
				status_icon = "…"
				status_color_desc = status

		lines.append("%s %s [%s]" % [status_icon, name, status_color_desc])
		lines.append("  期限: %s  %s" % [deadline_text, remaining_text])

		# 移動予測（active/availableのみ）
		if status in ["active", "available"] and travel is Dictionary and not travel.is_empty():
			var est = int(travel.get("estimated_minutes", 0))
			var foot = int(travel.get("foot_minutes", 0))
			var kmf = int(travel.get("kmf_minutes", 0))
			var warning = str(travel.get("warning", ""))
			lines.append("  移動予測: 徒%d分 / KMF%d分 (現在%sで%d分)" % [foot, kmf, "徒" if mode == "foot" else "KMF", est])
			if warning != "":
				lines.append("  %s" % warning)

		lines.append("")

	lines.append("--- 優先度目安 ---")
	lines.append("残り60分以下: 優先対応推奨")
	lines.append("残り30分以下: 至急対応が必要")
	lines.append("残り0分以下: 期限切れの可能性があります")

	_tab("案件期限").text = "\n".join(lines)

func _get_case_overviews_fallback() -> Array:
	var overviews: Array = []
	var day1 = GameState.get_section("day1")
	var known_cases: Array = day1.get("known_cases", [])
	var case_states: Dictionary = day1.get("case_states", {})
	var now_minute = GameState.get_minute_of_day()
	var player_loc = str(GameState.get_section("player").get("locationId", "base"))
	var mode = str(GameState.get_section("player").get("mode", "foot"))

	var case_defs: Dictionary = {
		"quest_hospital_medicine": {"name": "病院医薬品輸送", "loc": "hospital"},
		"quest_evacuation_rescue": {"name": "避難民救助", "loc": "evacuation_center"},
		"quest_supply_depot": {"name": "食料倉庫確保", "loc": "industrial_area"},
	}

	var foot_times: Dictionary = {
		"base->hospital": 20, "base->city_center": 25, "base->evacuation_center": 35,
		"hospital->base": 20, "hospital->city_center": 15,
		"city_center->base": 25, "city_center->hospital": 15, "city_center->evacuation_center": 20,
	}
	var kmf_times: Dictionary = {
		"base->hospital": 5, "base->city_center": 8, "base->evacuation_center": 12,
		"hospital->base": 5, "hospital->city_center": 4,
		"city_center->base": 8, "city_center->hospital": 4, "city_center->evacuation_center": 6,
	}

	for case_id in known_cases:
		var state = case_states.get(case_id, {})
		var def = case_defs.get(case_id, {})
		var deadline = int(state.get("deadline_abs_minute", 0))
		var remaining = deadline - now_minute
		var status = str(state.get("status", "active"))
		var to_loc = str(def.get("loc", ""))
		var key = "%s->%s" % [player_loc, to_loc]

		var travel: Dictionary = {
			"estimated_minutes": kmf_times.get(key, 15) if mode == "kmf" else foot_times.get(key, 30),
			"foot_minutes": foot_times.get(key, 30),
			"kmf_minutes": kmf_times.get(key, 15),
			"warning": "※予測時間。道路状況・敵の有無で変動します。" if mode == "foot" else "※予測時間。封鎖・戦闘で遅延の可能性があります。",
		}

		var remaining_text = ""
		if remaining < 0:
			remaining_text = "期限切れ"
		elif remaining < 30:
			remaining_text = "残り%d分 (至急!)" % remaining
		elif remaining < 60:
			remaining_text = "残り%d分" % remaining
		else:
			remaining_text = "残り%d時間%d分" % [remaining / 60, remaining % 60]

		overviews.append({
			"name": str(def.get("name", case_id)),
			"status": status,
			"remaining_text": remaining_text,
			"deadline_text": "%02d:%02d" % [deadline / 60, deadline % 60],
			"travel_estimate": travel,
		})

	return overviews

