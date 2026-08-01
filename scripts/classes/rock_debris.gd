class_name RockDebris
extends Node3D
## A boulder coming apart: the shell splits into wedges, they scatter, they settle, they fade.
##
## WHY IT IS ITS OWN NODE rather than an animation the barricade plays before freeing itself. The
## moment the third swing lands, the cell has to be walkable and out of the "blocked" set -- a
## Brute who has just earned the corridor should not be stopped by a rock that is visibly in
## pieces, and a bot re-planning during the animation must not be told the route is still shut.
## So the barricade dies immediately and this takes over the *look* of it. The rule and the
## picture have different lifetimes, so they are different objects.
##
## MADE OF THE ROCK IT CAME FROM. The shards are cut from the boulder's own triangles, in
## contiguous patches, each closed into a solid wedge by connecting the patch back to the centre.
## Scattering a handful of generic lumps would have been less code and would read as a rock being
## replaced by debris; this reads as the same rock breaking, because it is.
##
## ONE KNOWN INTERACTION, noted so it isn't a mystery later: the cave-in cursor's box ignores
## depth by design (dig_cursor.gdshader), so pieces that land inside the cell an Engineer happens
## to be aiming at are painted over by it. It cannot happen to the Brute doing the breaking, who
## has no such cursor, and it costs nothing when it does -- but it is why an early screenshot of
## this showed a rock vanishing into thin air rather than falling apart.
##
## NO PHYSICS BODIES. Half a dozen rigid bodies per break, on their own collision layer, for two
## thirds of a second of decoration, is a lot of moving parts to get a bounce that a line of
## integration gives you. They fall, they hit the floor, they lose most of it and skid. Nothing
## can be pushed by them, which is right: debris that shoves a mouse is a mechanic, and this is
## not one.

## How many pieces a boulder breaks into.
@export var shards: int = 6
## How hard they leave, in metres per second, outward from the centre. Kept modest: a boulder
## shouldered apart by a Brute drops into pieces around its own footprint, and pieces that clear
## the cell read as an explosion -- which is a different mechanic and one this game does not have.
@export var burst_speed: Vector2 = Vector2(0.7, 1.5)
## The upward kick on top of that. Without it everything slides along the floor and it reads as
## a rock deflating rather than breaking.
@export var lift_speed: Vector2 = Vector2(0.6, 1.4)
@export var spin_speed: float = 9.0
## Seconds before they start to go, and how long the fade takes. Short: this is punctuation, not
## a cutscene, and the Brute wants to walk through the gap.
@export var settle_seconds: float = 0.5
@export var fade_seconds: float = 0.5
## How much of its speed a shard keeps when it hits the floor. Low -- these are stones, not balls.
@export_range(0.0, 1.0, 0.05) var bounce: float = 0.25
@export var gravity: float = 9.0

var _pieces: Array[Dictionary] = []
var _material: StandardMaterial3D
var _age: float = 0.0


## Break `shell` apart at `at`. `size` is the boulder's current scale, which matters because a
## barricade shrinks as it takes hits and the pieces should match what was on screen.
static func burst(
	parent: Node, at: Vector3, shell: ArrayMesh, colour: Color, size: float, seed_value: int
) -> RockDebris:
	var debris := RockDebris.new()
	parent.add_child(debris)
	# Placed after entering the tree, so `at` is honoured as the world point it is regardless of
	# what transform the parent happens to carry.
	debris.global_position = at
	debris._build(shell, colour, size, seed_value)
	return debris


func _build(shell: ArrayMesh, colour: Color, size: float, seed_value: int) -> void:
	if shell == null or shell.get_surface_count() == 0:
		queue_free()
		return

	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	_material = StandardMaterial3D.new()
	_material.albedo_color = colour
	_material.roughness = 0.95
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Ordinary alpha. This used to be impossible -- the pixel pass ran before the transparent
	# queue and erased anything translucent -- but it is a CompositorEffect now and runs after,
	# so a fade is just a fade. See mouse.gd, which paid for that lesson.
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	DirtTexture.apply_to(_material)

	var vertices: PackedVector3Array = shell.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var triangles := vertices.size() / 3
	if triangles < shards:
		queue_free()
		return

	# Contiguous runs of triangles, because the shell is generated ring by ring -- so a run is a
	# patch of neighbouring surface rather than a scattering of unrelated faces.
	# The middle of the boulder, not its origin. The shell is built sitting ON the floor, so its
	# origin is the ground under it -- pulling the shards toward that point made every piece a
	# thin curl that pointed at the mouse's feet rather than a wedge cut out of a rock.
	var core := shell.get_aabb().get_center()

	# EACH PIECE IS A PATCH AROUND A DIRECTION, not a run of consecutive triangles. The shell is
	# generated ring by ring, so consecutive triangles are a band that goes all the way round the
	# boulder -- every shard came out a long curved sliver, like a slice of orange peel. Bucketing
	# by whichever seed direction a triangle faces gives compact patches instead, and it does not
	# care how the shell was built.
	var seeds: Array[Vector3] = []
	for i in range(shards):
		seeds.append(Vector3(
			rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)
		).normalized())

	var buckets: Array[PackedInt32Array] = []
	for i in range(shards):
		buckets.append(PackedInt32Array())
	for triangle in range(triangles):
		var facing := (
			(vertices[triangle * 3] + vertices[triangle * 3 + 1] + vertices[triangle * 3 + 2])
			/ 3.0 - core
		)
		if facing.length_squared() < 0.000001:
			facing = Vector3.UP
		facing = facing.normalized()
		var best := 0
		var closest := -2.0
		for i in range(shards):
			var score := seeds[i].dot(facing)
			if score > closest:
				closest = score
				best = i
		buckets[best].append(triangle)

	for bucket: PackedInt32Array in buckets:
		if not bucket.is_empty():
			_add_piece(vertices, bucket, core, size, rng)


func _add_piece(
	vertices: PackedVector3Array, bucket: PackedInt32Array, core: Vector3, size: float,
	rng: RandomNumberGenerator
) -> void:
	# The patch's own centre, so the piece can be built around its origin and then moved -- a mesh
	# built in boulder space would rotate about the boulder's middle and swing rather than tumble.
	var middle := Vector3.ZERO
	for triangle: int in bucket:
		middle += vertices[triangle * 3] + vertices[triangle * 3 + 1] + vertices[triangle * 3 + 2]
	middle /= float(bucket.size() * 3)

	var t := SurfaceTool.new()
	t.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i: int in bucket:
		var a := vertices[i * 3] * size
		var b := vertices[i * 3 + 1] * size
		var c := vertices[i * 3 + 2] * size
		var origin := middle * size
		# The outer face, and the same triangle pulled in toward the boulder's core, joined up the
		# sides. That closes each shard into a solid wedge -- a bare patch of shell is a curved
		# sheet, and a sheet seen edge-on disappears, which reads as pieces blinking out.
		var centre := core * size
		var inner_a := centre + (a - centre) * 0.3
		var inner_b := centre + (b - centre) * 0.3
		var inner_c := centre + (c - centre) * 0.3
		for vertex: Vector3 in [
			a, b, c,
			inner_c, inner_b, inner_a,
			a, inner_a, inner_b, a, inner_b, b,
			b, inner_b, inner_c, b, inner_c, c,
			c, inner_c, inner_a, c, inner_a, a,
		]:
			t.add_vertex(vertex - origin)
	t.generate_normals()

	var mesh := MeshInstance3D.new()
	mesh.mesh = t.commit()
	mesh.material_override = _material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh.position = middle * size
	add_child(mesh)

	# Outward from the middle of the boulder, so the pieces leave the way they were facing.
	var out := Vector3(middle.x, 0.0, middle.z)
	if out.length_squared() < 0.001:
		out = Vector3(rng.randf_range(-1.0, 1.0), 0.0, rng.randf_range(-1.0, 1.0))
	_pieces.append({
		"node": mesh,
		"velocity": (
			out.normalized() * rng.randf_range(burst_speed.x, burst_speed.y)
			+ Vector3.UP * rng.randf_range(lift_speed.x, lift_speed.y)
		),
		"spin": Vector3(
			rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)
		).normalized() * rng.randf_range(spin_speed * 0.4, spin_speed),
	})


func _process(delta: float) -> void:
	# A burst with nothing to burst -- no shell, or a shell with fewer triangles than pieces --
	# frees itself during `_build`, and a deferred free still gets a tick or two first.
	if _material == null:
		return
	_age += delta
	for piece: Dictionary in _pieces:
		var node: MeshInstance3D = piece["node"]
		var velocity: Vector3 = piece["velocity"]
		velocity.y -= gravity * delta
		node.position += velocity * delta
		node.rotation += (piece["spin"] as Vector3) * delta

		# The floor of the cell, which is this node's own origin. Anything below it has landed.
		if node.position.y < 0.02:
			node.position.y = 0.02
			velocity.y = -velocity.y * bounce
			velocity.x *= 0.6
			velocity.z *= 0.6
		piece["velocity"] = velocity

	if _age < settle_seconds:
		return
	var left := 1.0 - (_age - settle_seconds) / maxf(fade_seconds, 0.01)
	if left <= 0.0:
		queue_free()
		return
	_material.albedo_color.a = left
