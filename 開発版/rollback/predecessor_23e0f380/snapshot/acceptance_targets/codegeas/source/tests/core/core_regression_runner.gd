extends SceneTree
## Runs the existing Node-based core regression inside a real project/Main context.

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var packed = load("res://scenes/Main.tscn")
	if packed == null:
		print("[CORE-RUNNER] FAIL: Main scene missing")
		quit(2)
		return
	var main = packed.instantiate()
	get_root().add_child(main)
	await process_frame
	await process_frame

	var test_script = load("res://tests/core/test_core.gd")
	if test_script == null:
		print("[CORE-RUNNER] FAIL: test_core.gd failed to load")
		quit(2)
		return
	var test_node = test_script.new()
	main.add_child(test_node)
	var result: Dictionary = test_node.run_all()
	for detail in result.get("details", []):
		print(detail)
	print("[CORE-RUNNER] passed=%d failed=%d" % [int(result.get("passed", 0)), int(result.get("failed", 0))])
	if int(result.get("failed", 0)) > 0:
		quit(1)
		return
	print("CORE REGRESSION PASSED")
	quit(0)
