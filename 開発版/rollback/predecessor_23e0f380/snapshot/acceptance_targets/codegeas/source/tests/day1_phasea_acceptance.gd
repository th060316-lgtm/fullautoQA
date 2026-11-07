# day1_phasea_acceptance.gd
# Phase A Grok担当自己テスト
# 実行していない検査をPASSと書かない

extends Node

func run_tests() -> Dictionary:
	var results: Dictionary = {
		"passed": [],
		"failed": [],
		"not_run": [],
		"notes": [],
	}
	var gs = get_node_or_null("/root/GameState")
	var eb = get_node_or_null("/root/EventBus")
	var day1 = get_tree().get_first_node_in_group("day1_controller")
	if day1 == null:
		day1 = get_node_or_null("/root/Day1Controller")
	if day1 == null:
		# try scene
		var main = get_tree().current_scene
		if main:
			day1 = main.get_node_or_null("Day1Controller")

	if day1 == null or not day1.has_method("initialize_day1"):
		results["failed"].append("Day1Controller not found")
		return results

	# Reset-ish
	if not day1.is_initialized():
		day1.initialize_day1()

	# 1. Day1 bootで3案件存在、known=2
	var known = day1.get_known_cases()
	var states_ok = true
	for cid in ["quest_hospital_medicine", "quest_evacuation_rescue", "quest_supply_depot"]:
		var st = day1.get_case_state(cid)
		if st.is_empty():
			states_ok = false
	if states_ok and known.size() == 2 and "quest_supply_depot" not in known:
		results["passed"].append("T1: 3 cases exist, known=2")
	else:
		results["failed"].append("T1: known=%s size=%d states_ok=%s" % [str(known), known.size(), str(states_ok)])

	# 2. hidden caseはunknownのまま進行し、discover_caseでknown化
	var st_supply = day1.get_case_state("quest_supply_depot")
	if not bool(st_supply.get("known", true)):
		var disc = day1.discover_case("quest_supply_depot", {"sourceType": "npc_testimony", "sourceId": "rei"})
		var after = day1.get_case_state("quest_supply_depot")
		if disc and bool(after.get("known", false)):
			results["passed"].append("T2: discover_case works for hidden")
		else:
			results["failed"].append("T2: discover failed")
	else:
		results["failed"].append("T2: supply was already known")

	# 3. Hospital案件をbaseから直接完了不能
	var player = gs.get_section("player") if gs else {}
	player["locationId"] = "base"
	if gs:
		gs.set_section("player", player)
	day1.accept_case("quest_hospital_medicine")
	var forced = day1.try_complete_case("quest_hospital_medicine", {})
	if not forced:
		results["passed"].append("T3: cannot complete hospital from base without conditions")
	else:
		results["failed"].append("T3: hospital completed without conditions")

	# 4. deadline超過で最低1案件expired/failed
	# 時間を進めてdeadline超え
	if gs:
		var st = day1.get_case_state("quest_evacuation_rescue")
		var dl = int(st.get("deadline_abs_minute", 900))
		var now = gs.get_minute_of_day()
		var need = max(0, dl - now + 10)
		gs.advance_time(need)
		if day1.has_method("on_time_advanced"):
			day1.on_time_advanced(need)
		var after_st = day1.get_case_state("quest_evacuation_rescue")
		var status = str(after_st.get("status", ""))
		if status in ["expired", "failed"]:
			results["passed"].append("T4: deadline exceeded -> %s" % status)
		else:
			results["failed"].append("T4: status still %s after deadline" % status)
	else:
		results["not_run"].append("T4: no GameState")

	# 5. 徒歩固有action成功
	if gs:
		gs.set_player_mode("foot")
	var foot_res = day1.perform_foot_action("observe", {"target": "hospital_area"})
	if bool(foot_res.get("ok", false)):
		results["passed"].append("T5: foot observe success")
	else:
		results["failed"].append("T5: foot action failed: %s" % str(foot_res))

	# 6. KMF固有/優位action成功
	if gs:
		gs.set_player_mode("kmf")
	var kmf_res = day1.perform_kmf_action("rubble_breakthrough", {})
	if bool(kmf_res.get("ok", false)):
		results["passed"].append("T6: kmf rubble_breakthrough success")
	else:
		results["failed"].append("T6: kmf action failed: %s" % str(kmf_res))
	if gs:
		gs.set_player_mode("foot")

	# 7. NPCが時間/条件でlocationId変化
	var rt_before = gs.get_section("day1").get("npc_runtime", {}) if gs else {}
	if day1.has_method("request_npc_move"):
		var moved = day1.request_npc_move("aoi", "hospital", "test_move")
		var rt_after = gs.get_section("day1").get("npc_runtime", {}) if gs else {}
		var aoi_loc = str(rt_after.get("aoi", {}).get("locationId", ""))
		if moved and aoi_loc == "hospital":
			results["passed"].append("T7: NPC locationId changed")
		else:
			results["failed"].append("T7: NPC move failed loc=%s" % aoi_loc)
	else:
		results["not_run"].append("T7: no request_npc_move")

	# 8. facility state変更
	var fac_before = day1.get_facility_state("hospital")
	var ok_fac = day1.apply_facility_delta("hospital", {"capacity": 0.9}, "test_delta")
	var fac_after = day1.get_facility_state("hospital")
	if ok_fac and float(fac_after.get("capacity", 0)) == 0.9:
		results["passed"].append("T8: facility state changed")
	else:
		results["failed"].append("T8: facility change failed")

	# 9. Save/Loadで担当state一致 (簡易)
	if gs and gs.has_method("get_snapshot") and gs.has_method("apply_snapshot"):
		var snap = gs.get_snapshot()
		var day1_snap = snap.get("day1", {})
		# mutate then restore
		day1.apply_facility_delta("maintenance", {"service_level": 0.1}, "temp")
		gs.apply_snapshot(snap)
		var restored = day1.get_facility_state("maintenance")
		if float(restored.get("service_level", -1)) != 0.1:
			results["passed"].append("T9: Save/Load day1 state consistent (simplified)")
		else:
			results["failed"].append("T9: restore did not revert")
	else:
		results["not_run"].append("T9: no snapshot API")

	# 10. affection -100で主人公即死しない
	if gs:
		var h = gs.get_section("heroine")
		h["affection"] = -100
		gs.set_section("heroine", h)
		if gs.is_player_alive():
			results["passed"].append("T10: affection -100 not instant GO")
		else:
			results["failed"].append("T10: player died from affection -100")
	else:
		results["not_run"].append("T10")

	return results

func print_results(res: Dictionary) -> void:
	print("=== Phase A Acceptance ===")
	for p in res.get("passed", []):
		print("[PASS] ", p)
	for f in res.get("failed", []):
		print("[FAIL] ", f)
	for n in res.get("not_run", []):
		print("[NOT RUN] ", n)
	print("PASS=%d FAIL=%d NOT_RUN=%d" % [res.get("passed", []).size(), res.get("failed", []).size(), res.get("not_run", []).size()])
