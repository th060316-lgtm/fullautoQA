class_name WarSystem
extends RefCounted

var world: WorldState
var war_policy: WarSupplyPolicy = null

func _init(p_world: WorldState):
	world = p_world
	war_policy = WarSupplyPolicy.new(world)

func process_day() -> void:
	if world.war_active:
		_process_ongoing_war()
	else:
		_maybe_start_war()

func _maybe_start_war() -> void:
	if world.day < 25 or world.day % 12 != 0 or world.rng.randf() > 0.22:
		return
	var candidates: Array = []
	for n in world.nations:
		if n.active:
			candidates.append(n.id)
	if candidates.size() < 2:
		return
	var a_index = world.rng.randi_range(0, candidates.size() - 1)
	var a = candidates[a_index]
	candidates.remove_at(a_index)
	var b = candidates[world.rng.randi_range(0, candidates.size() - 1)]
	_start_war(a, b)

func _start_war(nation_a_id: int, nation_b_id: int) -> void:
	var na = world.get_nation(nation_a_id)
	var nb = world.get_nation(nation_b_id)
	if na == null or nb == null or not na.active or not nb.active or nation_a_id == nation_b_id:
		return
	world.war_active = true
	world.war_nation_a = nation_a_id
	world.war_nation_b = nation_b_id
	world.war_days_left = 18 + world.rng.randi_range(0, 12)
	na.is_at_war = true
	na.war_opponent_id = nation_b_id
	na.war_bonus = 0.0
	nb.is_at_war = true
	nb.war_opponent_id = nation_a_id
	nb.war_bonus = 0.0
	world.add_event("%sと%sが開戦！" % [na.name, nb.name])
	war_policy.spawn_supply_bases(nation_a_id, nation_b_id)

func _spawn_supply_base(nation_a_id: int, nation_b_id: int) -> void:
	war_policy.spawn_supply_bases(nation_a_id, nation_b_id)

func _process_ongoing_war() -> void:
	var na = world.get_nation(world.war_nation_a)
	var nb = world.get_nation(world.war_nation_b)
	if na == null or nb == null or not na.active or not nb.active:
		_end_war_cleanup()
		return
	world.war_days_left -= 1
	for base_id in war_policy.get_active_base_ids():
		var base = world.get_settlement(base_id)
		if base and base.active:
			base.food_demand = min(base.food_demand + 1.8, 40.0)
			base.fuel_demand = min(base.fuel_demand + 1.5, 35.0)
	if world.war_days_left <= 0:
		_resolve_war()

func _resolve_war() -> void:
	var na = world.get_nation(world.war_nation_a)
	var nb = world.get_nation(world.war_nation_b)
	if na == null or nb == null or not na.active or not nb.active:
		_end_war_cleanup()
		return
	na.recalculate_power(world.settlements)
	nb.recalculate_power(world.settlements)
	var score_a = na.power * (0.65 + na.stability * 0.35) + na.war_bonus * 12.0 + world.rng.randf_range(-8.0, 12.0)
	var score_b = nb.power * (0.65 + nb.stability * 0.35) + nb.war_bonus * 12.0 + world.rng.randf_range(-8.0, 12.0)
	var winner: Nation = na if score_a >= score_b else nb
	var loser: Nation = nb if score_a >= score_b else na
	var extreme_upset := false
	# Very rare independent upset: preserves the design space where a tiny state can beat a great power.
	if world.rng.randf() < 0.005 and absf(na.power - nb.power) > 10.0:
		winner = na if na.power < nb.power else nb
		loser = nb if winner == na else na
		extreme_upset = true
		world.add_event("[大番狂わせ] 劣勢だった%sが戦争に勝利" % winner.name)
	world.add_event("%s勝利！ (スコア %.1f vs %.1f)" % [winner.name, max(score_a, score_b), min(score_a, score_b)])
	world.add_event("補給補正: %s=%.2f / %s=%.2f" % [na.name, na.war_bonus, nb.name, nb.war_bonus])
	var loser_cities: Array = []
	for s in world.settlements:
		if s.active and not s.is_supply_base and s.nation_id == loser.id:
			loser_cities.append(s)
	if not loser_cities.is_empty():
		var collapse := world.rng.randf() < 0.005
		var transfer_count := loser_cities.size() if collapse else 1
		for i in range(transfer_count):
			if loser_cities.is_empty():
				break
			var index := world.rng.randi_range(0, loser_cities.size() - 1)
			var transferred = loser_cities[index]
			loser_cities.remove_at(index)
			transferred.nation_id = winner.id
			transferred.economy_state = Settlement.EconomyState.RECESSION
			transferred.population *= 0.92
			transferred.economy *= 0.88
			transferred.war_damage = min(0.9, transferred.war_damage + 0.12)
			transferred.reconstruction_demand += 5.0
			world.add_event("都市%sの所属が%sから%sへ変更" % [transferred.name, loser.name, winner.name])
		if collapse:
			loser.active = false
			world.add_event("[国家崩壊] %sは戦争結果により解体" % loser.name)
		winner.stability = clamp(winner.stability + (0.03 if extreme_upset else 0.05), 0.3, 0.95)
		loser.stability = clamp(loser.stability - 0.12, 0.2, 0.9)
	else:
		world.add_event("譲渡可能な都市がありませんでした。")
	for n in world.nations:
		if n.active:
			n.recalculate_power(world.settlements)
	if world.ground != null:
		world.ground.paint_nation_ownership_from_settlements()
	_end_war_cleanup()

func _end_war_cleanup() -> void:
	war_policy.finalize_bases()
	world.war_active = false
	world.war_nation_a = -1
	world.war_nation_b = -1
	world.war_days_left = 0
	for n in world.nations:
		n.is_at_war = false
		n.war_opponent_id = -1
		n.war_bonus = 0.0
	world.add_event("戦争が終結しました。")
