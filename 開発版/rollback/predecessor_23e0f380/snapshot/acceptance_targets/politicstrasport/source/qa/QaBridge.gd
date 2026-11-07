extends Node

@export var host := "127.0.0.1"
@export var port := 17777

var _server := TCPServer.new()
var _peer: StreamPeerTCP = null
var _recv_buffer := ""
var _adapter: Node = null


func _ready() -> void:
	var err := _server.listen(port, host)
	if err != OK:
		push_error("QA Bridge listen failed: %s" % err)
	else:
		print("QA Bridge listening on %s:%d" % [host, port])


func set_adapter(adapter: Node) -> void:
	_adapter = adapter


func _process(_delta: float) -> void:
	if _peer == null:
		if _server.is_connection_available():
			_peer = _server.take_connection()
			_recv_buffer = ""
		return
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		_peer = null
		_recv_buffer = ""
		return
	var available := _peer.get_available_bytes()
	if available <= 0:
		return
	_recv_buffer += _peer.get_utf8_string(available)
	while "\n" in _recv_buffer:
		var pos := _recv_buffer.find("\n")
		var line := _recv_buffer.substr(0, pos)
		_recv_buffer = _recv_buffer.substr(pos + 1)
		if line.strip_edges().is_empty():
			continue
		_handle_line(line)


func _handle_line(line: String) -> void:
	var data = JSON.parse_string(line)
	if typeof(data) != TYPE_DICTIONARY:
		_send({"ok": false, "error": "invalid_json"})
		return
	var cmd: String = str(data.get("cmd", ""))
	match cmd:
		"ping":
			_send({"ok": true, "pong": true, "bridge": "PoliticsTrasport-QA-v1"})
		"get_state":
			_send({"ok": true, "state": _get_state()})
		"input":
			if is_instance_valid(_adapter) and _adapter.has_method("qa_input_event"):
				var accepted = _adapter.call("qa_input_event", data.get("action", {}))
				_send({"ok": bool(accepted)})
			else:
				_send({"ok": false, "error": "input_adapter_unavailable"})
		_:
			_send({"ok": false, "error": "unknown_command"})


func _get_state() -> Dictionary:
	if is_instance_valid(_adapter) and _adapter.has_method("qa_get_state"):
		var state = _adapter.call("qa_get_state")
		if typeof(state) == TYPE_DICTIONARY:
			return state
	var scene_name := ""
	if get_tree().current_scene:
		scene_name = get_tree().current_scene.name
	return {"scene": scene_name, "goal_status": "running", "legal_actions": [], "qa_ready": false}


func _send(payload: Dictionary) -> void:
	if _peer == null:
		return
	_peer.put_data((JSON.stringify(payload) + "\n").to_utf8_buffer())



func _exit_tree() -> void:
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	_recv_buffer = ""
	_server.stop()
