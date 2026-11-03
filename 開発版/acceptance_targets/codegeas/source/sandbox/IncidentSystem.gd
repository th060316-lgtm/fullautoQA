extends RefCounted
## Generic incident/objective/consequence lifecycle over campaign data.

const TERMINAL: Array[String] = ["resolved", "failed", "expired"]
const TRANSITIONS: Dictionary = {
	"hidden": ["discovered", "expired"],
	"discovered": ["available", "expired"],
	"available": ["active", "failed", "expired"],
	"active": ["resolved", "failed", "expired"],
	"resolved": [], "failed": [], "expired": [],
}

static func register(campaign: Dictionary, definition: Dictionary, now_total_minutes: int) -> bool:
	var incident_id := str(definition.get("id", ""))
	if incident_id.is_empty() or campaign.get("incidents", {}).has(incident_id):
		return false
	var incident := definition.duplicate(true)
	incident["status"] = str(definition.get("initial_status", "hidden"))
	if not TRANSITIONS.has(incident["status"]):
		return false
	incident["progress"] = {}
	incident["created_at"] = now_total_minutes
	var duration := int(definition.get("deadline_minutes", 0))
	incident["deadline_at"] = now_total_minutes + duration if duration > 0 else -1
	campaign["incidents"][incident_id] = incident
	return true

static func transition(campaign: Dictionary, incident_id: String, next_status: String) -> bool:
	var incidents: Dictionary = campaign.get("incidents", {})
	if not incidents.has(incident_id):
		return false
	var incident: Dictionary = incidents[incident_id]
	var current := str(incident.get("status", "hidden"))
	var allowed: Array = TRANSITIONS.get(current, [])
	if next_status not in allowed:
		return false
	incident["status"] = next_status
	incidents[incident_id] = incident
	campaign["incidents"] = incidents
	return true

static func expire_due(campaign: Dictionary, now_total_minutes: int) -> Array[String]:
	var expired: Array[String] = []
	for incident_id in campaign.get("incidents", {}).keys():
		var incident: Dictionary = campaign["incidents"][incident_id]
		var deadline := int(incident.get("deadline_at", -1))
		if deadline >= 0 and now_total_minutes >= deadline and str(incident.get("status", "")) not in TERMINAL:
			if transition(campaign, str(incident_id), "expired"):
				expired.append(str(incident_id))
	return expired

static func set_objective_progress(campaign: Dictionary, incident_id: String, objective_id: String, value: int) -> bool:
	var incident: Dictionary = campaign.get("incidents", {}).get(incident_id, {})
	if str(incident.get("status", "")) != "active":
		return false
	var valid := false
	for objective in incident.get("objectives", []):
		if str(objective.get("id", "")) == objective_id:
			valid = true
			break
	if not valid:
		return false
	incident["progress"][objective_id] = maxi(0, value)
	campaign["incidents"][incident_id] = incident
	return true
