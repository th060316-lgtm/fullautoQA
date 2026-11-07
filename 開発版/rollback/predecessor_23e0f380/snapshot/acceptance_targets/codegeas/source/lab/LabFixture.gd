extends RefCounted
## LabFixture - Combat & Exploration Lab の決定論的固定条件 (Phase 0.5 Block 2)
##
## 契約 DOCS/02_COMBAT_LAB_CONTRACT.txt をそのまま実装する。
##   Play area : Rect2(0,0,1280,960)
##   Player    : (160,480) foot
##   Owned KMF : (240,480)
##   Enemy A   : infantry (720,360)  HP 40
##   Enemy B   : infantry (720,600)  HP 40
##   Enemy C   : light armor (900,480) HP 80
##   Enemy D   : enemy KMF (1080,480) aggregate HP 150
##   Extraction: (120,480)
##   Seed      : 20261021
##   weapon    : projectile speed 400 / foot damage 8 / KMF damage 25
##
## 3方式 (RT / Paused / WEGO) はすべてこの fixture を共有する。
## ここで値を変えない限り、方式だけの比較になる。
##
## ※ 契約に無い値 (敵の射撃威力など) は EXPERIMENTAL_VARIABLES に分離して記録する。
##   方式ごとの rebalance は禁止。3方式で同一値を使う。

const LAB_SEED: int = 20261021

const PLAY_AREA: Rect2 = Rect2(0.0, 0.0, 1280.0, 960.0)
const PLAYER_START: Vector2 = Vector2(160.0, 480.0)
const KMF_START: Vector2 = Vector2(240.0, 480.0)
const EXTRACTION_POINT: Vector2 = Vector2(120.0, 480.0)
const EXTRACTION_RADIUS: float = 28.0
const OBJECTIVE_TEXT: String = "目的: 生存して指定地点へ離脱する"
const RETREAT_ROUTE_HINT: String = "退避ルート: 西端の離脱点 (120,480) へ戻る"

## 遮蔽トポロジー (セル 32px)。3方式で同一。
## 開始地点・敵初期位置・離脱点と重ならない配置。
const COVER_RECTS: Array = [
	Rect2i(12, 8, 3, 2),
	Rect2i(10, 12, 2, 2),
	Rect2i(18, 13, 2, 3),
	Rect2i(24, 9, 2, 2),
	Rect2i(15, 20, 4, 2),
	Rect2i(26, 17, 3, 2),
]

## 敵定義。hp は互換用の集計HP。
const ENEMY_DEFS: Array = [
	{
		"id": "enemy_a", "type": "infantry", "display_name": "敵歩兵A",
		"position": Vector2(720.0, 360.0), "hp": 40.0, "kind": "human",
		"speed": 45.0, "detection_range": 260.0, "desired_range": 150.0,
		"weapon_damage": 6.0, "fire_interval": 1.4, "aim_error": 18.0,
		"projectile_speed": 320.0,
	},
	{
		"id": "enemy_b", "type": "infantry", "display_name": "敵歩兵B",
		"position": Vector2(720.0, 600.0), "hp": 40.0, "kind": "human",
		"speed": 45.0, "detection_range": 260.0, "desired_range": 150.0,
		"weapon_damage": 6.0, "fire_interval": 1.4, "aim_error": 18.0,
		"projectile_speed": 320.0,
	},
	{
		"id": "enemy_c", "type": "light_armor", "display_name": "敵軽装甲",
		"position": Vector2(900.0, 480.0), "hp": 80.0, "kind": "human",
		"speed": 38.0, "detection_range": 300.0, "desired_range": 190.0,
		"weapon_damage": 10.0, "fire_interval": 1.8, "aim_error": 14.0,
		"projectile_speed": 360.0,
	},
	{
		"id": "enemy_d", "type": "enemy_kmf", "display_name": "敵KMF",
		"position": Vector2(1080.0, 480.0), "hp": 150.0, "kind": "kmf",
		"speed": 55.0, "detection_range": 340.0, "desired_range": 230.0,
		"weapon_damage": 14.0, "fire_interval": 2.0, "aim_error": 10.0,
		"projectile_speed": 400.0,
	},
]

## 契約に無い追加値。3方式で同一 (方式差分にしない)。
## 記録目的: 後で Grok 案と比較時の差分特定用。
const EXPERIMENTAL_VARIABLES: Dictionary = {
	"enemy_weapon_damage": "歩兵6 / 軽装甲10 / 敵KMF14 (契約指定値ではない)",
	"enemy_fire_interval": "歩兵1.4s / 軽装甲1.8s / 敵KMF2.0s",
	"enemy_aim_error": "歩兵18px / 軽装甲14px / 敵KMF10px (発射時決定的)",
	"enemy_speed": "歩兵45 / 軽装甲38 / 敵KMF55 px/s",
	"extraction_radius": "28px (開始位置 160,480 との距離 40px より小さく、開始直後に離脱済みにしない)",
	"run_time_limit": "180s (超過でタイムアウト=失敗扱い)",
	"wego_turn_seconds": "1.0s (1ターン = 1秒分のシミュレーション)",
	"wego_actions_per_turn": "2 (1ターンあたりのコマンド上限)",
	"dodge_distance": "96px / 0.25s のダッシュ",
	"dodge_invulnerable": "0.20s",
}

## Open gameplay competition: Prototype E decision points.
## These are experimental map decisions layered on the same fixture; they do not alter Day1.
const DECISION_NODES: Array = [
	{
		"id": "north_cover",
		"label": "北側遮蔽路",
		"position": Vector2(500.0, 300.0),
		"time_cost": 18.0,
		"risk": 1,
		"fuel_cost": 0,
		"intel_delta": 1,
		"salvage_delta": 0,
		"summary": "時間18 / 危険1 / 情報+1",
	},
	{
		"id": "salvage",
		"label": "物資回収地点",
		"position": Vector2(640.0, 720.0),
		"time_cost": 28.0,
		"risk": 2,
		"fuel_cost": 0,
		"intel_delta": 0,
		"salvage_delta": 2,
		"summary": "時間28 / 危険2 / 回収+2",
	},
	{
		"id": "breach",
		"label": "中央突破",
		"position": Vector2(850.0, 480.0),
		"time_cost": 12.0,
		"risk": 3,
		"fuel_cost": 1,
		"intel_delta": 0,
		"salvage_delta": 0,
		"summary": "時間12 / 危険3 / KMFなら燃料1",
	},
	{
		"id": "scout",
		"label": "高所偵察",
		"position": Vector2(700.0, 220.0),
		"time_cost": 22.0,
		"risk": 1,
		"fuel_cost": 0,
		"intel_delta": 2,
		"salvage_delta": 0,
		"summary": "時間22 / 危険1 / 情報+2",
	},
	{
		"id": "extract",
		"label": "離脱",
		"position": EXTRACTION_POINT,
		"time_cost": 8.0,
		"risk": 0,
		"fuel_cost": 0,
		"intel_delta": 0,
		"salvage_delta": 0,
		"summary": "時間8 / 危険0 / 生存撤退",
	},
]

const RUN_TIME_LIMIT: float = 180.0

## fixture の生データ (deep copy) を返す。
static func build() -> Dictionary:
	return {
		"seed": LAB_SEED,
		"play_area": PLAY_AREA,
		"player_start": PLAYER_START,
		"kmf_start": KMF_START,
		"extraction_point": EXTRACTION_POINT,
		"extraction_radius": EXTRACTION_RADIUS,
		"cover_rects": COVER_RECTS.duplicate(true),
		"enemies": ENEMY_DEFS.duplicate(true),
		"objective": OBJECTIVE_TEXT,
		"time_limit": RUN_TIME_LIMIT,
	}

## セル矩形からワールド矩形へ変換する。
static func cell_to_world(cell: Rect2i, cell_size: int = 32) -> Rect2:
	return Rect2(
		Vector2(float(cell.position.x * cell_size), float(cell.position.y * cell_size)),
		Vector2(float(cell.size.x * cell_size), float(cell.size.y * cell_size))
	)

## 遮蔽矩形のワールド表現。
static func get_cover_world_rects(cell_size: int = 32) -> Array:
	var out: Array = []
	for cell in COVER_RECTS:
		out.append(cell_to_world(cell as Rect2i, cell_size))
	return out

## 円 (半径 r) を遮蔽矩形の外へ押し出す。
static func resolve_cover(position: Vector2, radius: float, cover_world: Array) -> Vector2:
	var out: Vector2 = position
	for item in cover_world:
		if not (item is Rect2):
			continue
		var rect: Rect2 = item
		var closest := Vector2(
			clampf(out.x, rect.position.x, rect.position.x + rect.size.x),
			clampf(out.y, rect.position.y, rect.position.y + rect.size.y)
		)
		var delta: Vector2 = out - closest
		if delta.length() < 0.0001:
			# 矩形の中心付近にいる場合は最短の辺方向へ押し出す
			var candidates: Array = [
				Vector2(rect.position.x - radius - out.x, 0.0),
				Vector2(rect.position.x + rect.size.x + radius - out.x, 0.0),
				Vector2(0.0, rect.position.y - radius - out.y),
				Vector2(0.0, rect.position.y + rect.size.y + radius - out.y),
			]
			var best: Vector2 = candidates[0]
			for c in candidates:
				if (c as Vector2).length() < best.length():
					best = c
			out += best
		elif delta.length() < radius:
			out = closest + delta.normalized() * radius
	return out

## 指定点がプレイ領域内か。
static func is_inside_play_area(point: Vector2) -> bool:
	return PLAY_AREA.has_point(point)

static func get_decision_nodes() -> Array:
	return DECISION_NODES.duplicate(true)

static func get_decision_node(node_id: String) -> Dictionary:
	for item in DECISION_NODES:
		if item is Dictionary and str((item as Dictionary).get("id", "")) == node_id:
			return (item as Dictionary).duplicate(true)
	return {}
