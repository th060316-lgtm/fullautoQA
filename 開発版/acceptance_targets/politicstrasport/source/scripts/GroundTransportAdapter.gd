class_name GroundTransportAdapter
extends RefCounted

## MiniMax: AI 会社の「地上接続要求」を Grok 側 API へ渡す境界
##
## ────────────────────────────────────────────────────────────
## Grok 側 (地上交通 管轄) に要求する provider の仕様:
##
##   func can_build_ground_connection(
##       company_id: int, mode: int, origin_id: int, destination_id: int) -> bool
##   func request_ground_connection(
##       company_id: int, mode: int, origin_id: int, destination_id: int) -> int
##   func estimate_ground_build_cost(mode: int, origin_id: int, destination_id: int) -> float
##   func estimate_ground_length(mode: int, origin_id: int, destination_id: int) -> float
##
##   mode は TransportModeConfig.Mode (0=ROAD, 1=RAIL)
##   request_ground_connection は成功時に connection(route) の id、
##   失敗時に -1 を返すこと。
## ────────────────────────────────────────────────────────────
##
## provider が未設定の場合の Mock は「直線距離ベースの仮接続」を作るだけ。
## タイル敷設・地上 PathFinder は Mock にも持たせない (Grok 管轄)。
## 本クラスは統合前テスト用の足場であり、実運用では provider を必ず設定する。

const MOCK_REQUEST_LOG_LIMIT := 200

var world: WorldState
var provider: Object = null
var using_mock: bool = false
var request_log: Array = []   # 診断用: 発行した地上接続要求

func _init(p_world: WorldState) -> void:
	world = p_world

## Grok 実装の provider を設定する。null で戻すと Mock に復帰。
func configure_provider(p_provider: Object) -> void:
	provider = p_provider
	using_mock = false

func has_provider() -> bool:
	return provider != null

func _provider_has(method_name: String) -> bool:
	return provider != null and provider.has_method(method_name)

# ------------------------------------------------------------------
# 境界API (AI 側が呼び出す)
# ------------------------------------------------------------------

## AI が地上接続を要求できるか (Grok の PathFinder / 予算判定)
func can_build_ground_connection(company_id: int, mode: int, origin_id: int, destination_id: int) -> bool:
	if not TransportModeConfig.is_ground(mode):
		return false
	if _provider_has("can_build_ground_connection"):
		return bool(provider.can_build_ground_connection(company_id, mode, origin_id, destination_id))
	_log_provider_missing("can_build_ground_connection")
	return false

## AI が地上接続を要求する。成功時は connection id、失敗時は -1。
func request_ground_connection(company_id: int, mode: int, origin_id: int, destination_id: int) -> int:
	if not TransportModeConfig.is_ground(mode):
		return -1
	_log_request(company_id, mode, origin_id, destination_id)
	if _provider_has("request_ground_connection"):
		return int(provider.request_ground_connection(company_id, mode, origin_id, destination_id))
	_log_provider_missing("request_ground_connection")
	return -1

## 地上接続の建設費見積 (Grok の Warp / タイル費用基準)
func estimate_ground_build_cost(mode: int, origin_id: int, destination_id: int) -> float:
	if _provider_has("estimate_ground_build_cost"):
		return float(provider.estimate_ground_build_cost(mode, origin_id, destination_id))
	_log_provider_missing("estimate_ground_build_cost")
	return INF

## 地上接続の距離見積 (px)
func estimate_ground_length(mode: int, origin_id: int, destination_id: int) -> float:
	if _provider_has("estimate_ground_length"):
		return float(provider.estimate_ground_length(mode, origin_id, destination_id))
	_log_provider_missing("estimate_ground_length")
	return 0.0


func _log_provider_missing(method_name: String) -> void:
	if world != null:
		world.add_event("地上provider未接続: %s" % method_name)

# ------------------------------------------------------------------
# Legacy mock helpers retained only for isolated old tests; integrated runtime does not call them.
# ------------------------------------------------------------------

func _mock_can_build(company_id: int, mode: int, origin_id: int, destination_id: int) -> bool:
	if origin_id == destination_id:
		return false
	var a = world.get_settlement(origin_id)
	var b = world.get_settlement(destination_id)
	if a == null or b == null or not a.active or not b.active:
		return false
	if a.is_supply_base or b.is_supply_base:
		return false
	return true

func _mock_request(company_id: int, mode: int, origin_id: int, destination_id: int) -> int:
	if not _mock_can_build(company_id, mode, origin_id, destination_id):
		return -1
	var route = world.create_route(origin_id, destination_id, mode, company_id)
	if route == null:
		return -1
	route.path_length = _mock_length(origin_id, destination_id)
	return route.id

func _mock_build_cost(mode: int, origin_id: int, destination_id: int) -> float:
	var base: float = TransportModeConfig.build_cost(mode)
	var dist: float = _mock_length(origin_id, destination_id)
	# 距離に応じた上乗せ (Mock の簡易モデル)
	return base + dist * (0.02 if mode == TransportModeConfig.Mode.RAIL else 0.04)

func _mock_length(origin_id: int, destination_id: int) -> float:
	var a = world.get_settlement(origin_id)
	var b = world.get_settlement(destination_id)
	if a == null or b == null:
		return 0.0
	return a.position.distance_to(b.position)

func _log_request(company_id: int, mode: int, origin_id: int, destination_id: int) -> void:
	request_log.append({
		"day": world.day,
		"company_id": company_id,
		"mode": mode,
		"origin_id": origin_id,
		"destination_id": destination_id,
		"mock": using_mock,
	})
	while request_log.size() > MOCK_REQUEST_LOG_LIMIT:
		request_log.pop_front()
