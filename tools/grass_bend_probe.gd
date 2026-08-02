extends SceneTree
## Does a bending blade keep its length?
##
## Replicates both versions of grass_interact.gdshader's vertex maths in GDScript and measures the
## blade. The old one slid each vertex sideways and left its height alone, which makes the blade
## the hypotenuse of its own lean -- it GROWS as something walks into it, and since the wind drives
## the same term it never stops. The new one drops each vertex so its distance from the root is
## unchanged, so the tip travels along an arc instead of off the end of one.
##
##   godot --headless --script res://tools/grass_bend_probe.gd

## grass_patch.gd's blade_segments = 3 gives a QuadMesh with five rows of vertices.
const ROWS := 5
const INTERACT_POWER := 0.18


func _process(_delta: float) -> bool:
	return true


func _initialize() -> void:
	print("blade length under load, as a %% of its rest length")
	print("(push 1.0 is a sprinting mouse at point blank; 0.04 is the wind alone)\n")
	print("  push   rest    old      new")
	for height: float in [0.44, 0.68]:
		print("-- blade %.2f m" % height)
		for push: float in [0.04, 0.25, 0.5, 0.75, 1.0, 1.05]:
			var old_len := _length(height, push, false)
			var new_len := _length(height, push, true)
			print("  %.2f   %.3f   %+5.1f%%   %+5.1f%%" % [
				push, height, 100.0 * (old_len / height - 1.0), 100.0 * (new_len / height - 1.0)
			])


## Walk the blade's spine and sum the distance between consecutive vertices -- its arc length,
## which is the thing a bend must not change and a stretch does.
func _length(height: float, push: float, preserve: bool) -> float:
	var points: Array[Vector2] = []
	for row in range(ROWS):
		# UV.y is 1 at the root and 0 at the tip; VERTEX.y is the other way round.
		var uv_y := 1.0 - float(row) / float(ROWS - 1)
		var vertex_y := 1.0 - uv_y
		var freedom := (1.0 - uv_y) * (1.0 - uv_y)

		# The push is horizontal in world metres; the blade's local Y is scaled by its height.
		var lean := push * INTERACT_POWER * freedom
		var along := vertex_y * height
		var world_y := along
		if preserve:
			world_y = sqrt(maxf(along * along - lean * lean, 0.0))
		points.append(Vector2(lean, world_y))

	var total := 0.0
	for i in range(1, points.size()):
		total += points[i].distance_to(points[i - 1])
	return total
