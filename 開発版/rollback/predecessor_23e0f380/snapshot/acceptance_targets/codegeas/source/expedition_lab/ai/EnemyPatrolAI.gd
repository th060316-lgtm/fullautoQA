extends RefCounted

const Fixture=preload("res://expedition_lab/ExpeditionFixture.gd")

var indices: Dictionary={}
var last_attack_time: Dictionary={}

func reset() -> void:
	indices.clear()
	last_attack_time.clear()

func tick(state, delta: float) -> Array:
	var events: Array=[]
	for id in state.enemy_truth.keys():
		var enemy=state.actors.get(id)
		var truth: Dictionary=state.enemy_truth[id]
		if enemy==null or not enemy.is_active() or enemy.incapacitated:
			continue
		var effects: Dictionary=enemy.get_effects()
		var nearest_id:=""
		var nearest_distance:=1.0e20
		for friendly_id in ["hero","scout","medic","friendly_kmf"]:
			var friendly=state.actors.get(friendly_id)
			if friendly==null or not friendly.is_active() or friendly.incapacitated:
				continue
			if friendly.kind=="human" and not str(friendly.meta.get("inside_kmf","")).is_empty():
				continue
			var distance: float=friendly.position.distance_to(enemy.position)
			if distance<nearest_distance:
				nearest_distance=distance
				nearest_id=friendly_id

		var detection_range:=165.0*float(effects.get("detection_multiplier",1.0))
		if not nearest_id.is_empty() and nearest_distance<detection_range and not bool(truth.get("alerted",false)):
			truth["alerted"]=true
			truth["engage_after"]=state.sim_time+0.6
			events.append({"kind":"enemy_detected_player","enemy_id":id})

		var immobilized:=bool(effects.get("immobilized",false))
		var attack_range:=220.0 if enemy.kind=="human" else 320.0
		if bool(truth.get("alerted",false)) and not nearest_id.is_empty():
			var target_actor=state.actors.get(nearest_id)
			if not immobilized and nearest_distance>attack_range*0.75:
				enemy.position=enemy.position.move_toward(target_actor.position,(52.0 if enemy.kind=="human" else 78.0)*float(effects.get("mobility_multiplier",1.0))*delta)
			elif nearest_distance<=attack_range and state.sim_time>=float(truth.get("engage_after",-1.0)) and not bool(effects.get("weapon_disabled",false)) and _line_clear(enemy.position,target_actor.position):
				var interval:=2.2 if enemy.kind=="human" else 1.6
				if state.sim_time-float(last_attack_time.get(id,-1000.0))>=interval:
					last_attack_time[id]=state.sim_time
					events.append({"kind":"enemy_attack","enemy_id":id,"target_id":nearest_id,"amount":6.0 if enemy.kind=="human" else 14.0})
		elif not immobilized:
			var patrol: Array=truth.get("patrol",[])
			if not patrol.is_empty():
				var idx:=int(indices.get(id,0))%patrol.size()
				var target: Vector2=patrol[idx]
				enemy.position=enemy.position.move_toward(target,(52.0 if enemy.kind=="human" else 78.0)*float(effects.get("mobility_multiplier",1.0))*delta)
				if enemy.position.distance_to(target)<3.0:
					indices[id]=(idx+1)%patrol.size()
		truth["position"]=enemy.position
		state.enemy_truth[id]=truth
	return events

func _line_clear(start: Vector2, target: Vector2) -> bool:
	var distance:=start.distance_to(target)
	var steps:=maxi(1,int(ceil(distance/16.0)))
	for i in range(steps+1):
		var p:=start.lerp(target,float(i)/float(steps))
		for rect in Fixture.BLOCKED_RECTS:
			if rect.has_point(p):
				return false
	return true
