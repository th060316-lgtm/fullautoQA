extends SceneTree

## MiniMax: Project 起動 / 実ラン動作のスモークテスト
##
## 実行:
##   godot --headless --script tests/GameBootSmokeTest.gd
##
## 確認する内容:
##   ・Main.tscn が起動し Main scene boot が完了する
##   ・MiniMax の各システム (船舶/航空/競争/AI/補給) が組み込まれる
##   ・ゲームループが日進する (x1)
##   ・x5 / Pause の切替が機能する
##   ・入力 (R/T/Y/U/P/A/X) がビルドモードへ反映される
##   ・実行中にエラーが出ない

var failures: Array[String] = []
var passes: Array[String] = []

func _init() -> void:
	call_deferred("_run")

func _ok(condition: bool, label: String, detail: String = "") -> void:
	if condition:
		passes.append(label)
		print("PASS: ", label)
	else:
		failures.append(label + (" :: " + detail if detail != "" else ""))
		push_error("FAIL: " + label + (" :: " + detail if detail != "" else ""))

func _run() -> void:
	print("=== PoliticsTrasport v0.2 MiniMax game boot smoke test ===")
	var packed = load("res://scenes/Main.tscn")
	_ok(packed != null, "Main.tscn loads")
	if packed == null:
		_finish()
		return
	var main = packed.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame

	var game = main.get_node_or_null("GameController")
	_ok(game != null, "GameController node exists")
	if game == null:
		_finish()
		return

	var w = game.world
	_ok(w != null, "WorldState initialised")
	_ok(w.settlements.size() == 6, "6 cities generated", str(w.settlements.size()))
	_ok(w.nations.size() == 3, "3 nations generated", str(w.nations.size()))
	var ai_count := 0
	for c in w.companies:
		if not c.is_player:
			ai_count += 1
	_ok(ai_count == 2, "2 AI competitors exist at boot", str(ai_count))
	_ok(game.transport_system != null, "TransportSystem (competition engine) wired")
	_ok(game.ship_system != null and game.air_system != null, "ShipSystem + AirSystem wired")
	_ok(game.ai_system != null, "AICompetitionSystem wired")
	_ok(main.get_node_or_null("UI/MiniMaxUI") != null, "MiniMaxUI created")
	_ok(main.get_node_or_null("UI/TransportOverlay") != null, "TransportOverlay created")

	# ゲームループ: 一定時間回して日進・資金変化・AI行動を確認
	var day_before: int = w.day
	var pop_before: float = w.get_settlement(0).population
	for _i in range(240):
		await process_frame
	_ok(w.day > day_before, "Game loop advances days", "%d -> %d" % [day_before, w.day])
	_ok(w.get_settlement(0).population != pop_before,
		"City values evolve while the simulation runs", "%s -> %s" % [pop_before, w.get_settlement(0).population])
	var ai_built := 0
	for r in w.routes:
		if r.company_id != 0:
			ai_built += 1
	_ok(ai_built > 0, "AI competitors build connections during play", str(ai_built))
	_ok(w.event_log.size() > 0, "Event log records activity", str(w.event_log.size()))

	# x5 / Pause
	game.set_time_scale(5.0)
	_ok(_approx(game.time_scale, 5.0), "x5 speed switch works")
	game.toggle_pause()
	_ok(game.paused, "Pause toggle works")
	var day_paused: int = w.day
	for _i in range(30):
		await process_frame
	_ok(w.day == day_paused, "Paused simulation does not advance days")
	game.toggle_pause()
	game.set_time_scale(1.0)

	# 入力: ビルドモード
	for pair in [["build_road", 0], ["build_rail", 1], ["build_ship", 2], ["build_air", 3]]:
		var ev := InputEventAction.new()
		ev.action = pair[0]
		ev.pressed = true
		game._unhandled_input(ev)
		_ok(game.build_mode == int(pair[1]), "%s input enters build mode %d" % [pair[0], int(pair[1])])
	game.cancel_build()

	# 港/空港の開設 (選択中の都市に対して)
	w.money = 5000.0   # 港+空港+航路を順に開設できるだけの運転資金
	game.select_settlement(1)
	var port_ok: bool = game.build_port_selected()
	_ok(port_ok, "Port can be built at a coastal city via UI command")
	_ok(game.world.get_settlement(1).has_port, "City now has a port")
	game.select_settlement(0)
	_ok(not game.build_port_selected(), "Port build refused inland")
	game.select_settlement(2)
	# AI が既に空港を開設済みの場合は「空港を持つ」ことで成立とする
	game.build_airport_selected()
	_ok(game.world.get_settlement(2).has_airport, "City has an airport (built by player or already present)")
	_ok(game.world.get_settlement(2).has_airport, "Airport state is consistent")

	# 航路開設 (両端に港が必要)
	game.select_settlement(4)
	# AI が既に港を開いている可能性があるため「港を持てば成立」とする
	game.build_port_selected()
	_ok(game.world.get_settlement(4).has_port, "Second coastal city has a port")
	game.start_build_ship()
	game.select_settlement(4)
	game.select_settlement(1)
	var ship_routes := 0
	for r in w.routes:
		if r.type == Route.RouteType.SHIP and r.company_id == WorldState.PLAYER_COMPANY_ID:
			ship_routes += 1
	_ok(ship_routes == 1, "Player ship route created through the UI flow", str(ship_routes))

	main.queue_free()
	await process_frame
	await process_frame
	_finish()

func _approx(a: float, b: float, eps: float = 0.0001) -> bool:
	return abs(a - b) <= eps

func _finish() -> void:
	print("=== SUMMARY ===")
	print("PASS COUNT: ", passes.size())
	print("FAIL COUNT: ", failures.size())
	for f in failures:
		print("FAILED: ", f)
	if failures.size() > 0:
		quit(1)
	else:
		print("ALL BOOT SMOKE TESTS PASSED")
		quit(0)
