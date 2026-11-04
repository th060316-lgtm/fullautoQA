class_name CompetitionResolver
extends RefCounted

const W_SPEED := 0.35
const W_CAPACITY := 0.30
const W_FREQUENCY := 0.20
var world: WorldState

func _init(p_world: WorldState) -> void:
	world = p_world

func market_key(a: int, b: int) -> int:
	return mini(a, b) * 100000 + maxi(a, b)

func _actor_key(route) -> String:
	if route.cooperation_group >= 0:
		return "g:%d" % route.cooperation_group
	return "c:%d" % route.company_id

func score_connection(route) -> float:
	var speed_score: float = route.speed / TransportModeConfig.SPEED_REF
	var cap_score: float = route.capacity / TransportModeConfig.CAPACITY_REF
	var freq_score: float = min(1.0, route.capacity / 12.0)
	var rep := 1.0
	var comp = world.get_company(route.company_id)
	if comp != null:
		rep = comp.reputation
	var cooperation_bonus := 1.05 if route.cooperation_group >= 0 else 1.0
	return (W_SPEED * speed_score + W_CAPACITY * cap_score + W_FREQUENCY * freq_score) \
		* rep * route.route_value_multiplier * cooperation_bonus

func refresh_scores() -> void:
	for r in world.routes:
		if r.is_operational(world):
			r.service_score = score_connection(r)
		else:
			r.service_score = 0.0

func _actor_scores(routes: Array) -> Dictionary:
	var result := {}
	for r in routes:
		if not r.is_operational(world):
			continue
		var key := _actor_key(r)
		result[key] = float(result.get(key, 0.0)) + maxf(0.0001, float(r.service_score))
	return result

func compute_market_shares() -> Dictionary:
	var pairs := build_market_index()
	var result := {}
	for key in pairs:
		var routes: Array = pairs[key].routes
		var actors := _actor_scores(routes)
		var total := 0.0
		for actor in actors:
			total += float(actors[actor])
		if total <= 0.0:
			continue
		var shares := {}
		for r in routes:
			if not r.is_operational(world):
				continue
			var actor := _actor_key(r)
			var actor_score: float = float(actors.get(actor, 0.0))
			if actor_score <= 0.0:
				continue
			var actor_share: float = actor_score / total
			var within: float = maxf(0.0001, float(r.service_score)) / actor_score
			shares[r.company_id] = float(shares.get(r.company_id, 0.0)) + actor_share * within
		result[key] = shares
	return result

func compute_connection_shares() -> Dictionary:
	var pairs := build_market_index()
	var result := {}
	for key in pairs:
		var routes: Array = pairs[key].routes
		var actors := _actor_scores(routes)
		var total := 0.0
		for actor in actors:
			total += float(actors[actor])
		if total <= 0.0:
			continue
		for r in routes:
			if not r.is_operational(world):
				continue
			var actor := _actor_key(r)
			var actor_score: float = float(actors.get(actor, 0.0))
			if actor_score <= 0.0:
				continue
			var actor_share: float = actor_score / total
			var within: float = maxf(0.0001, float(r.service_score)) / actor_score
			result[r.id] = actor_share * within
			r.market_share = float(result[r.id])
	return result

func build_market_index() -> Dictionary:
	var pairs := {}
	for r in world.routes:
		if not r.is_operational(world):
			continue
		var a: int = r.from_id
		var b: int = r.to_id
		if a == b:
			continue
		var key := market_key(a, b)
		if not pairs.has(key):
			pairs[key] = {"a": mini(a, b), "b": maxi(a, b), "routes": []}
		pairs[key].routes.append(r)
	return pairs

func distribute(routes: Array, demand: float, cargo: int) -> Array:
	var result: Array = []
	if demand <= 0.0 or routes.is_empty():
		return result
	var actors := _actor_scores(routes)
	var total := 0.0
	for actor in actors:
		total += float(actors[actor])
	if total <= 0.0:
		return result
	for actor in actors:
		var actor_score: float = float(actors[actor])
		var actor_demand: float = demand * (actor_score / total)
		var actor_routes: Array = []
		for r in routes:
			if r.is_operational(world) and _actor_key(r) == actor:
				actor_routes.append(r)
		if actor_routes.is_empty():
			continue

		# First pass: score-proportional allocation.
		var allocated: Dictionary = {}
		var moved_total := 0.0
		for r in actor_routes:
			var target: float = actor_demand * (maxf(0.0001, float(r.service_score)) / actor_score)
			var route_cap: float = minf(r.remaining_capacity(),
				TransportModeConfig.daily_cap(cargo, r.type) * r.route_value_multiplier)
			var moved: float = minf(target, route_cap)
			allocated[r.id] = moved
			moved_total += moved

		# Second pass: unused demand is pooled inside the company/cooperation group.
		# This is the actual cooperation effect: one member's saturated route can
		# hand demand to another member with spare capacity.
		var remaining: float = maxf(0.0, actor_demand - moved_total)
		if remaining > 0.0001:
			for r in actor_routes:
				if remaining <= 0.0001:
					break
				var already: float = float(allocated.get(r.id, 0.0))
				var route_cap: float = minf(r.remaining_capacity(),
					TransportModeConfig.daily_cap(cargo, r.type) * r.route_value_multiplier)
				var spare: float = maxf(0.0, route_cap - already)
				if spare <= 0.0001:
					continue
				var extra: float = minf(remaining, spare)
				allocated[r.id] = already + extra
				remaining -= extra

		for r in actor_routes:
			var moved: float = float(allocated.get(r.id, 0.0))
			if moved > 0.0001:
				result.append([r, moved])
	return result

func get_company_share(market: int, company_id: int) -> float:
	var shares := compute_market_shares()
	if not shares.has(market):
		return 0.0
	return float(shares[market].get(company_id, 0.0))
