class_name WarSupplyPolicy
extends RefCounted

## MiniMax: 戦争補給の所属判定 (重大修正)
##
## 旧 Prototpye の問題:
##   補給基地は 1 つだけ・支援側のタグも曖昧で、
##   敵国都市から敵軍補給基地へ物資を運ぶと
##   敵国側の war_bonus が増えて敵国が勝在深圳を奪う自己矛盾が発生していた。
##
## 本 Policies:
##   1. 開戦時に両軍分の補給基地を生成する (support_nation_id を持つ)。
##   2. 供給元都市.nation_id == 補給基地.support_nation_id のときだけ
##      その国家の軍事補給として有効。
##   3. 無効輸送は war_bonus に加算しない。理由もイベントログに残す。
##   4. 戦争終了時に両基地を停止し、接続線を「戦後不要」として残置する。
##
## 例外 (同盟援助・密輸・内通・外交) は本 Prototype では実装しない。

# 戦時補給プレミアム (既存 Grok 値を維持)
const WAR_FOOD_PRICE := 2.5
const WAR_FUEL_PRICE := 3.0
const WAR_FOOD_BONUS := 0.08
const WAR_FUEL_BONUS := 0.12
const WAR_DAILY_CAP_FOOD := 8.0
const WAR_DAILY_CAP_FUEL := 7.0
const WAR_MIN_FOOD := 0.4
const WAR_MIN_FUEL := 0.3

# 無効補給ログの抑止 (同一都市対につき N 日に1度だけ記録)
const INVALID_LOG_INTERVAL := 5

var world: WorldState
var resolver: CompetitionResolver = null

func _init(p_world: WorldState) -> void:
	world = p_world

func _get_resolver() -> CompetitionResolver:
	if resolver == null:
		resolver = CompetitionResolver.new(world)
	return resolver

# ------------------------------------------------------------------
# 補給基地の生成
# ------------------------------------------------------------------

## 戦争開始時に両軍分の補給基地を生成する。
func spawn_supply_bases(nation_a_id: int, nation_b_id: int) -> Array:
	var bases: Array = []
	var na = world.get_nation(nation_a_id)
	var nb = world.get_nation(nation_b_id)
	var base_a := _create_base(nation_a_id, "%s軍補給基地" % (na.name if na else "A"), _base_position(nation_a_id))
	var base_b := _create_base(nation_b_id, "%s軍補給基地" % (nb.name if nb else "B"), _base_position(nation_b_id))
	bases.append(base_a)
	bases.append(base_b)
	world.war_supply_base_ids = [base_a.id, base_b.id]
	world.war_supply_base_id = base_a.id
	if world.ground != null:
		world.ground.assign_terminals()
	world.add_event("前線補給基地が設置された（%s支援 / %s支援）" % [
		na.name if na else "?", nb.name if nb else "?"])
	return bases

func _create_base(support_nation_id: int, label: String, pos: Vector2) -> Settlement:
	var base := Settlement.new(world.next_settlement_id, label, pos)
	world.next_settlement_id += 1
	base.is_supply_base = true
	# 支援先国家。補給の有効判定はこれだけで行う。
	base.support_nation_id = support_nation_id
	# 補給基地そのものは中立 (国力に含めない)
	base.nation_id = -1
	base.food_demand = 25.0
	base.fuel_demand = 20.0
	base.population = 2.0
	base.economy = 1.0
	base.active = true
	world.settlements.append(base)
	return base

## その国家の都市群の重心付近に基地を置く
func _base_position(nation_id: int) -> Vector2:
	var pos := Vector2.ZERO
	var count := 0
	for s in world.settlements:
		if not s.active or s.is_supply_base:
			continue
		if s.nation_id == nation_id:
			pos += s.position
			count += 1
	if count > 0:
		pos /= float(count)
	else:
		pos = Vector2(480, 360)
	pos += Vector2(world.rng.randf_range(-30, 30), world.rng.randf_range(-30, 30))
	return pos

# ------------------------------------------------------------------
# 補給判定 (中核)
# ------------------------------------------------------------------

## 供給元都市からの物資が、指定補給基地の支援先国家に有効か。
## Logic Prototype では「供給元都市.nation_id == 補給基地.support_nation_id」のみ有効。
func is_valid_supply_source(source: Settlement, base: Settlement) -> bool:
	if source == null or base == null:
		return false
	if not base.is_supply_base:
		return false
	if base.support_nation_id < 0:
		return false
	if source.nation_id < 0:
		return false
	return source.nation_id == base.support_nation_id

## 無効理由の文言 (イベントログ用)
func invalid_reason_text(source: Settlement, base: Settlement) -> String:
	if source == null:
		return "供給元不明"
	if base == null or not base.is_supply_base:
		return "補給基地ではない"
	if base.support_nation_id < 0:
		return "支援先未設定"
	var support_nation = world.get_nation(base.support_nation_id)
	var source_nation = world.get_nation(source.nation_id)
	return "%s(物資供給元:%s)の物資は %s(支援先:%s) の補給として計上されない" % [
		source.name,
		source_nation.name if source_nation else "中立",
		base.name,
		support_nation.name if support_nation else "不明",
	]

# ------------------------------------------------------------------
# 日次補給処理
# ------------------------------------------------------------------

## 補給基地向けの輸送を処理し、有効な補給だけを war_bonus に加算する。
func process_supply() -> void:
	var res := _get_resolver()
	for base_id in get_active_base_ids():
		var base = world.get_settlement(base_id)
		if base == null or not base.active or not base.is_supply_base:
			continue
		_supply_food(res, base)
		_supply_fuel(res, base)

func get_active_base_ids() -> Array:
	var ids: Array = []
	for bid in world.war_supply_base_ids:
		if not ids.has(bid):
			ids.append(bid)
	if world.war_supply_base_id >= 0 and not ids.has(world.war_supply_base_id):
		ids.append(world.war_supply_base_id)
	return ids

func _connected_routes(base_id: int) -> Array:
	var result: Array = []
	for r in world.routes:
		if not r.active:
			continue
		if r.from_id == base_id or r.to_id == base_id:
			result.append(r)
	return result

func _other_end(route, base_id: int) -> int:
	if route.from_id == base_id:
		return route.to_id
	return route.from_id

func _supply_food(res: CompetitionResolver, base: Settlement) -> void:
	var routes := _connected_routes(base.id)
	if routes.is_empty():
		return
	# 需要は「消費側=補給基地、供給側=都市」ごとに分割する
	for r in routes:
		var other_id := _other_end(r, base.id)
		var other = world.get_settlement(other_id)
		if other == null or not other.active or other.is_supply_base:
			continue
		if other.food_supply_capacity < 0.5:
			continue
		var demand: float = min(base.food_demand * 0.8, other.food_supply_capacity * 0.5)
		if demand <= 0.0:
			continue
		var moves := res.distribute([r], demand, TransportModeConfig.Cargo.FOOD)
		for m in moves:
			var route = m[0]
			var moved: float = m[1]
			if moved > WAR_DAILY_CAP_FOOD:
				moved = WAR_DAILY_CAP_FOOD
			if moved < WAR_MIN_FOOD:
				continue
			route.carried_food += moved
			base.food_demand = max(0.0, base.food_demand - moved)
			other.food_supply_capacity = max(0.0, other.food_supply_capacity - moved * 0.4)
			var revenue: float = moved * WAR_FOOD_PRICE
			route.last_revenue += revenue
			route.daily_revenue += revenue
			world.add_company_revenue(route.company_id, revenue)
			_apply_war_bonus(base, other, moved, true)

func _supply_fuel(res: CompetitionResolver, base: Settlement) -> void:
	var routes := _connected_routes(base.id)
	if routes.is_empty():
		return
	for r in routes:
		var other_id := _other_end(r, base.id)
		var other = world.get_settlement(other_id)
		if other == null or not other.active or other.is_supply_base:
			continue
		if other.fuel_supply_capacity < 0.3:
			continue
		var demand: float = min(base.fuel_demand * 0.8, other.fuel_supply_capacity * 0.5)
		if demand <= 0.0:
			continue
		var moves := res.distribute([r], demand, TransportModeConfig.Cargo.FUEL)
		for m in moves:
			var route = m[0]
			var moved: float = m[1]
			if moved > WAR_DAILY_CAP_FUEL:
				moved = WAR_DAILY_CAP_FUEL
			if moved < WAR_MIN_FUEL:
				continue
			route.carried_fuel += moved
			base.fuel_demand = max(0.0, base.fuel_demand - moved)
			other.fuel_supply_capacity = max(0.0, other.fuel_supply_capacity - moved * 0.35)
			var revenue: float = moved * WAR_FUEL_PRICE
			route.last_revenue += revenue
			route.daily_revenue += revenue
			world.add_company_revenue(route.company_id, revenue)
			_apply_war_bonus(base, other, moved, false)

## 有効/無効の判定と war_bonus 加算、およびログ
func _apply_war_bonus(base: Settlement, source: Settlement, amount: float, is_food: bool) -> void:
	var cargo_name := "食料" if is_food else "燃料"
	if is_valid_supply_source(source, base):
		var nation = world.get_nation(base.support_nation_id)
		if nation != null:
			var bonus: float = amount * (WAR_FOOD_BONUS if is_food else WAR_FUEL_BONUS)
			nation.war_bonus += bonus
			world.add_event("%s補給により%s戦争補正+%.2f" % [cargo_name, nation.name, bonus])
		return
	# 無効補給: war_bonus には加算しない。理由もイベントログに残す。
	log_invalid_supply(source, base, cargo_name)

func log_invalid_supply(source: Settlement, base: Settlement, cargo_name: String) -> void:
	var key := "%d:%d" % [source.id, base.id]
	var last_day: int = world.war_supply_log_cooldown.get(key, -999)
	if world.day - last_day < INVALID_LOG_INTERVAL:
		return
	world.war_supply_log_cooldown[key] = world.day
	world.add_event("[無効補給] %s: %s" % [cargo_name, invalid_reason_text(source, base)])

# ------------------------------------------------------------------
# 戦争終了時の停止と cleanup
# ------------------------------------------------------------------

## 戦争終了時: 両軍補給基地を停止し、接続線を「戦後不要connection」として残す。
## 一時基地データが無限増殖しないよう、基地実体は settlements から除去する。
## 接続線は Route として残し、obsolete フラグで撤去判断可能にする。
func finalize_bases() -> void:
	var ids := get_active_base_ids()
	for bid in ids:
		var base = world.get_settlement(bid)
		if base == null:
			continue
		base.active = false
		base.support_nation_id = -1
		for r in world.routes:
			# Front relocation can make a ground supply route inactive before
			# armistice. It is still a former base route and must be classified
			# obsolete for cleanup/diagnostics instead of escaping this pass.
			if r.from_id == bid or r.to_id == bid:
				r.obsolete = true
				world.add_event("戦後不要connection: 補給基地接続路線 (撤去可能)")
		world.settlements.erase(base)
	world.war_supply_base_ids = []
	world.war_supply_base_id = -1
	world.war_supply_log_cooldown.clear()
	# Ground terminal table must be rebuilt after temporary bases are removed.
	if world.ground != null:
		world.ground.assign_terminals()
	# 安全掃討: 参照されなくなった一時基地データが残っていないか確認
	world.purge_inactive_supply_bases()

