extends Node2D
## CameraManager - カメラ政策の独立化 (Phase 0.5 Block 1)
##
## 開発計画の要求:
##   "CameraManagerをPlayerControllerから独立させる。徒歩とKMFの双方に対して、
##    追尾、Look-ahead、Zoom、Smooth、Transition、戦闘時の画面構成を統一管理する。"
##
## 本ノードは Player の子として配置され、既存の Camera2D を駆動する。
## Camera2D ノード自体は Main.tscn のまま (パス互換を保つ)。
##
## 責務:
##   1. 追従 (親=Player なので基準点は常に Player)
##   2. Look-ahead (Aim 方向へ僅かに先行)
##   3. Zoom (徒歩 / KMF / 照準focus)
##   4. プレイ領域クランプ (Player 座標を領域内へ留める)
##   5. HUD Safe Area 回避 (Player / 重要敵が HUD の裏へ隠れない構図)
##   6. 戦闘フレーミング (交戦中の敵を視界に保つ)
##
## 既存 public method / signal は削除・改名しない。

const CameraRouter = preload("res://core/PlayAreaBounds.gd")
const InputRouter = preload("res://core/InputRouter.gd")

## ズーム設定
const ZOOM_FOOT: float = 1.0
const ZOOM_KMF: float = 0.85
const ZOOM_FOCUS: float = 1.15
const ZOOM_LERP_SPEED: float = 6.0

## Look-ahead
const LOOK_AHEAD_FOOT: float = 48.0
const LOOK_AHEAD_KMF: float = 72.0
const LOOK_AHEAD_LERP_SPEED: float = 5.0

## 戦闘フレーミング
const COMBAT_FOCUS_WEIGHT: float = 0.35
const COMBAT_MAX_OFFSET: float = 220.0

## HUD 回避
const HUD_MARGIN: float = 8.0

var camera: Camera2D = null
var target: Node2D = null

var _bounds: Rect2 = Rect2()
var _zoom: float = ZOOM_FOOT
var _zoom_target: float = ZOOM_FOOT
var _look_ahead: Vector2 = Vector2.ZERO
var _look_ahead_target: Vector2 = Vector2.ZERO
var _aim_direction: Vector2 = Vector2.ZERO
var _focus_target: Node2D = null
var _hud: Node = null
var _map_manager: Node = null
var _combat_manager: Node = null
var _player_occluded: bool = false
var _initialised: bool = false

func _ready() -> void:
	# 追加の論理アクション (primary_attack / aim / sprint / hud_toggle ...) を
	# runtime で InputMap へ登録しておく (project.godot は変更しない)。
	InputRouter.ensure_actions_registered()
	# Camera2D は Player の子。PlayerControllerLegacy と同一ノードを参照する。
	var parent := get_parent()
	if parent != null:
		camera = parent.get_node_or_null("Camera2D") as Camera2D
		target = parent as Node2D
		_map_manager = parent.get_parent().get_node_or_null("MapManager") if parent.get_parent() != null else null
	_zoom = ZOOM_FOOT
	_zoom_target = ZOOM_FOOT
	_refresh_bounds()
	_apply_camera_limits()
	_initialised = true
	set_process(true)

## 外部から初期化する (Main.gd から明示的に呼ばせる場合のフック)。
## 引数は Node で受け取る (呼び出し側が get_node_or_null() の戻り値をそのまま渡せるように)。
func setup(player: Node, cam: Node, map_manager: Node = null) -> void:
	if player is Node2D:
		target = player as Node2D
	if cam is Camera2D:
		camera = cam as Camera2D
	_map_manager = map_manager
	_refresh_bounds()
	_apply_camera_limits()
	_initialised = true

## HUD は Safe Area 情報の提供元。任意 (無ければ HUD 回避はしない)。
func set_hud(hud: Node) -> void:
	_hud = hud

## 交戦中の重要ターゲット (敵KMF / 軽装甲など) を視界に保つ。
func set_focus_target(node: Node2D) -> void:
	_focus_target = node

## 照準方向 (Look-ahead および 戦闘フレーミングに使用)。
func set_aim_direction(dir: Vector2) -> void:
	if dir.length_squared() > 0.0001:
		_aim_direction = dir.normalized()
	else:
		_aim_direction = Vector2.ZERO

## プレイ領域 (地図境界)。
func get_play_area() -> Rect2:
	return _bounds

func set_play_area(bounds: Rect2) -> void:
	_bounds = bounds
	_apply_camera_limits()

func _refresh_bounds() -> void:
	_bounds = CameraRouter.resolve_bounds(_map_manager)

## Camera2D の limit をプレイ領域に合わせる。
## (PlayerControllerLegacy._configure_camera_limits と同じ値になるが、正本はこのノード側)
func _apply_camera_limits() -> void:
	if camera == null or not is_instance_valid(camera):
		return
	if _bounds.size.x <= 0.0 or _bounds.size.y <= 0.0:
		_bounds = CameraRouter.get_default_bounds()
	camera.limit_left = int(_bounds.position.x)
	camera.limit_top = int(_bounds.position.y)
	camera.limit_right = int(_bounds.position.x + _bounds.size.x)
	camera.limit_bottom = int(_bounds.position.y + _bounds.size.y)
	# Player/KMF の可視性を最優先する。Camera2D の内蔵位置 smoothing は
	# テレポート/Load/KMF高速移動時にカメラだけ遅れて Player を画面外へ出すため使わない。
	# Look-ahead と zoom の補間は CameraManager 側で継続する。
	camera.position_smoothing_enabled = false
	camera.limit_smoothed = false

func _process(delta: float) -> void:
	if not _initialised or camera == null or not is_instance_valid(camera):
		return
	if target == null or not is_instance_valid(target):
		return
	_update_zoom(delta)
	_update_look_ahead(delta)
	_update_focus_target()
	_update_camera_position(delta)

func _update_zoom(delta: float) -> void:
	var mode: String = _get_player_mode()
	var base_zoom: float = ZOOM_KMF if mode == "kmf" else ZOOM_FOOT
	_zoom_target = base_zoom
	if _is_focus_held():
		_zoom_target = ZOOM_FOCUS if mode == "foot" else (ZOOM_FOCUS * 0.92)
	_zoom = lerpf(_zoom, _zoom_target, clampf(ZOOM_LERP_SPEED * delta, 0.0, 1.0))
	camera.zoom = Vector2(_zoom, _zoom)

func _is_focus_held() -> bool:
	return bool(InputRouter.is_pressed("aim"))

func _update_look_ahead(delta: float) -> void:
	var mode: String = _get_player_mode()
	var distance: float = LOOK_AHEAD_KMF if mode == "kmf" else LOOK_AHEAD_FOOT
	_look_ahead_target = _aim_direction * distance
	_look_ahead = _look_ahead.lerp(_look_ahead_target, clampf(LOOK_AHEAD_LERP_SPEED * delta, 0.0, 1.0))

func _update_focus_target() -> void:
	if _combat_manager == null or not is_instance_valid(_combat_manager):
		if get_tree() != null:
			_combat_manager = get_tree().get_first_node_in_group("combat_manager")
	if _combat_manager == null or not is_instance_valid(_combat_manager):
		return
	if _combat_manager.has_method("get_focus_target"):
		var node: Variant = _combat_manager.call("get_focus_target")
		if node is Node2D and is_instance_valid(node):
			_focus_target = node
			return
	_focus_target = null

func _update_camera_position(delta: float) -> void:
	var view_size: Vector2 = _get_viewport_size()
	var player_world: Vector2 = target.global_position

	# 1) 基本注視点 = Player + Look-ahead
	var desired: Vector2 = player_world + _look_ahead

	# 2) 戦闘フレーミング: 交戦ターゲットを視界内へ寄せる
	if _focus_target != null and is_instance_valid(_focus_target):
		var to_target: Vector2 = _focus_target.global_position - player_world
		if to_target.length() > COMBAT_MAX_OFFSET:
			to_target = to_target.normalized() * COMBAT_MAX_OFFSET
		desired = desired + to_target * COMBAT_FOCUS_WEIGHT

	# 3) プレイ領域クランプ (ビューが領域内に収まる位置)
	desired = CameraRouter.clamp_camera_target(desired, _bounds, view_size / maxf(_zoom, 0.01))

	# 4) HUD Safe Area 回避
	var push: Vector2 = _compute_hud_push(desired, view_size)
	if push != Vector2.ZERO:
		desired += push
		desired = CameraRouter.clamp_camera_target(desired, _bounds, view_size / maxf(_zoom, 0.01))

	# 5) 適用 (Camera2D は Player の子なので、ローカル位置で相対量を指定する)
	camera.position = desired - player_world
	_update_occlusion_alert()

## HUD 矩形が覆っている領域から Player を押し出すベクトルを返す (world 単位)。
func _compute_hud_push(desired: Vector2, view_size: Vector2) -> Vector2:
	if _hud == null or not is_instance_valid(_hud):
		return Vector2.ZERO
	if not _hud.has_method("get_hud_occlusion_rects"):
		return Vector2.ZERO
	var rects: Variant = _hud.call("get_hud_occlusion_rects")
	if not (rects is Array):
		return Vector2.ZERO
	var push: Vector2 = Vector2.ZERO
	var player_world: Vector2 = target.global_position
	var center: Vector2 = desired
	var zoom: float = maxf(_zoom, 0.01)
	for item in (rects as Array):
		if not (item is Rect2):
			continue
		var rect: Rect2 = item
		var screen_pos: Vector2 = (player_world - center) * zoom + view_size * 0.5
		var grown: Rect2 = rect.grow(HUD_MARGIN)
		if not grown.has_point(screen_pos):
			continue
		# 最近傍の辺へ最短距離で逃がす
		var left: float = screen_pos.x - grown.position.x
		var right: float = grown.position.x + grown.size.x - screen_pos.x
		var top: float = screen_pos.y - grown.position.y
		var bottom: float = grown.position.y + grown.size.y - screen_pos.y
		var best: float = left
		var offset: Vector2 = Vector2(-left, 0.0)
		if right < best:
			best = right
			offset = Vector2(right, 0.0)
		if top < best:
			best = top
			offset = Vector2(0.0, -top)
		if bottom < best:
			best = bottom
			offset = Vector2(0.0, bottom)
		push -= offset / zoom
	return push

func _update_occlusion_alert() -> void:
	if _hud == null or not is_instance_valid(_hud):
		return
	if not _hud.has_method("set_occlusion_alert"):
		return
	var occluded: bool = is_target_occluded()
	if occluded != _player_occluded:
		_player_occluded = occluded
		_hud.call("set_occlusion_alert", occluded)

## 現在のカメラ位置で、Player が HUD 矩形に隠れているか。
func is_target_occluded() -> bool:
	if _hud == null or not is_instance_valid(_hud):
		return false
	if not _hud.has_method("get_hud_occlusion_rects"):
		return false
	var rects: Variant = _hud.call("get_hud_occlusion_rects")
	if not (rects is Array):
		return false
	var view_size: Vector2 = _get_viewport_size()
	var center: Vector2 = camera.get_screen_center_position() if camera != null else Vector2.ZERO
	var zoom: float = maxf(_zoom, 0.01)
	var screen_pos: Vector2 = (target.global_position - center) * zoom + view_size * 0.5
	for item in (rects as Array):
		if item is Rect2 and (item as Rect2).has_point(screen_pos):
			return true
	return false

## 重要な対象 (Player / KMF / 交戦ターゲット) が HUD の裏へ隠れていないか。
## 自動回帰と Lab 側からの利用を想定した公開クエリ。
func is_world_point_visible(world_pos: Vector2) -> bool:
	if camera == null or not is_instance_valid(camera):
		return false
	var view_size: Vector2 = _get_viewport_size()
	var center: Vector2 = camera.get_screen_center_position()
	var zoom: float = maxf(_zoom, 0.01)
	var screen_pos: Vector2 = (world_pos - center) * zoom + view_size * 0.5
	if screen_pos.x < 0.0 or screen_pos.y < 0.0 or screen_pos.x > view_size.x or screen_pos.y > view_size.y:
		return false
	if _hud == null or not is_instance_valid(_hud):
		return true
	if not _hud.has_method("get_hud_occlusion_rects"):
		return true
	var rects: Variant = _hud.call("get_hud_occlusion_rects")
	if not (rects is Array):
		return true
	for item in (rects as Array):
		if item is Rect2 and (item as Rect2).has_point(screen_pos):
			return false
	return true

## HUD を避けた「安全表示領域」(pixel)。
func get_safe_viewport_rect() -> Rect2:
	var view_size: Vector2 = _get_viewport_size()
	var safe: Rect2 = Rect2(Vector2.ZERO, view_size)
	if _hud == null or not is_instance_valid(_hud):
		return safe
	if not _hud.has_method("get_hud_occlusion_rects"):
		return safe
	var rects: Variant = _hud.call("get_hud_occlusion_rects")
	if not (rects is Array):
		return safe
	var edge_tolerance: float = 12.0
	for item in (rects as Array):
		if not (item is Rect2):
			continue
		var rect: Rect2 = item
		# 画面端に接している HUD 領域だけを食い込みとして扱う。
		if rect.position.x <= edge_tolerance:
			safe.position.x = maxf(safe.position.x, rect.position.x + rect.size.x)
			safe.size.x = minf(safe.size.x, view_size.x - safe.position.x)
		if rect.position.x + rect.size.x >= view_size.x - edge_tolerance:
			safe.size.x = minf(safe.size.x, rect.position.x)
		if rect.position.y <= edge_tolerance:
			safe.position.y = maxf(safe.position.y, rect.position.y + rect.size.y)
			safe.size.y = minf(safe.size.y, view_size.y - safe.position.y)
		if rect.position.y + rect.size.y >= view_size.y - edge_tolerance:
			safe.size.y = minf(safe.size.y, rect.position.y)
	if safe.size.x <= 0.0 or safe.size.y <= 0.0:
		return Rect2(Vector2.ZERO, view_size)
	return safe

## GameState は autoload。存在しないシーンでも安全に評価する。
func _get_player_mode() -> String:
	var gs := get_node_or_null("/root/GameState")
	if gs == null:
		return "foot"
	return str(gs.get_player_mode())

func _get_viewport_size() -> Vector2:
	var viewport := get_viewport()
	if viewport == null:
		return Vector2(1280.0, 720.0)
	return Vector2(viewport.get_visible_rect().size)
