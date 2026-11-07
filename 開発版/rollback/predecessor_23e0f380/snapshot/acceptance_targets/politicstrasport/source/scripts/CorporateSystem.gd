class_name CorporateSystem
extends RefCounted

var world: WorldState
var diagnostics: SimulationDiagnostics
var next_contract_id: int = 1
var next_related_business_id: int = 1
var related_businesses: Array = []

func _init(p_world: WorldState, p_diagnostics: SimulationDiagnostics) -> void:
	world = p_world
	diagnostics = p_diagnostics
	_seed_related_businesses()

func _seed_related_businesses() -> void:
	if not related_businesses.is_empty():
		return
	for spec in [
		{"name": "地域建設社", "service": "construction", "valuation": 420.0},
		{"name": "車両供給社", "service": "vehicle_supply", "valuation": 520.0},
		{"name": "整備保守社", "service": "maintenance", "valuation": 360.0},
	]:
		var business := {
			"id": next_related_business_id,
			"name": str(spec.name),
			"service": str(spec.service),
			"valuation": float(spec.valuation),
			"owner_company_id": -1,
			"active": true,
		}
		next_related_business_id += 1
		related_businesses.append(business)

func process_day() -> void:
	if world.day % 30 == 0:
		_pay_dividends()
	for c in world.companies:
		if c.active:
			_process_contracts(c)

func acquire_company(buyer_id: int, target_id: int, share: float = 0.51, hostile: bool = false) -> bool:
	var buyer = world.get_company(buyer_id)
	var target = world.get_company(target_id)
	if buyer == null or target == null or not buyer.active or not target.active or buyer_id == target_id:
		return false
	share = clampf(share, 0.05, 1.0)
	var control_premium := 1.0
	if share >= 0.51:
		control_premium = 1.35 if hostile else 1.20
	var cost: float = target.estimated_value() * share * control_premium
	if not world.pay_company(buyer_id, cost):
		return false
	var current := float(buyer.shareholdings.get(target_id, 0.0))
	buyer.shareholdings[target_id] = clampf(current + share, 0.0, 1.0)
	if float(buyer.shareholdings[target_id]) >= 0.51:
		target.parent_company_id = buyer_id
		if not buyer.subsidiary_ids.has(target_id):
			buyer.subsidiary_ids.append(target_id)
	diagnostics.record("corporate",
		"%sが%sの持分%.0f%%を%s取得" % [
			buyer.company_name, target.company_name, share * 100.0,
			"敵対的に" if hostile else ""], 2,
		{"buyer": buyer_id, "target": target_id, "hostile": hostile})
	return true

func acquire_related_business(buyer_id: int, business_id: int, share: float = 0.51, hostile: bool = false) -> bool:
	var buyer = world.get_company(buyer_id)
	var business := get_related_business(business_id)
	if buyer == null or business.is_empty() or not buyer.active or not bool(business.get("active", false)):
		return false
	share = clampf(share, 0.05, 1.0)
	var premium := 1.30 if hostile and share >= 0.51 else (1.15 if share >= 0.51 else 1.0)
	var cost: float = float(business.get("valuation", 100.0)) * share * premium
	if not world.pay_company(buyer_id, cost):
		return false
	var key := "related:%d" % business_id
	buyer.shareholdings[key] = clampf(float(buyer.shareholdings.get(key, 0.0)) + share, 0.0, 1.0)
	if float(buyer.shareholdings[key]) >= 0.51:
		business["owner_company_id"] = buyer_id
	diagnostics.record("corporate", "%sが関連会社%sを%s取得" % [
		buyer.company_name, str(business.get("name", "?")), "敵対的に" if hostile else ""], 2,
		{"buyer": buyer_id, "business_id": business_id, "share": buyer.shareholdings[key]})
	return true

func get_related_business(business_id: int) -> Dictionary:
	for business in related_businesses:
		if int(business.get("id", -1)) == business_id:
			return business
	return {}

func request_outsource(company_id: int, service: String, cost: float, duration_days: int = 20) -> int:
	var company = world.get_company(company_id)
	if company == null or not company.active or cost <= 0.0 or not service in ["construction", "vehicle_supply", "maintenance"]:
		return -1
	var provider := {}
	for business in related_businesses:
		if bool(business.get("active", false)) and str(business.get("service", "")) == service:
			provider = business
			break
	var effective_cost := cost
	if not provider.is_empty() and int(provider.get("owner_company_id", -1)) == company_id:
		effective_cost *= 0.65
	if not world.pay_company(company_id, effective_cost):
		return -1
	var contract := {
		"id": next_contract_id, "service": service, "start_day": world.day,
		"end_day": world.day + maxi(1, duration_days), "cost": effective_cost, "active": true,
		"provider_business_id": int(provider.get("id", -1)),
	}
	next_contract_id += 1
	company.outsourcing_contracts.append(contract)
	diagnostics.record("outsourcing", "%sが%sを外注（費用%.0f、支払一度のみ）" % [
		company.company_name, service, effective_cost], 1)
	return int(contract.id)

func create_cooperation(a_id: int, b_id: int) -> bool:
	var a = world.get_company(a_id)
	var b = world.get_company(b_id)
	if a == null or b == null or not a.active or not b.active or a_id == b_id:
		return false
	if not a.cooperation_partner_ids.has(b_id):
		a.cooperation_partner_ids.append(b_id)
	if not b.cooperation_partner_ids.has(a_id):
		b.cooperation_partner_ids.append(a_id)
	var group: int = int(a.cooperation_group_id)
	if group < 0:
		group = int(b.cooperation_group_id)
	if group < 0:
		group = mini(a_id, b_id) * 1000 + maxi(a_id, b_id)
	a.cooperation_group_id = group
	b.cooperation_group_id = group
	for r in world.routes:
		if r.company_id in [a_id, b_id]:
			r.cooperation_group = group
	diagnostics.record("cooperation", "%sと%sが共同輸送を開始" % [a.company_name, b.company_name], 2,
		{"group": group})
	return true

func set_subsidiary_directive(parent_id: int, child_id: int, directive: String, value) -> bool:
	var parent = world.get_company(parent_id)
	var child = world.get_company(child_id)
	if parent == null or child == null or child.parent_company_id != parent_id:
		return false
	if not directive in ["preferred_mode", "preferred_nation", "growth_posture", "regional_focus"]:
		return false
	child.set_management_directive(directive, value)
	diagnostics.record("corporate", "%sが子会社%sへ%s方針を設定" % [
		parent.company_name, child.company_name, directive], 1)
	return true

func _pay_dividends() -> void:
	for child in world.companies:
		if not child.active or child.parent_company_id < 0:
			continue
		var parent = world.get_company(child.parent_company_id)
		if parent == null or not parent.active:
			child.parent_company_id = -1
			continue
		var profit: float = maxf(0.0, float(child.last_day_revenue) - float(child.last_day_expense))
		var amount: float = minf(float(child.money) * 0.10, profit * float(child.dividend_rate))
		if amount <= 0.01:
			continue
		child.money -= amount
		child.register_expense(amount)
		world.add_company_revenue(parent.company_id, amount)
		diagnostics.record("dividend", "%s→%s 配当%.1f" % [child.company_name, parent.company_name, amount], 1)

func _process_contracts(company) -> void:
	for contract in company.outsourcing_contracts:
		if bool(contract.get("active", false)) and world.day >= int(contract.get("end_day", 0)):
			contract["active"] = false
			var service := str(contract.get("service", ""))
			if service == "maintenance":
				company.reputation = min(1.4, company.reputation + 0.03)
			elif service == "construction":
				company.reputation = min(1.4, company.reputation + 0.01)
