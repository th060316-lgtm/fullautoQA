extends RefCounted
## InputRouter - 論理アクション abstraction (Phase 0.5 Block 1)
##
## 目的:
##   1. 「キーコンフィグを後から実装できる」論理アクション層を用意する。
##   2. 既存の InputMap を壊さない (既存 action は InputMap が正典のまま)。
##   3. マウス操作 (左クリック=主攻撃 / 右クリック=照準) を InputMap 改変なしで足す。
##
## 方針:
##   - 既存 action (move_up / fire / interact / board_kmf / save_game ...) は
##     Input.is_action_pressed() をそのまま使い、挙動互換を100%保つ。
##   - 既存に無い action だけ runtime で InputMap へ登録する
##     (project.godot を改変しないため、起動失敗リスクゼロ)。
##   - 「プロファイル」でキー割当を切り替える。default=本編 / lab=Lab。
##
## 注意: InputMap への runtime 登録は Input.has_action() で存在判定し、
## 既に project.godot 側で定義されている場合は上書きしない。

const PROFILE_DEFAULT: String = "default"
const PROFILE_LAB: String = "lab"
const PROFILE_TACTICAL: String = "tactical"

## logical action -> {"keys": [Key], "buttons": [MouseButton]}
const BINDINGS: Dictionary = {
	# --- 移動 (InputMap 既存の move_* を優先) ---
	"move_up": {"keys": [KEY_W, KEY_UP], "buttons": []},
	"move_down": {"keys": [KEY_S, KEY_DOWN], "buttons": []},
	"move_left": {"keys": [KEY_A, KEY_LEFT], "buttons": []},
	"move_right": {"keys": [KEY_D, KEY_RIGHT], "buttons": []},
	# --- 戦闘 ---
	"fire": {"keys": [KEY_SPACE], "buttons": []},
	"primary_attack": {"keys": [], "buttons": [MOUSE_BUTTON_LEFT]},
	"aim": {"keys": [], "buttons": [MOUSE_BUTTON_RIGHT]},
	"sprint": {"keys": [KEY_SHIFT], "buttons": []},
	# --- 操作 ---
	"interact": {"keys": [KEY_F], "buttons": []},
	"board_kmf": {"keys": [KEY_E], "buttons": []},
	"hud_toggle": {"keys": [KEY_H], "buttons": []},
	"tactical_pause": {"keys": [KEY_P], "buttons": []},
	"tactical_select": {"keys": [], "buttons": [MOUSE_BUTTON_LEFT]},
	"tactical_context": {"keys": [], "buttons": [MOUSE_BUTTON_RIGHT]},
	"tactical_speed_1": {"keys": [KEY_1], "buttons": []},
	"tactical_speed_4": {"keys": [KEY_4], "buttons": []},
	"tactical_speed_8": {"keys": [KEY_8], "buttons": []},
	# --- 系統 ---
	"save_game": {"keys": [KEY_F5], "buttons": []},
	"load_game": {"keys": [KEY_F6], "buttons": []},
	"debug_dump": {"keys": [KEY_F12], "buttons": []},
	# --- Lab 専用 ---
	"lab_dodge": {"keys": [KEY_SPACE], "buttons": []},
	"lab_pause": {"keys": [KEY_P], "buttons": []},
	"lab_reset": {"keys": [KEY_R], "buttons": []},
	"lab_mode_cycle": {"keys": [KEY_TAB], "buttons": []},
	"lab_plan_confirm": {"keys": [KEY_ENTER, KEY_KP_ENTER], "buttons": []},
	"lab_target_cycle": {"keys": [KEY_Q], "buttons": []},
	"lab_retreat": {"keys": [KEY_X], "buttons": []},
}

## 既定プロファイルで InputMap へ runtime 登録する action のみ。
## lab_* は Lab シーン内でのみ使用する。
const RUNTIME_ACTIONS: Array = [
	"primary_attack", "aim", "sprint", "hud_toggle", "tactical_pause",
	"tactical_select", "tactical_context", "tactical_speed_1",
	"tactical_speed_4", "tactical_speed_8",
	"lab_dodge", "lab_pause", "lab_reset", "lab_mode_cycle",
	"lab_plan_confirm", "lab_target_cycle", "lab_retreat",
]

## 人が読むアクション表示名
const DISPLAY_LABELS: Dictionary = {
	"move_up": "W / ↑",
	"move_down": "S / ↓",
	"move_left": "A / ←",
	"move_right": "D / →",
	"fire": "Space",
	"primary_attack": "左クリック",
	"aim": "右クリック",
	"sprint": "Shift",
	"interact": "F",
	"board_kmf": "E",
	"hud_toggle": "H",
	"tactical_pause": "P",
	"tactical_select": "左クリック",
	"tactical_context": "右クリック",
	"tactical_speed_1": "1",
	"tactical_speed_4": "4",
	"tactical_speed_8": "8",
	"save_game": "F5",
	"load_game": "F6",
	"debug_dump": "F12",
	"lab_dodge": "Space",
	"lab_pause": "P",
	"lab_reset": "R",
	"lab_mode_cycle": "Tab",
	"lab_plan_confirm": "Enter",
	"lab_target_cycle": "Q",
	"lab_retreat": "X",
}

static var _registered: bool = false

## InputMap へ action を登録する (既にあるものは何もしない)。
## 呼び出しは冪等。static なので誰でも呼べる。
static func ensure_actions_registered() -> void:
	if _registered:
		return
	_registered = true
	for action_name in RUNTIME_ACTIONS:
		var action: String = str(action_name)
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, 0.5)
		var spec: Dictionary = BINDINGS.get(action, {})
		for key_code in spec.get("keys", []):
			var ev := InputEventKey.new()
			# keycode と physical_keycode の双方を割り当てる (レイアウト差で割れないように)
			ev.keycode = int(key_code)
			ev.physical_keycode = int(key_code)
			InputMap.action_add_event(action, ev)
		for button in spec.get("buttons", []):
			var mb := InputEventMouseButton.new()
			mb.button_index = int(button)
			InputMap.action_add_event(action, mb)

## 論理アクションが押されているか。
static func is_pressed(action: String) -> bool:
	ensure_actions_registered()
	if InputMap.has_action(action):
		return Input.is_action_pressed(action)
	return false

## 論理アクションがこのフレームで押されたか。
static func is_just_pressed(action: String) -> bool:
	ensure_actions_registered()
	if InputMap.has_action(action):
		return Input.is_action_just_pressed(action)
	return false

## 論理アクションが解放されたか。
static func is_just_released(action: String) -> bool:
	ensure_actions_registered()
	if InputMap.has_action(action):
		return Input.is_action_just_released(action)
	return false

## HUD 等に出すキーラベル。
static func get_label(action: String) -> String:
	return str(DISPLAY_LABELS.get(action, action))

## 指定プロファイルで action が割り当てられているか。
static func has_binding(action: String, profile: String = PROFILE_DEFAULT) -> bool:
	if profile == PROFILE_TACTICAL:
		return action in [
			"tactical_select", "tactical_context", "tactical_pause",
			"tactical_speed_1", "tactical_speed_4", "tactical_speed_8",
			"hud_toggle",
		]
	if profile == PROFILE_LAB:
		return action.begins_with("lab_") or BINDINGS.has(action) or InputMap.has_action(action)
	return BINDINGS.has(action) or InputMap.has_action(action)

## HUDとContext UIが同じ表示源を使うための戦術操作一覧。
static func get_profile_labels(profile: String) -> Dictionary:
	if profile == PROFILE_TACTICAL:
		return {
			"select": get_label("tactical_select"),
			"context": get_label("tactical_context"),
			"pause": "Space / " + get_label("tactical_pause"),
			"speed": "%s / %s / %s" % [get_label("tactical_speed_1"), get_label("tactical_speed_4"), get_label("tactical_speed_8")],
			"debug": get_label("hud_toggle"),
		}
	return {}

## プロファイル一覧 (将来のキーコンフィグUI用)。
static func get_profiles() -> Array:
	return [PROFILE_DEFAULT, PROFILE_LAB, PROFILE_TACTICAL]

