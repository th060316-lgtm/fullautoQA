extends RefCounted

const UNKNOWN := "unknown"
const SIGNAL := "signal"
const ESTIMATED := "estimated"
const CONFIRMED := "confirmed"
const LOST_CONTACT := "lost_contact"

var contacts: Dictionary = {}

func reset() -> void:
	contacts.clear()

func observe(contact_id: String, level: String, source: String, confidence: float, sim_time: float, position: Vector2, uncertainty: float) -> Dictionary:
	var previous := str(contacts.get(contact_id, {}).get("status", UNKNOWN))
	var row := {
		"id": contact_id, "status": level, "source": source,
		"confidence": clampf(confidence, 0.0, 1.0),
		"last_confirmed_time": sim_time if level == CONFIRMED else float(contacts.get(contact_id, {}).get("last_confirmed_time", -1.0)),
		"estimated_position": position, "uncertainty_radius": maxf(0.0, uncertainty),
	}
	contacts[contact_id] = row
	return {"changed": previous != level, "previous": previous, "current": level, "contact": row.duplicate(true)}

func decay(sim_time: float) -> void:
	for id in contacts.keys():
		var row: Dictionary = contacts[id]
		var age := sim_time - float(row.get("last_confirmed_time", sim_time))
		if str(row.get("status", UNKNOWN)) == CONFIRMED and age > 8.0:
			row["status"] = LOST_CONTACT
			row["confidence"] = 0.35
			row["uncertainty_radius"] = 96.0
		elif str(row.get("status", UNKNOWN)) == ESTIMATED:
			row["confidence"] = maxf(0.1, float(row.get("confidence", 0.5)) - 0.003)
			row["uncertainty_radius"] = minf(240.0, float(row.get("uncertainty_radius", 64.0)) + 0.25)
		contacts[id] = row

func get_contact(contact_id: String) -> Dictionary:
	return contacts.get(contact_id, {}).duplicate(true)

func visible_contacts() -> Array:
	var out: Array = []
	for row in contacts.values():
		if str(row.get("status", UNKNOWN)) != UNKNOWN:
			out.append((row as Dictionary).duplicate(true))
	return out

func has_exact_truth(contact_id: String) -> bool:
	return str(contacts.get(contact_id, {}).get("status", UNKNOWN)) == CONFIRMED
