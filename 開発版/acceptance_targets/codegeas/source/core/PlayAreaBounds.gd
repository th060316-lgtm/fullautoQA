extends RefCounted
## PlayAreaBounds - プレイ可能領域の単一情報源 (Phase 0.5 Block 1)
##
## 既存の Main.tscn は 40x30 セル x 32px = 1280x960 地図と Camera2D の limit のみで
## 構成されていた。Camera limit は「カメラを止まる」だけで、Player/KMF の座標そのものは
## 地図外へ移動できてしまい、Camera 停止 → Player 画面外消失 の原因になっていた。
##
## 本クラスは以下を1箇所に集約する。
##   - プレイ領域矩形の解決 (MapManager があればその境界を優先、無ければ既定値)
##   - 座標クランプ (半径マージン付き)
##   - カメラ注視点のクランプ
##
## 状態を持たないためどこからでも静的に呼べる。GameState を触らない。

const DEFAULT_WIDTH: int = 1280
const DEFAULT_HEIGHT: int = 960
const DEFAULT_CELL_SIZE: int = 32
const DEFAULT_MARGIN: float = 16.0

## 基準マップは 40x30 セル x 32px (Main.tscn / MapManagerLegacy と同一)。
static func get_default_bounds() -> Rect2:
	return Rect2(Vector2.ZERO, Vector2(float(DEFAULT_WIDTH), float(DEFAULT_HEIGHT)))

## MapManager が持つ正規マップ境界があればそれを、無ければ既定値を返す。
## map_manager: Node or null (duck typed: get_map_bounds())
## (原文の日本語コメント: 地図境界は MapManager が正典)
static func resolve_bounds(map_manager: Node = null) -> Rect2:
	if map_manager != null and is_instance_valid(map_manager):
		if map_manager.has_method("get_map_bounds"):
			var bounds: Variant = map_manager.call("get_map_bounds")
			if bounds is Rect2:
				var rect: Rect2 = bounds
				if rect.size.x > 0.0 and rect.size.y > 0.0:
					return rect
	return get_default_bounds()

## 中心座標 p を bounds 内に収める。margin は「sprite が境界外へはみ出さない」分。
static func clamp_point(p: Vector2, bounds: Rect2, margin: float = DEFAULT_MARGIN) -> Vector2:
	var half_w: float = bounds.size.x * 0.5
	var half_h: float = bounds.size.y * 0.5
	if half_w <= margin or half_h <= margin:
		# 領域がマージンより小さい場合は中心へ寄せる
		return bounds.position + bounds.size * 0.5
	var min_x: float = bounds.position.x + margin
	var max_x: float = bounds.position.x + bounds.size.x - margin
	var min_y: float = bounds.position.y + margin
	var max_y: float = bounds.position.y + bounds.size.y - margin
	return Vector2(
		clampf(p.x, min_x, max_x),
		clampf(p.y, min_y, max_y)
	)

## bounds の外側なら true (境界上は内側扱い)
static func is_inside(p: Vector2, bounds: Rect2, margin: float = 0.0) -> bool:
	return (
		p.x >= bounds.position.x + margin
		and p.x <= bounds.position.x + bounds.size.x - margin
		and p.y >= bounds.position.y + margin
		and p.y <= bounds.position.y + bounds.size.y - margin
	)

## カメラ注視点をマップ内に収める。ビューが領域より大きい場合は中央寄せ。
## view_size はカメラビューのピクセルサイズ。
static func clamp_camera_target(target: Vector2, bounds: Rect2, view_size: Vector2) -> Vector2:
	var half: Vector2 = view_size * 0.5
	var out: Vector2 = target
	if bounds.size.x > view_size.x:
		out.x = clampf(out.x, bounds.position.x + half.x, bounds.position.x + bounds.size.x - half.x)
	else:
		out.x = bounds.position.x + bounds.size.x * 0.5
	if bounds.size.y > view_size.y:
		out.y = clampf(out.y, bounds.position.y + half.y, bounds.position.y + bounds.size.y - half.y)
	else:
		out.y = bounds.position.y + bounds.size.y * 0.5
	return out
