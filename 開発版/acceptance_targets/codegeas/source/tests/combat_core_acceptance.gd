extends SceneTree
## Phase 0.5 Block 4: mode-agnostic Combat Core acceptance
##
## 実行:
##   godot --headless --path game -s res://tests/combat_core_acceptance.gd
##
## 検証内容:
##   - damage / hit / target / combat event が Core 側で一元化されている
##   - Human / KMF の部位プロファイルが既存 DamageSystem を再訪している (複製していない)
##   - KMF 部位破壊が運動/武器/索敵/鹵獲可否へ反映される
##   - 方式 (RT / Paused / WEGO) に依存しない判定である
##   - 方式別の rebalance が起きない (balance 値は main と一致)

const EXPECTED_CHECKS: int = 45
const DamageSystem = preload("res://sandbox/DamageSystem.gd")
const CombatCore = preload("res://combat/core/CombatCore.gd")
const Combatant = preload("res://combat/core/Combatant.gd")
const CombatBalance = preload("res://combat/core/CombatBalance.gd")
const PartEffects = preload("res://combat/core/PartEffects.gd")
const CombatEvent = preload("res://combat/core/CombatEvent.gd")
# Canonical main values. The static delta checker separately verifies these against
# CombatManagerLegacy/PlayerControllerLegacy without standalone-preloading Node scripts.
const MAIN_PROJECTILE_SPEED: float = 400.0
const MAIN_FOOT_DAMAGE: float = 8.0
const MAIN_KMF_DAMAGE: float = 25.0
const MAIN_FOOT_SPEED: float = 80.0
const MAIN_KMF_SPEED: float = 160.0
const MAIN_FOOT_VISION: float = 120.0
const MAIN_KMF_VISION: float = 220.0

var failures: Array[String] = []
var ran: int = 0

func _init() -> void:
	call_deferred("_run")

func check(name: String, condition: bool) -> void:
	ran += 1
	if condition:
		print("[PASS] ", name)
	else:
		failures.append(name)
		print("[FAIL] ", name)

func _run() -> void:
	print("=== COMBAT CORE ACCEPTANCE (Phase 0.5 Block 4) ===")

	# --- balance は main の値と一致 (方式別 rebalance 禁止) ---
	check("projectile speed matches main", is_equal_approx(CombatBalance.PROJECTILE_SPEED, MAIN_PROJECTILE_SPEED))
	check("foot damage matches main", is_equal_approx(CombatBalance.FOOT_DAMAGE, MAIN_FOOT_DAMAGE))
	check("KMF damage matches main", is_equal_approx(CombatBalance.KMF_DAMAGE, MAIN_KMF_DAMAGE))
	check("foot speed matches main", is_equal_approx(CombatBalance.FOOT_SPEED, MAIN_FOOT_SPEED))
	check("KMF speed matches main", is_equal_approx(CombatBalance.KMF_SPEED, MAIN_KMF_SPEED))
	check("foot vision matches main", is_equal_approx(CombatBalance.FOOT_VISION, MAIN_FOOT_VISION))
	check("KMF vision matches main", is_equal_approx(CombatBalance.KMF_VISION, MAIN_KMF_VISION))

	# --- Core 基本 ---
	var core = CombatCore.new()
	var events: Array = []
	var feedbacks: Array = []
	core.combat_event.connect(func(e): events.append(e))
	core.feedback_requested.connect(func(f): feedbacks.append(f))

	var infantry := Combatant.new("infantry", "敵歩兵", "enemy", "human", 40.0)
	infantry.position = Vector2(100.0, 0.0)
	var enemy_kmf := Combatant.new("enemy_kmf", "敵KMF", "enemy", "kmf", 150.0)
	enemy_kmf.position = Vector2(200.0, 0.0)
	check("core registers combatants", core.register_combatant(infantry) and core.register_combatant(enemy_kmf))
	check("combatant reuses DamageSystem profiles", infantry.get_profile_id() == "human" and enemy_kmf.get_profile_id() == "kmf")
	check("human has the 6 contract parts", infantry.get_part_ids().size() == 6)
	check("KMF has the 9 contract parts", enemy_kmf.get_part_ids().size() == 9)

	# --- 部位ダメージ ---
	var hit: Dictionary = core.apply_damage("infantry", "torso", 8.0, {"mode_id": "realtime"})
	check("part damage reduces part hp", is_equal_approx(infantry.get_part_hp("torso"), 92.0))
	check("part damage reduces aggregate hp (compatibility)", is_equal_approx(infantry.hp, 32.0))
	check("damage emits a combat event", events.size() >= 2)
	check("damage emits feedback", feedbacks.size() >= 1)
	check("core keeps an event log", core.get_event_log().size() >= 2)

	# --- 部位選択は決定的 ---
	var part_a: String = core.choose_part(enemy_kmf, enemy_kmf.position + Vector2(0.0, -30.0))
	var part_b: String = core.choose_part(enemy_kmf, enemy_kmf.position + Vector2(0.0, -30.0))
	check("part selection is deterministic", part_a == part_b)
	check("aiming high on a KMF selects the cockpit", part_a == "cockpit")
	var leg_part: String = core.choose_part(enemy_kmf, enemy_kmf.position + Vector2(0.0, 40.0))
	check("aiming low on a KMF selects a leg", leg_part in ["left_leg", "right_leg"])

	# --- 生命部位 (戦闘不能) ---
	core.apply_damage("infantry", "head", 40.0, {"mode_id": "realtime"})
	check("vital part destruction incapacitates", infantry.incapacitated)
	check("incapacitated target is no longer active", not infantry.is_active())
	check("incapacitation emits an event", events.any(func(e): return str(e.get("kind", "")) == CombatEvent.KIND_INCAPACITATED))

	# --- 撃破 ---
	core.apply_damage("enemy_kmf", "frame", 200.0, {"mode_id": "wego"})
	check("aggregate hp reaching zero destroys the target", enemy_kmf.destroyed and not enemy_kmf.alive)
	check("destruction emits an event", events.any(func(e): return str(e.get("kind", "")) == CombatEvent.KIND_DESTROYED))

	# --- KMF 部位効果 ---
	# 部位効果の検証用: 集計HP に余裕を持たせる (部位破壊が総撃破に直結しない条件)
	var kmf2 := Combatant.new("kmf2", "KMF2", "enemy", "kmf", 1000.0)
	core.register_combatant(kmf2)
	core.apply_damage("kmf2", "left_leg", 200.0, {"mode_id": "realtime"})
	var effects_leg: Dictionary = PartEffects.evaluate(kmf2.body)
	check("one destroyed leg reduces mobility", is_equal_approx(float(effects_leg.get("mobility_multiplier", 1.0)), 0.6))
	core.apply_damage("kmf2", "right_leg", 200.0, {"mode_id": "realtime"})
	var effects_legs: Dictionary = PartEffects.evaluate(kmf2.body)
	check("both legs destroyed immobilise the KMF", bool(effects_legs.get("immobilized", false)))
	core.apply_damage("kmf2", "weapon", 100.0, {"mode_id": "realtime"})
	var effects_weapon: Dictionary = PartEffects.evaluate(kmf2.body)
	check("weapon destruction disables fire", bool(effects_weapon.get("weapon_disabled", false)))
	core.apply_damage("kmf2", "sensor", 100.0, {"mode_id": "realtime"})
	var effects_sensor: Dictionary = PartEffects.evaluate(kmf2.body)
	check("sensor destruction degrades detection", bool(effects_sensor.get("sensor_degraded", false)))
	check("sensor destruction adds an accuracy penalty", float(effects_sensor.get("accuracy_penalty", 0.0)) >= 0.25)
	core.apply_damage("kmf2", "cockpit", 200.0, {"mode_id": "realtime"})
	var effects_cockpit: Dictionary = PartEffects.evaluate(kmf2.body)
	check("cockpit destruction kills the pilot", bool(effects_cockpit.get("pilot_dead", false)))
	check("cockpit destruction is reported as a part event",
		events.any(func(e): return str(e.get("kind", "")) == CombatEvent.KIND_PART_DESTROYED and str(e.get("part_id", "")) == "cockpit"))

	# --- 方式非依存 (mode_id はメタデータのみ) ---
	var core_a = CombatCore.new()
	var core_b = CombatCore.new()
	var ta := Combatant.new("t", "T", "enemy", "human", 40.0)
	var tb := Combatant.new("t", "T", "enemy", "human", 40.0)
	core_a.register_combatant(ta)
	core_b.register_combatant(tb)
	core_a.apply_damage("t", "torso", 8.0, {"mode_id": "realtime", "hit_position": Vector2(5, 5)})
	core_b.apply_damage("t", "torso", 8.0, {"mode_id": "wego", "hit_position": Vector2(5, 5)})
	check("damage result is identical across combat modes",
		is_equal_approx(ta.hp, tb.hp) and is_equal_approx(ta.get_part_hp("torso"), tb.get_part_hp("torso")))

	# --- AI / tactics 境界 ---
	var tactics: Script = load("res://combat/core/BaselineTactics.gd")
	check("tactics interface exists", tactics != null)
	var decision_ok: bool = false
	var approach_ok: bool = false
	if tactics != null:
		var ai = tactics.new()
		ai.reset({"entity_index": 0})
		var decision: Dictionary = ai.evaluate({
			"self_position": Vector2(0, 0), "player_position": Vector2(200, 0),
			"distance": 200.0, "desired_range": 150.0, "detection_range": 260.0,
			"weapon_ready": true, "effects": {}, "hp_ratio": 1.0, "delta": 0.016,
		})
		decision_ok = decision.has("action") and decision.has("fire")
		approach_ok = str(decision.get("action", "")) == "approach"
	check("tactics returns a decision dictionary", decision_ok)
	check("tactics approaches when out of range", approach_ok)

	# --- Block 6/7: non-shooting tactics + part-effect reaction ---
	var retreat_ok: bool = false
	var flank_ok: bool = false
	var seek_ok: bool = false
	var immobilized_hold: bool = false
	if tactics != null:
		var ai2 = tactics.new()
		ai2.reset({"entity_index": 1})
		var d_retreat: Dictionary = ai2.evaluate({
			"self_position": Vector2(0, 0), "player_position": Vector2(80, 0),
			"distance": 80.0, "desired_range": 150.0, "detection_range": 260.0,
			"weapon_ready": true, "effects": {}, "hp_ratio": 0.2, "delta": 0.016,
			"cover_available": false,
		})
		retreat_ok = str(d_retreat.get("action", "")) == "retreat"
		var d_seek: Dictionary = ai2.evaluate({
			"self_position": Vector2(0, 0), "player_position": Vector2(80, 0),
			"distance": 80.0, "desired_range": 150.0, "detection_range": 260.0,
			"weapon_ready": true, "effects": {}, "hp_ratio": 0.2, "delta": 0.016,
			"cover_available": true,
		})
		seek_ok = str(d_seek.get("action", "")) == "seek_cover"
		var d_flank: Dictionary = ai2.evaluate({
			"self_position": Vector2(0, 0), "player_position": Vector2(40, 0),
			"distance": 40.0, "desired_range": 150.0, "detection_range": 260.0,
			"weapon_ready": true, "effects": {}, "hp_ratio": 1.0, "delta": 0.016,
		})
		flank_ok = str(d_flank.get("action", "")) == "flank"
		var d_im: Dictionary = ai2.evaluate({
			"self_position": Vector2(0, 0), "player_position": Vector2(100, 0),
			"distance": 100.0, "desired_range": 150.0, "detection_range": 260.0,
			"weapon_ready": true, "effects": {"immobilized": true}, "hp_ratio": 0.8, "delta": 0.016,
		})
		immobilized_hold = str(d_im.get("action", "")) in ["hold_fire", "hold"]
	check("tactics retreats on low hp without cover", retreat_ok)
	check("tactics seeks cover on low hp with cover", seek_ok)
	check("tactics flanks when too close", flank_ok)
	check("tactics holds when immobilized", immobilized_hold)

	# Part mechanical effects (Block 6)
	var body_kmf = DamageSystem.create_body("kmf")
	DamageSystem.apply_damage(body_kmf, "left_leg", 999.0)
	DamageSystem.apply_damage(body_kmf, "right_leg", 999.0)
	var eff_im = PartEffects.evaluate(body_kmf)
	check("both legs destroyed immobilizes", bool(eff_im.get("immobilized", false)))
	var body_w = DamageSystem.create_body("kmf")
	DamageSystem.apply_damage(body_w, "weapon", 999.0)
	var eff_w = PartEffects.evaluate(body_w)
	check("weapon destroyed disables fire", bool(eff_w.get("weapon_disabled", false)))
	var body_s = DamageSystem.create_body("kmf")
	DamageSystem.apply_damage(body_s, "sensor", 999.0)
	var eff_s = PartEffects.evaluate(body_s)
	check("sensor destroyed degrades detection", bool(eff_s.get("sensor_degraded", false)) and float(eff_s.get("detection_multiplier", 1.0)) < 1.0)

	# Aggregate HP compatibility after part damage already checked earlier; re-confirm default target
	var core2 = CombatCore.new()
	var t2 = Combatant.new("t2", "t", "enemy", "human", 40.0)
	core2.register_combatant(t2)
	var auto_hit = core2.resolve_shot("", "t2", "auto", 5.0, {"aim_point": t2.position})
	check("auto part targeting succeeds", bool(auto_hit.get("ok", false)) and bool(auto_hit.get("hit", false)))
	check("auto targeting produces a part_id", str(auto_hit.get("part_id", "")) != "")

	# Re-hitting an already-destroyed part must not emit duplicate transition events.
	var core3 = CombatCore.new()
	var t3 = Combatant.new("t3", "t", "enemy", "kmf", 300.0)
	core3.register_combatant(t3)
	core3.apply_damage("t3", "sensor", 999.0, {})
	core3.apply_damage("t3", "sensor", 1.0, {})
	var part_destroyed_events: int = 0
	for event in core3.get_event_log():
		if str(event.get("kind", "")) == "part_destroyed" and str(event.get("part_id", "")) == "sensor":
			part_destroyed_events += 1
	check("part-destroyed transition emits once", part_destroyed_events == 1)

	_finish()

func _finish() -> void:
	print("Ran %d / %d; failures=%d" % [ran, EXPECTED_CHECKS, failures.size()])
	if ran != EXPECTED_CHECKS:
		print("INCOMPLETE (expected %d checks)" % EXPECTED_CHECKS)
		quit(2)
		return
	if not failures.is_empty():
		for f in failures:
			print("  FAIL: ", f)
		quit(1)
		return
	print("ALL CHECKS PASSED")
	quit(0)
