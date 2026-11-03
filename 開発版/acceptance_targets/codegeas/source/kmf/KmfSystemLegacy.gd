extends Node
## KmfSystem - KMF状態管理ヘルパー
## 搭乗/降機はPlayerController側、ここでは境界値と整備

func _ready() -> void:
	EventBus.kmf_state_changed.connect(_on_kmf_changed)

func _on_kmf_changed() -> void:
	var kmf = GameState.get_section("kmf")
	# 境界クランプ
	kmf["durability"] = clampf(float(kmf.get("durability", 0)), 0.0, float(kmf.get("max_durability", 100)))
	kmf["energy"] = clampf(float(kmf.get("energy", 0)), 0.0, float(kmf.get("max_energy", 100)))
	kmf["ammo"] = clampi(int(kmf.get("ammo", 0)), 0, int(kmf.get("max_ammo", 30)))
	kmf["sensor"] = clampf(float(kmf.get("sensor", 0)), 0.0, 100.0)
	GameState.set_section("kmf", kmf, false)

## 整備所利用（時間消費あり）
func repair_at_hangar() -> bool:
	var loc = GameState.get_section("player").get("locationId", "")
	# 簡易: 位置で判定
	var pos = GameState.get_player_position()
	if pos.x < 30 * 32 or pos.y > 5 * 32:
		EventBus.player_notice.emit("KMF整備は整備区画で行えます")
		return false
	GameState.advance_time(60)  # 1時間整備
	var kmf = GameState.get_section("kmf")
	kmf["durability"] = kmf.get("max_durability", 100.0)
	kmf["energy"] = kmf.get("max_energy", 100.0)
	kmf["ammo"] = kmf.get("max_ammo", 30)
	kmf["sensor"] = 100.0
	kmf["owned"] = true
	GameState.set_section("kmf", kmf)
	EventBus.player_notice.emit("KMFの整備が完了しました")
	return true

func get_visibility_noise() -> float:
	return float(GameState.get_section("kmf").get("visibilityNoise", 0.0))

func is_operational() -> bool:
	var kmf = GameState.get_section("kmf")
	return bool(kmf.get("owned", false)) and float(kmf.get("durability", 0)) > 0.0

