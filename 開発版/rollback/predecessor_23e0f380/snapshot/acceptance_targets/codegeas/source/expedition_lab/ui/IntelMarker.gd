extends Node2D

var status := "unknown"
var uncertainty_radius := 0.0

func configure(value: String, uncertainty: float) -> void:
	status = value
	uncertainty_radius = uncertainty
	queue_redraw()

func _draw() -> void:
	if status == "confirmed":
		draw_colored_polygon(PackedVector2Array([Vector2(0,-10),Vector2(10,0),Vector2(0,10),Vector2(-10,0)]),Color("f15b5b"))
	elif status != "unknown":
		draw_circle(Vector2.ZERO,uncertainty_radius,Color(1,0.7,0.2,0.1))
		draw_arc(Vector2.ZERO,10,0,TAU,16,Color("f3bc52"),2)
