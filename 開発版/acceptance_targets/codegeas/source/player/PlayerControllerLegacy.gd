extends CharacterBody2D
## PlayerController - 徒歩/KMF移動制御
## modeに応じて速度・衝突・視界を切替

const FOOT_SPEED: float = 80.0
const KMF_SPEED: float = 160.0
const KMF_JUMP_SPEED: float = 280.0
const FOOT_VISION: float = 120.0
const KMF_VISION: float = 220.0

## Phase 0.5 Block 1: 入力抽象化とプレイ領域クランプ
const InputRouter = preload("res://core/InputRouter.gd")
const PlayAreaBounds = preload("res://core/PlayAreaBounds.gd")
## Player がsprite 分だけ境界の内側に留まるマージン (pixel)
const PLAY_AREA_MARGIN: float = 16.0
## 徒歩スプリント倍率 (Shift)
const FOOT_SPRINT_MULTIPLIER: float = 1.6

@onready var sprite: ColorRect = $Sprite
@onready var collision: CollisionShape2D = $CollisionShape2D
@onready var camera: Camera2D = $Camera2D

var _jump_cooldown: float = 0.0
var _fire_cooldown: float = 0.0

func _ready() -> void:
	add_to_group("player")
	_configure_camera_limits()
	_sync_from_state()
	EventBus.player_mode_changed.connect(_on_mode_changed)
	EventBus.load_completed.connect(func(_s): _sync_from_state())

func _sync_from_state() -> void:
	var pos = GameState.get_player_position()
	global_position = pos
	_update_visual()

func _physics_process(delta: float) -> void:
	if not GameState.is_player_alive():
		velocity = Vector2.ZERO
		return

	_jump_cooldown = maxf(0.0, _jump_cooldown - delta)
	_fire_cooldown = maxf(0.0, _fire_cooldown - delta)

	var mode = GameState.get_player_mode()
	var speed = KMF_SPEED if mode == "kmf" else FOOT_SPEED
	# Phase 0.5 Block 1: 徒歩/KMF の入力境界 (Shift=徒歩スプリント / KMFブースト)
	var sprinting: bool = mode == "foot" and InputRouter.is_pressed("sprint")
	if sprinting:
		speed *= FOOT_SPRINT_MULTIPLIER

	var input_dir = Vector2.ZERO
	if InputRouter.is_pressed("move_up"):
		input_dir.y -= 1
	if InputRouter.is_pressed("move_down"):
		input_dir.y += 1
	if InputRouter.is_pressed("move_left"):
		input_dir.x -= 1
	if InputRouter.is_pressed("move_right"):
		input_dir.x += 1

	if input_dir != Vector2.ZERO:
		input_dir = input_dir.normalized()
		# KMF短距離跳躍 (Shift相当: 連打防止でcooldown)
		if mode == "kmf" and InputRouter.is_pressed("sprint") and _jump_cooldown <= 0.0:
			if GameState.consume_kmf_energy(5.0):
				velocity = input_dir * KMF_JUMP_SPEED
				_jump_cooldown = 1.2
				GameState.add_fatigue(0.5)
			else:
				velocity = input_dir * speed
		else:
			velocity = input_dir * speed
			if mode == "kmf":
				GameState.consume_kmf_energy(delta * 2.0)  # 移動でエナジー消費
			GameState.add_fatigue(delta * ((0.6 if sprinting else 0.3) if mode == "foot" else 0.1))
	else:
		velocity = velocity.move_toward(Vector2.ZERO, speed * 4.0 * delta)

	move_and_slide()
	# Phase 0.5 Block 1: プレイ領域外への逸脱を禁止する。
	# (Camera limit だけでは Camera が止まるだけで Player だけ画面外へ出るため)
	global_position = PlayAreaBounds.clamp_point(global_position, _get_play_area_bounds(), PLAY_AREA_MARGIN)
	GameState.set_player_position(global_position)
	_update_camera_aim()

	# 搭乗/降機
	if Input.is_action_just_pressed("board_kmf"):
		_try_board_or_disembark()

	# 射撃 (Space=fire は従来どおり / 左クリック=primary_attack は追加)
	if (InputRouter.is_just_pressed("fire") or InputRouter.is_just_pressed("primary_attack")) and _fire_cooldown <= 0.0:
		_try_fire()

func _try_board_or_disembark() -> void:
	var mode = GameState.get_player_mode()
	var kmf = GameState.get_section("kmf")
	if mode == "foot":
		# 近傍にKMFがあるか
		var kmf_pos = Vector2(float(kmf.get("position", {}).get("x", 0)), float(kmf.get("position", {}).get("y", 0)))
		if global_position.distance_to(kmf_pos) < 48.0:
			if kmf.get("owned", false) and float(kmf.get("durability", 0)) > 0:
				GameState.set_player_mode("kmf")
				global_position = kmf_pos
				_update_visual()
				_record_day1_action("kmf_board", {"mode": "kmf", "noise": 4.0, "visible": true})
				EventBus.player_notice.emit("KMFに搭乗しました")
			else:
				EventBus.player_notice.emit("このKMFには搭乗できません")
		else:
			EventBus.player_notice.emit("KMFへ近づいてEで搭乗")
	else:
		GameState.set_player_mode("foot")
		_update_visual()
		EventBus.player_notice.emit("KMFから降りました")

func _try_fire() -> void:
	var mode = GameState.get_player_mode()
	if mode == "kmf":
		if GameState.consume_kmf_ammo(1):
			_spawn_projectile(true)
			_record_day1_action("kmf_fire", {"mode": "kmf", "noise": 18.0, "visible": true})
			_fire_cooldown = 0.25
			GameState.add_fatigue(0.2)
		else:
			EventBus.player_notice.emit("弾薬がありません")
	else:
		# 徒歩簡易射撃（制限あり）
		_spawn_projectile(false)
		_fire_cooldown = 0.8
		GameState.add_fatigue(1.0)

func _spawn_projectile(is_kmf: bool) -> void:
	# 簡易弾: 実際のCombatManagerに委譲
	var combat = get_tree().get_first_node_in_group("combat_manager")
	if combat and combat.has_method("spawn_player_shot"):
		combat.spawn_player_shot(global_position, is_kmf)

func _on_mode_changed(mode: String) -> void:
	_update_visual()
	# 衝突レイヤ調整
	if mode == "kmf":
		collision_layer = 8  # kmf layer
		collision_mask = 2 | 4  # obstacle + enemy
	else:
		collision_layer = 1
		collision_mask = 2 | 4

func _update_visual() -> void:
	var mode = GameState.get_player_mode()
	if mode == "kmf":
		sprite.color = Color(0.2, 0.6, 0.9)
		sprite.size = Vector2(28, 28)
		sprite.position = Vector2(-14, -14)
		if collision.shape is RectangleShape2D:
			(collision.shape as RectangleShape2D).size = Vector2(28, 28)
	else:
		sprite.color = Color(0.3, 0.9, 0.4)
		sprite.size = Vector2(16, 16)
		sprite.position = Vector2(-8, -8)
		if collision.shape is RectangleShape2D:
			(collision.shape as RectangleShape2D).size = Vector2(16, 16)

func get_vision_radius() -> float:
	return KMF_VISION if GameState.get_player_mode() == "kmf" else FOOT_VISION

func _configure_camera_limits() -> void:
	var map_manager := get_parent().get_node_or_null("MapManager")
	# Phase 0.5 Block 1: CameraManager があればそちらが正本 (同一値)。
	var manager := get_node_or_null("CameraManager")
	if manager != null and manager.has_method("set_play_area"):
		manager.set_play_area(PlayAreaBounds.resolve_bounds(map_manager))
		return
	var map_width := 40 * 32
	var map_height := 30 * 32
	if map_manager and map_manager.has_method("get_map_bounds"):
		var bounds: Rect2 = map_manager.get_map_bounds()
		camera.limit_left = int(bounds.position.x)
		camera.limit_top = int(bounds.position.y)
		camera.limit_right = int(bounds.end.x)
		camera.limit_bottom = int(bounds.end.y)
	else:
		camera.limit_left = 0
		camera.limit_top = 0
		camera.limit_right = map_width
		camera.limit_bottom = map_height
	camera.limit_smoothed = true


## プレイ領域 (MapManager の境界、無ければ既定値)。
func _get_play_area_bounds() -> Rect2:
	var map_manager: Node = null
	if get_parent() != null:
		map_manager = get_parent().get_node_or_null("MapManager")
	return PlayAreaBounds.resolve_bounds(map_manager)

## カメラへ照準方向を渡す (Look-ahead / 戦闘フレーミング用)。
func _update_camera_aim() -> void:
	var manager := get_node_or_null("CameraManager")
	if manager == null or not is_instance_valid(manager):
		return
	if not manager.has_method("set_aim_direction"):
		return
	var aim: Vector2 = get_global_mouse_position() - global_position
	if aim.length() > 1.0:
		manager.set_aim_direction(aim.normalized())

func _record_day1_action(action_type: String, payload: Dictionary) -> void:
	var root = get_tree().root if get_tree() else null
	if root == null:
		return
	var d1 = root.find_child("Day1Controller", true, false)
	if d1 and d1.has_method("record_action") and d1.has_method("is_initialized") and d1.is_initialized():
		d1.record_action(action_type, payload)

