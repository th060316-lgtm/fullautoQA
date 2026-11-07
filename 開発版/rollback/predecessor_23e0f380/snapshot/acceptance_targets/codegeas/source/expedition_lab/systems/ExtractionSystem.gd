extends RefCounted

func start_retreat(state) -> Dictionary:
	state.retreat_started=true
	state.phase="retreat"
	state.metrics["retreat_started"]=true
	return {"ok":true,"primary":preload("res://expedition_lab/ExpeditionFixture.gd").EXTRACTION_PRIMARY,"backup":preload("res://expedition_lab/ExpeditionFixture.gd").EXTRACTION_BACKUP}

func evaluate(state, point: Vector2, radius: float=55.0) -> Dictionary:
	if not state.retreat_started:
		return {"ok":false,"reason":"retreat_not_started"}
	var human_ids: Array[String] = []
	for actor in state.actors.values():
		if actor.team == "player" and actor.kind == "human": human_ids.append(actor.id)
	var returned: Array[String]=[]
	for id in human_ids:
		var actor=state.actors.get(id)
		if actor!=null and actor.is_active() and not actor.incapacitated and actor.position.distance_to(point)<=radius:
			returned.append(id)
	for id in human_ids:
		if returned.has(id): continue
		var actor=state.actors.get(id)
		if actor==null or not actor.incapacitated: continue
		var carrier_id:=str(actor.meta.get("carried_by",""))
		if returned.has(carrier_id) and actor.position.distance_to(point)<=radius:
			returned.append(id)
	if not returned.has("hero"):
		return {"ok":false,"reason":"hero_not_at_extraction","returned":returned}
	var left_behind: Array[String]=[]
	for id in human_ids:
		if not returned.has(id): left_behind.append(id)
	for rescue_id in state.rescue_targets.keys():
		var row: Dictionary=state.rescue_targets[rescue_id]
		if str(row.get("status",""))=="escorted" and returned.has(str(row.get("carrier_id",""))):
			row["status"]="extracted"
			state.rescue_targets[rescue_id]=row
	var kmf=state.actors.get("friendly_kmf")
	state.abandoned_kmf = kmf==null or kmf.position.distance_to(point)>radius or not kmf.is_active()
	state.metrics["kmf_abandoned"]=1 if state.abandoned_kmf else 0
	state.metrics["returned_ids"]=returned.duplicate()
	state.metrics["left_behind_ids"]=left_behind.duplicate()
	state.retreat_success=true
	state.metrics["retreat_success"]=true
	state.phase="complete"
	return {"ok":true,"retreat_success":true,"returned":returned,"left_behind":left_behind,"kmf_abandoned":state.abandoned_kmf}
