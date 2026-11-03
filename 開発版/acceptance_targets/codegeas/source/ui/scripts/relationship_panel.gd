# ui/scripts/relationship_panel.gd
# NPC Relationship panel — shows relationship graph
# Shows relationship values (not raw affection truth)
# Color-coded: green=positive, red=negative, yellow=near-zero

extends Control

var _nm: Node

@onready var container: VBoxContainer = $MarginContainer/ScrollContainer/VBoxContainer

func _ready() -> void:
	_nm = get_node_or_null("/root/NpcManager")
	_refresh()

func _refresh() -> void:
	for child in container.get_children():
		child.queue_free()

	var npc_ids = _nm.get_npc_ids() if _nm else []
	for npc_id in npc_ids:
		var npc = _nm.get_npc(npc_id) if _nm else {}
		if npc.is_empty():
			continue

		var section = VBoxContainer.new()

		# NPC name header
		var header = Label.new()
		header.text = "◆ %s（%s）" % [npc.get("name", npc_id), npc_id]
		header.add_theme_color_override("font_color", Color(0.9, 0.9, 0.7))
		section.add_child(header)

		# Self stats
		var self_label = Label.new()
		var aff = npc.get("affection", 0)
		var trust = npc.get("trust", 0)
		var fear = npc.get("fear", 0)
		self_label.text = "  主人公への感情: %+d  信頼: %+d  恐怖: %+d" % [aff, trust, fear]
		section.add_child(self_label)

		# Relationship graph
		var rels = _nm.get_related_npcs(npc_id) if _nm else {}
		var shown = false
		for rel_type in ["positive", "negative", "neutral"]:
			var items = rels.get(rel_type, [])
			if items.is_empty():
				continue
			for rel in items:
				var rel_label = Label.new()
				var rid = rel["id"]
				var rval = rel["value"]
				var other_npc = _nm.get_npc(rid) if _nm else {}
				var other_name = other_npc.get("name", rid)

				var type_label = {"positive": "友好", "negative": "敵対", "neutral": "中立"}[rel_type]
				rel_label.text = "  %s → %s: %.0f" % [type_label, other_name, rval]

				var col = Color(0.8, 0.8, 0.8)
				if rel_type == "positive":
					col = Color(0.3, 0.8, 0.4)
				elif rel_type == "negative":
					col = Color(0.9, 0.3, 0.3)
				rel_label.add_theme_color_override("font_color", col)
				section.add_child(rel_label)
				shown = true

		if shown:
			container.add_child(section)
			var sep = HBoxContainer.new()
			sep.add_child(Label.new())
			sep.get_child(0).text = "────────────────"
			container.add_child(sep)

