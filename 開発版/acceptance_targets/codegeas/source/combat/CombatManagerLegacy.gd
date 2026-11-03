extends Node2D
## CombatManager - 簡易リアルタイム戦闘
## 徒歩/KMF射撃、敵歩兵/軽装甲/KMF少数
## 護衛男性は実装しない（倒せる通常敵にしない）

const PROJECTILE_SPEED: float = 400.0
const FOOT_DAMAGE: float = 8.0
const KMF_DAMAGE: float = 25.0
const FIRST_PLAY_GRACE_SECONDS: float = 90.0
const ENEMY_KMF_ACTIVE_MINUTE: int = 9 * 60 + 30
const ENEMY_KMF_AGGRO_RANGE: float = 230.0
const OTHER_ENEMY_AGGRO_RANGE: float = 155.0
var _real_play_seconds: float = 0.0

var _projectiles: Array = []
var _enemies: Array = []

func _ready() -> void:
	add_to_group("combat_manager")
	_spawn_test_enemies()

func _spawn_test_enemies() -> void:
	# テスト用簡易敵
	_create_enemy(Vector2(400, 300), "infantry", 40.0, Color(0.8, 0.2, 0.2))
	_create_enemy(Vector2(500, 250), "infantry", 40.0, Color(0.8, 0.2, 0.2))
	_create_enemy(Vector2(600, 400), "light_armor", 80.0, Color(0.7, 0.4, 0.1))
	_create_enemy(Vector2(1070, 340), "enemy_kmf", 150.0, Color(0.6, 0.1, 0.6))

func _create_enemy(pos: Vector2, type: String, hp: float, color: Color) -> void:
	var enemy = CharacterBody2D.new()
	enemy.position = pos
	enemy.collision_layer = 4
	enemy.collision_mask = 1 | 8 | 2
	var shape = CollisionShape2D.new()
	var rect = RectangleShape2D.new()
	rect.size = Vector2(20, 20) if type != "enemy_kmf" else Vector2(28, 28)
	shape.shape = rect
	enemy.add_child(shape)
	var spr = ColorRect.new()
	spr.size = rect.size
	spr.position = -rect.size / 2
	spr.color = color
	enemy.add_child(spr)
	enemy.set_meta("spawn_position", pos)
	enemy.set_meta("hp", hp)
	enemy.set_meta("max_hp", hp)
	enemy.set_meta("type", type)
	enemy.set_meta("speed", 40.0 if type == "infantry" else (30.0 if type == "light_armor" else 90.0))
	add_child(enemy)
	_enemies.append(enemy)

func spawn_player_shot(origin: Vector2, is_kmf: bool) -> void:
	var mouse = get_global_mouse_position()
	var dir = (mouse - origin).normalized()
	if dir == Vector2.ZERO:
		dir = Vector2.RIGHT
	var proj = {
		"pos": origin,
		"dir": dir,
		"speed": PROJECTILE_SPEED * (1.3 if is_kmf else 1.0),
		"damage": KMF_DAMAGE if is_kmf else FOOT_DAMAGE,
		"is_player": true,
		"life": 1.5,
		"node": null,
	}
	var node = ColorRect.new()
	node.size = Vector2(6, 6) if not is_kmf else Vector2(10, 10)
	node.color = Color(1, 1, 0.3) if is_kmf else Color(1, 0.8, 0.2)
	node.position = origin - node.size / 2
	add_child(node)
	proj["node"] = node
	_projectiles.append(proj)

func _process(delta: float) -> void:
	_real_play_seconds += delta
	_update_projectiles(delta)
	_update_enemies(delta)

func _update_projectiles(delta: float) -> void:
	var to_remove: Array = []
	for i in range(_projectiles.size()):
		var p = _projectiles[i]
		p["life"] -= delta
		p["pos"] += p["dir"] * p["speed"] * delta
		if p["node"]:
			p["node"].position = p["pos"] - p["node"].size / 2
		if p["life"] <= 0:
			to_remove.append(i)
			continue
		# 衝突判定
		if p["is_player"]:
			for enemy in _enemies.duplicate():
				if not is_instance_valid(enemy):
					continue
				if p["pos"].distance_to(enemy.global_position) < 18.0:
					var hp = float(enemy.get_meta("hp")) - float(p["damage"])
					enemy.set_meta("hp", hp)
					to_remove.append(i)
					if hp <= 0:
						enemy.queue_free()
						_enemies.erase(enemy)
						EventBus.player_notice.emit("敵を撃破しました")
					break
	# 後ろから削除
	to_remove.sort()
	to_remove.reverse()
	for idx in to_remove:
		if _projectiles[idx]["node"]:
			_projectiles[idx]["node"].queue_free()
		_projectiles.remove_at(idx)

func _update_enemies(delta: float) -> void:
	var player = get_tree().get_first_node_in_group("player")
	if player == null or not GameState.is_player_alive():
		return
	var ppos = player.global_position
	for enemy in _enemies:
		if not is_instance_valid(enemy):
			continue
		var type = str(enemy.get_meta("type"))
		var speed = float(enemy.get_meta("speed"))
		var origin: Vector2 = enemy.get_meta("spawn_position", enemy.global_position)
		var aggro_range: float = ENEMY_KMF_AGGRO_RANGE if type == "enemy_kmf" else OTHER_ENEMY_AGGRO_RANGE
		var kmf_too_early: bool = type == "enemy_kmf" and GameState.get_day() == 1 and GameState.get_minute_of_day() < ENEMY_KMF_ACTIVE_MINUTE
		# Give players time to read. Pursuit stays local; time-skipping cannot bypass the real-time grace period.
		if _real_play_seconds < FIRST_PLAY_GRACE_SECONDS or kmf_too_early or ppos.distance_to(origin) > aggro_range or enemy.global_position.distance_to(ppos) > aggro_range:
			enemy.velocity = Vector2.ZERO
			continue
		var dir = (ppos - enemy.global_position).normalized()
		# 簡易AI: 近づく
		enemy.velocity = dir * speed
		enemy.move_and_slide()
		# 近接ダメージ
		if enemy.global_position.distance_to(ppos) < 24.0:
			var dmg = 5.0 if type == "infantry" else (12.0 if type == "light_armor" else 20.0)
			GameState.damage_player(dmg * delta)
			if GameState.get_player_mode() == "kmf":
				GameState.damage_kmf(dmg * delta * 0.5)

func get_enemy_count() -> int:
	return _enemies.size()

func spawn_reinforcement(pos: Vector2) -> void:
	_create_enemy(pos, "infantry", 40.0, Color(1.0, 0.25, 0.1))

