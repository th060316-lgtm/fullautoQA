# memory_system.gd — Memory and Information management
# Enforces: systemFacts NEVER modified by memory rewriting.
# npcMemories are NPC subjective and can be modified.
# reports carry sourceId, category, confidence/uncertainty, timestamp.

extends Node

var _gs: Node
var _eb: Node
var _rng: Node

## All confirmed system facts (read-only after write, never modified)
var _system_facts: Dictionary = {}  # fact_id -> {description, timestamp, sourceLocation, verified}

## NPC subjective memories (modifiable by geass effects, conversations, etc.)
## Format: npc_id -> [memory_entry, ...]
var _npc_memories: Dictionary = {}

## Reports: testimonies, rumors, heroine analysis, male friend estimates
## Each report: {id, sourceId, sourceType, content, confidence, uncertainty, timestamp, day, minute, sourceLocation, relatedNpcs, relatedCases, tags}
## sourceType: "direct_observation" | "npc_testimony" | "hearsay" | "remote_report" | "analysis"
## NOTE: truth/is_true NOT exposed to UI - must not reveal definitive truth answers
var _reports: Array = []

## Extended source types for provenance (Phase A extension)
enum ReportSourceType {
	DIRECT_OBSERVATION = 0,
	NPC_TESTIMONY = 1,
	HEARSAY = 2,
	REMOTE_REPORT = 3,
	ANALYSIS = 4,
}

## Report categories
enum ReportCategory {
	TESTIMONY,     # direct observation by NPC
	RUMOR,         # heard from others, unverified
	ANALYSIS,      # heroine's structured analysis
	MALE_FRIEND_ESTIMATE,  # estimated male friend state
	CONTRADICTION, # conflicting reports
	UNCONFIRMED,   # not yet evaluated
}

## Information confidence levels
enum Confidence {
	CERTAIN = 3,   # confirmed by multiple sources / direct observation
	PROBABLE = 2,  # single strong source
	POSSIBLE = 1,  # rumor, unverified
	UNLIKELY = 0,  # contradicted by known facts
}

var _report_counter: int = 0

func _ready() -> void:
	_gs = get_node_or_null("/root/GameState")
	_eb = get_node_or_null("/root/EventBus")
	_rng = get_node_or_null("/root/RngService")

func initialize() -> void:
	_report_counter = 0

## --- SYSTEM FACTS (immutable) ---

func add_system_fact(fact_id: String, description: String, source_location: String = "", verified: bool = true) -> void:
	## KEY INVARIANT: systemFacts are NEVER modified after being written.
	## Memory rewriting affects npcMemories and reports only.
	if _system_facts.has(fact_id):
		return  # Already recorded, don't overwrite
	_system_facts[fact_id] = {
		"id": fact_id,
		"description": description,
		"timestamp": _gs.get_day() if _gs else 1,
		"sourceLocation": source_location,
		"verified": verified,
	}
	_gs.add_system_fact(fact_id, _system_facts[fact_id]) if _gs else null
	print("[Memory] System fact added: %s — %s" % [fact_id, description])
	if _eb:
		_eb.emit_fact_observed(fact_id, _system_facts[fact_id])

func get_system_facts() -> Dictionary:
	return _system_facts.duplicate(true)

func has_system_fact(fact_id: String) -> bool:
	return _system_facts.has(fact_id)

func get_system_fact(fact_id: String) -> Dictionary:
	return _system_facts.get(fact_id, {})

func get_all_system_facts_sorted() -> Array:
	var facts = []
	for fid in _system_facts:
		facts.append(_system_facts[fid])
	facts.sort_custom(func(a, b): return a["timestamp"] < b["timestamp"])
	return facts

## --- NPC MEMORIES (mutable) ---

func add_npc_memory(npc_id: String, memory: Dictionary) -> void:
	## memory keys: content, category, source, emotional_tag, geass_affected
	if not _npc_memories.has(npc_id):
		_npc_memories[npc_id] = []
	
	var entry = memory.duplicate(true)
	entry["id"] = "mem_%s_%d" % [npc_id, _npc_memories[npc_id].size()]
	entry["day"] = _gs.get_day() if _gs else 1
	entry["minute"] = _gs.get_minute_of_day() if _gs else 0
	entry["geass_affected"] = memory.get("geass_affected", false)
	
	_npc_memories[npc_id].append(entry)
	
	# Also update the NPC manager's memory
	var nm = get_node_or_null("/root/NpcManager")
	if nm:
		nm.add_memory(npc_id, entry)
	
	if _eb:
		_eb.memory_modified.emit(npc_id, entry["id"], {}, entry)
		_eb.emit_npc_state_changed(npc_id)
	
	print("[Memory] NPC %s memory added: %s" % [npc_id, memory.get("content", "")])

func modify_npc_memory(npc_id: String, memory_id: String, new_content: String, geass_affected: bool = false) -> void:
	## KEY: This is how geass rewrites memory.
	## systemFacts remain unchanged.
	if not _npc_memories.has(npc_id):
		return
	
	var found = false
	for i in range(_npc_memories[npc_id].size()):
		var entry = _npc_memories[npc_id][i]
		if entry.get("id") == memory_id:
			var old_val = entry.duplicate(true)
			entry["content"] = new_content
			entry["geass_affected"] = geass_affected
			entry["modified"] = true
			entry["modifiedDay"] = _gs.get_day() if _gs else 1
			found = true
			if _eb:
				_eb.memory_modified.emit(npc_id, memory_id, old_val, entry)
			break
	
	# Also update NPC manager
	var nm = get_node_or_null("/root/NpcManager")
	if nm:
		var memories = nm.get_memories(npc_id)
		for i in range(memories.size()):
			if memories[i].get("id") == memory_id:
				memories[i]["content"] = new_content
				memories[i]["geass_affected"] = geass_affected
				break

func get_npc_memories(npc_id: String) -> Array:
	return _npc_memories.get(npc_id, []).duplicate(true)

func clear_npc_memory(npc_id: String) -> void:
	## Wipe all memories for an NPC (used in extreme geass scenarios)
	var old_memories = _npc_memories.get(npc_id, []).duplicate(true)
	_npc_memories[npc_id] = []
	if _eb:
		for mem in old_memories:
			_eb.memory_modified.emit(npc_id, mem.get("id", ""), mem, {})

func get_conflicting_memories(npc_id: String) -> Array:
	## Find memories that contradict each other
	var memories = _npc_memories.get(npc_id, [])
	var conflicts = []
	for i in range(memories.size()):
		for j in range(i + 1, memories.size()):
			var a = memories[i]
			var b = memories[j]
			# Simple heuristic: same category but different content
			if a.get("category") == b.get("category") and a.get("content") != b.get("content"):
				conflicts.append({"mem_a": a, "mem_b": b})
	return conflicts

## --- REPORTS ---

func add_report(
	category: int,
	content: String,
	source_id: String,
	related_npcs: Array = [],
	confidence: int = -1,
	uncertainty: float = 0.5,
	tags: Array = [],
	source_location: String = "",
	source_type: int = -1,
	related_cases: Array = []
) -> Dictionary:
	## confidence = -1 means auto-determine based on category
	## NOTE: truth/is_true NOT included in report output for UI safety
	var actual_conf = confidence
	if actual_conf < 0:
		match category:
			ReportCategory.TESTIMONY:
				actual_conf = Confidence.CERTAIN if _rng and _rng.probability(0.7) else Confidence.PROBABLE
			ReportCategory.RUMOR:
				actual_conf = Confidence.POSSIBLE
			ReportCategory.ANALYSIS:
				actual_conf = Confidence.PROBABLE
			ReportCategory.MALE_FRIEND_ESTIMATE:
				actual_conf = Confidence.POSSIBLE
			_:
				actual_conf = Confidence.POSSIBLE
	
	_report_counter += 1
	var report = {
		"id": "report_%d" % _report_counter,
		"category": category,
		"content": content,
		"sourceId": source_id,
		"confidence": actual_conf,
		"uncertainty": uncertainty,
		"day": _gs.get_day() if _gs else 1,
		"minute": _gs.get_minute_of_day() if _gs else 0,
		"relatedNpcs": related_npcs.duplicate(true),
		"tags": tags.duplicate(true),
		# Phase A provenance extension
		"sourceLocation": source_location if source_location != "" else _get_current_location(),
		"sourceType": source_type if source_type >= 0 else _infer_source_type(category, source_id),
		"sourceTypeName": ReportSourceType.keys()[source_type] if source_type >= 0 else _infer_source_type_name(category, source_id),
		"relatedCases": related_cases.duplicate(true),
	}
	_reports.append(report)
	_gs.add_report(report) if _gs else null
	if _eb:
		_eb.report_added.emit(report["id"], ReportCategory.keys()[category])
	return report

func _get_current_location() -> String:
	if _gs:
		var player = _gs.get_section("player")
		return player.get("locationId", "unknown")
	return "unknown"

func _infer_source_type(category: int, source_id: String) -> int:
	match category:
		ReportCategory.TESTIMONY:
			return ReportSourceType.NPC_TESTIMONY if source_id != "player" else ReportSourceType.DIRECT_OBSERVATION
		ReportCategory.RUMOR:
			return ReportSourceType.HEARSAY
		ReportCategory.ANALYSIS:
			return ReportSourceType.ANALYSIS
		ReportCategory.MALE_FRIEND_ESTIMATE:
			return ReportSourceType.ANALYSIS
	return ReportSourceType.REMOTE_REPORT

func _infer_source_type_name(category: int, source_id: String) -> String:
	return ReportSourceType.keys()[_infer_source_type(category, source_id)]

func get_reports(category: int = -1) -> Array:
	if category < 0:
		return _reports.duplicate(true)
	return _reports.filter(func(r): return r["category"] == category).duplicate(true)

func get_reports_by_source(source_id: String) -> Array:
	return _reports.filter(func(r): return r["sourceId"] == source_id).duplicate(true)

func get_reports_by_npc(npc_id: String) -> Array:
	return _reports.filter(func(r): return npc_id in r.get("relatedNpcs", []) or r["sourceId"] == npc_id).duplicate(true)

func get_reports_by_source_type(source_type: int) -> Array:
	return _reports.filter(func(r): return r.get("sourceType", -1) == source_type).duplicate(true)

func get_reports_by_location(location_id: String) -> Array:
	return _reports.filter(func(r): return r.get("sourceLocation", "") == location_id).duplicate(true)

func get_reports_by_case(case_id: String) -> Array:
	return _reports.filter(func(r): return case_id in r.get("relatedCases", [])).duplicate(true)

func get_reports_sorted_by_confidence() -> Array:
	var copy = _reports.duplicate(true)
	copy.sort_custom(func(a, b): return a["confidence"] > b["confidence"])
	return copy

func get_conflicting_reports() -> Array:
	## Find reports about the same subject with different confidence levels
	var by_npc = {}
	for r in _reports:
		var npcs = r.get("relatedNpcs", [])
		for npc_id in npcs:
			if not by_npc.has(npc_id):
				by_npc[npc_id] = []
			by_npc[npc_id].append(r)
	
	var conflicts = []
	for npc_id in by_npc:
		var reports = by_npc[npc_id]
		for i in range(reports.size()):
			for j in range(i + 1, reports.size()):
				var a = reports[i]
				var b = reports[j]
				if abs(a["confidence"] - b["confidence"]) >= 2:
					conflicts.append({"report_a": a, "report_b": b})
	return conflicts

func add_testimony(npc_id: String, content: String, related_npcs: Array = []) -> Dictionary:
	return add_report(ReportCategory.TESTIMONY, content, npc_id, related_npcs)

func add_rumor(npc_id: String, content: String, related_npcs: Array = []) -> Dictionary:
	return add_report(ReportCategory.RUMOR, content, npc_id, related_npcs)

func add_heroine_analysis(content: String, related_npcs: Array = [], confidence: int = -1) -> Dictionary:
	return add_report(ReportCategory.ANALYSIS, content, "yui", related_npcs, confidence)

func add_male_friend_estimate(content: String, related_npcs: Array = []) -> Dictionary:
	return add_report(ReportCategory.MALE_FRIEND_ESTIMATE, content, "yui", related_npcs, Confidence.POSSIBLE)

func get_uncertain_reports() -> Array:
	## Reports with high uncertainty or low confidence — need player attention
	return _reports.filter(func(r): return r["uncertainty"] > 0.4 or r["confidence"] <= Confidence.POSSIBLE).duplicate(true)

## --- Information summary for heroine ---
func get_information_summary() -> Dictionary:
	return {
		"systemFacts": get_all_system_facts_sorted(),
		"confirmedReports": _reports.filter(func(r): return r["confidence"] >= Confidence.PROBABLE).size(),
		"uncertainReports": get_uncertain_reports().size(),
		"totalFacts": _system_facts.size(),
		"totalReports": _reports.size(),
	}

## --- UI-safe report export (excludes truth/is_true) ---
func export_reports_for_ui() -> Array:
	## Returns reports with full provenance but WITHOUT truth/is_true
	## UI should NOT display definitive truth answers per spec
	var result = []
	for r in _reports:
		var ui_report = {
			"id": r["id"],
			"content": r["content"],
			"sourceId": r["sourceId"],
			"sourceTypeName": r.get("sourceTypeName", "unknown"),
			"sourceLocation": r.get("sourceLocation", "unknown"),
			"day": r["day"],
			"minute": r["minute"],
			"category": ReportCategory.keys()[r["category"]],
			"confidence_label": _get_confidence_label(r["confidence"]),
			"relatedNpcs": r.get("relatedNpcs", []),
			"relatedCases": r.get("relatedCases", []),
			"tags": r.get("tags", []),
		}
		# NOTE: truth/is_true intentionally NOT included
		result.append(ui_report)
	return result

func _get_confidence_label(confidence: int) -> String:
	match confidence:
		Confidence.CERTAIN:
			return "確実"
		Confidence.PROBABLE:
			return " probable"
		Confidence.POSSIBLE:
			return "不確実"
		Confidence.UNLIKELY:
			return "信頼低い"
	return "不明"

## --- Save/Load ---
func serialize() -> Dictionary:
	return {
		"system_facts": _system_facts.duplicate(true),
		"npc_memories": _npc_memories.duplicate(true),
		"reports": _reports.duplicate(true),
		"report_counter": _report_counter,
	}

func deserialize(data: Dictionary) -> void:
	if data.has("system_facts"):
		_system_facts = data["system_facts"].duplicate(true)
	if data.has("npc_memories"):
		_npc_memories = data["npc_memories"].duplicate(true)
	if data.has("reports"):
		# Backward compatibility: migrate old reports without new fields
		_reports = data["reports"].duplicate(true)
		for report in _reports:
			if not report.has("sourceLocation"):
				report["sourceLocation"] = "unknown"
			if not report.has("sourceType"):
				report["sourceType"] = _infer_source_type(report.get("category", 0), report.get("sourceId", ""))
				report["sourceTypeName"] = ReportSourceType.keys()[report["sourceType"]]
			if not report.has("relatedCases"):
				report["relatedCases"] = []
	if data.has("report_counter"):
		_report_counter = data["report_counter"]
