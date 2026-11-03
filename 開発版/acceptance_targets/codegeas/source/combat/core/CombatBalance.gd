extends RefCounted
## CombatBalance - 戦闘 balancer の単一情報源 (Phase 0.5 Block 4)
##
## 既存 main の値を 正規値 として固定する。
##  contract 02_COMBAT_LAB_CONTRACT.txt:
##    projectile speed 400 / foot damage 8 / KMF damage 25
##  「方式ごとに rebalance して片方看起来よく見せる」ことを禁じている。
##  方式差分は CombatMode 側の「時間・判断頻度」だけに集約し、ダメージ値は全方式で同一。
##
## 既存スクリプトとの一致は
##   game/tests/combat_core_acceptance.gd
## が preoload して検証する (CombatManagerLegacy / PlayerControllerLegacy と実数値一致を assert)。

## --- 弾 / ダメージ (CombatManagerLegacy と同値) ---
const PROJECTILE_SPEED: float = 400.0
const FOOT_DAMAGE: float = 8.0
const KMF_DAMAGE: float = 25.0

## --- 移動 (PlayerControllerLegacy と同値) ---
const FOOT_SPEED: float = 80.0
const KMF_SPEED: float = 160.0
const KMF_BOOST_SPEED: float = 280.0
const FOOT_SPRINT_MULTIPLIER: float = 1.6

## --- 射撃間隔 (PlayerControllerLegacy と同値) ---
const FOOT_FIRE_COOLDOWN: float = 0.8
const KMF_FIRE_COOLDOWN: float = 0.25

## --- 視界 / 搭乗 (PlayerControllerLegacy / PlayerController と同値) ---
const FOOT_VISION: float = 120.0
const KMF_VISION: float = 220.0
const BOARD_RANGE: float = 48.0

## --- プレイヤー ---
const PLAYER_MAX_HP: float = 100.0

## --- KMF ---
const KMF_MAX_HP: float = 100.0
const KMF_MAX_ENERGY: float = 100.0
const KMF_MAX_AMMO: int = 30
const KMF_MOVE_ENERGY_PER_SEC: float = 2.0
const KMF_BOOST_ENERGY_COST: float = 5.0
const KMF_BOOST_COOLDOWN: float = 1.2

## --- 弾の寿命 (Lab 共通) ---
const PROJECTILE_LIFE: float = 1.5

## --- 部位サイズ (選択判定の正規化用) ---
const HUMAN_BODY_SIZE: Vector2 = Vector2(24.0, 40.0)
const KMF_BODY_SIZE: Vector2 = Vector2(56.0, 64.0)

## Human / KMF の部位 --> 正規化矩形 (0..1, 原点=左上, y は下向き)
const PART_HITBOXES: Dictionary = {
	"human": {
		"head": Rect2(0.35, 0.00, 0.30, 0.22),
		"torso": Rect2(0.20, 0.22, 0.60, 0.40),
		"right_arm": Rect2(0.00, 0.22, 0.20, 0.40),
		"left_arm": Rect2(0.80, 0.22, 0.20, 0.40),
		"right_leg": Rect2(0.22, 0.62, 0.28, 0.38),
		"left_leg": Rect2(0.50, 0.62, 0.28, 0.38),
	},
	"kmf": {
		"cockpit": Rect2(0.32, 0.00, 0.36, 0.22),
		"sensor": Rect2(0.05, 0.04, 0.22, 0.18),
		"weapon": Rect2(0.78, 0.30, 0.22, 0.22),
		"frame": Rect2(0.20, 0.22, 0.60, 0.50),
		"right_arm": Rect2(0.00, 0.26, 0.20, 0.42),
		"left_arm": Rect2(0.80, 0.26, 0.20, 0.42),
		"right_leg": Rect2(0.20, 0.72, 0.28, 0.28),
		"left_leg": Rect2(0.52, 0.72, 0.28, 0.28),
		"energy": Rect2(0.40, 0.52, 0.20, 0.20),
	},
}

## 生命部位 (KMF はコックピット即死 -> 鹵獲可能性が高い)
const VITAL_PRIORITY: Dictionary = {
	"human": ["head", "torso"],
	"kmf": ["cockpit", "frame"],
}

## 部位の重要度 (狙う優先順位の補助)
const PART_PRIORITY: Dictionary = {
	"human": {"head": 100, "torso": 80, "left_leg": 40, "right_leg": 40, "left_arm": 25, "right_arm": 25},
	"kmf": {"cockpit": 120, "sensor": 70, "weapon": 60, "energy": 45, "frame": 90, "left_leg": 50, "right_leg": 50, "left_arm": 35, "right_arm": 35},
}

static func get_body_size(kind: String) -> Vector2:
	return KMF_BODY_SIZE if kind == "kmf" else HUMAN_BODY_SIZE
