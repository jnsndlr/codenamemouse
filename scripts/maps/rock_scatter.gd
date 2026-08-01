extends Node3D
## Scatters rocks across the arena so you can tell you're moving.
##
## An 80x80 slab of flat ground gives the eye nothing to measure against -- at mouse scale
## you can run for seconds and feel stationary, because nothing passes you. Rocks are
## motion reference first and cover second, which is why there are a lot of small ones
## rather than a few big ones: what sells speed is things streaming past close by.
##
## Seeded, so the layout is identical every run and a session is reproducible. That's also
## the direction GDD section 8 goes -- maps as a recipe plus a seed rather than a fixed
## layout -- so this is a cheap rehearsal of that idea.

@export var rock_seed: int = 20260729
## Sized for DENSITY, not for total count. What matters is how many are in frame: the
## camera sees roughly 11x11 units, so ~0.14 rocks per square unit puts 15-odd on screen
## at all times. The first pass used 190 over the whole 80x80 arena, which worked out to
## about two in view, and running past two rocks feels identical to running past none.
@export var count: int = 760
## Kept inside the perimeter wall.
@export var half_extent: float = 37.0
## No rocks in the spawn area, so you don't start the session inside one.
@export var clear_radius: float = 2.0

@export_group("Size")
@export var small_size: Vector2 = Vector2(0.25, 0.7)
@export var large_size: Vector2 = Vector2(1.0, 2.0)
## Fraction that are the bigger sort. Mostly small -- big rocks read as cover and block
## sightlines, and this milestone wants speed cues, not a maze.
@export_range(0.0, 1.0, 0.01) var large_fraction: float = 0.10
## Only rocks at least this tall get collision. Pebbles are scenery you run straight over:
## giving all 760 a physics body would cost a lot to have the mouse constantly snagging on
## specks, and the point of the small ones is that they stream past, not that they stop you.
@export var collide_above: float = 0.9

@export_group("Look")
## Deliberately cooler and darker than the ground's (0.44, 0.42, 0.31). The first pass was
## near-identical to it, so even the large rocks barely separated from the dirt -- and a
## rock you can't distinguish from the ground tells you nothing about how fast you're going.
@export var rock_color: Color = Color(0.33, 0.32, 0.31)

var _solid: int = 0


func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = rock_seed

	# One material and one mesh shared by every rock. Per-rock copies would mean ~190
	# materials for the depth-focus fade to walk, for no visual difference.
	var material := StandardMaterial3D.new()
	material.albedo_color = rock_color
	material.roughness = 0.95
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	mesh.material = material

	var placed := 0
	var attempts := 0
	while placed < count and attempts < count * 12:
		attempts += 1
		var spot := Vector2(
			rng.randf_range(-half_extent, half_extent),
			rng.randf_range(-half_extent, half_extent)
		)
		if spot.length() < clear_radius:
			continue
		# Nests keep their ground clear. A rock on the capture disc is ugly; a rock on the spawn
		# point is a bot pinned against it for a whole match -- and the scatter is seeded, so it
		# would happen every single time and look like an AI bug.
		if Nest.blocks(get_tree(), spot):
			continue
		# Nothing lies on a patio. The zone's whole job is to read as obviously not-ground from
		# across the yard (GDD section 3), and pebbles scattered over the slab undo that faster
		# than any amount of getting the colour right.
		if NoSurfaceZone.seals(get_tree(), spot):
			continue

		var big := rng.randf() < large_fraction
		var span: Vector2 = large_size if big else small_size
		var size := Vector3(
			rng.randf_range(span.x, span.y),
			rng.randf_range(span.x, span.y) * 0.75,
			rng.randf_range(span.x, span.y)
		)

		var rock := MeshInstance3D.new()
		rock.name = "Rock%d" % placed
		rock.mesh = mesh
		rock.scale = size
		# Sunk slightly so they read as embedded in the ground rather than resting on it.
		rock.position = Vector3(spot.x, size.y * 0.5 - size.y * 0.22, spot.y)
		rock.rotation.y = rng.randf_range(0.0, TAU)
		rock.rotation.x = rng.randf_range(-0.12, 0.12)
		rock.rotation.z = rng.randf_range(-0.12, 0.12)
		add_child(rock)

		if maxf(size.x, size.z) >= collide_above:
			var body := StaticBody3D.new()
			var shape := CollisionShape3D.new()
			var box := BoxShape3D.new()
			box.size = Vector3.ONE
			shape.shape = box
			body.add_child(shape)
			rock.add_child(body)
			_solid += 1

		placed += 1

	print("rock scatter: %d rocks, %d with collision" % [placed, _solid])
