extends Node
## InteractionService - インタラクション候補の収集と実行 (Phase 0.5 Block 1)
##
## 開発計画の要求:
##   "Interaction時には画面上へ、対象名 / 可能な行動 / 必要キー / 現在距離 /
##    必要なモード / 行動結果の簡潔な説明 を提示する。"
##   "目的地まで到着しているにもかかわらず『次に何をすればよいか分からない』
##    状態を原則として排除する。"
##
## 設計:
##   - 候補は provider ノードから「記述のみ」で受け取る (副作用ゼロ)。
##     Day1Controller は get_interaction_options() を実装し、
##     try_interact() と同じ対象解決順序を使う。
##   - 実行は Service が一括で持つ (F キーの所有者を二重化しない)。
##   - 候補が無い場合は HUD が従来どおり Day1Controller.try_interact("") に委譲する。
##
## 既存 public method / signal は削除・改名しない。

const InputRouter = preload("res://core/InputRouter.gd")

const INTERACT_RANGE: float = 72.0
const BOARD_RANGE: float = 48.0
const REFRESH_INTERVAL: float = 0.12

signal prompt_changed(prompt: Dictionary)
signal interaction_performed(result: Dictionary)

var _player: Node2D = null
var _day1: Node = null
var _kmf_system: Node = null
var _candidates: Array = []
var _prompt: Dictionary = {}
var _elapsed: float = 0.0

func _ready() -> void:
	_player = get_tree().get_first_node_in_group("player") if get_tree() else null
	_day1 = get_tree().root.find_child("Day1Controller", true, false) if get_tree() else null
	_kmf_system = get_tree().root.find_child("KmfSystem", true, false) if get_tree() else null
	set_process(true)

func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < REFRESH_INTERVAL:
		return
	_elapsed = 0.0
	refresh()

## 候補を再収集して prompt を更新する。
func refresh() -> void:
	_candidates = _collect_candidates()
	var next: Dictionary = _build_prompt(_candidates)
	if next != _prompt:
		_prompt = next
		prompt_changed.emit(_prompt)

## 現在のプロンプト (HUD 消费的)。
func get_prompt() -> Dictionary:
	return _prompt

## 現在の候補一覧。
func get_candidates() -> Array:
	return _candidates.duplicate(true)

func _collect_candidates() -> Array:
	var out: Array = []
	var player_pos: Vector2 = _get_player_position()
	var mode: String = _get_player_mode()

	# --- Day1 の NPC / 施設 ---
	if _day1 != null and is_instance_valid(_day1) and _day1.has_method("get_interaction_options"):
		var options: Variant = _day1.call("get_interaction_options", player_pos, mode)
		if options is Array:
			for option in (options as Array):
				if option is Dictionary:
					out.append(option)

	# --- 自機KMF の搭乗/降機 ---
	var kmf_option: Dictionary = _build_kmf_option(player_pos, mode)
	if not kmf_option.is_empty():
		out.append(kmf_option)

	return out

func _build_kmf_option(player_pos: Vector2, mode: String) -> Dictionary:
	if _kmf_system == null or not is_instance_valid(_kmf_system):
		return {}
	if not _kmf_system.has_method("get_kmf_position"):
		return {}
	var kmf_pos: Vector2 = _kmf_system.call("get_kmf_position")
	var distance: float = player_pos.distance_to(kmf_pos)
	var key_label: String = InputRouter.get_label("board_kmf")

	if mode == "kmf":
		return {
			"target_id": "owned_kmf",
			"target_name": "自機KMF",
			"action_label": "降りる",
			"key_label": key_label,
			"distance": distance,
			"required_mode": "kmf",
			"blocked": false,
			"reason": "",
			"hint": "E: KMFから降りる",
			"source": "kmf",
		}

	var owned: bool = false
	var durability: float = 0.0
	if _kmf_system.has_method("is_operational"):
		owned = bool(_kmf_system.call("is_operational"))
	elif _kmf_system.has_method("can_board"):
		owned = true
	if not owned:
		return {
			"target_id": "owned_kmf",
			"target_name": "自機KMF",
			"action_label": "搭乗",
			"key_label": key_label,
			"distance": distance,
			"required_mode": "foot",
			"blocked": true,
			"reason": "KMFが使用不能",
			"hint": "自機KMFは使用不能",
			"source": "kmf",
		}
	if distance > BOARD_RANGE:
		return {
			"target_id": "owned_kmf",
			"target_name": "自機KMF",
			"action_label": "搭乗",
			"key_label": key_label,
			"distance": distance,
			"required_mode": "foot",
			"blocked": true,
			"reason": "近づくと搭乗できる (範囲 %dm)" % int(round(BOARD_RANGE / 10.0)),
			"hint": "自機KMFへ近づくと E で搭乗できる",
			"source": "kmf",
		}
	return {
		"target_id": "owned_kmf",
		"target_name": "自機KMF",
		"action_label": "搭乗",
		"key_label": key_label,
		"distance": distance,
		"required_mode": "foot",
		"blocked": false,
		"reason": "",
		"hint": "E: 自機KMFに乗る",
		"source": "kmf",
	}

func _build_prompt(candidates: Array) -> Dictionary:
	if candidates.is_empty():
		return {"has_target": false}
	# 主表示は「F で実行できる Day1 候補」。
	# KMF 搭乗は E キーの操作なので、Display は主Slots に出さない (F の操作と混同しないため)。
	var day1_best: Dictionary = {}
	var kmf_best: Dictionary = {}
	for item in candidates:
		if not (item is Dictionary):
			continue
		var entry: Dictionary = item
		if str(entry.get("source", "day1")) == "kmf":
			if kmf_best.is_empty() or _score(entry) < _score(kmf_best):
				kmf_best = entry
		else:
			if day1_best.is_empty() or _score(entry) < _score(day1_best):
				day1_best = entry

	var best: Dictionary = day1_best if not day1_best.is_empty() else kmf_best
	if best.is_empty():
		return {"has_target": false}
	var prompt: Dictionary = {
		"has_target": true,
		"target_name": str(best.get("target_name", "対象")),
		"action_label": str(best.get("action_label", "")),
		"key_label": str(best.get("key_label", InputRouter.get_label("interact"))),
		"distance": float(best.get("distance", 0.0)),
		"required_mode": str(best.get("required_mode", "any")),
		"blocked": bool(best.get("blocked", false)),
		"reason": str(best.get("reason", "")),
		"hint": str(best.get("hint", "")),
		"source": str(best.get("source", "day1")),
	}
	# 副表示: E で搭乗できる距離なら自機KMF を添える (操作キーの混同を避ける)。
	if not kmf_best.is_empty() and not day1_best.is_empty() and not bool(kmf_best.get("blocked", false)):
		prompt["secondary"] = "%s: %s で%s (%.1fm)" % [
			str(kmf_best.get("target_name", "自機KMF")),
			str(kmf_best.get("key_label", "E")),
			str(kmf_best.get("action_label", "搭乗")),
			float(kmf_best.get("distance", 0.0)) / 10.0,
		]
	return prompt

## 候補の優先スコア (小さいほど優先)。実行不能な候補は後回し。
func _score(entry: Dictionary) -> float:
	var score: float = float(entry.get("distance", 9999.0))
	if bool(entry.get("blocked", false)):
		score += 10000.0
	return score

## 最重要候補を実行する。実行しなかった場合は {"executed": false} を返す。
## HUD はこの結果を見て、従来の Day1Controller.try_interact("") へ委譲する。
func execute_primary() -> Dictionary:
	# F キーは「話す/渡す/引き渡す」(Day1 候補) の実行にのみ使う。
	# 自機KMF の搭乗は E キーの責務 (PlayerController) なのでここでは実行しない。
	var best: Dictionary = {}
	for item in _candidates:
		if not (item is Dictionary):
			continue
		var entry: Dictionary = item
		if str(entry.get("source", "day1")) == "kmf":
			continue
		if bool(entry.get("blocked", false)):
			continue
		if best.is_empty() or _score(entry) < _score(best):
			best = entry
	if best.is_empty():
		# 実行可能な候補が無い。不足している条件だけ通知する。
		for item in _candidates:
			if not (item is Dictionary):
				continue
			var entry2: Dictionary = item
			if bool(entry2.get("blocked", false)):
				interaction_performed.emit({"executed": false, "ok": false, "reason": str(entry2.get("reason", ""))})
				break
		return {"executed": false, "ok": false, "reason": "no_candidate"}
	var target_id: String = str(best.get("target_id", ""))
	var ok: bool = false
	if _day1 != null and is_instance_valid(_day1) and _day1.has_method("try_interact"):
		ok = bool(_day1.call("try_interact", target_id))
	var result: Dictionary = {"executed": true, "ok": ok, "target_id": target_id, "source": str(best.get("source", "day1"))}
	interaction_performed.emit(result)
	refresh()
	return result

func _get_player_position() -> Vector2:
	if _player != null and is_instance_valid(_player):
		return _player.global_position
	return Vector2.ZERO

func _get_player_mode() -> String:
	var gs := get_node_or_null("/root/GameState")
	if gs == null:
		return "foot"
	return str(gs.get_player_mode())
