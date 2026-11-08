extends RefCounted

var last_action_time: Dictionary = {}

func tick(state, order_system, perception, _delta: float) -> Array:
	var reports: Array=[]
	for actor in state.actors.values():
		if actor.team != "player" or actor.kind != "human" or actor.id == "hero":
			continue
		if not actor.is_active() or actor.incapacitated:
			continue
		var id: String = actor.id
		var role: String = state.orders.get_role(id)
		if role=="Scout":
			for event in perception.scan(state,id):
				if bool(event.get("changed",false)):
					reports.append(event)
		elif role=="Medic" and not _danger_near(state,actor.position,190.0):
			for target in state.actors.values():
				if target.team=="player" and target.kind=="human" and actor.position.distance_to(target.position)<70.0:
					if target.incapacitated:
						reports.append({"kind":"medic_ready","target":target.id})
					elif _has_treatable_damage(target) and _ready(id,state.sim_time,2.0):
						var treatment := _restore_part_hp(target,4.0)
						if bool(treatment.get("applied",false)):
							reports.append({"kind":"treated","target":target.id,"part_id":treatment.get("part_id",""),"amount":treatment.get("amount",0.0)})
		elif role=="Repair" and not _danger_near(state,actor.position,220.0):
			var kmf=state.actors.get("friendly_kmf")
			if kmf!=null and actor.position.distance_to(kmf.position)<75.0 and _has_treatable_damage(kmf) and _ready(id,state.sim_time,2.5):
				var repair := _restore_part_hp(kmf,5.0)
				if bool(repair.get("applied",false)):
					reports.append({"kind":"repaired","target":"friendly_kmf","part_id":repair.get("part_id",""),"amount":repair.get("amount",0.0)})
		elif role=="Guard" and _ready(id,state.sim_time,1.6):
			for contact in state.knowledge.visible_contacts():
				if str(contact.get("status",""))=="confirmed":
					var enemy=state.actors.get(str(contact.get("id","")))
					if enemy!=null and enemy.is_active() and not enemy.incapacitated and actor.position.distance_to(enemy.position)<230.0:
						reports.append({"kind":"guard_attack","source":id,"target":enemy.id})
						break
		elif role=="Follow":
			var leader=state.actors.get("hero")
			if leader!=null and actor.position.distance_to(leader.position)>110.0 and state.orders.peek(id).is_empty():
				var side := 35.0 if abs(id.hash()) % 2 == 0 else -35.0
				order_system.issue_move(state,id,leader.position+Vector2(-45.0,side))
	return reports


func _has_treatable_damage(target) -> bool:
	for part in target.body.get("parts",{}).values():
		if bool(part.get("destroyed",false)):
			continue
		if float(part.get("hp",0.0)) < float(part.get("max_hp",0.0)):
			return true
	return false

func _restore_part_hp(target, amount: float) -> Dictionary:
	var parts: Dictionary = target.body.get("parts",{})
	var best_id := ""
	var best_ratio := 2.0
	for part_id in parts.keys():
		var part: Dictionary = parts[part_id]
		if bool(part.get("destroyed",false)):
			continue
		var max_hp := float(part.get("max_hp",0.0))
		var hp := float(part.get("hp",0.0))
		if max_hp <= 0.0 or hp >= max_hp:
			continue
		var ratio := hp / max_hp
		if ratio < best_ratio:
			best_ratio = ratio
			best_id = str(part_id)
	if best_id.is_empty():
		return {"applied":false}
	var selected: Dictionary = parts[best_id]
	var before := float(selected.get("hp",0.0))
	var after := minf(float(selected.get("max_hp",0.0)),before+amount)
	selected["hp"] = after
	parts[best_id] = selected
	target.body["parts"] = parts
	var restored := after-before
	target.hp = minf(target.max_hp,target.hp+restored)
	return {"applied":restored>0.0,"part_id":best_id,"amount":restored}

func _ready(actor_id: String, sim_time: float, interval: float) -> bool:
	if sim_time-float(last_action_time.get(actor_id,-1000.0))<interval:
		return false
	last_action_time[actor_id]=sim_time
	return true

func _danger_near(state, position: Vector2, radius: float) -> bool:
	for contact in state.knowledge.visible_contacts():
		if not str(contact.get("status","")) in ["estimated","confirmed","lost_contact"]:
			continue
		var contact_position: Vector2 = contact.get("estimated_position",Vector2.ZERO)
		if contact_position.distance_to(position)<radius:
			return true
	return false
