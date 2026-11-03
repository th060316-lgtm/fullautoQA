extends Node
## Campaign/game-flow boundary. Day1 stays a prologue; this service owns post-Day1 flow.

const Defaults = preload("res://sandbox/FoundationDefaults.gd")
const Bridge = preload("res://sandbox/Day1SandboxBridge.gd")
const HospitalAdapter = preload("res://sandbox/HospitalDistrictExpeditionAdapter.gd")

func _ready() -> void:
	ensure_initialized()

func ensure_initialized() -> void:
	if not has_node("/root/GameState"):
		return
	var campaign: Dictionary = GameState.get_section("campaign")
	if campaign.is_empty():
		GameState.set_section("campaign", Defaults.create_campaign(), false)

func get_campaign() -> Dictionary:
	return GameState.get_section("campaign") if has_node("/root/GameState") else {}

func set_campaign(campaign: Dictionary) -> bool:
	var version := int(campaign.get("schema_version", 0))
	if campaign.is_empty() or version <= 0 or version > Defaults.CAMPAIGN_SCHEMA_VERSION:
		return false
	GameState.set_section("campaign", campaign)
	return true

func is_sandbox_active() -> bool:
	return str(get_campaign().get("mode", "prologue")) == "sandbox"

func transition_from_day1(day1_override: Dictionary = {}) -> bool:
	var snapshot: Dictionary = GameState.get_snapshot()
	var day1: Dictionary = day1_override.duplicate(true) if not day1_override.is_empty() else snapshot.get("day1", {})
	if not Bridge.can_transition(day1):
		return false
	return set_campaign(Bridge.build_campaign(day1, snapshot))

func advance_campaign_time(minutes: int) -> bool:
	if minutes <= 0:
		return false
	var campaign := get_campaign()
	var clock: Dictionary = campaign.get("clock", {})
	var total := (int(clock.get("day", 1)) - 1) * 1440 + int(clock.get("minute_of_day", 0)) + minutes
	clock["day"] = int(total / 1440) + 1
	clock["minute_of_day"] = total % 1440
	campaign["clock"] = clock
	return set_campaign(campaign)

func launch_hospital_district(seed_override: int = -1) -> Dictionary:
	var campaign := get_campaign()
	var result := HospitalAdapter.launch(campaign, seed_override)
	if bool(result.get("ok", false)) and not set_campaign(campaign):
		return {"ok": false, "reason": "campaign_save_failed"}
	return result

func launch_hospital_district_prepared(preparation: Dictionary, seed_override: int = -1) -> Dictionary:
	var campaign := get_campaign()
	var result := HospitalAdapter.launch_with_preparation(campaign, preparation, seed_override)
	if bool(result.get("ok", false)) and not set_campaign(campaign):
		return {"ok": false, "reason": "campaign_save_failed"}
	return result

func get_active_hospital_district_launch_snapshot() -> Dictionary:
	return HospitalAdapter.get_active_launch_snapshot(get_campaign())

func apply_hospital_district_outcome(outcome: Dictionary) -> Dictionary:
	var campaign := get_campaign()
	var result := HospitalAdapter.apply_outcome(campaign, outcome)
	if bool(result.get("ok", false)) and not set_campaign(campaign):
		return {"ok": false, "reason": "campaign_save_failed"}
	return result

