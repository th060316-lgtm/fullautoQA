class_name TransportModeConfig
extends RefCounted

## MiniMax: 輸送モード別パラメータ定義 (Logic Prototype 用)
##
## モード番号は SHARED_INTEGRATION_CONTRACT.md に厳密に従う:
##   0 = ROAD, 1 = RAIL, 2 = SHIP, 3 = AIR
##
## 差分設計:
##   ROAD  小容量 / 低速 / 低額     (Grok 管轄)
##   RAIL  中容量 / 中速 / 高額     (Grok 管轄)
##   SHIP  大容量 / 低速 / 中額     (MiniMax 管轄: 遠距離・大物)
##   AIR   低〜中容量 / 最高速 / 高額 (MiniMax 管轄: 高速・高単価)

enum Mode { ROAD = 0, RAIL = 1, SHIP = 2, AIR = 3 }

# Cargo kinds (0 = passenger, 1 = food, 2 = fuel)
enum Cargo { PASSENGER = 0, FOOD = 1, FUEL = 2 }

const MODE_NAME := {0: "道路", 1: "鉄道", 2: "船舶", 3: "航空"}
const MODE_NAME_EN := {0: "ROAD", 1: "RAIL", 2: "SHIP", 3: "AIR"}

const GROUND_MODES := [0, 1]
const SEA_MODES := [2]
const AIR_MODES := [3]

# 1日あたり輸送可能量 (既存 Grok 値: ROAD=8 / RAIL=25 を厳守)
const CAPACITY := {0: 8.0, 1: 25.0, 2: 70.0, 3: 22.0}
# 速度 (px/day 相当)。競合スコアと所要日数の基準になる。
const SPEED := {0: 120.0, 1: 200.0, 2: 70.0, 3: 420.0}
# 建設費 (既存 Grok 値: ROAD=40 / RAIL=180 を厳守)
const BUILD_COST := {0: 40.0, 1: 180.0, 2: 240.0, 3: 320.0}
# 1日あたり運行費
const OPERATING_COST := {0: 1.5, 1: 4.0, 2: 6.5, 3: 8.0}
# 貨物種別 × モード の単価 (既存 Grok 値: ROAD/RAIL を厳守)
const UNIT_PASSENGER := {0: 0.8, 1: 1.2, 2: 1.6, 3: 3.0}
const UNIT_FOOD := {0: 1.0, 1: 1.5, 2: 1.9, 3: 2.0}
const UNIT_FUEL := {0: 1.2, 1: 1.8, 2: 2.1, 3: 2.2}
# 1ルート1日あたりの輸送上限 (ソフトキャップ)
const DAILY_CAP_PASSENGER := {0: 4.0, 1: 6.0, 2: 8.0, 3: 10.0}
const DAILY_CAP_FOOD := {0: 6.0, 1: 8.0, 2: 12.0, 3: 5.0}
const DAILY_CAP_FUEL := {0: 5.0, 1: 7.0, 2: 9.0, 3: 4.0}

# 港湾 / 空港の開設費
const PORT_COST := 90.0
const AIRPORT_COST := 120.0
# 海岸線からこの距離以内なら港を建設できる (px)
const PORT_COAST_LIMIT := 150.0

# 競合スコアの正規化基準 (最速=420, 最大容量=70)
const SPEED_REF := 420.0
const CAPACITY_REF := 70.0

static func mode_name(mode: int) -> String:
	return MODE_NAME.get(mode, "路線")

static func mode_name_en(mode: int) -> String:
	return MODE_NAME_EN.get(mode, "UNKNOWN")

static func capacity(mode: int) -> float:
	return CAPACITY.get(mode, 8.0)

static func speed(mode: int) -> float:
	return SPEED.get(mode, 120.0)

static func build_cost(mode: int) -> float:
	return BUILD_COST.get(mode, 40.0)

static func operating_cost(mode: int) -> float:
	return OPERATING_COST.get(mode, 1.0)

static func is_ground(mode: int) -> bool:
	return GROUND_MODES.has(mode)

static func is_valid_mode(mode: int) -> bool:
	return MODE_NAME.has(mode)

static func unit_price(cargo: int, mode: int) -> float:
	match cargo:
		Cargo.PASSENGER:
			return UNIT_PASSENGER.get(mode, 1.0)
		Cargo.FOOD:
			return UNIT_FOOD.get(mode, 1.0)
		_:
			return UNIT_FUEL.get(mode, 1.0)

static func daily_cap(cargo: int, mode: int) -> float:
	match cargo:
		Cargo.PASSENGER:
			return DAILY_CAP_PASSENGER.get(mode, 4.0)
		Cargo.FOOD:
			return DAILY_CAP_FOOD.get(mode, 6.0)
		_:
			return DAILY_CAP_FUEL.get(mode, 5.0)
