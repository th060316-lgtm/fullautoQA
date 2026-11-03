extends Node
## SaveManager - JSON系Save/Load
## schemaVersion必須、最低1スロット、論理状態完全一致を目標

const SAVE_DIR: String = "user://saves/"
const SLOT_NAME: String = "slot1"

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)

func save_game(slot: String = SLOT_NAME) -> bool:
	var snapshot = GameState.get_snapshot()
	# JSON numbers cannot safely round-trip the RNG's 64-bit state. Persist the
	# two integers as decimal strings; RngService.set_state also accepts legacy
	# numeric values through int(...), so old saves remain readable.
	if has_node("/root/RngService"):
		var rng_state: Dictionary = RngService.get_state()
		snapshot["meta"]["rng"] = {
			"seed": str(rng_state.get("seed", 0)),
			"state": str(rng_state.get("state", 0))
		}
	if has_node("/root/SocialManager"):
		snapshot["_socialRuntime"] = SocialManager.serialize()
	var d1 = get_parent().get_node_or_null("Day1Controller") if get_parent() else null
	if d1 and d1.has_method("serialize_runtime"):
		snapshot["_day1Runtime"] = d1.serialize_runtime()
	var json_str = JSON.stringify(snapshot, "\t")
	var path = SAVE_DIR + slot + ".json"
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Save failed: " + str(FileAccess.get_open_error()))
		EventBus.player_notice.emit("セーブに失敗しました")
		return false
	file.store_string(json_str)
	file.close()
	EventBus.save_completed.emit(slot)
	return true

func load_game(slot: String = SLOT_NAME) -> bool:
	var path = SAVE_DIR + slot + ".json"
	if not FileAccess.file_exists(path):
		EventBus.player_notice.emit("セーブデータがありません")
		return false
	var file = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Load failed")
		return false
	var json_str = file.get_as_text()
	file.close()
	var data = JSON.parse_string(json_str)
	if data == null or not data is Dictionary:
		push_error("Invalid save data")
		return false
	if not GameState.can_apply_snapshot(data):
		push_warning("Unsupported or invalid save schema")
		return false
	# Extract runtime-only payloads before restoring GameState.
	var rng_state = null
	if data.has("meta") and data["meta"].has("rng"):
		rng_state = data["meta"]["rng"]
		data["meta"].erase("rng")
	var social_data: Dictionary = data.get("_socialRuntime", {})
	var day1_runtime: Dictionary = data.get("_day1Runtime", {})
	data.erase("_socialRuntime")
	data.erase("_day1Runtime")

	# Restore subsystem runtime first. Some subsystem deserializers mirror their
	# state back into GameState, so the saved GameState snapshot is applied LAST
	# and remains the authoritative logical state.
	if has_node("/root/SocialManager") and not social_data.is_empty():
		SocialManager.deserialize(social_data)
	if not GameState.apply_snapshot(data):
		push_error("Save snapshot migration failed")
		return false

	# Restore RNG state AFTER GameState.apply_snapshot, which may seed RngService.
	if rng_state != null:
		RngService.set_state(rng_state)
	elif data.has("meta") and data["meta"].has("seed"):
		RngService.set_seed(int(data["meta"]["seed"]))

	var d1 = get_parent().get_node_or_null("Day1Controller") if get_parent() else null
	if d1:
		if d1.has_method("deserialize_runtime") and not day1_runtime.is_empty():
			d1.deserialize_runtime(day1_runtime)
		elif d1.has_method("upgrade_loaded_state"):
			# Old saves may not contain _day1Runtime. The persisted GameState still
			# needs the current Day1 schema/deadline/stage migration.
			d1.upgrade_loaded_state()

	EventBus.load_completed.emit(slot)
	return true

## ラウンドトリップテスト用
func test_round_trip() -> bool:
	var before = GameState.get_snapshot()
	var rng_before = RngService.get_state() if has_node("/root/RngService") else null
	var social_before: Dictionary = SocialManager.serialize() if has_node("/root/SocialManager") else {}
	var d1 = get_parent().get_node_or_null("Day1Controller") if get_parent() else null
	var d1_before: Dictionary = d1.serialize_runtime() if d1 and d1.has_method("serialize_runtime") else {}

	var tmp_slot = "_test_rt"
	if not save_game(tmp_slot):
		return false

	GameState.advance_time(10)
	GameState.damage_player(1.0)
	if d1 and d1.has_method("record_action"):
		d1.record_action("round_trip_mutation", {"test": true})

	if not load_game(tmp_slot):
		return false

	var after = GameState.get_snapshot()
	if not _logical_equal(before, after):
		_report_top_level_difference(before, after, "GameState")
		push_error("Round-trip mismatch on GameState logical snapshot")
		EventBus.debug_message.emit("RT fail: GameState")
		return false

	if rng_before != null and not _logical_equal(rng_before, RngService.get_state()):
		push_error("Round-trip mismatch on RNG logical state")
		EventBus.debug_message.emit("RT fail: RNG")
		return false

	if has_node("/root/SocialManager"):
		var social_after: Dictionary = SocialManager.serialize()
		if not _logical_equal(social_before, social_after):
			_report_top_level_difference(social_before, social_after, "SocialRuntime")
			push_error("Round-trip mismatch on SocialManager runtime")
			EventBus.debug_message.emit("RT fail: SocialRuntime")
			return false

	if d1 and d1.has_method("serialize_runtime"):
		var d1_after: Dictionary = d1.serialize_runtime()
		if not _logical_equal(d1_before, d1_after):
			_report_top_level_difference(d1_before, d1_after, "Day1Runtime")
			push_error("Round-trip mismatch on Day1 runtime logical state")
			EventBus.debug_message.emit("RT fail: Day1 runtime")
			return false

	EventBus.debug_message.emit("Save/Load round-trip OK")
	return true

func _logical_equal(a: Variant, b: Variant) -> bool:
	# JSON represents all numeric values without preserving the original int/float
	# storage class. Round-trip acceptance therefore compares logical numeric value.
	if (a is int or a is float) and (b is int or b is float):
		return is_equal_approx(float(a), float(b))
	if typeof(a) != typeof(b):
		return false
	if a is Dictionary:
		if a.size() != b.size():
			return false
		for key in a.keys():
			if not b.has(key) or not _logical_equal(a[key], b[key]):
				return false
		return true
	if a is Array:
		if a.size() != b.size():
			return false
		for i in range(a.size()):
			if not _logical_equal(a[i], b[i]):
				return false
		return true
	return a == b

func _report_top_level_difference(before: Dictionary, after: Dictionary, label: String) -> void:
	var keys: Array = before.keys()
	for key in after.keys():
		if key not in keys:
			keys.append(key)
	for key in keys:
		if not before.has(key):
			print("[RT-DIFF] %s added section: %s" % [label, key])
		elif not after.has(key):
			print("[RT-DIFF] %s missing section: %s" % [label, key])
		elif not _logical_equal(before[key], after[key]):
			print("[RT-DIFF] %s differs at section: %s" % [label, key])



