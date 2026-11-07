class_name IndustryCompany
extends RefCounted

## Simplified industry ownership entity (Issue #4 / #7)
## Not a full management sim. Holds facilities, can split/independent.

var id: int = 0
var name: String = ""
var home_settlement_id: int = -1
var active: bool = true
var facility_ids: Array = []  # int

# Soft capital (for split logic only; no full accounting)
var capital: float = 50.0
var total_shipper_profit: float = 0.0
var days_since_split: int = 0
var parent_company_id: int = -1  # -1 if original

func _init(p_id: int = 0, p_name: String = "", p_home: int = -1):
	id = p_id
	name = p_name
	home_settlement_id = p_home

func add_facility(fid: int) -> void:
	if not facility_ids.has(fid):
		facility_ids.append(fid)

func remove_facility(fid: int) -> void:
	facility_ids.erase(fid)

func register_profit(amount: float) -> void:
	total_shipper_profit += amount
	capital += amount * 0.15

## Issue #7: possible split when capital and facility count grow
func can_split(min_facilities: int = 2, min_capital: float = 80.0, min_days: int = 40) -> bool:
	return active and facility_ids.size() >= min_facilities \
		and capital >= min_capital and days_since_split >= min_days

func to_dict() -> Dictionary:
	return {
		"id": id,
		"name": name,
		"home_settlement_id": home_settlement_id,
		"active": active,
		"facility_ids": facility_ids.duplicate(),
		"capital": capital,
		"total_shipper_profit": total_shipper_profit,
		"days_since_split": days_since_split,
		"parent_company_id": parent_company_id
	}

static func from_dict(d: Dictionary) -> IndustryCompany:
	var c = IndustryCompany.new(
		int(d.get("id", 0)),
		str(d.get("name", "")),
		int(d.get("home_settlement_id", -1))
	)
	c.active = bool(d.get("active", true))
	c.facility_ids = d.get("facility_ids", []).duplicate()
	c.capital = float(d.get("capital", 50.0))
	c.total_shipper_profit = float(d.get("total_shipper_profit", 0.0))
	c.days_since_split = int(d.get("days_since_split", 0))
	c.parent_company_id = int(d.get("parent_company_id", -1))
	return c

