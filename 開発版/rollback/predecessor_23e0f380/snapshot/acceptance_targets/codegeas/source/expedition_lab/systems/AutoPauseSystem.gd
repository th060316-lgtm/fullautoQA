extends RefCounted

var paused := false
var reason := ""
var history: Array[Dictionary] = []

func trigger(code: String, message: String, sim_time: float, metrics: Dictionary) -> bool:
	paused = true; reason = message
	history.append({"code":code,"message":message,"time":sim_time})
	var counts: Dictionary = metrics.get("auto_pauses", {})
	counts[code] = int(counts.get(code, 0)) + 1; metrics["auto_pauses"] = counts
	return true

func resume() -> void:
	paused = false; reason = ""

func manual_pause(metrics: Dictionary) -> void:
	paused = true; reason = "手動停止"; metrics["manual_pauses"] = int(metrics.get("manual_pauses",0)) + 1
