extends RefCounted

const Combatant = preload("res://combat/core/Combatant.gd")
const KnowledgeState = preload("res://expedition_lab/state/KnowledgeState.gd")
const OrderState = preload("res://expedition_lab/state/OrderState.gd")

var seed: int = 20261022
var sim_time := 0.0
var phase := "infiltration"
var actors: Dictionary = {}
var enemy_truth: Dictionary = {}
var loot: Dictionary = {}
var intel_sources: Dictionary = {}
var rescue_targets: Dictionary = {}
var knowledge = KnowledgeState.new()
var orders = OrderState.new()
var selected_id := "hero"
var retreat_started := false
var retreat_success := false
var primary_progress := 0
var acquired_loot: Array[String] = []
var acquired_intel: Array[String] = []
var abandoned_kmf := false
var metrics: Dictionary = {}

func reset(fixture: Dictionary) -> void:
	seed = int(fixture.get("seed", 20261022)); sim_time = 0.0; phase = "infiltration"
	actors.clear(); enemy_truth.clear(); knowledge.reset(); orders.clear()
	loot = fixture.get("loot", {}).duplicate(true); intel_sources = fixture.get("intel", {}).duplicate(true)
	rescue_targets = fixture.get("rescue", {}).duplicate(true); acquired_loot.clear(); acquired_intel.clear()
	retreat_started = false; retreat_success = false; primary_progress = 0; abandoned_kmf = false; selected_id = "hero"
	metrics = {
		"number_of_orders": 0, "first_valid_order_time": -1.0,
		"invalid_commands": 0, "blocked_commands": {}, "context_menu_uses": 0,
		"movement_orders": 0, "repaths": 0, "cancelled_orders": 0, "arrivals": 0,
		"manual_pauses": 0, "auto_pauses": {}, "contact_transitions": {},
		"confirmed_contacts": 0, "observe_actions": 0, "scout_actions": 0,
		"combat_started": false, "part_target_actions": 0, "non_attack_actions": 0,
		"enemies_killed": 0, "enemies_incapacitated": 0, "damage_received": 0.0,
		"rescues": 0, "loot_acquired": 0, "loot_abandoned": 0,
		"kmf_abandoned": 0, "retreat_started": false, "retreat_success": false,
		"elapsed_real_time": 0.0, "elapsed_sim_time": 0.0,
	}
	for definition in fixture.get("friendlies", []): _add_actor(definition, "player")
	for definition in fixture.get("enemies", []):
		var actor = _add_actor(definition, "enemy")
		enemy_truth[actor.id] = {"position": actor.position, "patrol": definition.get("patrol", []), "alerted": false}
	orders.set_role("hero", "Follow"); orders.set_role("scout", "Scout"); orders.set_role("medic", "Medic"); orders.set_role("friendly_kmf", "Guard")

func add_player_actor(definition: Dictionary):
	return _add_actor(definition, "player")

func _add_actor(definition: Dictionary, team: String):
	var c = Combatant.new(str(definition.get("id", "actor")), str(definition.get("name", definition.get("id", "actor"))), team, str(definition.get("kind", "human")), float(definition.get("hp", 100.0)))
	c.position = definition.get("position", Vector2.ZERO); c.ensure_body(); c.meta = definition.get("meta", {}).duplicate(true)
	# CombatCore keeps aggregate HP for legacy compatibility. In this localized-damage
	# prototype, KMF aggregate HP mirrors the sum of part durability so several
	# non-vital disabled parts do not falsely destroy an otherwise intact machine.
	if c.kind == "kmf":
		var compatibility_hp := 0.0
		for part in c.body.get("parts", {}).values():
			compatibility_hp += float(part.get("max_hp", 0.0))
		if compatibility_hp > 0.0:
			c.max_hp = compatibility_hp
			c.hp = compatibility_hp
	actors[c.id] = c
	return c

func outcome_summary() -> Dictionary:
	var survivors: Array[String] = []
	var injured: Array[String] = []
	var incapacitated: Array[String] = []
	var human_parts: Dictionary = {}
	for actor in actors.values():
		if actor.team != "player": continue
		if actor.is_active() and not actor.incapacitated: survivors.append(actor.id)
		if actor.get_hp_ratio() < 0.999: injured.append(actor.id)
		if actor.incapacitated or actor.destroyed: incapacitated.append(actor.id)
		if actor.kind == "human": human_parts[actor.id] = actor.body.get("parts", {}).duplicate(true)
	var kmf = actors.get("friendly_kmf")
	var left_behind: Array = metrics.get("left_behind_ids", [])
	var returned: Array = metrics.get("returned_ids", [])
	var rescued_civilians: Array[String]=[]
	for id in rescue_targets.keys():
		if str(rescue_targets[id].get("status",""))=="extracted":
			rescued_civilians.append(str(id))
	var alert_delta:=0
	if bool(metrics.get("combat_started",false)): alert_delta+=8
	alert_delta+=int(metrics.get("enemies_killed",0))*3
	return {"primary_objective_progress":primary_progress,"survivors":survivors,"injured":injured,"incapacitated":incapacitated,"returned":returned.duplicate(),"left_behind":left_behind.duplicate(),"rescued_civilians":rescued_civilians,"human_parts":human_parts,"kmf_returned":retreat_success and not abandoned_kmf,"kmf_abandoned":abandoned_kmf,"kmf_campaign_id":"" if kmf == null else str(kmf.meta.get("campaign_kmf_id", "")),"kmf_parts":{} if kmf == null else kmf.body.get("parts", {}).duplicate(true),"loot":acquired_loot.duplicate(),"intel":acquired_intel.duplicate(),"retreat_success":retreat_success,"elapsed_time":sim_time,"world_consequence":{"hospital_supplies":acquired_loot.has("medical_cache"),"civilian_rescued":not rescued_civilians.is_empty(),"alert_delta_candidate":alert_delta,"left_behind":left_behind.duplicate(),"abandoned_kmf":abandoned_kmf}}

func snapshot() -> Dictionary:
	var positions := {}
	for id in actors.keys():
		positions[id] = actors[id].position
	return {"seed":seed,"phase":phase,"positions":positions,"loot":loot.duplicate(true),"intel":intel_sources.duplicate(true),"knowledge":knowledge.contacts.duplicate(true),"metrics":metrics.duplicate(true),"rescue":rescue_targets.duplicate(true)}

