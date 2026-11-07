extends RefCounted
## PartEffects - 部位破壊から導かれる「効果」を導出する (Phase 0.5 Block 4)
##
## 開発計画 3.3 の要求:
##   「コックピットを狙って高速撃破 / 脚を破壊して移動不能化 / 腕を破壊して攻撃能力低下 /
##     武器を破壊して無力化 / センサーを破壊して索敵・命中低下 /
##     機体を可能な限り残して鹵獲」
##
## ここには「どの部位が壊れたか -> どう変化するか」だけを置く。
## 戦闘方式 (RT / Paused / WEGO) に依存しないため、Core 側に固定される。
##
## DamageSystem (既存) の PROFILES を拡張する関係には置かない。
## DamageSystem は触らず、Effected 変換だけを本ファイルが持つ。

## 部位破壊から効果を導出する。
## body: DamageSystem.create_body() 由来の body 辞書
static func evaluate(body: Dictionary) -> Dictionary:
	var parts: Dictionary = body.get("parts", {})
	var out: Dictionary = {
		"destroyed_parts": [],
		"disabled_parts": [],
		"immobilized": false,
		"mobility_multiplier": 1.0,
		"weapon_disabled": false,
		"accuracy_penalty": 0.0,
		"sensor_degraded": false,
		"detection_multiplier": 1.0,
		"pilot_dead": false,
		"structural_failure": false,
		"destroyed": false,
	}
	var destroyed: Array = []
	for part_id in parts.keys():
		var part: Dictionary = parts[part_id]
		if bool(part.get("destroyed", false)):
			destroyed.append(str(part_id))
	out["destroyed_parts"] = destroyed

	var has_left_leg: bool = destroyed.has("left_leg")
	var has_right_leg: bool = destroyed.has("right_leg")
	var has_left_arm: bool = destroyed.has("left_arm")
	var has_right_arm: bool = destroyed.has("right_arm")

	if destroyed.has("cockpit"):
		out["pilot_dead"] = true
		out["immobilized"] = true
	if destroyed.has("frame"):
		out["structural_failure"] = true
		out["destroyed"] = true
		out["immobilized"] = true
	if has_left_leg or has_right_leg:
		if has_left_leg and has_right_leg:
			out["immobilized"] = true
		else:
			out["mobility_multiplier"] = 0.6
	if has_left_arm or has_right_arm:
		if has_left_arm and has_right_arm:
			out["weapon_disabled"] = true
		else:
			out["accuracy_penalty"] = float(out["accuracy_penalty"]) + 0.2
	if destroyed.has("weapon"):
		out["weapon_disabled"] = true
	if destroyed.has("sensor"):
		out["sensor_degraded"] = true
		out["accuracy_penalty"] = float(out["accuracy_penalty"]) + 0.25
		out["detection_multiplier"] = 0.5
	out["accuracy_penalty"] = clampf(float(out["accuracy_penalty"]), 0.0, 0.85)
	return out

## 部位が破壊された直後、その部位による即時効果を部分集合で返す。
## フィードバック表示 (「脚を破壊した」等) 用。
static func describe_part_effect(part_id: String) -> String:
	match part_id:
		"cockpit": return "コックピット破壊: 操縦不能・高速撃破"
		"frame": return "機体骨格破壊: 即時撃破"
		"left_leg", "right_leg": return "脚部破壊: 移動能力低下"
		"left_arm", "right_arm": return "腕部破壊: 射撃精度低下"
		"weapon": return "武器破壊: 射撃不可"
		"sensor": return "センサー破壊: 索敵・命中低下"
		"energy": return "エネルギー系破壊: 出力低下"
		"head": return "頭部破壊: 戦闘不能"
		"torso": return "胴体破壊: 戦闘不能"
	return "部位破壊: " + part_id
