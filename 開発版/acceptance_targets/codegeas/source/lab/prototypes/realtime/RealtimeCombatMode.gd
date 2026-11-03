extends "res://lab/CombatMode.gd"
## RealtimeCombatMode - 方式 A: 完全リアルタイム (Phase 0.5 Block 3)
##
## 特徴:
##   - シミュレーションは連続。planning / pause は存在しない。
##   - プレイヤーは常時操作でき、判断頻度は上限が無い。
##   - 数値 (ダメージ・射撃間隔・敵性能) は他方式と同一。
##
## 比較軸の予想:
##   操作しやすさ (最高) / 部位攻撃との相性 (中) / 仲間指示 (低) /
##   戦術の幅 (中) / 視認性 (高) / AI実装負荷 (低) / コンテンツ制作負荷 (中)

func get_mode_id() -> String:
	return "realtime"

func get_display_name() -> String:
	return "A: 完全リアルタイム"

func get_description() -> String:
	return "連続シミュレーション。停止できない。判断頻度は自由。"

## 完全リアルタイムでは停止できない (pause 回数 = 0)。
func enter_planning() -> bool:
	return false

func exit_planning() -> bool:
	return false

func get_status_lines() -> Array:
	var lines: Array = []
	lines.append("方式: %s" % get_display_name())
	lines.append("状態: 連続進行 (停止不可)")
	return lines
