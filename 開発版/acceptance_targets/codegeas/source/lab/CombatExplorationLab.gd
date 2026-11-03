extends Node2D
## CombatExplorationLab - 戦闘方式比較 Lab (Phase 0.5 Block 2 / Block 3)
##
## 契約 DOCS/02_COMBAT_LAB_CONTRACT.txt の実装。
##   - 同一 seed / 同一マップ / 同一敵 / 同一初期状態 / 同一目的
##   - 何度でも reset できる
##   - retreat / extraction できる
##   - foot / KMF 切替できる
##   - Day1 本編進行へ副作用を出さない
##
## 3方式 (Full Realtime / Realtime+Tactical Pause / Lightweight WEGO) は
## 「別ゲーム」ではなく、本ノードが持つ単一 fixture と単一 CombatCore を共有し、
## CombatMode だけ差し替えて比較する。
##
## Day1 への副作用ゼロ:
##   - GameState を一切触らない (自前の状態を持つ)
##   - グローバル RngService を触らない (自前の RandomNumberGenerator)
##   - Day1Controller / CombatManager / MapManager を参照しない
##   - 時刻 (GameState.advance_time) を進めない

const InputRouter = preload("res://core/InputRouter.gd")
const PlayAreaBounds = preload("res://core/PlayAreaBounds.gd")
const LabFixture = preload("res://lab/LabFixture.gd")
const LabMetrics = preload("res://lab/LabMetrics.gd")
const CombatCore = preload("res://combat/core/CombatCore.gd")
const CombatBalance = preload("res://combat/core/CombatBalance.gd")
const CombatEvent = preload("res://combat/core/CombatEvent.gd")
const CombatFeedback = preload("res://combat/core/CombatFeedback.gd")
const Combatant = preload("res://combat/core/Combatant.gd")
const BaselineTactics = preload("res://combat/core/BaselineTactics.gd")
const CombatMode = preload("res://lab/CombatMode.gd")
const RealtimeMode = preload("res://lab/prototypes/realtime/RealtimeCombatMode.gd")
const TacticalPauseMode = preload("res://lab/prototypes/tactical_pause/TacticalPauseCombatMode.gd")
const WegoMode = preload("res://lab/prototypes/wego/WegoCombatMode.gd")
const CommandPauseMode = preload("res://lab/prototypes/command_pause/CommandPauseCombatMode.gd")
const DecisionPointMode = preload("res://lab/prototypes/decision_point/DecisionPointCombatMode.gd")

const MODE_ORDER: Array = ["realtime", "tactical_pause", "wego", "command_pause", "decision_point"]

const PLAYER_ID: String = "player"
const KMF_ID: String = "player_kmf"
const DODGE_DISTANCE: float = 96.0
const DODGE_DURATION: float = 0.25
const DODGE_COOLDOWN: float = 1.0
const DODGE_INVULNERABLE: float = 0.20
const ENEMY_HIT_RADIUS: float = 20.0
const PLAYER_HIT_RADIUS: float = 18.0

var fixture: Dictionary = {}
var core: CombatCore = null
var metrics: LabMetrics = null
var mode: CombatMode = null

var arena: Node2D = null
var hud: Node = null
var camera: Camera2D = null

# --- 状態 ---
var _player_pos: Vector2 = Vector2.ZERO
var _player_mode: String = "foot"
var _player_combatant: Combatant = null
var _kmf_combatant: Combatant = null
var _kmf_pos: Vector2 = Vector2.ZERO
var _kmf_owned: bool = true
var _kmf_boost_cooldown: float = 0.0
var _kmf_ammo: int = 0
var _enemies: Array = []
var _projectiles: Array = []
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _cover_world: Array = []
var _run_active: bool = false
var _fire_cooldown: float = 0.0
var _aim_override: Vector2 = Vector2.INF
var _locked_part: String = ""
var _last_move_dir: Vector2 = Vector2.ZERO
var _dodge_time_left: float = 0.0
var _dodge_dir: Vector2 = Vector2.ZERO
var _dodge_cooldown: float = 0.0
var _invulnerable: float = 0.0
var _retreat_order: bool = false
var _session_results: Array = []
var _scripted_direction: Vector2 = Vector2.INF
var _scripted_shot: Dictionary = {}
var _manual_step: bool = false
var _message: String = ""
var _message_time: float = 0.0
var _planning_last_move_command: Vector2 = Vector2.ZERO

# Prototype D: point-and-command movement state.
var _command_destination: Vector2 = Vector2.INF
var _command_path: Array = []

# Prototype E: compressed decision-point state.
var _decision_nodes: Array = []
var _decision_selected_id: String = ""
var _decision_state: Dictionary = {}

func _ready() -> void:
	arena = get_node_or_null("Arena") as Node2D
	hud = get_node_or_null("HUD")
	camera = get_node_or_null("Camera2D") as Camera2D
	core = CombatCore.new()
	metrics = LabMetrics.new()
	fixture = LabFixture.build()
	_cover_world = LabFixture.get_cover_world_rects()
	_rng = RandomNumberGenerator.new()
	_rng.seed = int(fixture.get("seed", LabFixture.LAB_SEED))
	reset_lab("realtime")
	set_process(true)

# ------------------------------------------------------------------
# 方式の切替 / reset
# ------------------------------------------------------------------

## 方式 ID からスクリプトを引く。
func _make_mode(mode_id: String) -> CombatMode:
	match mode_id:
		"tactical_pause":
			return TacticalPauseMode.new()
		"wego":
			return WegoMode.new()
		"command_pause":
			return CommandPauseMode.new()
		"decision_point":
			return DecisionPointMode.new()
		_:
			return RealtimeMode.new()

## 方式を切り替える (比較のためにランも初期化される)。
func set_mode(mode_id: String) -> bool:
	if not MODE_ORDER.has(mode_id):
		return false
	reset_lab(mode_id)
	return true

## 次の方式へ巡回する。
func cycle_mode() -> String:
	var index: int = MODE_ORDER.find(mode.get_mode_id()) if mode != null else 0
	var next_index: int = (index + 1) % MODE_ORDER.size()
	reset_lab(str(MODE_ORDER[next_index]))
	return get_mode_id()

func get_mode_id() -> String:
	return mode.get_mode_id() if mode != null else ""

func get_available_modes() -> Array:
	return MODE_ORDER.duplicate()

## 同一条件へ戻す。seed / 敵 / 初期位置 / 目的 / メトリクス をすべて初期化する。
func reset_lab(mode_id: String = "") -> void:
	var target_mode: String = mode_id
	if target_mode.is_empty():
		target_mode = get_mode_id()
		if target_mode.is_empty():
			target_mode = "realtime"

	fixture = LabFixture.build()
	_cover_world = LabFixture.get_cover_world_rects()
	_rng = RandomNumberGenerator.new()
	_rng.seed = int(fixture.get("seed", LabFixture.LAB_SEED))

	core = CombatCore.new()
	core.combat_event.connect(_on_core_event)
	core.feedback_requested.connect(_on_core_feedback)

	metrics = LabMetrics.new()
	metrics.reset(target_mode)

	mode = _make_mode(target_mode)
	mode.configure(self)
	mode.begin_run()

	_player_pos = fixture.get("player_start", LabFixture.PLAYER_START)
	_player_mode = "foot"
	_kmf_pos = fixture.get("kmf_start", LabFixture.KMF_START)
	_kmf_owned = true
	_build_combatants()
	_projectiles.clear()
	_kmf_boost_cooldown = 0.0
	_kmf_ammo = CombatBalance.KMF_MAX_AMMO
	_fire_cooldown = 0.0
	_aim_override = Vector2.INF
	_locked_part = ""
	_last_move_dir = Vector2.ZERO
	_dodge_time_left = 0.0
	_dodge_cooldown = 0.0
	_invulnerable = 0.0
	_retreat_order = false
	_command_destination = Vector2.INF
	_command_path = []
	_decision_nodes = LabFixture.get_decision_nodes()
	_decision_selected_id = ""
	_decision_state = {
		"fuel": 3,
		"medical": 1,
		"intel": 0,
		"salvage": 0,
		"history": [],
		"last_consequence": "",
	}
	_scripted_direction = Vector2.INF
	_scripted_shot = {}
	_run_active = true
	_set_message("Lab 開始: 方式 %s / seed %d" % [mode.get_display_name(), int(fixture.get("seed", 0))])
	_sync_arena()
	_refresh_hud()

func _build_combatants() -> void:
	_player_combatant = Combatant.new(PLAYER_ID, "主人公", "player", "human", CombatBalance.PLAYER_MAX_HP)
	_player_combatant.position = _player_pos
	core.register_combatant(_player_combatant)

	_kmf_combatant = Combatant.new(KMF_ID, "自機KMF", "player", "kmf", CombatBalance.KMF_MAX_HP)
	_kmf_combatant.position = _kmf_pos
	core.register_combatant(_kmf_combatant)

	_enemies.clear()
	var defs: Array = fixture.get("enemies", [])
	for index in range(defs.size()):
		var def: Dictionary = defs[index]
		var combatant := Combatant.new(str(def.get("id", "enemy_%d" % index)), str(def.get("display_name", "敵")), "enemy", str(def.get("kind", "human")), float(def.get("hp", 40.0)))
		combatant.position = def.get("position", Vector2.ZERO)
		core.register_combatant(combatant)
		var ai := BaselineTactics.new()
		ai.reset({"entity_index": index})
		_enemies.append({
			"id": combatant.id,
			"combatant": combatant,
			"def": def,
			"ai": ai,
			"fire_timer": float(def.get("fire_interval", 1.5)) * 0.5,
			"aim_index": index,
		})

# ------------------------------------------------------------------
# メインループ
# ------------------------------------------------------------------

func _process(delta: float) -> void:
	if mode == null:
		return
	_handle_global_input()
	_track_live_movement()
	if not _manual_step:
		mode.tick(delta)
	_update_camera()
	_message_time = maxf(0.0, _message_time - delta)
	_sync_arena()
	_refresh_hud()

## Lab カメラ: 主人公を追う (プレイ領域内に収める)。
func _update_camera() -> void:
	if camera == null or not is_instance_valid(camera):
		return
	var play_area: Rect2 = fixture.get("play_area", LabFixture.PLAY_AREA)
	var view_size: Vector2 = Vector2(1280.0, 720.0)
	var viewport := get_viewport()
	if viewport != null:
		view_size = Vector2(viewport.get_visible_rect().size)
	var target: Vector2 = PlayAreaBounds.clamp_camera_target(_player_pos, play_area, view_size)
	camera.global_position = target

func _handle_global_input() -> void:
	if InputRouter.is_just_pressed("lab_reset"):
		reset_lab(get_mode_id())
		return
	if InputRouter.is_just_pressed("lab_mode_cycle"):
		cycle_mode()
		return
	if InputRouter.is_just_pressed("board_kmf"):
		var kmf_action: String = "dismount" if _player_mode == "kmf" else "board"
		var kmf_result: Dictionary = issue_command(kmf_action, {})
		if not bool(kmf_result.get("ok", false)):
			_set_message("KMF操作不可: %s" % str(kmf_result.get("reason", "unknown")))
		return
	if InputRouter.is_just_pressed("lab_target_cycle"):
		var target_part: String = cycle_locked_part()
		_set_message("狙う部位: %s" % ("自動" if target_part.is_empty() else target_part))
		return
	if InputRouter.is_just_pressed("lab_pause"):
		if get_mode_id() in ["tactical_pause", "command_pause"] and mode != null and mode.is_planning():
			issue_command("resume", {})
		elif get_mode_id() in ["tactical_pause", "command_pause"]:
			issue_command("pause", {})
		return
	if InputRouter.is_just_pressed("lab_plan_confirm"):
		issue_command("plan_confirm", {})
		_planning_last_move_command = Vector2.ZERO
		return
	if InputRouter.is_just_pressed("lab_dodge"):
		issue_command("dodge", {})
		return
	if InputRouter.is_just_pressed("lab_retreat"):
		issue_command("retreat_order", {})
		return
	match get_mode_id():
		"command_pause":
			_handle_command_mode_input()
		"decision_point":
			_handle_decision_mode_input()
		_:
			_handle_planning_live_input()

func _handle_command_mode_input() -> void:
	if InputRouter.is_just_pressed("primary_attack"):
		handle_world_click(get_global_mouse_position())

func _handle_decision_mode_input() -> void:
	if InputRouter.is_just_pressed("primary_attack"):
		var world_pos: Vector2 = get_global_mouse_position()
		var node_id: String = find_decision_node_at(world_pos)
		if node_id.is_empty():
			_set_message("判断点をクリックしてください")
			return
		var result: Dictionary = issue_command("decision_select", {"node_id": node_id})
		if not bool(result.get("ok", false)):
			_set_message("判断点を選択できません: %s" % str(result.get("reason", "unknown")))

## Public bridge used by human mouse input and headless acceptance.
func handle_world_click(world_pos: Vector2) -> Dictionary:
	if get_mode_id() == "command_pause":
		var target_id: String = find_enemy_at(world_pos)
		if not target_id.is_empty():
			return issue_command("attack_target", {"target_id": target_id, "part_id": _locked_part})
		return issue_command("move_target", {"position": world_pos})
	if get_mode_id() == "decision_point":
		var node_id: String = find_decision_node_at(world_pos)
		if node_id.is_empty():
			return {"ok": false, "reason": "no_decision_node"}
		return issue_command("decision_select", {"node_id": node_id})
	return {"ok": false, "reason": "mode_does_not_use_world_click"}

func find_enemy_at(world_pos: Vector2, radius: float = 42.0) -> String:
	var best_id: String = ""
	var best_distance: float = radius
	for entry in _enemies:
		if not (entry is Dictionary):
			continue
		var combatant: Combatant = (entry as Dictionary).get("combatant")
		if combatant == null or not combatant.is_active():
			continue
		var distance: float = combatant.position.distance_to(world_pos)
		if distance <= best_distance:
			best_distance = distance
			best_id = combatant.id
	return best_id

func find_decision_node_at(world_pos: Vector2, radius: float = 48.0) -> String:
	var best_id: String = ""
	var best_distance: float = radius
	for item in _decision_nodes:
		if not (item is Dictionary):
			continue
		var node: Dictionary = item
		var node_pos: Vector2 = node.get("position", Vector2.ZERO)
		var distance: float = node_pos.distance_to(world_pos)
		if distance <= best_distance:
			best_distance = distance
			best_id = str(node.get("id", ""))
	return best_id

## Human-play bridge for the planning modes.
## Tactical Pause / WEGO previously exposed command APIs only to scripted tests.
## This routes real WASD / left-click input into the exact same command path.
func _handle_planning_live_input() -> void:
	if mode == null or not mode.is_planning():
		_planning_last_move_command = Vector2.ZERO
		return

	var dir: Vector2 = _read_move_input()
	if dir == Vector2.ZERO:
		_planning_last_move_command = Vector2.ZERO
	elif dir != _planning_last_move_command:
		_planning_last_move_command = dir
		var move_result: Dictionary = issue_command("move", {"direction": dir})
		if not bool(move_result.get("ok", false)):
			_set_message("移動指示不可: %s" % str(move_result.get("reason", "unknown")))

	if InputRouter.is_just_pressed("primary_attack"):
		var attack_result: Dictionary = issue_command("attack", {
			"aim_point": get_aim_point(),
			"part_id": _locked_part,
		})
		if not bool(attack_result.get("ok", false)):
			_set_message("射撃指示不可: %s" % str(attack_result.get("reason", "unknown")))

## 方式-independent なコマンド入口 (HUD / 自動テストから叩ける)。
func issue_command(action: String, payload: Dictionary = {}) -> Dictionary:
	if mode == null:
		return {"ok": false, "reason": "no_mode"}
	match action:
		"board", "dismount":
			var kmf_result: Dictionary = _toggle_kmf()
			if bool(kmf_result.get("ok", false)):
				record_player_action(action, payload, true)
			return kmf_result
		"dodge":
			var dodge_result: Dictionary = mode.issue_action(action, payload)
			if bool(dodge_result.get("ok", false)):
				_start_dodge()
			return dodge_result
		"aim":
			_aim_override = payload.get("aim_point", Vector2.INF)
			return {"ok": true, "reason": ""}
		"target_part":
			_locked_part = str(payload.get("part_id", ""))
			return mode.issue_action(action, payload)
		"move":
			return mode.issue_action("move_order", {"direction": payload.get("direction", Vector2.ZERO)})
		"move_target":
			return mode.issue_action("move_target", {"position": payload.get("position", _player_pos)})
		"attack_target":
			var target_id: String = str(payload.get("target_id", ""))
			var target = core.get_combatant(target_id)
			if target == null or not target.is_active():
				return {"ok": false, "reason": "no_target"}
			return mode.issue_action("attack_target", {
				"target_id": target_id,
				"aim_point": target.position,
				"part_id": str(payload.get("part_id", _locked_part)),
			})
		"decision_select":
			return mode.issue_action("decision_select", payload)
		"attack":
			var shot: Dictionary = {
				"aim_point": payload.get("aim_point", get_aim_point()),
				"part_id": str(payload.get("part_id", _locked_part)),
			}
			return mode.issue_action("attack", shot)
		_:
			return mode.issue_action(action, payload)

## 連続移動の入力変化を「操作」として数える (方式A/B のみ)。
## スクリプト固定入力の場合も「実際に効いた方向」を数えるので、
## ライブ操作と自動計測の action_count が同じ定義になる。
func _track_live_movement() -> void:
	if mode == null or not mode.uses_live_movement():
		return
	var dir: Vector2 = get_input_direction()
	var quantized: Vector2 = Vector2(
		signf(roundf(dir.x)),
		signf(roundf(dir.y))
	)
	if quantized != _last_move_dir:
		_last_move_dir = quantized
		record_player_action("move", {"direction": quantized}, true)

func _read_move_input() -> Vector2:
	var dir: Vector2 = Vector2.ZERO
	if InputRouter.is_pressed("move_left"):
		dir.x -= 1.0
	if InputRouter.is_pressed("move_right"):
		dir.x += 1.0
	if InputRouter.is_pressed("move_up"):
		dir.y -= 1.0
	if InputRouter.is_pressed("move_down"):
		dir.y += 1.0
	return dir.normalized() if dir.length() > 0.0 else Vector2.ZERO

## 方式に渡す生入力。
## スクリプト (自動テスト / 比較計測) から固定したい場合は set_scripted_input を使う。
func get_input_direction() -> Vector2:
	if _scripted_direction.x != INF and _scripted_direction.y != INF:
		return _scripted_direction
	return _read_move_input()

## 生入力からの発射要求。
func read_fire_input() -> Dictionary:
	if not _scripted_shot.is_empty():
		var shot: Dictionary = _scripted_shot
		_scripted_shot = {}
		return shot
	if InputRouter.is_just_pressed("primary_attack"):
		return {
			"aim_point": get_aim_point(),
			"part_id": _locked_part,
		}
	return {}

## --- スクリプト操作 API (自動テスト / 計測用) ---

## 移動入力を固定する (Vector2.INF で解除)。
func set_scripted_input(direction: Vector2) -> void:
	_scripted_direction = direction

## 発射を1回予約する。
func queue_scripted_shot(aim_point: Vector2, part_id: String = "") -> void:
	_scripted_shot = {"aim_point": aim_point, "part_id": part_id}

## _process による自動進行を止め、手動で固定ステップを刻むようにする。
func set_manual_step(enabled: bool) -> void:
	_manual_step = enabled

## 固定ステップでシミュレーションを進める (決定論)。
func step_fixed(dt: float) -> void:
	if mode == null:
		return
	mode.tick(dt)

func get_aim_point() -> Vector2:
	if _aim_override.x != INF and _aim_override.y != INF:
		return _aim_override
	var world_mouse: Vector2 = get_global_mouse_position()
	return world_mouse

func get_locked_part() -> String:
	return _locked_part

func cycle_locked_part() -> String:
	var candidates: Array = ["", "cockpit", "head", "torso", "left_leg", "right_leg", "left_arm", "right_arm", "weapon", "sensor"]
	var index: int = candidates.find(_locked_part)
	_locked_part = str(candidates[(index + 1) % candidates.size()])
	return _locked_part

# ------------------------------------------------------------------
# シミュレーション
# ------------------------------------------------------------------

func is_run_active() -> bool:
	return _run_active

## 1フレーム分のシミュレーションを進める (CombatMode が呼ぶ)。
func sim_advance(delta: float) -> void:
	if not _run_active or delta <= 0.0:
		return
	metrics.combat_time += delta
	metrics.real_time += delta
	core.set_clock(metrics.combat_time)

	_update_player(delta)
	_update_enemies(delta)
	_update_projectiles(delta)
	_check_end_conditions()

## planning 中の処理 (combat_time は進めない)。
func on_planning_tick(delta: float) -> void:
	metrics.real_time += delta

func _update_player(delta: float) -> void:
	_fire_cooldown = maxf(0.0, _fire_cooldown - delta)
	_dodge_cooldown = maxf(0.0, _dodge_cooldown - delta)
	_invulnerable = maxf(0.0, _invulnerable - delta)
	_kmf_boost_cooldown = maxf(0.0, _kmf_boost_cooldown - delta)

	# --- 発射 ---
	var shot: Dictionary = mode.poll_shot()
	if not shot.is_empty():
		_fire(shot)

	# --- 移動 ---
	var dir: Vector2 = mode.get_move_direction()
	if _retreat_order:
		if get_mode_id() == "command_pause":
			if not has_command_destination():
				set_command_destination(get_extraction_point())
			dir = get_command_move_direction()
		else:
			var to_extract: Vector2 = (fixture.get("extraction_point", LabFixture.EXTRACTION_POINT) - _player_pos)
			if to_extract.length() > 1.0:
				dir = to_extract.normalized()
			else:
				_retreat_order = false

	if _dodge_time_left > 0.0:
		_dodge_time_left -= delta
		_move_player(_dodge_dir, DODGE_DISTANCE / DODGE_DURATION * delta)
	else:
		_move_player(dir, _get_move_speed() * delta)

	_player_combatant.position = _player_pos
	_kmf_combatant.position = _kmf_pos

func _get_move_speed() -> float:
	var base: float = CombatBalance.KMF_SPEED if _player_mode == "kmf" else CombatBalance.FOOT_SPEED
	if _player_mode == "kmf":
		var effects: Dictionary = _kmf_combatant.get_effects() if _kmf_combatant != null else {}
		base *= float(effects.get("mobility_multiplier", 1.0))
		if InputRouter.is_pressed("sprint") and _kmf_boost_cooldown <= 0.0 and _kmf_combatant != null:
			var effects2: Dictionary = _kmf_combatant.get_effects()
			if not bool(effects2.get("immobilized", false)):
				base = CombatBalance.KMF_BOOST_SPEED
				_kmf_boost_cooldown = CombatBalance.KMF_BOOST_COOLDOWN
	else:
		if InputRouter.is_pressed("sprint"):
			base *= CombatBalance.FOOT_SPRINT_MULTIPLIER
	return base

func _move_player(dir: Vector2, distance: float) -> void:
	if dir == Vector2.ZERO or distance == 0.0:
		return
	var next: Vector2 = _player_pos + dir.normalized() * distance
	next = LabFixture.resolve_cover(next, 12.0, _cover_world)
	var play_area: Rect2 = fixture.get("play_area", LabFixture.PLAY_AREA)
	next.x = clampf(next.x, play_area.position.x + 8.0, play_area.position.x + play_area.size.x - 8.0)
	next.y = clampf(next.y, play_area.position.y + 8.0, play_area.position.y + play_area.size.y - 8.0)
	_player_pos = next
	if _player_mode == "kmf":
		_kmf_pos = _player_pos

func _start_dodge() -> void:
	if _dodge_cooldown > 0.0:
		return
	var dir: Vector2 = _read_move_input()
	if dir == Vector2.ZERO:
		dir = Vector2.RIGHT
	_dodge_dir = dir
	_dodge_time_left = DODGE_DURATION
	_dodge_cooldown = DODGE_COOLDOWN
	_invulnerable = DODGE_INVULNERABLE
	metrics.dodges += 1

# --- 敵 ---

func _update_enemies(delta: float) -> void:
	for entry in _enemies:
		if not (entry is Dictionary):
			continue
		var e: Dictionary = entry
		var combatant: Combatant = e.get("combatant")
		if combatant == null or not combatant.is_active():
			continue
		var def: Dictionary = e.get("def", {})
		var ai = e.get("ai")
		var effects: Dictionary = combatant.get_effects()
		var distance: float = combatant.position.distance_to(_player_pos)
		var context: Dictionary = {
			"self_position": combatant.position,
			"player_position": _player_pos,
			"distance": distance,
			"desired_range": float(def.get("desired_range", 160.0)),
			"detection_range": float(def.get("detection_range", 220.0)),
			"weapon_ready": not bool(effects.get("weapon_disabled", false)),
			"effects": effects,
			"hp_ratio": combatant.get_hp_ratio(),
			"cover_available": true,
			"allies_alive": true,
			"target_kind": _player_mode,
			"delta": delta,
			"entity_index": int(e.get("aim_index", 0)),
		}
		var decision: Dictionary = ai.evaluate(context) if ai != null else {"action": "hold"}
		var action: String = str(decision.get("action", "hold"))
		var move_dir: Vector2 = decision.get("direction", Vector2.ZERO)
		var speed: float = float(def.get("speed", 40.0))
		speed *= float(effects.get("mobility_multiplier", 1.0))
		# Track AI tactical actions for metrics / comparison (Block 5 & 7).
		var prev_action: String = str(e.get("last_ai_action", ""))
		if action != prev_action and action not in ["", "hold"]:
			metrics.ai_tactical_total += 1
			var counts: Dictionary = metrics.ai_tactical_actions
			counts[action] = int(counts.get(action, 0)) + 1
			metrics.ai_tactical_actions = counts
			core.emit_event("ai_tactic", {
				"time": metrics.combat_time,
				"source_id": combatant.id,
				"mode_id": get_mode_id(),
				"meta": {"action": action, "reason": str(decision.get("reason", "")), "direction": move_dir},
			})
		e["last_ai_action"] = action
		if action in ["approach", "flank", "retreat", "seek_cover"]:
			var next: Vector2 = combatant.position + move_dir * speed * delta
			combatant.position = LabFixture.resolve_cover(next, 14.0, _cover_world)
		elif action == "engage":
			# 射程維持: 少し横移動
			var side := Vector2(-move_dir.y, move_dir.x) * 0.4
			var next2: Vector2 = combatant.position + side * speed * delta
			combatant.position = LabFixture.resolve_cover(next2, 14.0, _cover_world)
		# --- 射撃 ---
		var fire_timer: float = float(e.get("fire_timer", 0.0)) - delta
		var want_fire: bool = bool(decision.get("fire", false)) and action == "engage"
		if want_fire and fire_timer <= 0.0:
			_enemy_fire(combatant, def, int(e.get("aim_index", 0)))
			fire_timer = float(def.get("fire_interval", 1.5))
		e["fire_timer"] = fire_timer

func _enemy_fire(enemy: Combatant, def: Dictionary, aim_index: int) -> void:
	var target_pos: Vector2 = _player_pos
	var error: float = float(def.get("aim_error", 12.0))
	# 決定的な外れ (乱数を使わない)
	var angle: float = float(aim_index) * 1.7 + 0.6
	var offset := Vector2(cos(angle), sin(angle)) * error
	var aim: Vector2 = target_pos + offset
	var dir: Vector2 = (aim - enemy.position).normalized()
	if dir == Vector2.ZERO:
		dir = Vector2.RIGHT
	_projectiles.append({
		"pos": enemy.position,
		"dir": dir,
		"speed": float(def.get("projectile_speed", 320.0)),
		"damage": float(def.get("weapon_damage", 6.0)),
		"is_player": false,
		"source_id": enemy.id,
		"life": 2.0,
	})

# --- 弾 ---

func _fire(shot: Dictionary) -> void:
	if _fire_cooldown > 0.0:
		return
	var is_kmf: bool = _player_mode == "kmf"
	if is_kmf:
		var effects: Dictionary = _kmf_combatant.get_effects() if _kmf_combatant != null else {}
		if bool(effects.get("weapon_disabled", false)):
			_set_message("KMFの武器が壊れている (発射不可)")
			return
		if _kmf_ammo <= 0:
			_set_message("KMFの弾薬が尽きた")
			return
		_kmf_ammo -= 1
		_fire_cooldown = CombatBalance.KMF_FIRE_COOLDOWN
		metrics.kmf_shots += 1
	else:
		_fire_cooldown = CombatBalance.FOOT_FIRE_COOLDOWN
		metrics.foot_shots += 1
	metrics.shots_fired += 1

	var origin: Vector2 = _player_pos
	var aim: Vector2 = shot.get("aim_point", get_aim_point())
	var dir: Vector2 = (aim - origin).normalized()
	if dir == Vector2.ZERO:
		dir = Vector2.RIGHT
	_projectiles.append({
		"pos": origin,
		"dir": dir,
		"speed": CombatBalance.PROJECTILE_SPEED,
		"damage": CombatBalance.KMF_DAMAGE if is_kmf else CombatBalance.FOOT_DAMAGE,
		"is_player": true,
		"source_id": PLAYER_ID,
		"part_id": str(shot.get("part_id", _locked_part)),
		"aim_point": aim,
		"life": CombatBalance.PROJECTILE_LIFE,
	})
	core.emit_event(CombatEvent.KIND_SHOT, {
		"time": metrics.combat_time,
		"source_id": PLAYER_ID,
		"position": origin,
		"mode_id": get_mode_id(),
		"meta": {"is_kmf": is_kmf},
	})

func _update_projectiles(delta: float) -> void:
	var to_remove: Array = []
	for index in range(_projectiles.size()):
		var p: Dictionary = _projectiles[index]
		p["life"] = float(p["life"]) - delta
		p["pos"] = Vector2(p["pos"]) + Vector2(p["dir"]) * float(p["speed"]) * delta
		if float(p["life"]) <= 0.0:
			to_remove.append(index)
			continue
		if bool(p.get("is_player", false)):
			_resolve_player_projectile(p, index, to_remove)
		else:
			_resolve_enemy_projectile(p, index, to_remove)
	for idx in to_remove:
		if idx < _projectiles.size():
			_projectiles.remove_at(idx)

func _resolve_player_projectile(p: Dictionary, index: int, to_remove: Array) -> void:
	for entry in _enemies:
		if not (entry is Dictionary):
			continue
		var e: Dictionary = entry
		var combatant: Combatant = e.get("combatant")
		if combatant == null or not combatant.is_active():
			continue
		var pos: Vector2 = p["pos"]
		if pos.distance_to(combatant.position) > ENEMY_HIT_RADIUS:
			continue
		var aim: Vector2 = p.get("aim_point", pos)
		var part_id: String = str(p.get("part_id", ""))
		if part_id.is_empty():
			part_id = core.choose_part(combatant, aim)
		var result: Dictionary = core.resolve_shot(PLAYER_ID, combatant.id, part_id, float(p["damage"]), {
			"mode_id": get_mode_id(),
			"aim_point": aim,
			"hit_position": pos,
			"origin": p["pos"],
		})
		if bool(result.get("hit", false)):
			metrics.hits += 1
			metrics.part_hits += 1
			if bool(result.get("part_destroyed", false)):
				metrics.part_destroys += 1
			if bool(result.get("incapacitated", false)):
				metrics.enemies_neutralized += 1
			if bool(result.get("destroyed", false)):
				metrics.enemies_destroyed += 1
		else:
			metrics.misses += 1
		to_remove.append(index)
		return

func _resolve_enemy_projectile(p: Dictionary, index: int, to_remove: Array) -> void:
	var pos: Vector2 = p["pos"]
	var target_id: String = PLAYER_ID
	var target_pos: Vector2 = _player_pos
	if _player_mode == "kmf":
		target_id = KMF_ID
		target_pos = _kmf_pos
	if pos.distance_to(target_pos) > PLAYER_HIT_RADIUS:
		return
	if _invulnerable > 0.0:
		to_remove.append(index)
		_set_message("回避成功 (被弾なし)")
		return

	var damage: float = float(p["damage"])
	var combatant = core.get_combatant(target_id)
	if combatant == null:
		to_remove.append(index)
		return
	var part_id: String = core.choose_part(combatant, pos)
	var result: Dictionary = core.apply_damage(target_id, part_id, damage, {
		"source_id": str(p.get("source_id", "")),
		"mode_id": get_mode_id(),
		"hit_position": pos,
	})
	if bool(result.get("hit", false)):
		metrics.damage_received += damage
		metrics.player_hp_lost += damage
		if _player_mode == "kmf":
			var kmf_damage: float = damage * 0.5
			var kmf_result: Dictionary = core.apply_damage(KMF_ID, part_id, kmf_damage, {
				"source_id": str(p.get("source_id", "")),
				"mode_id": get_mode_id(),
				"hit_position": pos,
			})
			if bool(kmf_result.get("hit", false)):
				metrics.kmf_damage += kmf_damage
				_after_kmf_damage()
	to_remove.append(index)

func _after_kmf_damage() -> void:
	if _kmf_combatant == null:
		return
	var effects: Dictionary = _kmf_combatant.get_effects()
	if bool(effects.get("structural_failure", false)):
		_lose_kmf("機体骨格が崩壊した")
		return
	if bool(effects.get("pilot_dead", false)):
		_lose_kmf("コックピットが破壊された (操縦手が抛出)")
		return
	if bool(effects.get("immobilized", false)):
		_set_message("KMFの脚が壊れ、機動力を確保できない")

func _lose_kmf(reason: String) -> void:
	_kmf_owned = false
	if _player_mode == "kmf":
		_player_mode = "foot"
		metrics.dismounts += 1
		core.apply_damage(PLAYER_ID, "torso", 20.0, {"mode_id": get_mode_id()})
	_set_message("KMF喪失: %s" % reason)

# ------------------------------------------------------------------
# Open gameplay competition prototypes (D / E)
# ------------------------------------------------------------------

func get_extraction_point() -> Vector2:
	return fixture.get("extraction_point", LabFixture.EXTRACTION_POINT)

func clear_command_destination() -> void:
	_command_destination = Vector2.INF
	_command_path = []

func has_command_destination() -> bool:
	return _command_destination.x != INF and _command_destination.y != INF and not _command_path.is_empty()

func set_command_destination(world_pos: Vector2) -> Dictionary:
	var area: Rect2 = fixture.get("play_area", LabFixture.PLAY_AREA)
	var target := Vector2(
		clampf(world_pos.x, area.position.x + 16.0, area.position.x + area.size.x - 16.0),
		clampf(world_pos.y, area.position.y + 16.0, area.position.y + area.size.y - 16.0)
	)
	var path: Array = _build_command_path(_player_pos, target)
	if path.is_empty():
		return {"ok": false, "reason": "no_path"}
	_command_destination = target
	_command_path = path
	_set_message("移動先指定: 距離 %.0f / ETA %.1fs" % [_get_command_path_distance(), _get_command_eta()])
	return {"ok": true, "reason": "", "destination": target, "path": path.duplicate()}

func get_command_move_direction() -> Vector2:
	while not _command_path.is_empty():
		var next_point: Vector2 = _command_path[0]
		if _player_pos.distance_to(next_point) <= 10.0:
			_command_path.remove_at(0)
			continue
		return (next_point - _player_pos).normalized()
	clear_command_destination()
	return Vector2.ZERO

func _get_command_path_distance() -> float:
	if _command_path.is_empty():
		return 0.0
	var total: float = 0.0
	var previous: Vector2 = _player_pos
	for item in _command_path:
		var point: Vector2 = item
		total += previous.distance_to(point)
		previous = point
	return total

func _get_command_eta() -> float:
	var speed: float = maxf(1.0, _get_move_speed())
	return _get_command_path_distance() / speed

func get_command_status_lines() -> Array:
	if not has_command_destination():
		return ["移動先: 未指定 (空地点クリック)", "敵をクリック: 対象指定射撃"]
	return [
		"移動先: (%.0f, %.0f)" % [_command_destination.x, _command_destination.y],
		"残距離: %.0f / ETA %.1fs" % [_get_command_path_distance(), _get_command_eta()],
		"敵をクリック: 対象指定射撃",
	]

func _world_to_cell(point: Vector2) -> Vector2i:
	var x: int = clampi(int(floor(point.x / 32.0)), 0, 39)
	var y: int = clampi(int(floor(point.y / 32.0)), 0, 29)
	return Vector2i(x, y)

func _cell_center(cell: Vector2i) -> Vector2:
	return Vector2((float(cell.x) + 0.5) * 32.0, (float(cell.y) + 0.5) * 32.0)

func _build_command_path(start: Vector2, target: Vector2) -> Array:
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(0, 0, 40, 30)
	grid.cell_size = Vector2(32.0, 32.0)
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	grid.update()
	for cover_item in fixture.get("cover_rects", LabFixture.COVER_RECTS):
		if not (cover_item is Rect2i):
			continue
		var rect: Rect2i = cover_item
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			for y in range(rect.position.y, rect.position.y + rect.size.y):
				grid.set_point_solid(Vector2i(x, y), true)
	var start_id: Vector2i = _world_to_cell(start)
	var target_id: Vector2i = _world_to_cell(target)
	if grid.is_point_solid(target_id):
		target_id = _nearest_walkable_cell(grid, target_id)
	if grid.is_point_solid(start_id) or grid.is_point_solid(target_id):
		return []
	var ids: Array[Vector2i] = grid.get_id_path(start_id, target_id, true)
	if ids.is_empty():
		return []
	var out: Array = []
	for id in ids:
		out.append(_cell_center(id))
	out[0] = start
	if _world_to_cell(target) == target_id:
		out[out.size() - 1] = target
	return out

func _nearest_walkable_cell(grid: AStarGrid2D, origin: Vector2i) -> Vector2i:
	for radius in range(1, 5):
		for x in range(origin.x - radius, origin.x + radius + 1):
			for y in range(origin.y - radius, origin.y + radius + 1):
				var candidate := Vector2i(x, y)
				if x < 0 or x >= 40 or y < 0 or y >= 30:
					continue
				if not grid.is_point_solid(candidate):
					return candidate
	return origin

func select_decision_node(node_id: String) -> Dictionary:
	var node: Dictionary = LabFixture.get_decision_node(node_id)
	if node.is_empty():
		return {"ok": false, "reason": "unknown_decision_node"}
	_decision_selected_id = node_id
	_set_message("%s: %s" % [str(node.get("label", node_id)), str(node.get("summary", ""))])
	return {"ok": true, "reason": "", "node": node}

func resolve_decision_node(node_id: String) -> Dictionary:
	var node: Dictionary = LabFixture.get_decision_node(node_id)
	if node.is_empty():
		return {"ok": false, "reason": "unknown_decision_node"}
	var fuel_cost: int = int(node.get("fuel_cost", 0)) if _player_mode == "kmf" else 0
	var fuel: int = int(_decision_state.get("fuel", 0))
	if fuel_cost > fuel:
		return {"ok": false, "reason": "insufficient_fuel"}

	var time_cost: float = float(node.get("time_cost", 0.0))
	metrics.combat_time += time_cost
	metrics.real_time += time_cost
	core.set_clock(metrics.combat_time)
	_decision_state["fuel"] = fuel - fuel_cost
	_decision_state["intel"] = int(_decision_state.get("intel", 0)) + int(node.get("intel_delta", 0))
	_decision_state["salvage"] = int(_decision_state.get("salvage", 0)) + int(node.get("salvage_delta", 0))

	_player_pos = node.get("position", _player_pos)
	if _player_mode == "kmf":
		_kmf_pos = _player_pos
	_player_combatant.position = _player_pos
	_kmf_combatant.position = _kmf_pos

	var risk: int = int(node.get("risk", 0))
	var damage: float = 0.0
	var damaged_part: String = ""
	if risk > 0:
		var target_id: String = KMF_ID if _player_mode == "kmf" else PLAYER_ID
		var target = core.get_combatant(target_id)
		var parts: Array = target.get_part_ids() if target != null else []
		if not parts.is_empty():
			var history: Array = _decision_state.get("history", [])
			damaged_part = str(parts[(history.size() + risk) % parts.size()])
			damage = float(risk * (4 if _player_mode == "kmf" else 6))
			var damage_result: Dictionary = core.apply_damage(target_id, damaged_part, damage, {
				"source_id": "decision_risk",
				"mode_id": get_mode_id(),
				"hit_position": _player_pos,
			})
			if bool(damage_result.get("hit", false)):
				metrics.damage_received += damage
				if _player_mode == "kmf":
					metrics.kmf_damage += damage
					_after_kmf_damage()

	var consequence: String = "%s / 時間+%.0f / 危険%d" % [str(node.get("label", node_id)), time_cost, risk]
	if damage > 0.0:
		consequence += " / %s -%.0f" % [damaged_part, damage]
	if int(node.get("intel_delta", 0)) != 0:
		consequence += " / 情報+%d" % int(node.get("intel_delta", 0))
	if int(node.get("salvage_delta", 0)) != 0:
		consequence += " / 回収+%d" % int(node.get("salvage_delta", 0))
	_decision_state["last_consequence"] = consequence
	var history2: Array = _decision_state.get("history", [])
	history2.append({"node_id": node_id, "consequence": consequence})
	_decision_state["history"] = history2
	_decision_selected_id = ""

	if node_id == "extract":
		metrics.retreat_attempted = true
	_check_end_conditions()
	if _run_active:
		_set_message(consequence)
	return {"ok": true, "reason": "", "consequence": consequence}

func get_decision_status_lines() -> Array:
	var lines: Array = []
	lines.append("資源: fuel %d / medical %d / intel %d / salvage %d" % [
		int(_decision_state.get("fuel", 0)),
		int(_decision_state.get("medical", 0)),
		int(_decision_state.get("intel", 0)),
		int(_decision_state.get("salvage", 0)),
	])
	if _decision_selected_id.is_empty():
		lines.append("判断点: 未選択")
	else:
		var node: Dictionary = LabFixture.get_decision_node(_decision_selected_id)
		lines.append("選択: %s" % str(node.get("label", _decision_selected_id)))
		lines.append(str(node.get("summary", "")))
	var last: String = str(_decision_state.get("last_consequence", ""))
	if not last.is_empty():
		lines.append("直前: %s" % last)
	return lines

func get_decision_nodes_view() -> Array:
	var out: Array = []
	for item in _decision_nodes:
		if not (item is Dictionary):
			continue
		var node: Dictionary = (item as Dictionary).duplicate(true)
		node["selected"] = str(node.get("id", "")) == _decision_selected_id
		out.append(node)
	return out

func get_decision_state() -> Dictionary:
	return _decision_state.duplicate(true)

func get_help_text() -> String:
	match get_mode_id():
		"command_pause":
			return "D操作:\n空地点クリック=移動先 / 敵クリック=対象指定射撃 / Q=部位\nP=停止・再開 / E=搭乗・降機 / X=離脱指示\nTab=方式切替 / R=リセット"
		"decision_point":
			return "E操作:\n判断点クリック=選択 / Enter=確定 / E=搭乗・降機\nX=離脱判断を選択 / Tab=方式切替 / R=リセット"
		_:
			return "操作:\nWASD 移動 / 左クリック 射撃 / Q 部位指定 / Space 回避\nE 搭乗・降機 / X 退避指示 / P 戦術ポーズ開始・再開\nWEGO: planning中にWASD/左クリックで指示 → Enterで1ターン実行\nTab 方式切替 / R リセット"

# ------------------------------------------------------------------
# 状態遷移 / 勝敗
# ------------------------------------------------------------------

func _check_end_conditions() -> void:
	if not _run_active:
		return
	# 主人公死亡
	if not _player_combatant.is_active():
		metrics.player_dead = true
		metrics.outcome = LabMetrics.OUTCOME_DEAD
		_end_run()
		return
	# 離脱成功
	var extraction: Vector2 = fixture.get("extraction_point", LabFixture.EXTRACTION_POINT)
	var radius: float = float(fixture.get("extraction_radius", LabFixture.EXTRACTION_RADIUS))
	if _player_pos.distance_to(extraction) <= radius:
		metrics.retreat_success = true
		metrics.outcome = LabMetrics.OUTCOME_EXTRACTED
		_end_run()
		return
	# タイムアウト
	if metrics.combat_time >= float(fixture.get("time_limit", LabFixture.RUN_TIME_LIMIT)):
		metrics.timeout = true
		metrics.outcome = LabMetrics.OUTCOME_TIMEOUT
		_end_run()

func _end_run() -> void:
	_run_active = false
	if mode != null:
		mode.end_run()
	var row: Dictionary = metrics.get_comparison_row()
	_session_results.append(row)
	_set_message("ラン終了: %s (戦闘 %.1fs / 撃破 %d)" % [str(metrics.outcome), metrics.combat_time, metrics.enemies_destroyed])
	if hud != null and hud.has_method("push_result"):
		hud.push_result(row)

## 現在のランを中断して次の準備に入る (結果は保持しない)。
func abort_run() -> void:
	_run_active = false

# ------------------------------------------------------------------
# KMF 搭乗 / 降機
# ------------------------------------------------------------------

func _toggle_kmf() -> Dictionary:
	if _player_mode == "kmf":
		_player_mode = "foot"
		_kmf_pos = _player_pos
		metrics.dismounts += 1
		core.emit_event(CombatEvent.KIND_DISMOUNT, {"time": metrics.combat_time, "position": _player_pos, "mode_id": get_mode_id()})
		_set_message("KMFから降りた")
		return {"ok": true, "reason": ""}
	if not _kmf_owned:
		_set_message("自機KMFは使用不能")
		return {"ok": false, "reason": "kmf_unavailable"}
	if _player_pos.distance_to(_kmf_pos) > CombatBalance.BOARD_RANGE:
		_set_message("自機KMFへ近づいて E で搭乗 (距離 %dm)" % int(round(_player_pos.distance_to(_kmf_pos) / 10.0)))
		return {"ok": false, "reason": "too_far"}
	_player_mode = "kmf"
	_player_pos = _kmf_pos
	metrics.boards += 1
	core.emit_event(CombatEvent.KIND_BOARD, {"time": metrics.combat_time, "position": _player_pos, "mode_id": get_mode_id()})
	_set_message("自機KMFに乗った")
	return {"ok": true, "reason": ""}

func get_player_mode() -> String:
	return _player_mode

func get_player_position() -> Vector2:
	return _player_pos

func get_kmf_position() -> Vector2:
	return _kmf_pos

func is_kmf_owned() -> bool:
	return _kmf_owned

func get_player_combatant() -> Combatant:
	return _player_combatant

func get_kmf_combatant() -> Combatant:
	return _kmf_combatant

func get_enemies() -> Array:
	return _enemies.duplicate(true)

func get_metrics() -> Dictionary:
	return metrics.to_dictionary()

func get_session_results() -> Array:
	return _session_results.duplicate(true)

# ------------------------------------------------------------------
# メトリクス / 通知
# ------------------------------------------------------------------

func record_player_action(action: String, payload: Dictionary, is_decision: bool) -> void:
	if metrics == null:
		return
	metrics.action_count += 1
	if is_decision:
		metrics.decision_count += 1
	if action == "retreat_order":
		metrics.retreat_orders += 1
		metrics.retreat_attempted = true
		_retreat_order = true

func add_planning_time(delta: float) -> void:
	if metrics == null:
		return
	metrics.planning_seconds += delta

func on_pause_started() -> void:
	if metrics == null:
		return
	metrics.pause_count += 1
	core.emit_event(CombatEvent.KIND_PLAN_START, {"time": metrics.combat_time, "mode_id": get_mode_id()})

func on_pause_ended() -> void:
	core.emit_event(CombatEvent.KIND_PLAN_END, {"time": metrics.combat_time, "mode_id": get_mode_id()})

func on_planning_started() -> void:
	if metrics == null:
		return
	metrics.planning_count += 1
	core.emit_event(CombatEvent.KIND_PLAN_START, {"time": metrics.combat_time, "mode_id": get_mode_id()})

func on_planning_ended() -> void:
	core.emit_event(CombatEvent.KIND_PLAN_END, {"time": metrics.combat_time, "mode_id": get_mode_id()})

func _on_core_event(event: Dictionary) -> void:
	if arena != null and arena.has_method("push_event"):
		arena.push_event(event)

func _on_core_feedback(feedback: Dictionary) -> void:
	if arena != null and arena.has_method("push_feedback"):
		arena.push_feedback(feedback)
	# Player-readable message for key combat transitions (Block 7).
	var kind: String = str(feedback.get("kind", ""))
	var text: String = str(feedback.get("text", ""))
	if kind in ["part_destroyed", "incapacitated", "destroyed"] and not text.is_empty():
		_set_message(text)
	elif kind == "hit" and not text.is_empty():
		# Short flash message; do not spam every tick.
		if _message_time <= 0.4:
			_set_message(text)

func _set_message(text: String) -> void:
	_message = text
	_message_time = 3.0

func get_message() -> String:
	return _message if _message_time > 0.0 else ""

func _sync_arena() -> void:
	if arena == null or not arena.has_method("sync_state"):
		return
	arena.sync_state({
		"player_position": _player_pos,
		"player_mode": _player_mode,
		"player_hp": _player_combatant.hp if _player_combatant != null else 0.0,
		"player_max_hp": _player_combatant.max_hp if _player_combatant != null else 100.0,
		"kmf_position": _kmf_pos,
		"kmf_owned": _kmf_owned,
		"kmf_body": _kmf_combatant.body if _kmf_combatant != null else {},
		"enemies": _enemies,
		"projectiles": _projectiles,
		"cover": _cover_world,
		"extraction": fixture.get("extraction_point", LabFixture.EXTRACTION_POINT),
		"extraction_radius": float(fixture.get("extraction_radius", LabFixture.EXTRACTION_RADIUS)),
		"play_area": fixture.get("play_area", LabFixture.PLAY_AREA),
		"dodge_flash": _invulnerable,
		"mode_id": get_mode_id(),
		"command_path": _command_path.duplicate(),
		"command_destination": _command_destination,
		"decision_nodes": get_decision_nodes_view(),
		"decision_state": get_decision_state(),
	})

func _refresh_hud() -> void:
	if hud == null or not hud.has_method("refresh_lab"):
		return
	hud.refresh_lab({
		"mode_id": get_mode_id(),
		"mode_name": mode.get_display_name() if mode != null else "",
		"mode_description": mode.get_description() if mode != null else "",
		"status_lines": mode.get_status_lines() if mode != null else [],
		"metrics": metrics.to_dictionary() if metrics != null else {},
		"comparison": metrics.get_comparison_row() if metrics != null else {},
		"results": _session_results,
		"objective": str(fixture.get("objective", LabFixture.OBJECTIVE_TEXT)),
		"retreat_hint": LabFixture.RETREAT_ROUTE_HINT,
		"player_mode": _player_mode,
		"message": get_message(),
		"run_active": _run_active,
		"planning": mode.is_planning() if mode != null else false,
		"help_text": get_help_text(),
	})
