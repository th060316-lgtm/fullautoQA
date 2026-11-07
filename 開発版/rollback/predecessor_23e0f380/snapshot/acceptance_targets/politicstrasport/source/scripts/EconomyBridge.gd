class_name EconomyBridge
extends RefCounted

## Stable Work/Grok boundary. Grok Phase A may register a delegate implementing
## the same methods; until then the fallback keeps #8-#15 executable.

var world: WorldState
var delegate: Object = null

func _init(p_world: WorldState) -> void:
	world = p_world

func set_delegate(p_delegate: Object) -> void:
	delegate = p_delegate

func get_demand_multiplier(settlement_id: int, cargo_key: String) -> float:
	var s = world.get_settlement(settlement_id)
	if s == null:
		return 1.0
	var n = world.get_nation(s.nation_id)
	var result := n.logistics_multiplier(cargo_key) if n != null else 1.0
	result *= clamp(1.0 - s.transport_disruption * 0.75, 0.1, 1.0)
	if cargo_key == "passenger":
		result *= 1.0 + min(0.7, s.refugee_pressure * 0.03 + s.promotion_support * 0.002)
	elif cargo_key == "construction":
		result *= 1.0 + min(2.0, s.reconstruction_demand * 0.05)
	elif cargo_key == "military":
		result *= 1.0 + min(2.0, s.military_demand * 0.05)
	# The economic delegate augments political/war modifiers; it never replaces
	# them. This preserves the Work-side indirect-control contract.
	if delegate != null and delegate.has_method("get_demand_multiplier"):
		result *= float(delegate.call("get_demand_multiplier", settlement_id, cargo_key))
	return clamp(result, 0.05, 5.0)

func notify_regional_shock(settlement_id: int, category: String, magnitude: float) -> void:
	if delegate != null and delegate.has_method("notify_regional_shock"):
		delegate.call("notify_regional_shock", settlement_id, category, magnitude)

func choose_facility_operator(settlement_id: int, facility_type: String) -> String:
	if delegate != null and delegate.has_method("choose_facility_operator"):
		var candidate = delegate.call("choose_facility_operator", settlement_id, facility_type)
		if str(candidate) != "":
			return str(candidate)
	var s = world.get_settlement(settlement_id)
	return "local_industry_n%d" % (s.nation_id if s != null else -1)

func register_player_built_facility(facility: Dictionary) -> void:
	if delegate != null and delegate.has_method("register_player_built_facility"):
		delegate.call("register_player_built_facility", facility)

func diagnostic_snapshot() -> Dictionary:
	if delegate != null and delegate.has_method("diagnostic_snapshot"):
		return delegate.call("diagnostic_snapshot")
	return {"source": "work_stub", "cargo_registry_connected": false}
