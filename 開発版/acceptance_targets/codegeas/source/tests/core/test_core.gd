extends Node
## 自動テストランナー（F8または手動呼出）
## Godotエディタ外でもロジック検証可能なよう設計

func _gs() -> Node:
	return get_node_or_null("/root/GameState")

func _rng() -> Node:
	return get_node_or_null("/root/RngService")

func run_all() -> Dictionary:
	var results = {"passed": 0, "failed": 0, "details": []}
	_test_mode_mutex(results)
	_test_time_no_reverse(results)
	# This invariant must be checked while the protagonist is alive; the later
	# day-boundary stress test can legitimately kill the player through starvation.
	_test_affection_not_go(results)
	_test_day_boundary(results)
	_test_kmf_bounds(results)
	_test_seed_repro(results)
	_test_save_roundtrip(results)
	return results

func _ok(results: Dictionary, name: String) -> void:
	results["passed"] += 1
	results["details"].append("[PASS] " + name)

func _ng(results: Dictionary, name: String, reason: String = "") -> void:
	results["failed"] += 1
	results["details"].append("[FAIL] " + name + (" : " + reason if reason else ""))

func _test_mode_mutex(results: Dictionary) -> void:
	_gs().set_player_mode("foot")
	_gs().set_player_mode("kmf")
	if _gs().get_player_mode() == "kmf" and _gs().get_section("kmf").get("boarded"):
		_ok(results, "徒歩/KMF同時成立禁止（搭乗一貫）")
	else:
		_ng(results, "徒歩/KMF同時成立禁止")
	_gs().set_player_mode("foot")
	if _gs().get_player_mode() == "foot" and not _gs().get_section("kmf").get("boarded", true):
		_ok(results, "降機一貫")
	else:
		_ng(results, "降機一貫")

func _test_time_no_reverse(results: Dictionary) -> void:
	var t0 = _gs().get_day() * 1440 + _gs().get_minute_of_day()
	_gs().advance_time(-5)
	var t1 = _gs().get_day() * 1440 + _gs().get_minute_of_day()
	if t1 >= t0:
		_ok(results, "時刻逆行禁止")
	else:
		_ng(results, "時刻逆行禁止")

func _test_day_boundary(results: Dictionary) -> void:
	# リセット気味に進める
	while _gs().get_day() < 7:
		_gs().advance_time(180)
	if _gs().get_day() == 7:
		_ok(results, "day1→7境界")
	else:
		_ng(results, "day1→7境界", "day=" + str(_gs().get_day()))

func _test_kmf_bounds(results: Dictionary) -> void:
	var kmf = _gs().get_section("kmf")
	kmf["energy"] = -10
	kmf["ammo"] = -5
	kmf["durability"] = -1
	_gs().set_section("kmf", kmf)
	# KmfSystemのクランプはsignal経由だが、直接set後に再取得
	var k2 = _gs().get_section("kmf")
	# 最低限0以下にならないようdamage経由で確認
	_gs().damage_kmf(999)
	if float(_gs().get_section("kmf").get("durability", -1)) >= 0:
		_ok(results, "KMF durability境界")
	else:
		_ng(results, "KMF durability境界")

func _test_seed_repro(results: Dictionary) -> void:
	_rng().set_seed(42)
	var a = _rng().randi_range_seeded(0, 9999)
	_rng().set_seed(42)
	var b = _rng().randi_range_seeded(0, 9999)
	if a == b:
		_ok(results, "Seed再現")
	else:
		_ng(results, "Seed再現")

func _test_affection_not_go(results: Dictionary) -> void:
	var h = _gs().get_section("heroine")
	h["affection"] = -100.0
	_gs().set_section("heroine", h)
	if _gs().is_player_alive():
		_ok(results, "好感度-100即GO禁止")
	else:
		_ng(results, "好感度-100即GO禁止")

func _test_save_roundtrip(results: Dictionary) -> void:
	var sm = get_tree().root.find_child("SaveManager", true, false)
	if sm == null:
		_ng(results, "Save/Load round-trip", "SaveManager not found")
		return
	if sm.test_round_trip():
		_ok(results, "Save/Load round-trip")
	else:
		_ng(results, "Save/Load round-trip")
