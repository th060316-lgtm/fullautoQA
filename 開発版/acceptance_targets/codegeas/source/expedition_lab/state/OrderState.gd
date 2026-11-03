extends RefCounted

var queues: Dictionary = {}
var roles: Dictionary = {}

func clear() -> void:
	queues.clear()
	roles.clear()

func set_role(actor_id: String, role: String) -> void:
	roles[actor_id] = role

func get_role(actor_id: String) -> String:
	return str(roles.get(actor_id, "Follow"))

func issue(actor_id: String, kind: String, target: Variant, eta: float, meta: Dictionary = {}) -> Dictionary:
	var order := {"actor_id": actor_id, "kind": kind, "target": target, "eta": maxf(0.0, eta), "remaining": maxf(0.0, eta), "meta": meta.duplicate(true)}
	queues[actor_id] = [order]
	return order.duplicate(true)

func peek(actor_id: String) -> Dictionary:
	var queue: Array = queues.get(actor_id, [])
	return {} if queue.is_empty() else (queue[0] as Dictionary).duplicate(true)

func replace_front(actor_id: String, order: Dictionary) -> void:
	var queue: Array = queues.get(actor_id, [])
	if queue.is_empty():
		return
	queue[0] = order.duplicate(true)
	queues[actor_id] = queue

func pop(actor_id: String) -> Dictionary:
	var queue: Array = queues.get(actor_id, [])
	if queue.is_empty(): return {}
	var row: Dictionary = queue.pop_front()
	queues[actor_id] = queue
	return row

func tick(actor_id: String, delta: float) -> Dictionary:
	var queue: Array = queues.get(actor_id, [])
	if queue.is_empty(): return {}
	var row: Dictionary = queue[0]
	row["remaining"] = maxf(0.0, float(row.get("remaining", 0.0)) - delta)
	queue[0] = row
	queues[actor_id] = queue
	return row.duplicate(true)
