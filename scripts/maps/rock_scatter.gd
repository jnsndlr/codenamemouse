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
## Only the substantial, collidable rocks are map terrain. Hundreds of pebbles are motion texture;
## drawing every one would turn the panel into grit and hide the routes it exists to explain.
var _minimap_rocks: Array[Dictionary] = []


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
			_add_body(spot, size, rock.rotation.y)
			_solid += 1
			_minimap_rocks.append({
				"position": spot,
				"radius": maxf(size.x, size.z) * 0.5,
			})

		placed += 1

	print("rock scatter: %d rocks, %d with collision" % [placed, _solid])


## The solid part of a big rock: a box standing ON the ground, never reaching under it.
##
## A ROCK'S COLLIDER MUST NOT REACH BELOW `y = 0`, AND THAT IS A RULE OF THIS WORLD RATHER THAN A
## DETAIL OF THIS FILE. Everything lying on the lawn collides on `WORLD_BIT`, which is the layer
## every mouse masks whatever plane it is standing on -- so a centimetre of surface rock hanging
## below the grass is a centimetre of surface rock standing in a tunnel.
##
## THE BUG IT FIXES WAS A BRUTE WELDED TO THE FLOOR OF PLANE 1. The body used to be a unit box
## parented to the MESH, so it inherited the mesh's scale, its 22% sinking and its lean -- and a
## big rock is up to 1.5m tall, which put the bottom of the box 33cm under the lawn and a leaning
## corner nearly 60cm under it. Plane 1's floor is at -0.65 and a mouse is 0.40 tall, so the earth
## between -0.25 and -0.65 is occupied ground: the box was IN it. The Brute met it first and met it
## worst -- widest body, so it reaches furthest from the corridor's spine -- and what a player saw
## was a class that jams solid in open tunnel, in the same handful of places every match, against
## nothing that is drawn anywhere.
##
## SO THE BODY IS ITS OWN NODE, not a child of the mesh, and that is the whole of the fix. Parented
## to the rock it could only ever inherit the sinking and the lean it has to be free of; out here
## the box is stated in world terms -- floor to visible top -- and cannot be dragged underground by
## an edit to how the rock LOOKS.
##
## THE LEAN IS DROPPED AND THE SPIN IS KEPT. Tilt is what sells a rock as dropped rather than
## placed, and it is worth exactly nothing to the physics: a couple of degrees on a lump you run
## into edge-on. Spinning about Y costs nothing and keeps the box lined up with the rock a player
## can see.
func _add_body(spot: Vector2, size: Vector3, turn: float) -> void:
	# The drawn rock spans its own height about a centre already lifted by 0.28 of it, so its top
	# is at 0.78 of the height and the rest is under the grass. The collider is that top part.
	var tall := size.y * 0.78
	var box := BoxShape3D.new()
	box.size = Vector3(size.x, tall, size.z)

	var shape := CollisionShape3D.new()
	shape.shape = box
	shape.position = Vector3(0.0, tall * 0.5, 0.0)

	var body := StaticBody3D.new()
	# Said out loud rather than left to the node default, because the default is right by accident
	# and this is the one property of a rock that a tunnel three quarters of a metre down depends on.
	body.collision_layer = TunnelNetwork.WORLD_BIT
	body.collision_mask = 0
	body.position = Vector3(spot.x, 0.0, spot.y)
	body.rotation.y = turn
	body.add_child(shape)
	add_child(body)


## Built on first ask and kept, like grass_patch.gd already does. The rocks are scattered once in
## `_ready` and never move, so rebuilding this was eighty-six dictionaries and eighty-six
## `to_global` calls per frame for an answer that could not have changed.
var _minimap_shapes: Array[Dictionary] = []


func minimap_shapes() -> Array[Dictionary]:
	if not _minimap_shapes.is_empty() or _minimap_rocks.is_empty():
		return _minimap_shapes
	for rock: Dictionary in _minimap_rocks:
		var local: Vector2 = rock["position"]
		var world: Vector3 = to_global(Vector3(local.x, 0.0, local.y))
		_minimap_shapes.append({
			"kind": &"circle",
			"style": &"surface_rock",
			"position": Vector2(world.x, world.z),
			"radius": rock["radius"],
			"min_radius_px": 1.1,
		})
	return _minimap_shapes
