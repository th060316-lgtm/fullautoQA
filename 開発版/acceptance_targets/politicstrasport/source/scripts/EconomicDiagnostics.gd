class_name EconomicDiagnostics
extends RefCounted

## Diagnostic backend for Issue #15 (revenue reasons, saturation, industry change)
## Provides structured data for UI without owning UI itself.

enum ReasonCategory {
	NONE = 0,
	SATURATION,          # market saturation lowered unit price
	DEMAND_GROWTH,       # population / cycle raised demand
	DEMAND_SHRINK,
	INDUSTRY_EXPAND,     # production_level up
	INDUSTRY_CONTRACT,
	INDUSTRY_SPLIT,
	COMPETITION,         # market share / rival activity (placeholder hook)
	WAR_DEMAND,
	WAR_DISRUPTION,
	CYCLE_SHIFT,         # business cycle change
	SCALE_CHANGE,        # settlement stage up/down
	NEW_FACILITY,
	ROUTE_CAPACITY,
	PRICE_FLOOR          # hit recirculation floor
}

const REASON_NAMES := {
	ReasonCategory.NONE: "なし",
	ReasonCategory.SATURATION: "需要飽和",
	ReasonCategory.DEMAND_GROWTH: "需要拡大",
	ReasonCategory.DEMAND_SHRINK: "需要縮小",
	ReasonCategory.INDUSTRY_EXPAND: "産業拡張",
	ReasonCategory.INDUSTRY_CONTRACT: "産業縮小",
	ReasonCategory.INDUSTRY_SPLIT: "産業会社分裂",
	ReasonCategory.COMPETITION: "競争圧力",
	ReasonCategory.WAR_DEMAND: "戦時特需",
	ReasonCategory.WAR_DISRUPTION: "戦時混乱",
	ReasonCategory.CYCLE_SHIFT: "景気変動",
	ReasonCategory.SCALE_CHANGE: "集落規模変化",
	ReasonCategory.NEW_FACILITY: "新規施設",
	ReasonCategory.ROUTE_CAPACITY: "路線容量",
	ReasonCategory.PRICE_FLOOR: "現地再流通フロア"
}

var world_day: int = 0

# Recent diagnostic events (capped)
var events: Array = []  # Array of Dictionary
const MAX_EVENTS := 80

# Per-route last revenue reason tags: route_id -> Array of ReasonCategory
var route_revenue_reasons: Dictionary = {}

# Per-settlement last notable change
var settlement_flags: Dictionary = {}

func clear_day(day: int) -> void:
	world_day = day
	# Soft: keep history, but mark day

func add_event(category: int, message: String, meta: Dictionary = {}) -> void:
	var e = {
		"day": world_day,
		"category": category,
		"category_name": REASON_NAMES.get(category, "不明"),
		"message": message,
		"meta": meta
	}
	events.push_front(e)
	if events.size() > MAX_EVENTS:
		events.pop_back()

func tag_route_reason(route_id: int, category: int) -> void:
	if not route_revenue_reasons.has(route_id):
		route_revenue_reasons[route_id] = []
	var arr: Array = route_revenue_reasons[route_id]
	if not arr.has(category):
		arr.append(category)
	# Keep only last few distinct
	while arr.size() > 5:
		arr.pop_front()

func get_route_reasons(route_id: int) -> Array:
	return route_revenue_reasons.get(route_id, [])

func get_route_reason_names(route_id: int) -> Array:
	var out: Array = []
	for c in get_route_reasons(route_id):
		out.append(REASON_NAMES.get(c, "?"))
	return out

func flag_settlement(settlement_id: int, category: int, detail: String = "") -> void:
	settlement_flags[settlement_id] = {
		"category": category,
		"detail": detail,
		"day": world_day
	}

func get_recent_events(limit: int = 20) -> Array:
	var n = mini(limit, events.size())
	return events.slice(0, n)

func get_events_by_category(category: int, limit: int = 10) -> Array:
	var out: Array = []
	for e in events:
		if int(e.get("category", -1)) == category:
			out.append(e)
			if out.size() >= limit:
				break
	return out

## Snapshot for UI: major revenue-change explanations
func build_ui_snapshot() -> Dictionary:
	return {
		"day": world_day,
		"recent_events": get_recent_events(15),
		"route_reasons": route_revenue_reasons.duplicate(true),
		"settlement_flags": settlement_flags.duplicate(true)
	}

func to_dict() -> Dictionary:
	return build_ui_snapshot()

