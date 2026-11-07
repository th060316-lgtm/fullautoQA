extends RefCounted

func collect_loot(state, actor_id: String, loot_id: String) -> Dictionary:
	var actor=state.actors.get(actor_id); var row: Dictionary=state.loot.get(loot_id,{})
	if actor==null or actor.incapacitated or row.is_empty() or bool(row.get("taken",false)): return {"ok":false}
	if actor.position.distance_to(row.get("position",Vector2.ZERO))>54.0: return {"ok":false,"reason":"out_of_range"}
	row["taken"]=true; state.loot[loot_id]=row; state.acquired_loot.append(loot_id); state.metrics["loot_acquired"]=int(state.metrics.get("loot_acquired",0))+1
	return {"ok":true,"loot_id":loot_id}

func acquire_intel(state, actor_id: String, source_id: String) -> Dictionary:
	var actor=state.actors.get(actor_id); var row: Dictionary=state.intel_sources.get(source_id,{})
	if actor==null or actor.incapacitated or row.is_empty() or bool(row.get("examined",false)): return {"ok":false}
	if actor.position.distance_to(row.get("position",Vector2.ZERO))>60.0: return {"ok":false,"reason":"out_of_range"}
	row["examined"]=true; state.intel_sources[source_id]=row; state.acquired_intel.append(source_id); state.primary_progress+=1
	return {"ok":true,"source_id":source_id}

func rescue(state, actor_id: String, target_id: String) -> Dictionary:
	var actor=state.actors.get(actor_id); var row: Dictionary=state.rescue_targets.get(target_id,{})
	if actor==null or actor.incapacitated or row.is_empty() or str(row.get("status",""))!="waiting": return {"ok":false}
	if actor.position.distance_to(row.get("position",Vector2.ZERO))>65.0: return {"ok":false,"reason":"out_of_range"}
	row["status"]="escorted"; row["carrier_id"]=actor_id; row["position"]=actor.position+Vector2(16,12)
	state.rescue_targets[target_id]=row; state.metrics["rescues"]=int(state.metrics.get("rescues",0))+1
	return {"ok":true,"target_id":target_id}

func board(state, actor_id: String, kmf_id: String) -> Dictionary:
	var actor=state.actors.get(actor_id); var kmf=state.actors.get(kmf_id)
	if actor==null or kmf==null or actor.kind!="human" or kmf.kind!="kmf":
		return {"ok":false,"reason":"invalid_actor"}
	if actor.incapacitated or kmf.destroyed or not kmf.is_active():
		return {"ok":false,"reason":"unavailable"}
	if not str(kmf.meta.get("pilot_id","")).is_empty():
		return {"ok":false,"reason":"occupied"}
	if not str(actor.meta.get("carrying","")).is_empty():
		return {"ok":false,"reason":"carrying_casualty"}
	if actor.position.distance_to(kmf.position)>56.0:
		return {"ok":false,"reason":"out_of_range"}
	state.orders.pop(actor_id)
	kmf.meta["pilot_id"]=actor_id
	kmf.meta["boarded"]=true
	actor.meta["inside_kmf"]=kmf_id
	actor.position=kmf.position
	return {"ok":true}

func dismount(state, actor_id: String, kmf_id: String) -> Dictionary:
	var actor=state.actors.get(actor_id); var kmf=state.actors.get(kmf_id)
	if actor==null or kmf==null or str(kmf.meta.get("pilot_id",""))!=actor_id:
		return {"ok":false}
	state.orders.pop(kmf_id)
	actor.position=kmf.position+Vector2(-42,0)
	actor.meta.erase("inside_kmf")
	kmf.meta["pilot_id"]=""
	kmf.meta["boarded"]=false
	return {"ok":true}

func carry(state, carrier_id: String, casualty_id: String) -> Dictionary:
	var carrier=state.actors.get(carrier_id); var casualty=state.actors.get(casualty_id)
	if carrier==null or casualty==null or carrier.kind!="human" or not casualty.incapacitated:
		return {"ok":false}
	if carrier.incapacitated or carrier.position.distance_to(casualty.position)>65.0:
		return {"ok":false,"reason":"out_of_range"}
	if not str(carrier.meta.get("inside_kmf","")).is_empty():
		return {"ok":false,"reason":"inside_kmf"}
	carrier.meta["carrying"]=casualty_id
	carrier.meta["carry_speed_multiplier"]=0.62
	casualty.meta["carried_by"]=carrier_id
	casualty.position=carrier.position
	state.orders.pop(casualty_id)
	return {"ok":true,"state":"carried","speed_multiplier":0.62}
