extends SceneTree

const Defaults = preload("res://sandbox/FoundationDefaults.gd")
const Adapter = preload("res://sandbox/HospitalDistrictExpeditionAdapter.gd")
const CompanionSystem = preload("res://sandbox/CompanionSystem.gd")
const DamageSystem = preload("res://sandbox/DamageSystem.gd")

const EXPECTED_CHECKS := 23
var passed := 0
var failed: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("[CAMPAIGN BRIDGE PASS] " + label)
	else:
		failed.append(label)
		print("[CAMPAIGN BRIDGE FAIL] " + label)

func _sandbox_campaign(with_kmf: bool = true, with_companion: bool = true) -> Dictionary:
	var campaign: Dictionary = Defaults.create_campaign()
	campaign["mode"] = "sandbox"
	if with_kmf:
		campaign["base"]["kmf_ids"] = ["day1_owned_kmf"]
	if with_companion:
		CompanionSystem.register(campaign, {"id":"yui", "display_name":"水城ユイ", "role":"survivor", "alive":true})
	return campaign

func _run() -> void:
	var campaign: Dictionary = Defaults.create_campaign()
	check("Hospital District is an additive campaign region", campaign.get("regions", {}).has("hospital_district") and int(campaign.get("schema_version", 0)) == 1)
	check("Prologue cannot launch expedition", str(Adapter.launch(campaign, 77).get("reason", "")) == "sandbox_not_active")

	campaign = _sandbox_campaign(true, true)
	var launch: Dictionary = Adapter.launch(campaign, 4242)
	check("Sandbox launches Hospital District through adapter", bool(launch.get("ok", false)) and str(launch.get("site_id", "")) == "hospital_district")
	check("Launch enters exploring state", str(campaign.get("expedition", {}).get("state", "")) == "exploring")
	check("Launch snapshot carries party loadout and seed", int(launch.get("seed", 0)) == 4242 and (launch.get("party_ids", []) as Array).has("hero") and launch.has("loadout_ids"))
	check("Launch snapshot carries campaign companion and KMF state", (launch.get("party_ids", []) as Array).has("yui") and launch.get("companions", {}).has("yui") and (launch.get("kmf_ids", []) as Array).has("day1_owned_kmf") and launch.has("human_status") and launch.has("kmf_status"))

	var packed: PackedScene = load("res://expedition_lab/ExpeditionPrototypeLab.tscn")
	var lab = packed.instantiate()
	get_root().add_child(lab)
	await process_frame
	await process_frame
	var configured: Dictionary = lab.configure_campaign_launch(launch)
	check("Expedition runtime applies campaign party and owned KMF", bool(configured.get("ok", false)) and lab.state.actors.has("yui") and not lab.state.actors.has("scout") and not lab.state.actors.has("medic") and str(lab.state.actors["friendly_kmf"].meta.get("campaign_kmf_id", "")) == "day1_owned_kmf")

	var no_kmf_campaign := _sandbox_campaign(false, false)
	var no_kmf_launch: Dictionary = Adapter.launch(no_kmf_campaign, 4343)
	lab.configure_campaign_launch(no_kmf_launch)
	check("Campaign without an owned KMF does not receive a free expedition KMF", not lab.state.actors.has("friendly_kmf"))

	var human_body: Dictionary = DamageSystem.create_body("human")
	DamageSystem.apply_damage(human_body, "left_leg", 20.0)
	var kmf_body: Dictionary = DamageSystem.create_body("kmf")
	DamageSystem.apply_damage(kmf_body, "weapon", 15.0)
	var outcome: Dictionary = {
		"retreat_success":true, "elapsed_time":125.0,
		"loot":["medical_cache", "food_crate"], "intel":["hospital_terminal"],
		"rescued_civilians":["civilian_01"], "injured":["hero"], "incapacitated":[],
		"human_parts":{"hero":human_body["parts"].duplicate(true)},
		"kmf_returned":true, "kmf_abandoned":false, "kmf_campaign_id":"day1_owned_kmf",
		"kmf_parts":kmf_body["parts"].duplicate(true),
		"world_consequence":{"alert_delta_candidate":8}
	}
	var before_minute := int(campaign["clock"]["minute_of_day"])
	var resolved: Dictionary = Adapter.apply_outcome(campaign, outcome)
	check("Successful physical extraction returns campaign", bool(resolved.get("ok", false)) and str(campaign["expedition"].get("state", "")) == "returned")
	check("Loot persists to campaign inventory", campaign["inventory"]["items"].has("medicine") and campaign["inventory"]["items"].has("ration"))
	check("Intel persists as verified regional knowledge", (campaign["regions"]["hospital_district"].get("rumors", []) as Array).has("verified:hospital_terminal"))
	check("Rescue persists as companion and population", campaign["companions"].has("civilian_01") and int(campaign["regions"]["hospital_district"].get("population", 0)) == 1)
	check("Elapsed time and alert consequence persist", int(campaign["clock"]["minute_of_day"]) > before_minute and int(campaign["factions"]["britannia"].get("alert", 0)) == 28)
	check("Human injury and part state persist to campaign base", (campaign["base"]["injured_ids"] as Array).has("hero") and campaign["base"]["human_status"].has("hero") and float(campaign["base"]["human_status"]["hero"]["parts"]["left_leg"]["hp"]) < float(campaign["base"]["human_status"]["hero"]["parts"]["left_leg"]["max_hp"]))
	check("KMF identity and part state persist to campaign base", campaign["base"]["kmf_status"].has("day1_owned_kmf") and float(campaign["base"]["kmf_status"]["day1_owned_kmf"]["parts"]["weapon"]["hp"]) < float(campaign["base"]["kmf_status"]["day1_owned_kmf"]["parts"]["weapon"]["max_hp"]))
	check("Adapter outcome records allowed consequences", int(campaign["expedition"]["outcome"].get("adapter_version", 0)) == 2 and (campaign["expedition"]["outcome"].get("applied_items", []) as Array).has("medicine"))

	var abandoned_campaign := _sandbox_campaign(true, false)
	Adapter.launch(abandoned_campaign, 5151)
	var abandoned_outcome := {"retreat_success":true, "elapsed_time":60.0, "loot":[], "intel":[], "rescued_civilians":[], "injured":[], "incapacitated":[], "human_parts":{}, "kmf_returned":false, "kmf_abandoned":true, "kmf_campaign_id":"day1_owned_kmf", "kmf_parts":kmf_body["parts"].duplicate(true), "world_consequence":{}}
	var abandoned_result: Dictionary = Adapter.apply_outcome(abandoned_campaign, abandoned_outcome)
	check("Abandoned KMF is removed from available base machines but status is retained", bool(abandoned_result.get("ok", false)) and not (abandoned_campaign["base"]["kmf_ids"] as Array).has("day1_owned_kmf") and bool(abandoned_campaign["base"]["kmf_status"]["day1_owned_kmf"].get("abandoned", false)))

	var failed_campaign := _sandbox_campaign(true, false)
	Adapter.launch(failed_campaign, 6161)
	var failed_outcome := {
		"retreat_success":false, "elapsed_time":90.0,
		"loot":["medical_cache", "food_crate"], "intel":["hospital_terminal"],
		"rescued_civilians":["civilian_fail"], "injured":[], "incapacitated":[],
		"human_parts":{}, "kmf_returned":false, "kmf_abandoned":false,
		"kmf_campaign_id":"day1_owned_kmf", "kmf_parts":kmf_body["parts"].duplicate(true),
		"world_consequence":{"alert_delta_candidate":4}
	}
	var failed_result: Dictionary = Adapter.apply_outcome(failed_campaign, failed_outcome)
	check("Failed extraction cannot return collected loot to campaign", bool(failed_result.get("ok", false)) and str(failed_campaign["expedition"].get("state", "")) == "failed" and not failed_campaign["inventory"]["items"].has("medicine") and not failed_campaign["inventory"]["items"].has("ration"))
	check("Failed extraction cannot return intel or rescued civilians", not (failed_campaign["regions"]["hospital_district"].get("rumors", []) as Array).has("verified:hospital_terminal") and not failed_campaign["companions"].has("civilian_fail") and int(failed_campaign["regions"]["hospital_district"].get("population", 0)) == 0)
	check("Failed extraction records unrecovered recoverables", (failed_campaign["expedition"]["outcome"].get("abandoned_items", []) as Array).has("medical_cache") and (failed_campaign["expedition"]["outcome"].get("unrecovered_intel", []) as Array).has("hospital_terminal") and (failed_campaign["expedition"]["outcome"].get("unrecovered_rescues", []) as Array).has("civilian_fail"))

	var campaign_a: Dictionary = _sandbox_campaign(false, false)
	var campaign_b: Dictionary = _sandbox_campaign(false, false)
	var launch_a: Dictionary = Adapter.launch(campaign_a, 9876)
	var launch_b: Dictionary = Adapter.launch(campaign_b, 9876)
	check("Same seed produces identical launch snapshot", launch_a == launch_b)
	var encoded := JSON.stringify(campaign)
	var decoded = JSON.parse_string(encoded)
	check("Campaign adapter result is JSON round-trip safe", not encoded.is_empty() and decoded is Dictionary and decoded.has("regions") and decoded.has("expedition") and JSON.stringify(decoded) != "null")
	check("Foundation schema remains unchanged", Defaults.CAMPAIGN_SCHEMA_VERSION == 1)

	lab.queue_free()
	_finish()

func _finish() -> void:
	var ran := passed + failed.size()
	print("Ran %d / %d; failures=%d" % [ran, EXPECTED_CHECKS, failed.size()])
	if ran == EXPECTED_CHECKS and failed.is_empty():
		print("CAMPAIGN BRIDGE CHECKS PASSED")
		quit(0)
	else:
		print("CAMPAIGN BRIDGE CHECKS FAILED")
		quit(1)
