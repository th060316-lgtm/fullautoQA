extends Node
## RngService - Seed固定可能な乱数サービス (Grok Core実装)
## 再現可能な乱数を提供する

var _seed: int = 0
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

func _ready() -> void:
	# デフォルトseedは起動時刻由来だが、明示set_seedを推奨
	_seed = int(Time.get_unix_time_from_system()) % 2147483647
	_rng.seed = _seed

func set_seed(value: int) -> void:
	_seed = value
	_rng.seed = value

func get_seed() -> int:
	return _seed

func randf_range_seeded(min_value: float, max_value: float) -> float:
	return _rng.randf_range(min_value, max_value)

func randi_range_seeded(min_value: int, max_value: int) -> int:
	return _rng.randi_range(min_value, max_value)

func randf() -> float:
	return _rng.randf()

func randi() -> int:
	return _rng.randi()

## 状態保存用
func get_state() -> Dictionary:
	return {
		"seed": _seed,
		"state": _rng.state
	}

func set_state(state: Dictionary) -> void:
	if state.has("seed"):
		_seed = int(state["seed"])
		_rng.seed = _seed
	if state.has("state"):
		_rng.state = int(state["state"])

# --- Social/UI compatibility helpers ---
func randf_range(min_value: float, max_value: float) -> float:
	return randf_range_seeded(min_value, max_value)

func randi_range(min_value: int, max_value: int) -> int:
	return randi_range_seeded(min_value, max_value)

func choice(arr: Array):
	if arr.is_empty():
		return null
	return arr[randi_range_seeded(0, arr.size() - 1)]

func shuffle(arr: Array) -> Array:
	var copy: Array = arr.duplicate()
	for i in range(copy.size() - 1, 0, -1):
		var j := randi_range_seeded(0, i)
		var tmp = copy[i]
		copy[i] = copy[j]
		copy[j] = tmp
	return copy

func probability(p: float) -> bool:
	return randf() < clampf(p, 0.0, 1.0)
