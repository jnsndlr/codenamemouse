class_name TunnelNetwork
extends Node3D
## Four planes of dug cells, and everything about how they look.
##
## Storage is one GridMap per plane, as the implementation plan calls for: digging is
## setting a cell, collapse is clearing one, and Godot handles instancing and culling.
## Plane 0 is the surface -- it never holds floor cells, only ramps, which are entrances.
##
## The WALLS are not GridMap tiles. Connection-aware tiles would need a variant per
## neighbour mask, and the 8-way rule in GDD section 9 makes that combinatorially silly.
## Instead every dug cell emits a wall quad on each side that has no dug neighbour, all
## batched into one mesh per plane and rebuilt on change. At spike scale that rebuild is
## microseconds, and it gives something a tile set can't: a continuous bright rim tracing
## the exact outline of the network, which is the whole point of M2.

## Cutting a ramp from plane 0 is an ENTRANCE, and an entrance is the one dig that has to
## change the surface as well as the tunnel -- otherwise the ramp exists but the ground
## slab above it still has solid collision and the player simply cannot walk down.
signal entrance_cut(cell: Vector2i, step: Vector2i)

const PLANE_COUNT: int = 4
const SPACING: float = TunnelChunks.PLANE_SPACING
const CELL: float = TunnelChunks.CELL
## How far the earth face rises above the tunnel floor.
const WALL_HEIGHT: float = 0.55
## Width of the horizontal emissive band capping each wall. This band is the single
## biggest contributor to reading the shape from above -- it's the outline.
const RIM_WIDTH: float = 0.09

const SIDES: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)
]

@export_group("Bounds")
## Half-extent of diggable ground, in cells. Walls stop you WALKING off the arena; this is
## what stops you tunnelling off it. Without both, a tunnel runs out from under the map and
## you surface into open sky. Keep this inside the perimeter wall so tunnels never emerge
## underneath it.
@export var half_extent_cells: int = 37

@export_group("Look")
@export var floor_color: Color = Color(0.30, 0.26, 0.21)
@export var wall_color: Color = Color(0.17, 0.14, 0.11)
## Rim colour PER DEPTH, and this turned out to be load-bearing rather than decorative.
## With one colour for all planes, a zoomed-out three-plane network is unreadable: the
## planes are only SPACING apart, which at a 40 degree pitch projects to almost no screen
## offset, so three outlines land nearly on top of each other and dimming alone doesn't
## separate them. Hue does what vertical distance can't.
@export var rim_colors: Array[Color] = [
	Color(0.70, 0.80, 0.90),
	Color(0.40, 0.85, 1.00),
	Color(1.00, 0.70, 0.30),
	Color(1.00, 0.45, 0.80),
]
## How far unfocused planes fade toward invisible. The legibility bet is that ONE plane
## in focus reads, and all four at once does not.
@export_range(0.0, 1.0, 0.01) var unfocused_alpha: float = 0.28
@export_range(0.0, 1.0, 0.01) var unfocused_rim_energy: float = 0.15

var _cells: Array[Dictionary] = []
## Which way each ramp cell descends. Needed to rebuild its collision, since the GridMap
## stores orientation as an opaque basis index that is awkward to read back.
var _ramp_steps: Array[Dictionary] = []
var _grids: Array[GridMap] = []
var _walls: Array[MeshInstance3D] = []
var _bodies: Array[StaticBody3D] = []
var _shapes: Array[CollisionShape3D] = []
var _floor_materials: Array[StandardMaterial3D] = []
var _wall_materials: Array[StandardMaterial3D] = []
var _rim_materials: Array[StandardMaterial3D] = []
var _focus: int = 0


func _ready() -> void:
	for plane in range(PLANE_COUNT):
		_cells.append({})
		_ramp_steps.append({})

		var floor_material := _make_material(floor_color)
		var wall_material := _make_material(wall_color)
		var rim := rim_colors[plane] if plane < rim_colors.size() else Color.WHITE
		var rim_material := _make_material(rim)
		rim_material.emission_enabled = true
		rim_material.emission = rim
		rim_material.emission_energy_multiplier = 1.6
		_floor_materials.append(floor_material)
		_wall_materials.append(wall_material)
		_rim_materials.append(rim_material)

		var grid := GridMap.new()
		grid.name = "Plane%d" % plane
		grid.cell_size = Vector3(CELL, SPACING, CELL)
		grid.mesh_library = TunnelChunks.build(floor_material)
		grid.position = Vector3(0.0, plane_y(plane), 0.0)
		add_child(grid)
		_grids.append(grid)

		var wall := MeshInstance3D.new()
		wall.name = "Walls%d" % plane
		wall.position = Vector3(0.0, plane_y(plane), 0.0)
		add_child(wall)
		_walls.append(wall)

		# Collision is generated here rather than left to GridMap's MeshLibrary shapes.
		# Those shapes are set and valid but no body ever appears in the physics world, so
		# the player walks straight through the floor. Building one trimesh per plane from
		# the same cell data that drives the walls is deterministic, testable, and keeps
		# collision guaranteed identical to what's drawn. GridMap still does the rendering.
		var body := StaticBody3D.new()
		body.name = "Collision%d" % plane
		body.position = Vector3(0.0, plane_y(plane), 0.0)
		add_child(body)
		var shape := CollisionShape3D.new()
		body.add_child(shape)
		_bodies.append(body)
		_shapes.append(shape)

	set_focus_plane(0)


## Depth 0 is the surface. Each plane below sits one SPACING lower.
func plane_y(plane: int) -> float:
	return -SPACING * plane


func world_to_cell(position: Vector3) -> Vector2i:
	return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))


func cell_to_world(plane: int, cell: Vector2i) -> Vector3:
	return Vector3(cell.x * CELL, plane_y(plane), cell.y * CELL)


## Which plane a world height belongs to. Biased so that standing ON a floor reports that
## floor's plane rather than the one above it.
func plane_at_height(y: float) -> int:
	return clampi(roundi(-y / SPACING), 0, PLANE_COUNT - 1)


## Whether a cell is inside the diggable arena at all.
func in_bounds(cell: Vector2i) -> bool:
	return absi(cell.x) <= half_extent_cells and absi(cell.y) <= half_extent_cells


func is_dug(plane: int, cell: Vector2i) -> bool:
	return plane >= 0 and plane < PLANE_COUNT and _cells[plane].has(cell)


func cell_count(plane: int) -> int:
	return _cells[plane].size()


## Cut a floor cell. Returns false if it was already dug, so callers can tell a fresh
## segment from a no-op without re-querying.
func dig(plane: int, cell: Vector2i) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT or _cells[plane].has(cell):
		return false
	if not in_bounds(cell):
		return false
	_cells[plane][cell] = TunnelChunks.FLOOR
	_grids[plane].set_cell_item(Vector3i(cell.x, 0, cell.y), TunnelChunks.FLOOR)
	_rebuild_walls(plane)
	return true


## Cut a two-cell ramp descending from `plane` to `plane + 1`, starting at `cell` and
## running along `step`. Also digs the landing, because a ramp you arrive at the bottom of
## and cannot step off is worse than no ramp.
func dig_ramp(plane: int, cell: Vector2i, step: Vector2i) -> bool:
	if plane < 0 or plane + 1 >= PLANE_COUNT:
		return false
	if step == Vector2i.ZERO:
		return false

	var lower := cell + step
	# A ramp reaches two cells past its start, so all three have to be inside the arena --
	# checking only the entry cell lets a ramp land its exit outside the map.
	if not (in_bounds(cell) and in_bounds(lower) and in_bounds(lower + step)):
		return false
	if _cells[plane].has(cell) and _cells[plane][cell] != TunnelChunks.FLOOR:
		return false

	var orientation := _orientation_facing(step)
	for pair: Array in [[cell, TunnelChunks.RAMP_UPPER], [lower, TunnelChunks.RAMP_LOWER]]:
		var at: Vector2i = pair[0]
		var item: int = pair[1]
		_cells[plane][at] = item
		_ramp_steps[plane][at] = step
		_grids[plane].set_cell_item(Vector3i(at.x, 0, at.y), item, orientation)

	dig(plane + 1, lower + step)
	_rebuild_walls(plane)
	if plane == 0:
		entrance_cut.emit(cell, step)
	return true


## Focus a plane: it renders solid with a bright rim, everything else fades back. Called
## every time the player changes depth.
func set_focus_plane(plane: int) -> void:
	_focus = clampi(plane, 0, PLANE_COUNT - 1)
	for index in range(PLANE_COUNT):
		var focused := index == _focus
		var alpha := 1.0 if focused else unfocused_alpha
		_set_alpha(_floor_materials[index], alpha)
		_set_alpha(_wall_materials[index], alpha)
		_set_alpha(_rim_materials[index], alpha)
		_rim_materials[index].emission_energy_multiplier = (
			1.6 if focused else unfocused_rim_energy
		)


func get_focus_plane() -> int:
	return _focus


func _make_material(colour: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.95
	# Planes have to be able to fade, so they are transparent-capable from the start.
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


func _set_alpha(material: StandardMaterial3D, alpha: float) -> void:
	var colour := material.albedo_color
	colour.a = alpha
	material.albedo_color = colour


func _orientation_facing(step: Vector2i) -> int:
	# Ramp meshes descend toward +Z, so rotate that onto `step`. Asking a real grid for the
	# orthogonal index beats hardcoding Godot's 24-basis table from memory.
	var angle := atan2(float(step.x), float(step.y))
	return _grids[0].get_orthogonal_index_from_basis(Basis(Vector3.UP, angle))


## Rebuild everything derived from a plane's cell set: the wall mesh (dark quads on
## surface 0, emissive rim band on surface 1) and the collision trimesh.
func _rebuild_walls(plane: int) -> void:
	var cells: Dictionary = _cells[plane]
	var walls := SurfaceTool.new()
	var rims := SurfaceTool.new()
	walls.begin(Mesh.PRIMITIVE_TRIANGLES)
	rims.begin(Mesh.PRIMITIVE_TRIANGLES)

	var collision := PackedVector3Array()
	var half := CELL * 0.5
	var faces := 0

	for cell: Vector2i in cells:
		var centre := Vector3(cell.x * CELL, 0.0, cell.y * CELL)

		if cells[cell] != TunnelChunks.FLOOR:
			_collide_ramp(collision, centre, cells[cell], _ramp_steps[plane].get(cell))
			continue

		# Walkable surface.
		_collide_quad(collision,
			centre + Vector3(-half, 0.0, -half), centre + Vector3(half, 0.0, -half),
			centre + Vector3(half, 0.0, half), centre + Vector3(-half, 0.0, half))

		for side: Vector2i in SIDES:
			if cells.has(cell + side):
				continue

			# The shared edge between this cell and the missing neighbour.
			var outward := Vector3(side.x, 0.0, side.y)
			var along := Vector3(side.y, 0.0, -side.x)
			var edge := centre + outward * half
			var a := edge - along * half
			var b := edge + along * half

			var up := Vector3(0.0, WALL_HEIGHT, 0.0)
			_quad(walls, a, b, b + up, a + up)
			_collide_quad(collision, a, b, b + up, a + up)

			# Horizontal band capping the wall, laid INWARD so it reads from above.
			var inward := -outward * RIM_WIDTH
			_quad(rims, a + up, b + up, b + up + inward, a + up + inward)
			faces += 1

	var mesh: ArrayMesh = null
	if faces > 0:
		walls.generate_normals()
		rims.generate_normals()
		mesh = walls.commit()
		rims.commit(mesh)
		mesh.surface_set_material(0, _wall_materials[plane])
		mesh.surface_set_material(1, _rim_materials[plane])

	_walls[plane].mesh = mesh

	var body_shape: ConcavePolygonShape3D = null
	if not collision.is_empty():
		body_shape = ConcavePolygonShape3D.new()
		# Double-sided, so a quad emitted with the wrong winding still collides. Winding
		# is easy to get backwards and produces a floor you silently fall through, which
		# is a miserable thing to debug for zero benefit on static level geometry.
		body_shape.backface_collision = true
		body_shape.set_faces(collision)
	_shapes[plane].shape = body_shape


## Ramp halves slope from one edge to the other along `step`. Reconstructed here rather
## than read back off the GridMap so collision can never drift from what was stored.
func _collide_ramp(out: PackedVector3Array, centre: Vector3, item: int, step: Variant) -> void:
	if step == null:
		return
	var direction := Vector3((step as Vector2i).x, 0.0, (step as Vector2i).y)
	var side := direction.cross(Vector3.UP)
	var half := CELL * 0.5

	var high := 0.0 if item == TunnelChunks.RAMP_UPPER else -SPACING * 0.5
	var low := -SPACING * 0.5 if item == TunnelChunks.RAMP_UPPER else -SPACING

	var back := centre - direction * half
	var front := centre + direction * half
	_collide_quad(out,
		back - side * half + Vector3.UP * high, back + side * half + Vector3.UP * high,
		front + side * half + Vector3.UP * low, front - side * half + Vector3.UP * low)


func _collide_quad(out: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	for vertex: Vector3 in [a, b, c, a, c, d]:
		out.append(vertex)


func _quad(t: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	for vertex: Vector3 in [a, b, c, a, c, d]:
		t.add_vertex(vertex)
