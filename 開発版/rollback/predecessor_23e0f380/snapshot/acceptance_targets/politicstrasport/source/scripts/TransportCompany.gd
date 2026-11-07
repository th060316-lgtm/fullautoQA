class_name TransportCompany
extends RefCounted

enum Strategy { BALANCED, GROWTH, CONSERVATIVE, COOPERATIVE, OPPORTUNIST }

var company_id: int = 0
var company_name: String = "輸送会社"
var color: Color = Color.WHITE
var money: float = 0.0
var is_player: bool = false
var active: bool = true
var owned_connections: Array = []
var total_revenue: float = 0.0
var total_expenses: float = 0.0
var last_day_revenue: float = 0.0
var last_day_expense: float = 0.0
var reputation: float = 1.0
var mode_bias: Dictionary = {}
var lifetime_profit: float = 0.0
var connections_built: int = 0
var connections_removed: int = 0

# Issue #12/#13 simplified lifecycle and ownership.
var founded_day: int = 1
var insolvent_days: int = 0
var strategy: int = Strategy.BALANCED
var parent_company_id: int = -1
var shareholdings: Dictionary = {}
var subsidiary_ids: Array = []
var dividend_rate: float = 0.20
var cooperation_partner_ids: Array = []
var cooperation_group_id: int = -1
var outsourcing_contracts: Array = []
var management_directives: Dictionary = {}
var business_type: String = "transport"
var origin_business_type: String = "transport_startup"

func _init(p_id: int = 0, p_name: String = "", p_color: Color = Color.WHITE, p_is_player: bool = false):
	company_id = p_id
	company_name = p_name
	color = p_color
	is_player = p_is_player

func get_display_name() -> String:
	return company_name

func add_connection(route_id: int) -> void:
	if not owned_connections.has(route_id):
		owned_connections.append(route_id)

func remove_connection(route_id: int) -> void:
	owned_connections.erase(route_id)

func get_connection_count() -> int:
	return owned_connections.size()

func register_revenue(amount: float) -> void:
	total_revenue += amount
	last_day_revenue += amount
	lifetime_profit += amount

func register_expense(amount: float) -> void:
	total_expenses += amount
	last_day_expense += amount
	lifetime_profit -= amount

func begin_day() -> void:
	last_day_revenue = 0.0
	last_day_expense = 0.0

func update_reputation(profit_ratio: float) -> void:
	reputation = clamp(reputation + clamp(profit_ratio, -0.2, 0.2) * 0.1, 0.6, 1.4)

func estimated_value() -> float:
	return max(50.0, money + max(0.0, lifetime_profit) * 0.35 + get_connection_count() * 80.0)

func set_management_directive(key: String, value) -> void:
	if key == "":
		return
	management_directives[key] = value

func to_dict() -> Dictionary:
	return {
		"company_id": company_id, "name": company_name,
		"color": color.to_html(false), "money": money, "is_player": is_player,
		"active": active, "connections": owned_connections.duplicate(),
		"total_revenue": total_revenue, "total_expenses": total_expenses,
		"last_day_revenue": last_day_revenue, "last_day_expense": last_day_expense,
		"lifetime_profit": lifetime_profit, "reputation": reputation,
		"strategy": strategy, "parent_company_id": parent_company_id,
		"subsidiary_ids": subsidiary_ids.duplicate(),
		"cooperation_partner_ids": cooperation_partner_ids.duplicate(),
		"cooperation_group_id": cooperation_group_id,
		"origin_business_type": origin_business_type,
		"management_directives": management_directives.duplicate(true),
	}
