extends SceneTree

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	var chars = ["赤", "都", "道", "戦", "補", "給"]
	var font := SystemFont.new()
	font.font_names = PackedStringArray([
		"Noto Sans CJK JP",
		"Noto Sans CJK",
		"Source Han Sans",
		"Yu Gothic",
		"YuGothic",
		"Hiragino Sans",
		"Hiragino Kaku Gothic ProN",
		"Meiryo",
		"MS Gothic",
		"IPAGothic",
		"TakaoPGothic",
		"sans-serif"
	])
	var missing: Array[String] = []
	for ch in chars:
		if not font.has_char(ch.unicode_at(0)):
			missing.append(ch)
	var result = "SUPPORTED" if missing.is_empty() else "MISSING:" + ",".join(missing)
	var f = FileAccess.open("res://tests/font-support-result.txt", FileAccess.WRITE)
	if f:
		f.store_string(result)
		f.close()
	print("FONT_SUPPORT_RESULT=", result)
	if OS.get_name() == "Windows" and not missing.is_empty():
		push_error("Japanese UI glyph support missing on Windows target: " + ",".join(missing))
		quit(1)
	else:
		if not missing.is_empty():
			push_warning("Japanese UI glyphs unavailable on this non-Windows CI host: " + ",".join(missing))
		quit(0)
