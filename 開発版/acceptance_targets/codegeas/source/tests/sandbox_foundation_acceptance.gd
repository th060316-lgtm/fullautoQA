extends SceneTree
## Phase 0 fail-closed acceptance for the post-Day1 sandbox foundation.

const Defaults = preload("res://sandbox/FoundationDefaults.gd")
const IncidentSystem = preload("res://sandbox/IncidentSystem.gd")
const RegionSystem = preload("res://sandbox/RegionSystem.gd")
const ExpeditionSystem = preload("res://sandbox/ExpeditionSystem.gd")
const InventorySystem = preload("res://sandbox/InventorySystem.gd")
const DamageSystem = preload("res://sandbox/DamageSystem.gd")
const CompanionSystem = preload("res://sandbox/CompanionSystem.gd")
const BaseSystem = preload("res://sandbox/BaseSystem.gd")
const FactionSystem = preload("res://sandbox/FactionSystem.gd")
const WorldDirector = preload("res://sandbox/WorldDirector.gd")

const EXPECTED: int = 35
var passed: int = 0
var failed: int = 0
var gs: Node
var campaign_manager: Node
var rng_service: Node

func _check(ok: bool, label: String) -> void:
	if ok:
		passed += 1
		print("[FOUNDATION PASS] " + label)
	else:
		failed += 1
		print("[FOUNDATION FAIL] " + label)

func _init() -> void:
	call_deferred("_run")

func _tick(count: int = 1) -> void:
	for _i in range(count):
		await process_frame
		await physics_frame

func _run() -> void:
	gs = get_root().get_node_or_null("GameState")
	campaign_manager = get_root().get_node_or_null("CampaignManager")
	rng_service = get_root().get_node_or_null("RngService")
	_check(gs != null and campaign_manager != null and rng_service != null, "Foundation autoload services are available")
	if gs == null or campaign_manager == null or rng_service == null:
		_finish()
		return
	gs._init_default_state()
	var packed: PackedScene = load("res://scenes/Main.tscn")
	_check(packed != null, "Main scene loads")
	if packed == null:
		_finish()
		return
	var main: Node = packed.instantiate()
	get_root().add_child(main)
	await _tick(4)
	var save_manager: Node = main.get_node_or_null("SaveManager")

	var initial: Dictionary = gs.get_snapshot()
	_check(int(initial.get("campaign", {}).get("schema_version", 0)) == 1 and str(initial["campaign"].get("mode", "")) == "prologue", "Campaign foundation initializes in prologue mode")

	var old_save: Dictionary = initial.duplicate(true)
	old_save["meta"]["schemaVersion"] = 2
	old_save.erase("campaign")
	old_save["unknown_legacy_section"] = {"preserve": 77}
	var old_day1: Dictionary = old_save["day1"].duplicate(true)
	var old_npcs: Dictionary = old_save["npcs"].duplicate(true)
	_check(gs.apply_snapshot(old_save) and int(gs.get_snapshot()["meta"]["schemaVersion"]) == 3 and not gs.get_section("campaign").is_empty(), "Schema v2 save migrates to v3 with campaign defaults")
	_check(gs.get_snapshot().get("unknown_legacy_section", {}).get("preserve", 0) == 77, "Migration preserves unknown legacy data")
	_check(gs.get_section("day1") == old_day1 and gs.get_section("npcs") == old_npcs, "Migration preserves Day1 and NPC state")
	old_save["day1"]["migration_marker"] = "keep"
	old_save["npcs"]["legacy_npc"] = {"alive": true}
	var legacy_file := FileAccess.open("user://saves/_foundation_legacy.json", FileAccess.WRITE)
	if legacy_file:
		legacy_file.store_string(JSON.stringify(old_save, "\t"))
		legacy_file.close()
	var legacy_loaded := save_manager != null and bool(save_manager.load_game("_foundation_legacy"))
	_check(legacy_loaded and gs.get_section("campaign").has("regions") and gs.get_section("day1").get("migration_marker", "") == "keep" and gs.get_npc("legacy_npc").get("alive", false), "SaveManager loads real schema v2 file and migrates campaign without losing Day1/NPC")
	var before_future_file: Dictionary = gs.get_snapshot()
	var future_file_data: Dictionary = before_future_file.duplicate(true)
	future_file_data["campaign"]["schema_version"] = Defaults.CAMPAIGN_SCHEMA_VERSION + 1
	var future_file := FileAccess.open("user://saves/_foundation_future_campaign.json", FileAccess.WRITE)
	if future_file:
		future_file.store_string(JSON.stringify(future_file_data, "\t"))
		future_file.close()
	_check(save_manager != null and not bool(save_manager.load_game("_foundation_future_campaign")) and gs.get_snapshot() == before_future_file, "SaveManager rejects future campaign schema without partial restore")

	var before_future: Dictionary = gs.get_snapshot()
	var future: Dictionary = before_future.duplicate(true)
	future["meta"]["schemaVersion"] = gs.SCHEMA_VERSION + 1
	_check(not gs.apply_snapshot(future) and gs.get_snapshot() == before_future, "Future schema is rejected without partial GameState restore")
	var future_campaign: Dictionary = Defaults.create_campaign()
	future_campaign["schema_version"] = Defaults.CAMPAIGN_SCHEMA_VERSION + 1
	_check(not campaign_manager.set_campaign(future_campaign), "Campaign manager rejects unsupported future campaign schema")

	gs._init_default_state()
	_check(not campaign_manager.transition_from_day1(), "Incomplete Day1 cannot enter sandbox")
	var completed_day1: Dictionary = gs.get_section("day1")
	completed_day1["schema_version"] = 3
	completed_day1["end_result"] = "invalid_result"
	completed_day1["case_states"] = {"a": {"status": "completed"}, "b": {"status": "completed"}, "c": {"status": "failed"}}
	gs.set_section("day1", completed_day1)
	_check(not campaign_manager.transition_from_day1(), "Bridge rejects unknown Day1 result labels")
	completed_day1["end_result"] = "部分成功"
	completed_day1["summary"] = {"result": "部分成功", "completed_count": 2, "failed_count": 1}
	completed_day1["world_changes"] = {"hospital_operational": true}
	gs.set_section("day1", completed_day1)
	var day1_before_bridge: Dictionary = gs.get_section("day1")
	_check(campaign_manager.transition_from_day1() and campaign_manager.is_sandbox_active(), "Completed Day1 transitions through bridge")
	_check(gs.get_section("day1") == day1_before_bridge and campaign_manager.get_campaign()["source"]["day1_result"] == "部分成功", "Bridge preserves Day1 and records prologue result")

	var campaign: Dictionary = campaign_manager.get_campaign()
	var templates: Array = Defaults.create_incident_templates()
	var medical: Dictionary = templates[0]
	var incident_ok := IncidentSystem.register(campaign, medical, 100)
	incident_ok = incident_ok and IncidentSystem.transition(campaign, "medical_shortage", "discovered")
	incident_ok = incident_ok and IncidentSystem.transition(campaign, "medical_shortage", "available")
	incident_ok = incident_ok and IncidentSystem.transition(campaign, "medical_shortage", "active")
	incident_ok = incident_ok and IncidentSystem.set_objective_progress(campaign, "medical_shortage", "deliver_medicine", 2)
	incident_ok = incident_ok and IncidentSystem.transition(campaign, "medical_shortage", "resolved")
	_check(incident_ok and campaign["incidents"]["medical_shortage"]["status"] == "resolved", "Incident lifecycle reaches resolved through legal states")

	var salvage: Dictionary = templates[1]
	var expiry_ok := IncidentSystem.register(campaign, salvage, 0)
	var expired: Array[String] = IncidentSystem.expire_due(campaign, 1000)
	_check(expiry_ok and "industrial_salvage" in expired and campaign["incidents"]["industrial_salvage"]["status"] == "expired", "Incident deadline expires even an undiscovered incident")

	_check(RegionSystem.update_region(campaign, "city_center", {"danger": 140, "exploration": 0.5}) and int(RegionSystem.get_region(campaign, "city_center")["danger"]) == 100, "Region state updates with bounded danger")
	var expedition_ok := ExpeditionSystem.begin_preparation(campaign, "city_center", ["yui"], ["field_rifle"])
	expedition_ok = expedition_ok and ExpeditionSystem.transition(campaign, "deployed")
	expedition_ok = expedition_ok and ExpeditionSystem.transition(campaign, "exploring")
	expedition_ok = expedition_ok and ExpeditionSystem.transition(campaign, "extracting")
	expedition_ok = expedition_ok and ExpeditionSystem.transition(campaign, "returned", {"outcome": {"loot": 1}})
	_check(expedition_ok and campaign["expedition"]["state"] == "returned", "Expedition state machine completes return loop")
	_check(not ExpeditionSystem.transition(campaign, "deployed"), "Expedition rejects illegal state transition")

	campaign["inventory"]["capacity"] = 10.0
	var inventory_ok := InventorySystem.add_item(campaign, "ration", 4) and InventorySystem.add_item(campaign, "field_rifle", 1)
	inventory_ok = inventory_ok and is_equal_approx(InventorySystem.total_weight(campaign), 6.0)
	inventory_ok = inventory_ok and InventorySystem.remove_item(campaign, "ration", 1)
	_check(inventory_ok and int(campaign["inventory"]["items"]["ration"]["quantity"]) == 3, "Inventory adds, removes and calculates weight")
	_check(not InventorySystem.add_item(campaign, "kmf_servo", 1), "Inventory capacity blocks overweight loot")

	var human: Dictionary = DamageSystem.create_body("human")
	var arm_hit: Dictionary = DamageSystem.apply_damage(human, "right_arm", 100.0)
	_check(bool(arm_hit.get("disabled", false)) and not bool(human.get("incapacitated", true)), "Human limb damage disables part without automatic death")
	var kmf: Dictionary = DamageSystem.create_body("kmf")
	var sensor_hit: Dictionary = DamageSystem.apply_damage(kmf, "sensor", 100.0)
	var cockpit_hit: Dictionary = DamageSystem.apply_damage(kmf, "cockpit", 100.0)
	_check(bool(sensor_hit.get("disabled", false)) and bool(cockpit_hit.get("incapacitated", false)), "KMF profile supports sensor destruction and cockpit incapacitation")

	var companion_ok := CompanionSystem.register(campaign, {"id": "tamaki", "display_name": "玉城", "skills": {"combat": 2, "medical": 0, "maintenance": 1, "kmf_aptitude": 1}})
	_check(companion_ok and not CompanionSystem.register(campaign, {"id": "tamaki"}), "Companion registration rejects duplicate IDs")
	_check(BaseSystem.adjust_resource(campaign, "medicine", 2.0) and BaseSystem.register_kmf(campaign, "captured_sutherland"), "Base tracks resources and owned KMF")
	_check(FactionSystem.adjust_reputation(campaign, "resistance", 15) and FactionSystem.set_region_control(campaign, "city_center", "resistance") and campaign["regions"]["city_center"]["controller"] == "resistance", "Faction reputation and regional control update together")

	var no_flag: Array = WorldDirector.eligible_candidates(templates, campaign, {})
	var has_false_rumor := false
	for candidate in no_flag:
		if str(candidate.get("id", "")) == "false_curfew_rumor":
			has_false_rumor = true
	_check(not has_false_rumor, "Director never admits condition-ineligible incident")
	var typo_candidate: Dictionary = templates[0].duplicate(true)
	typo_candidate["id"] = "typo_condition"
	typo_candidate["conditions"] = {"base_resorce_below": {"medicine": 99}}
	_check(WorldDirector.eligible_candidates([typo_candidate], campaign, {}).is_empty(), "Director rejects unknown condition keys fail-closed")
	var pick_a: Dictionary = WorldDirector.select_candidate(templates, campaign, {"curfew_rumor_known": true}, 424242)
	var reversed_templates: Array = templates.duplicate(true)
	reversed_templates.reverse()
	var pick_b: Dictionary = WorldDirector.select_candidate(reversed_templates, campaign, {"curfew_rumor_known": true}, 424242)
	_check(not pick_a.is_empty() and pick_a.get("id") == pick_b.get("id"), "Director selection reproduces with same seed independent of input order")
	var fire_campaign: Dictionary = Defaults.create_campaign()
	var fired: Dictionary = WorldDirector.evaluate_and_fire(templates, fire_campaign, {"curfew_rumor_known": true}, 991, 500)
	_check(not fired.is_empty() and str(fired.get("status", "")) == "available" and not str(fire_campaign["director"]["last_incident_id"]).is_empty(), "Director evaluates, selects and fires an eligible incident")
	var invalid_fire: Dictionary = templates[0].duplicate(true)
	invalid_fire["id"] = "invalid_initial"
	invalid_fire["initial_status"] = "active"
	var rejected_fire: Dictionary = WorldDirector.evaluate_and_fire([invalid_fire], fire_campaign, {}, 10, 600)
	_check(rejected_fire.is_empty() and not fire_campaign["incidents"].has("invalid_initial"), "Director fire failure leaves no partial incident")

	campaign_manager.set_campaign(campaign)
	rng_service.set_seed(99173)
	rng_service.randi()
	var rng_before: Dictionary = rng_service.get_state()
	var saved := save_manager != null and bool(save_manager.save_game("_foundation_rng"))
	rng_service.randi()
	var loaded := saved and bool(save_manager.load_game("_foundation_rng"))
	_check(loaded and rng_service.get_state() == rng_before, "Save/load preserves RNG continuity")
	_check(save_manager != null and bool(save_manager.test_round_trip()), "New campaign save round-trip remains logically equal")

	var final_campaign: Dictionary = campaign_manager.get_campaign()
	_check(final_campaign.has("regions") and final_campaign.has("incidents") and final_campaign.has("factions"), "Campaign aggregate survives Save/Load")
	_check(RegionSystem.available_destinations(final_campaign).size() >= 2, "Strategic map exposes multiple region destinations")

	_finish()

func _finish() -> void:
	print("[FOUNDATION] passed=%d failed=%d expected=%d" % [passed, failed, EXPECTED])
	if passed != EXPECTED or failed != 0:
		print("SANDBOX FOUNDATION ACCEPTANCE: FAILED")
		quit(1)
		return
	print("SANDBOX FOUNDATION ACCEPTANCE: PASSED")
	quit(0)
