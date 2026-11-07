extends RefCounted

const Fixture = preload("res://expedition_lab/ExpeditionFixture.gd")
const CELL_SIZE := 32
const GRID_WIDTH := 40
const GRID_HEIGHT := 25

func _movement_speed(actor) -> float:
	var effects: Dictionary = actor.get_effects()
	var speed := float(actor.meta.get("speed", 80.0)) * float(effects.get("mobility_multiplier",1.0))
	if actor.kind == "human":
		var parts: Dictionary = actor.body.get("parts", {})
		if bool(parts.get("left_leg",{}).get("destroyed",false)) or bool(parts.get("right_leg",{}).get("destroyed",false)):
			speed *= 0.55
		speed *= float(actor.meta.get("carry_speed_multiplier",1.0))
	elif actor.kind == "kmf":
		var energy: Dictionary = actor.body.get("parts",{}).get("energy",{})
		if bool(energy.get("destroyed",false)):
			speed *= 0.6
	speed *= float(actor.meta.get("suppression_mobility", 1.0))
	return maxf(1.0, speed)

func _validate_actor(state, actor_id: String):
	var actor = state.actors.get(actor_id)
	if actor == null:
		return {"ok":false,"reason":"no_actor"}
	if actor.incapacitated or actor.destroyed:
		return {"ok":false,"reason":"incapacitated"}
	if actor.kind == "human":
		var kmf_id := str(actor.meta.get("inside_kmf",""))
		if not kmf_id.is_empty():
			var kmf = state.actors.get(kmf_id)
			if kmf == null or str(kmf.meta.get("pilot_id","")) != actor_id:
				return {"ok":false,"reason":"invalid_boarding_state"}
			return {"ok":true,"actor":kmf,"redirected_from":actor_id}
	if actor.kind == "kmf" and not bool(actor.meta.get("boarded",false)):
		return {"ok":false,"reason":"kmf_unoccupied"}
	if bool(actor.get_effects().get("immobilized",false)):
		return {"ok":false,"reason":"immobilized"}
	return {"ok":true,"actor":actor}

func preview_move(state, actor_id: String, destination: Vector2, waypoints: Array = []) -> Dictionary:
	var valid: Dictionary = _validate_actor(state, actor_id)
	if not bool(valid.get("ok", false)):
		return valid
	var actor = valid["actor"]
	var bounded := Vector2(clampf(destination.x,16.0,1264.0),clampf(destination.y,16.0,784.0))
	var points: Array = waypoints.duplicate()
	points.append(bounded)
	var full_path: Array = []
	var cursor: Vector2 = actor.position
	for point in points:
		var p: Vector2 = point
		p = Vector2(clampf(p.x,16.0,1264.0),clampf(p.y,16.0,784.0))
		var leg := _build_path(cursor, p)
		if leg.is_empty():
			return {"ok":false,"reason":"no_path"}
		for v in leg:
			if full_path.is_empty() or (full_path.back() as Vector2).distance_to(v) > 0.5:
				full_path.append(v)
		cursor = p
	var speed := _movement_speed(actor)
	return {"ok":true,"actor_id":actor.id,"destination":bounded,"path":full_path,"eta":_path_distance(actor.position,full_path)/speed,"speed":speed,"controlled_actor_id":actor.id}

func issue_move(state, actor_id: String, destination: Vector2) -> Dictionary:
	return issue_intent_move(state, actor_id, destination, "MOVE", [], {})

func issue_intent_move(state, actor_id: String, destination: Vector2, intent: String, waypoints: Array = [], extra_meta: Dictionary = {}) -> Dictionary:
	var preview := preview_move(state, actor_id, destination, waypoints)
	if not bool(preview.get("ok", false)):
		return preview
	var actual_id := str(preview.get("controlled_actor_id", actor_id))
	var replaced := str(state.orders.peek(actual_id).get("kind", "")) == "move"
	state.metrics["number_of_orders"] = int(state.metrics.get("number_of_orders",0)) + 1
	state.metrics["movement_orders"] = int(state.metrics.get("movement_orders",0)) + 1
	if replaced:
		state.metrics["repaths"] = int(state.metrics.get("repaths",0)) + 1
	var meta := {"speed":float(preview["speed"]),"path":preview["path"],"path_index":0,"intent":intent,"waypoints":waypoints.duplicate()}
	for key in extra_meta.keys():
		meta[key] = extra_meta[key]
	var order: Dictionary = state.orders.issue(actual_id,"move",preview["destination"],float(preview["eta"]),meta)
	return {"ok":true,"eta":preview["eta"],"path":(preview["path"] as Array).duplicate(),"order":order,"replaced":replaced,"controlled_actor_id":actual_id,"intent":intent}

func cancel_move(state, actor_id: String) -> Dictionary:
	var order: Dictionary = state.orders.peek(actor_id)
	if str(order.get("kind", "")) != "move":
		return {"ok": false, "reason": "no_active_move"}
	state.orders.pop(actor_id)
	state.metrics["cancelled_orders"] = int(state.metrics.get("cancelled_orders", 0)) + 1
	return {"ok": true, "actor_id": actor_id, "destination": order.get("target", Vector2.ZERO)}

func issue_role(state, actor_id: String, role: String) -> Dictionary:
	var actor = state.actors.get(actor_id)
	if actor == null or actor.team != "player":
		return {"ok":false,"reason":"invalid_actor"}
	if not role in ["Follow","Scout","Guard","Medic","Repair","HoldFire"]:
		return {"ok":false,"reason":"invalid_role"}
	state.orders.set_role(actor_id,role)
	state.metrics["number_of_orders"] = int(state.metrics.get("number_of_orders",0))+1
	return {"ok":true,"role":role}

func tick_movement(state, actor_id: String, delta: float) -> bool:
	var actor = state.actors.get(actor_id)
	var order: Dictionary = state.orders.peek(actor_id)
	if actor == null or actor.incapacitated or actor.destroyed or str(order.get("kind","")) != "move":
		return false
	if actor.kind == "human" and not str(actor.meta.get("inside_kmf","")).is_empty():
		state.orders.pop(actor_id)
		return false
	if actor.kind == "kmf" and not bool(actor.meta.get("boarded",false)):
		state.orders.pop(actor_id)
		return false
	var meta: Dictionary = order.get("meta",{})
	var path: Array = meta.get("path",[])
	var path_index := int(meta.get("path_index",0))
	if path_index >= path.size():
		state.orders.pop(actor_id)
		return true
	var target: Vector2 = path[path_index]
	var speed := float(meta.get("speed",80.0)) * float(actor.meta.get("suppression_mobility",1.0))
	actor.position = actor.position.move_toward(target,speed*delta)
	order["remaining"] = maxf(0.0,float(order.get("remaining",0.0))-delta)
	if actor.position.distance_to(target) <= 1.0:
		actor.position=target
		path_index+=1
		meta["path_index"]=path_index
		order["meta"]=meta
		if path_index>=path.size():
			state.orders.pop(actor_id)
			_sync_dependents(state,actor)
			return true
	state.orders.replace_front(actor_id,order)
	_sync_dependents(state,actor)
	return false

func _sync_dependents(state, actor) -> void:
	if actor.kind == "kmf":
		var pilot_id := str(actor.meta.get("pilot_id",""))
		var pilot = state.actors.get(pilot_id)
		if pilot != null:
			pilot.position = actor.position
	if actor.kind == "human":
		var casualty_id := str(actor.meta.get("carrying",""))
		var casualty = state.actors.get(casualty_id)
		if casualty != null:
			casualty.position = actor.position
		for rescue_id in state.rescue_targets.keys():
			var row: Dictionary = state.rescue_targets[rescue_id]
			if str(row.get("status",""))=="escorted" and str(row.get("carrier_id",""))==actor.id:
				row["position"]=actor.position+Vector2(16,12)
				state.rescue_targets[rescue_id]=row

func _build_path(start: Vector2, destination: Vector2) -> Array:
	if _point_blocked(destination):
		return []
	if _direct_path_clear(start,destination):
		return [destination]
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(0,0,GRID_WIDTH,GRID_HEIGHT)
	grid.cell_size = Vector2(CELL_SIZE,CELL_SIZE)
	grid.offset = Vector2(CELL_SIZE*0.5,CELL_SIZE*0.5)
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	grid.update()
	for x in range(GRID_WIDTH):
		for y in range(GRID_HEIGHT):
			var center:=Vector2(x*CELL_SIZE+CELL_SIZE*0.5,y*CELL_SIZE+CELL_SIZE*0.5)
			if _point_blocked(center):
				grid.set_point_solid(Vector2i(x,y),true)
	var start_id:=_cell_for(start)
	var end_id:=_cell_for(destination)
	grid.set_point_solid(start_id,false)
	var raw: PackedVector2Array=grid.get_point_path(start_id,end_id)
	if raw.is_empty():
		return []
	var out: Array=[]
	for i in range(1,raw.size()):
		out.append(raw[i])
	if out.is_empty() or (out[out.size()-1] as Vector2).distance_to(destination)>1.0:
		out.append(destination)
	return out

func _direct_path_clear(start: Vector2, destination: Vector2) -> bool:
	var distance:=start.distance_to(destination)
	var steps:=maxi(1,int(ceil(distance/16.0)))
	for i in range(steps+1):
		if _point_blocked(start.lerp(destination,float(i)/float(steps))):
			return false
	return true

func _point_blocked(point: Vector2) -> bool:
	for rect in Fixture.BLOCKED_RECTS:
		if rect.has_point(point):
			return true
	return false

func _cell_for(point: Vector2) -> Vector2i:
	return Vector2i(clampi(int(floor(point.x/CELL_SIZE)),0,GRID_WIDTH-1),clampi(int(floor(point.y/CELL_SIZE)),0,GRID_HEIGHT-1))

func _path_distance(start: Vector2, path: Array) -> float:
	var total:=0.0
	var cursor:=start
	for point in path:
		var next: Vector2=point
		total+=cursor.distance_to(next)
		cursor=next
	return total
