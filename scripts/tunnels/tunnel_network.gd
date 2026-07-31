class_name TunnelNetwork
extends Node3D
## Four planes of dug cells, and everything about how they look.
##
## Storage is one GridMap per plane, as the implementation plan calls for: digging is
## setting a cell, collapse is clearing one, and Godot handles instancing and culling.
##
## The WALLS are not GridMap tiles. Connection-aware tiles would need a variant per
## neighbour mask, and the 8-way rule in GDD section 9 makes that combinatorially silly.
## Instead every dug cell emits a wall quad on each side that has no dug neighbour, all
## batched into one mesh per plane and rebuilt on change. At spike scale that rebuild is
## microseconds, and it means the wall set is always exactly the outline of the network.
##
## HOW DEPTH IS READ. Each layer is drawn as an open TRENCH cut through solid earth. A lid
## sits one plane-spacing above every floor with the layer's own tunnels punched out of it
## (see earth_cutaway.gdshader), walls run the full height from floor to lid, and only the
## focused layer plus a dim hint of the one above it is drawn at all. You cannot see the
## layers below, so they cannot be confused with yours -- which is why the per-depth rim hue
## M2 landed on is gone. It was the right answer to "read four layers at once", and nobody
## needs to; what you want is your own tunnel, on the layer you are in.
##
## VERTICAL TRANSIT IS A SHAFT, not a ramp, and that single change deleted most of this file.
## A ramp was sloped, oriented, two cells long, and it hung down through the whole headroom
## of the plane below -- so it needed stored orientations, per-face height arithmetic, flank
## walls, a rule against digging underneath it, and a graph search on every cut to prove it
## had not sealed a tunnel off. A shaft is a flag on a flat cell. It takes no walkable space
## away and occupies nothing on the plane below, so digging can now only ever ADD
## connectivity, and every one of those mechanisms went with it.

## Why a dig didn't happen. Refusing silently is indistinguishable from the controls being
## broken -- the entrance key spent a whole session looking dead for exactly that reason.
signal dig_refused(reason: String)

const PLANE_COUNT: int = 4
const SPACING: float = TunnelChunks.PLANE_SPACING
const CELL: float = TunnelChunks.CELL
## Largest height change you can walk over. Every floor is flush with every other floor now,
## so nothing in the network ever exceeds it -- kept because props and map geometry will.
const STEP_TOLERANCE: float = 0.18
## Half-width of the dug mask, in cells. Comfortably past `half_extent_cells` so a tunnel can
## never reach a cell the cutaway has no texel for.
const MASK_HALF_CELLS: int = 64

## Bit 1 is the world: ground, arena walls, props, rocks. Everything a mouse collides with
## regardless of depth.
const WORLD_BIT: int = 1

const SIDES: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)
]

@export_group("Digging")
## How far a new shaft must keep from every existing one, in cells, measured as a square ring
## rather than a circle -- 1 forbids all eight neighbours, 0 turns the rule off.
##
## The GDD (section 3) always said each shaft has to start a tile away from the last; only the
## same-cell case was ever enforced, which let a staircase of shafts be packed into a 2x2 block
## and get you three planes down inside one stride. Spacing them out is what keeps depth a
## HORIZONTAL investment: to go deeper you have to tunnel sideways first, in the open, where it
## costs time and can be seen.
##
## It also fixes a legibility problem. Two mouths a cell apart read as one wide opening, and
## with a light beam falling down each the two pools of daylight merge into a single bright
## patch -- so the thing that is supposed to announce "a way out is HERE" stops saying where.
@export var shaft_exclusion_cells: int = 1

@export_group("Bounds")
## Half-extent of diggable ground, in cells. Walls stop you WALKING off the arena; this is
## what stops you tunnelling off it. Without both, a tunnel runs out from under the map and
## you surface into open sky. Keep this inside the perimeter wall so tunnels never emerge
## underneath it.
@export var half_extent_cells: int = 37

@export_group("Look")
## Warm, because the tunnel is lit from inside by lamplight and the world above is not. That
## temperature split is doing most of the work of telling you where you are.
@export var floor_color: Color = Color(0.46, 0.32, 0.20)
@export var wall_color: Color = Color(0.19, 0.13, 0.09)
## The earth a layer is cut into, seen from above. Only used for planes 2 and 3 -- plane 1's
## lid is the actual ground of the map, which the scene owns.
@export var lid_color: Color = Color(0.24, 0.18, 0.13)
## The mouth of a shaft leading down. Near-black, because it is a hole.
@export var shaft_down_color: Color = Color(0.05, 0.03, 0.02)

@export_group("Light rays")
## A shaft you can climb announces itself with the light falling out of it, not with a painted
## square. A mark can only say "something is here"; a beam says where it comes from, lights the
## floor it lands on, and reads instantly as a way out because that is what a shaft of daylight
## in a dark place means.
@export var ray_color: Color = Color(1.00, 0.93, 0.70)
@export_range(0.0, 1.0, 0.01) var ray_strength: float = 0.30
## Half-width of the beam where it leaves the ceiling, and where it lands. It widens on the
## way down, like a streetlight.
@export var ray_top_radius: float = 0.20
@export var ray_floor_radius: float = 0.52
@export var ray_light_energy: float = 2.2

@export_group("Shape")
## How far the DRAWN earth face rises above the tunnel floor. A full plane spacing, so the
## wall runs from the floor up to the underside of the lid and the trench is a real cut
## through solid ground rather than a kerb standing on an open plain.
@export var wall_height: float = TunnelChunks.PLANE_SPACING
## How far the INVISIBLE barrier rises. It cannot usefully exceed the plane spacing, because
## the only thing above a wall is the floor of the plane above -- set higher, barriers grow
## through it and fence off the layer above instead. What makes taller containment possible
## is PER-PLANE COLLISION LAYERS, which is what plane_bit below is for: a mouse only collides
## with the layer it is standing on, so a barrier can now overshoot without touching anyone.
@export var barrier_height: float = TunnelChunks.PLANE_SPACING * 2.0

@export_group("Lamps")
## Warm pools along the corridors. This is the single biggest reason the reference art reads
## as an inhabited burrow rather than a hole.
@export var lamp_color: Color = Color(1.00, 0.72, 0.42)
## Kept low with a generous range, rather than bright and tight. A hot little lamp blows out
## the floor directly under it into white and leaves the earth faces black.
@export var lamp_energy: float = 1.7
@export var lamp_range: float = 7.0
## One lamp per this many cells. Sparse on purpose: pools of light with dark between them
## read as depth, an evenly lit corridor reads as a flat texture.
@export var lamp_spacing_cells: int = 4
## Hard ceiling, so a large network can't quietly turn into a thousand-light scene.
@export var lamp_budget: int = 64

## plane -> {cell: true}. Every dug cell is flat walkable floor; there are no other kinds.
var _cells: Array[Dictionary] = []
## plane -> {cell: true}, meaning a shaft descends from `plane` to `plane + 1` at that cell.
##
## Stored on the UPPER of the two planes it joins, and stored once. A shaft is one object seen
## from two sides: standing on top of it you go down, standing under it you go up. That is
## what makes E unambiguous without a modifier -- there is only ever one shaft touching a
## cell, so there is only ever one direction to go.
var _shafts: Array[Dictionary] = []
var _grids: Array[GridMap] = []
var _walls: Array[MeshInstance3D] = []
var _bodies: Array[StaticBody3D] = []
var _shapes: Array[CollisionShape3D] = []
var _floor_materials: Array[StandardMaterial3D] = []
var _wall_materials: Array[StandardMaterial3D] = []
## One texel per cell, per plane: 255 where dug. Read by earth_cutaway.gdshader to punch the
## lid above that plane. Digging writes a texel instead of rebuilding anything.
var _mask_images: Array[Image] = []
var _mask_textures: Array[ImageTexture] = []
var _lids: Array[MeshInstance3D] = []
var _lamp_roots: Array[Node3D] = []
var _focus: int = 0


func _ready() -> void:
	for plane in range(PLANE_COUNT):
		_cells.append({})
		_shafts.append({})

		var floor_material := _make_material(floor_color)
		var wall_material := _make_material(wall_color)
		_floor_materials.append(floor_material)
		_wall_materials.append(wall_material)

		var mask := Image.create_empty(
			MASK_HALF_CELLS * 2, MASK_HALF_CELLS * 2, false, Image.FORMAT_R8
		)
		mask.fill(Color(0.0, 0.0, 0.0, 1.0))
		_mask_images.append(mask)
		_mask_textures.append(ImageTexture.create_from_image(mask))

		var grid := GridMap.new()
		grid.name = "Plane%d" % plane
		grid.cell_size = Vector3(CELL, SPACING, CELL)
		# Godot centres cells on ALL THREE axes by default, so map_to_local(0,0,0) comes
		# back as (0.5, 0.75, 0.5) rather than the origin. Left on, every tile rendered
		# half a cell off in X and Z and -- far worse -- half a plane-spacing ABOVE the
		# collision floor this class generates. Turning centring off makes cell (x,0,z)
		# mean exactly (x, 0, z), matching the wall and collision maths.
		grid.cell_center_x = false
		grid.cell_center_y = false
		grid.cell_center_z = false
		grid.mesh_library = TunnelChunks.build(
			floor_material, _make_material(shaft_down_color)
		)
		grid.position = Vector3(0.0, plane_y(plane), 0.0)
		add_child(grid)
		_grids.append(grid)

		var wall := MeshInstance3D.new()
		wall.name = "Walls%d" % plane
		wall.position = Vector3(0.0, plane_y(plane), 0.0)
		add_child(wall)
		_walls.append(wall)

		var lamps := Node3D.new()
		lamps.name = "Lamps%d" % plane
		lamps.position = Vector3(0.0, plane_y(plane), 0.0)
		add_child(lamps)
		_lamp_roots.append(lamps)

		# Collision is generated here rather than left to GridMap's MeshLibrary shapes.
		# Those shapes are set and valid but no body ever appears in the physics world, so
		# the player walks straight through the floor. Building one trimesh per plane from
		# the same cell data that drives the walls is deterministic, testable, and keeps
		# collision guaranteed identical to what's drawn. GridMap still does the rendering.
		var body := StaticBody3D.new()
		body.name = "Collision%d" % plane
		body.position = Vector3(0.0, plane_y(plane), 0.0)
		# Each plane on its own layer, and static geometry scans for nobody.
		body.collision_layer = plane_bit(plane)
		body.collision_mask = 0
		add_child(body)
		var shape := CollisionShape3D.new()
		body.add_child(shape)
		_bodies.append(body)
		_shapes.append(shape)

		_build_lid(plane)

	set_focus_plane(0)


# ------------------------------------------------------------------------- coordinates


## Depth 0 is the surface. Each plane below sits one SPACING lower.
func plane_y(plane: int) -> float:
	return -SPACING * plane


func world_to_cell(position: Vector3) -> Vector2i:
	return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))


func cell_to_world(plane: int, cell: Vector2i) -> Vector3:
	return Vector3(cell.x * CELL, plane_y(plane), cell.y * CELL)


## Which plane a world height belongs to. Biased so that standing ON a floor reports that
## floor's plane rather than the one above it.
##
## A fallback rather than the source of truth now. Nothing walks between planes, so the
## controller knows exactly which layer it put you on; this is for anything that only has a
## position to go on.
func plane_at_height(y: float) -> int:
	return clampi(roundi(-y / SPACING), 0, PLANE_COUNT - 1)


## Whether a cell is inside the diggable arena at all.
func in_bounds(cell: Vector2i) -> bool:
	return absi(cell.x) <= half_extent_cells and absi(cell.y) <= half_extent_cells


# ------------------------------------------------------------------------- collision


## The collision layer a plane's geometry lives on.
##
## PER-PLANE LAYERS, so a mouse only ever collides with the layer it is standing on. Without
## this every barrier is a barrier for everyone: raise plane 2's walls above the spacing and
## they grow through plane 1's floor and fence off a player up there who cannot see what is
## stopping them. It is also what lets barriers overshoot the wall height freely, which is
## what GDD section 6's displacement will need -- knockback has to be unable to throw a mouse
## out of its own tunnel.
static func plane_bit(plane: int) -> int:
	return 1 << (plane + 1)


## Set a body to collide with the world and with exactly one tunnel layer.
func apply_plane_collision(body: CollisionObject3D, plane: int) -> void:
	body.collision_mask = WORLD_BIT | plane_bit(clampi(plane, 0, PLANE_COUNT - 1))


# ------------------------------------------------------------------------- queries


func is_dug(plane: int, cell: Vector2i) -> bool:
	return plane >= 0 and plane < PLANE_COUNT and _cells[plane].has(cell)


func cell_count(plane: int) -> int:
	return _cells[plane].size()


## A shaft leading DOWN from this cell, to `plane + 1`.
func has_shaft_down(plane: int, cell: Vector2i) -> bool:
	return plane >= 0 and plane < PLANE_COUNT and _shafts[plane].has(cell)


## A shaft leading UP from this cell -- the same object, seen from underneath.
func has_shaft_up(plane: int, cell: Vector2i) -> bool:
	return has_shaft_down(plane - 1, cell)


## Where E takes you from here, or -1 for nowhere.
##
## At most one shaft can touch a cell (see the no-stacking rule in _shaft_refusal), so this
## never has to choose. That is the whole reason one key can do both jobs.
func shaft_target(plane: int, cell: Vector2i) -> int:
	if has_shaft_down(plane, cell):
		return plane + 1
	if has_shaft_up(plane, cell):
		return plane - 1
	return -1


## Whether this cell is, or could become, walkable floor on `plane`.
func can_stand(plane: int, cell: Vector2i) -> bool:
	return plane > 0 and plane < PLANE_COUNT and in_bounds(cell)


# ------------------------------------------------------------------------- digging


## Cut a floor cell. Returns false if it was already dug -- so callers can tell a fresh
## segment from a no-op without re-querying -- and also if it was refused outright.
func dig(plane: int, cell: Vector2i) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT or _cells[plane].has(cell):
		return false
	if not in_bounds(cell):
		return false
	_cells[plane][cell] = true
	_mark_mask(plane, cell, true)
	_refresh_cell(plane, cell)
	_rebuild_walls(plane)
	return true


## Sink a shaft from `plane` down to `plane + 1`, at the cell the player is standing on.
func dig_shaft_down(plane: int, cell: Vector2i) -> bool:
	var refusal := _shaft_refusal(plane, cell)
	if refusal != "":
		dig_refused.emit(refusal)
		return false

	# Open the landing before recording the shaft, so the cell below exists to arrive in. A
	# shaft you drop through onto solid earth is worse than no shaft.
	dig(plane + 1, cell)
	_shafts[plane][cell] = true
	_refresh_cell(plane, cell)
	_refresh_cell(plane + 1, cell)
	# Both ends of the new shaft change what their plane's lights should look like, and neither
	# gets rebuilt on its own: _rebuild_walls only relights when a FLOOR cell changes, and
	# breaking upward changes no floor on the plane you are standing on. So the beam -- the only
	# thing that says a shaft goes up from here -- did not appear until something else forced a
	# rebuild, which in practice meant climbing up and back down to trip set_focus_plane.
	_relight(plane)
	_relight(plane + 1)
	return true


## Sink a shaft from `plane - 1` down to `plane`, authored from below -- the same object as
## dig_shaft_down, just dug by someone standing underneath it.
func dig_shaft_up(plane: int, cell: Vector2i) -> bool:
	if plane <= 0:
		dig_refused.emit("nothing above to break into")
		return false
	# The cell above has to be floor to arrive on, unless it is the surface, which is
	# everywhere. Opened first so the shaft below has somewhere to land.
	dig(plane - 1, cell)
	return dig_shaft_down(plane - 1, cell)


## Why a shaft can't be sunk here, or "" if it can.
func _shaft_refusal(plane: int, cell: Vector2i) -> String:
	if plane < 0 or plane + 1 >= PLANE_COUNT:
		return "nothing below to break into"
	if not in_bounds(cell):
		return "outside the arena"
	# Plane 0 is the surface: standing anywhere on it is standing on solid ground, so an
	# entrance needs no floor cut first. Below that you have to be in a tunnel.
	if plane > 0 and not _cells[plane].has(cell):
		return "no floor to sink a shaft from"
	if _shafts[plane].has(cell):
		return "a shaft is already here"

	# THE NO-STACKING RULE. A cell with a shaft above it and a shaft below it would give E
	# two destinations and no way to choose between them without a second key. Forbidding it
	# also stops a well being drilled straight from the lawn to the deepest plane, which is
	# what keeps depth a horizontal investment rather than something you buy on the spot --
	# the spirit of GDD section 3's "you can't dig straight down", by a different mechanism.
	if has_shaft_up(plane, cell):
		return "a shaft already comes up here"
	if plane + 1 < PLANE_COUNT and _shafts[plane + 1].has(cell):
		return "a shaft already goes down from below"
	if _crowded(plane, cell):
		return "too close to another shaft"
	return ""


## Is there already a shaft within the exclusion radius of `cell`? See shaft_exclusion_cells.
##
## THREE LAYERS, because a shaft is a hole in two planes at once: recorded at `plane`, it is a
## hole in that plane's floor and a hole in the ceiling of the one below. So the new shaft is
## next to something if any of layers plane-1, plane or plane+1 has one nearby -- checking only
## `plane` would happily put a floor hole beside a ceiling hole, which is two mouths a stride
## apart in the same corridor and exactly what the rule exists to stop.
##
## The centre cell is skipped: it is refused already, by messages that say which of the three
## ways it collides rather than the vague one this returns.
func _crowded(plane: int, cell: Vector2i) -> bool:
	var reach := shaft_exclusion_cells
	if reach <= 0:
		return false
	for x in range(cell.x - reach, cell.x + reach + 1):
		for y in range(cell.y - reach, cell.y + reach + 1):
			var other := Vector2i(x, y)
			if other == cell:
				continue
			for layer in range(maxi(plane - 1, 0), mini(plane + 2, PLANE_COUNT)):
				if _shafts[layer].has(other):
					return true
	return false


# ------------------------------------------------------------------------- rendering


## Focus a plane: it is lit and open, the one above it is a dim hint, everything else is gone.
##
## Nothing here touches alpha. Layers are separated by whether they are DRAWN AT ALL and by
## how brightly, which is why the transparent-pass problems that dogged M2 -- flickering rims,
## the ground slab painting over the rock scatter -- simply cannot happen now.
func set_focus_plane(plane: int) -> void:
	_focus = clampi(plane, 0, PLANE_COUNT - 1)
	for index in range(PLANE_COUNT):
		# ONE LAYER, and nothing else. The layer above used to be drawn as a dim inlay of its
		# floors, on the theory that seeing where you'd come from helped orient you. In a
		# corridor it did the opposite: its tunnels are laid over the lid you are trying to
		# look through, so they read as marks on your own floor and obscure the layer you are
		# actually in. What you want to see is your tunnel. Where the layer above joins yours
		# is announced by the light falling down the shaft, which needs no floor plan.
		var focused := index == _focus
		_grids[index].visible = focused
		_walls[index].visible = focused
		_lamp_roots[index].visible = focused
		# Only the lid you are looking down through. The others would each hide the one below.
		if _lids[index] != null:
			_lids[index].visible = focused
	_rebuild_lamps(_focus)


func get_focus_plane() -> int:
	return _focus


## The tile a cell should be showing: plain floor, or marked with the way out.
func _refresh_cell(plane: int, cell: Vector2i) -> void:
	if plane < 0 or plane >= PLANE_COUNT:
		return
	var item := TunnelChunks.FLOOR
	if plane == 0:
		# The lawn is already the floor up here. A surface entrance is a mark on it, nothing more.
		if not has_shaft_down(0, cell):
			return
		item = TunnelChunks.ENTRANCE
	elif has_shaft_down(plane, cell):
		item = TunnelChunks.SHAFT_DOWN
	elif not _cells[plane].has(cell):
		return
	_grids[plane].set_cell_item(Vector3i(cell.x, 0, cell.y), item)


## The earth you look down through to see `plane`, sitting one spacing above its floor.
##
## Planes 2 and 3 get a generated slab. Plane 1's lid is the map's own ground -- grass, props,
## rocks and all -- so the scene owns it and depth_focus.gd hands it the same shader. Plane 0
## has no lid because it IS the top.
func _build_lid(plane: int) -> void:
	if plane < 2:
		_lids.append(null)
		return

	var material := ShaderMaterial.new()
	material.shader = load("res://art/shaders/earth_cutaway.gdshader") as Shader
	material.set_shader_parameter("dug_here", _mask_textures[plane])
	material.set_shader_parameter("dug_above", _mask_textures[plane - 1])
	# The lid stays SOLID over the layer above's tunnels. It only opened there to make room
	# for that layer's floor tiles, and those aren't drawn any more -- cutting anyway would
	# punch holes in your ceiling showing nothing behind them.
	material.set_shader_parameter("cut_above", false)
	material.set_shader_parameter("cell_size", CELL)
	material.set_shader_parameter("mask_half_cells", float(MASK_HALF_CELLS))
	material.set_shader_parameter("albedo_color", lid_color)

	var quad := PlaneMesh.new()
	quad.size = Vector2.ONE * float(MASK_HALF_CELLS * 2) * CELL

	var lid := MeshInstance3D.new()
	lid.name = "Lid%d" % plane
	lid.mesh = quad
	lid.material_override = material
	# A hair BELOW the floor of the plane above, which sits at exactly this height. The
	# cutaway already discards the lid wherever that floor exists, but coplanar surfaces still
	# fight along the seam a cell boundary leaves, and the result is a stripe crawling down
	# every corridor as the camera moves.
	lid.position = Vector3(0.0, plane_y(plane - 1) - 0.01, 0.0)
	lid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(lid)
	_lids.append(lid)


## The dug mask for a plane, for anything that needs to cut a hole in the earth above it.
func dug_mask(plane: int) -> Texture2D:
	return _mask_textures[clampi(plane, 0, PLANE_COUNT - 1)]


func mask_half_cells() -> int:
	return MASK_HALF_CELLS


## Punch or heal one texel. The entire cost of keeping the cutaway in sync -- no mesh, no CSG,
## no rebuild.
func _mark_mask(plane: int, cell: Vector2i, dug: bool) -> void:
	var x := cell.x + MASK_HALF_CELLS
	var y := cell.y + MASK_HALF_CELLS
	if x < 0 or y < 0 or x >= MASK_HALF_CELLS * 2 or y >= MASK_HALF_CELLS * 2:
		return
	_mask_images[plane].set_pixel(x, y, Color(1.0, 0.0, 0.0, 1.0) if dug else Color(0, 0, 0, 1))
	_mask_textures[plane].update(_mask_images[plane])


## Warm pools along the corridors of the focused layer.
##
## Spaced by DISTANCE FROM THE LAST LAMP, not by a lattice of cells whose coordinates divide
## evenly. A lattice looks reasonable and then lights nothing: a one-cell-wide corridor
## running along z = -5 contains no cell whose z is a multiple of four, so the whole corridor
## came out pitch black while the cells around the origin were fine.
func _rebuild_lamps(plane: int) -> void:
	var root := _lamp_roots[plane]
	for child in root.get_children():
		child.free()
	if plane <= 0:
		return

	var spacing := maxi(1, lamp_spacing_cells)
	var lit: Array[Vector2i] = []
	var cells: Array = _cells[plane].keys()
	cells.sort()  # Deterministic, so the same network always lights the same way.

	for cell: Vector2i in cells:
		if lit.size() >= lamp_budget:
			break
		# Never in a shaft. You wouldn't hang a lamp down the hole, and a light sitting on the
		# marker blows the one thing the player needs to read out to flat white.
		if has_shaft_down(plane, cell) or has_shaft_up(plane, cell):
			continue
		var clear := true
		for other: Vector2i in lit:
			if maxi(absi(other.x - cell.x), absi(other.y - cell.y)) < spacing:
				clear = false
				break
		if not clear:
			continue
		lit.append(cell)

		var lamp := OmniLight3D.new()
		lamp.light_color = lamp_color
		lamp.light_energy = lamp_energy
		lamp.omni_range = lamp_range
		# Shadows off, deliberately. Dozens of shadow-casting omnis in a trench is a lot of
		# cost for an effect the walls already give you by blocking the light's reach.
		lamp.shadow_enabled = false
		# Hung near the top of the trench, so light spills down the walls rather than starting
		# at the floor and leaving the earth faces flat.
		lamp.position = Vector3(cell.x * CELL, wall_height * 0.75, cell.y * CELL)
		root.add_child(lamp)

	_build_rays(plane, root)


## A shaft of light spilling out of every hole in the ceiling.
##
## This is the ONLY thing telling you a shaft goes up from here, now that the painted square
## is gone -- and it does the job better, because a beam is unmistakably a way out rather than
## a symbol you have to have been taught.
##
## The beam is additive and unshaded, which is a deliberate exception to this file's rule that
## nothing goes in the transparent pass. That rule exists because opaque surfaces wrongly
## marked transparent sort against each other and flicker; an additive beam writes no depth,
## occludes nothing, and has nothing to sort against. The spotlight beside it is what actually
## lights the floor -- the cone is only the dust in the air.
func _build_rays(plane: int, root: Node3D) -> void:
	if plane <= 0:
		return
	for cell: Vector2i in _shafts[plane - 1]:
		if not _cells[plane].has(cell):
			continue

		var beam := MeshInstance3D.new()
		beam.mesh = _ray_mesh()
		beam.material_override = _ray_material()
		beam.position = Vector3(cell.x * CELL, 0.0, cell.y * CELL)
		beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(beam)

		var light := SpotLight3D.new()
		light.light_color = ray_color
		light.light_energy = ray_light_energy
		light.spot_range = SPACING * 2.0
		light.spot_angle = 32.0
		light.shadow_enabled = false
		# Hung at the mouth of the shaft, pointing straight down the hole.
		light.position = Vector3(cell.x * CELL, SPACING * 0.95, cell.y * CELL)
		light.rotation_degrees.x = -90.0
		root.add_child(light)


## A cone widening downward from the ceiling, fading out as it falls. Vertex alpha does the
## fade, so the beam has no hard end -- it simply stops being light somewhere near the floor.
func _ray_mesh() -> ArrayMesh:
	var t := SurfaceTool.new()
	t.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segments := 14
	var top := SPACING
	var mouth := Vector3(0.0, top, 0.0)
	for i in range(segments):
		var a := TAU * float(i) / float(segments)
		var b := TAU * float(i + 1) / float(segments)
		var top_a := Vector3(cos(a) * ray_top_radius, top, sin(a) * ray_top_radius)
		var top_b := Vector3(cos(b) * ray_top_radius, top, sin(b) * ray_top_radius)
		var low_a := Vector3(cos(a) * ray_floor_radius, 0.02, sin(a) * ray_floor_radius)
		var low_b := Vector3(cos(b) * ray_floor_radius, 0.02, sin(b) * ray_floor_radius)
		for pair: Array in [[top_a, 1.0], [top_b, 1.0], [low_b, 0.0], [top_a, 1.0], [low_b, 0.0], [low_a, 0.0]]:
			t.set_color(Color(1.0, 1.0, 1.0, pair[1] as float))
			t.add_vertex(pair[0] as Vector3)

		# CAP THE MOUTH. Without it the cone is an open tube, and the cutaway has already
		# removed the ceiling over this cell -- so looking down the beam you saw straight past
		# the world to the clear colour, a black disc sitting in the middle of the light.
		# Filling it reads as what it should: the lit hole you would climb out of.
		for vertex: Vector3 in [mouth, top_b, top_a]:
			t.set_color(Color(1.0, 1.0, 1.0, 1.0))
			t.add_vertex(vertex)
	return t.commit()


func _ray_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.vertex_color_use_as_albedo = true
	material.albedo_color = Color(ray_color.r, ray_color.g, ray_color.b, ray_strength)
	# No depth write: the beam is light in the air, and anything it covers should still be
	# visible through it.
	material.no_depth_test = false
	material.disable_receive_shadows = true
	return material


## Always opaque. Focus is carried by visibility and brightness, so nothing here ever needs
## the transparent pass -- see set_focus_plane for why that matters.
func _make_material(colour: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.95
	material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


## Rebuild everything derived from a plane's cell set: the wall mesh and the collision trimesh.
##
## Walls run the FULL plane spacing, from the floor up to the underside of the lid, so the
## result is a trench cut through solid earth rather than a kerb standing on open ground. The
## lid caps them, which is why there is no separate top face: the cap is real geometry one
## layer up, and a lip drawn at the same height would only z-fight with it.
##
## Wonderfully dull now that every cell is flat. A neighbour is either dug or it isn't; there
## is no half-height edge to work out, no orientation to read back, and no cross-plane opening
## to remember. All of that existed to serve ramps.
func _rebuild_walls(plane: int) -> void:
	var cells: Dictionary = _cells[plane]
	var walls := SurfaceTool.new()
	walls.begin(Mesh.PRIMITIVE_TRIANGLES)

	var collision := PackedVector3Array()
	var half := CELL * 0.5
	var faces := 0
	var top := _wall_top(plane)
	var barrier := _barrier_top(plane)

	for cell: Vector2i in cells:
		var centre := Vector3(cell.x * CELL, 0.0, cell.y * CELL)

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

			# Drawn to the lid, collided to well above it. Two heights, two jobs -- and safe
			# to differ now that each plane collides only with its own occupant.
			var up := Vector3(0.0, top, 0.0)
			_quad(walls, a, b, b + up, a + up)
			_collide_quad(collision,
				a, b, Vector3(b.x, barrier, b.z), Vector3(a.x, barrier, a.z))
			faces += 1

	var mesh: ArrayMesh = null
	if faces > 0:
		walls.generate_normals()
		mesh = walls.commit()
		mesh.surface_set_material(0, _wall_materials[plane])

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

	_relight(plane)


## Rebuild a plane's lamps and beams, if it is the one being looked at. Off-focus planes are
## left alone on purpose: their lamp root is hidden, and set_focus_plane rebuilds whichever
## plane you arrive on, so building lights nobody can see is pure cost during a dig.
func _relight(plane: int) -> void:
	if plane == _focus and plane > 0 and plane < PLANE_COUNT:
		_rebuild_lamps(plane)


func _wall_top(plane: int) -> float:
	return 0.0 if plane == 0 else wall_height


func _barrier_top(plane: int) -> float:
	return 0.0 if plane == 0 else maxf(wall_height, barrier_height)


func _collide_quad(out: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	for vertex: Vector3 in [a, b, c, a, c, d]:
		out.append(vertex)


func _quad(t: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	for vertex: Vector3 in [a, b, c, a, c, d]:
		t.add_vertex(vertex)
