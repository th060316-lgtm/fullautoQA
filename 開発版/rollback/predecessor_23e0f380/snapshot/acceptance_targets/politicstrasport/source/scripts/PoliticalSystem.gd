class_name PoliticalSystem
extends RefCounted

var world: WorldState

func _init(p_world: WorldState):
	world = p_world

func process_day() -> void:
	if world.day % 25 == 0:
		for n in world.nations:
			if not n.active:
				continue
			var delta = world.rng.randf_range(-0.03, 0.04)
			n.stability = clamp(n.stability + delta, 0.20, 0.95)
	if world.day % 5 == 0:
		for n in world.nations:
			if n.active:
				n.recalculate_power(world.settlements)
