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
## A cell was opened, or a shaft was sunk through one. The routing graph rides on these rather
## than rescanning: a dig changes one cell out of five thousand, and a graph that rebuilds itself
## to learn that is a graph nobody can afford to keep current.
signal cell_opened(plane: int, cell: Vector2i)
signal shaft_opened(plane: int, cell: Vector2i)
## A cell was brought down. The one thing that makes the network get SMALLER, so it is the one
## thing every cache built on top of it has to hear about.
signal cell_collapsed(plane: int, cell: Vector2i)
## A dug cell somebody cannot walk through any more, and then can again -- a barricade going up
## and coming down. Separate from `cell_collapsed` because the cell is still THERE: the floor, the
## walls, the lamps and the mask are all unchanged, and the only thing that has to hear about it
## is anything planning a route. Folding the two together would mean rebuilding a plane's geometry
## every time a boulder moved.
signal cell_blocked(plane: int, cell: Vector2i)
signal cell_unblocked(plane: int, cell: Vector2i)
## A crew found out where some rock is, or a boulder stopped being rock. Carries the teams affected
## as a bit mask rather than the cells, because both things that listen -- the caps drawn in the
## world and the minimap -- redraw a whole plane anyway, and a per-cell signal would have them
## rebuild the same mesh forty times for one vein.
signal rock_revealed(plane: int, teams: int)
## A crew's map of the tunnel network changed. Tunnel geometry is shared by the world, but the
## minimap is not omniscient: each crew only gets the cells and shafts it cut itself.
signal tunnel_revealed(plane: int, teams: int)

## So anything spawned into the match can find the network without being wired to it. Bots are
## created at runtime and have no scene to hold a NodePath for them.
const NETWORK_GROUP: StringName = &"tunnel_network"

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

## Both crews, as the bit mask `_known` stores. For the things everybody can see: a boulder is
## rock you learn about by looking at it rather than by digging into it.
const TEAM_BITS: int = 0b11

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

@export_group("Rock")
## Per-plane rock obstructions (GDD section 3). Solid seams scattered through the earth that stop
## horizontal digging, with A DIFFERENT LAYOUT ON EVERY PLANE -- which is the whole idea. Rock in
## one place on every layer would be a flat maze repeated three times; rock that moves as you go
## down makes getting past an obstruction a question of which LAYER to go around it on, and turns
## map knowledge into four floors of map knowledge rather than one.
##
## A rock cell is not a new kind of thing. It is earth that can never be dug, so it is drawn by
## the same wall the surrounding earth is (in stone, so you can see what stopped you), collides as
## the same wall, and is invisible until somebody digs up against it -- which is exactly right for
## a game about hidden information: you learn where the rock is by paying for the knowledge.
@export var rock_seed: int = 20260801
## Fraction of plane 1 that is rock. Nothing on the surface: the lawn is not diggable in the first
## place, and a "rock" up there is just a prop.
@export_range(0.0, 0.5, 0.01) var rock_density: float = 0.09
## Added per plane below the first. Deeper is rockier, which gives the shallow planes a reason to
## exist once the deep ones are faster to cross -- and it is the same direction section 3 sends
## dig TIMES, so the two dials push the same way instead of cancelling.
@export_range(0.0, 0.2, 0.01) var rock_density_deeper: float = 0.035
## Cells in one seam. Seams rather than single blocked cells, because one cell is a thing you step
## around without noticing and a seam is a thing you have to make a decision about.
@export var rock_seam_cells: Vector2i = Vector2i(3, 11)
## Clear ground around every nest, in metres, so a crew can always get underground at home. A crew
## whose only entrance was blocked by generation would read as the map being broken, and it would
## happen identically every match because the layout is seeded.
@export var rock_nest_clearance: float = 6.0

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
## The face of a rock seam where a tunnel runs into one. Cool and pale against the warm earth --
## the message is "this is not the same stuff, and it is not going to open", and it has to land
## from across a corridor with no legend to read.
@export var rock_color: Color = Color(0.60, 0.64, 0.70)
## The same seam seen from ABOVE, once your crew has found it -- the cap over the solid cube you
## have run into (GDD section 3).
##
## PALE LIKE THE EXPOSED FACE. The old cap was both too dark and back-face culled from above, so a
## rock cube read as stone from the side and earth from the top. Matching the face's cool value
## makes the whole obstruction read as one material. Unknown rock still has no cap at all: this
## improves the revealed object without leaking seams.
@export var rock_top_color: Color = Color(0.60, 0.64, 0.70)

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
## plane -> {cell: true}: earth that will never open. Laid once at startup, and then edited by
## exactly one thing -- a boulder on the lawn adding its footprint to plane 1, and giving it back
## when a Brute breaks it. That was the `[DECIDE]` in GDD section 4 about destructible rock, and
## the answer turned out to be "the rock you can SEE, and only that".
var _rock: Array[Dictionary] = []
## plane -> {cell: team bits}: which crews have found out that a rock cell is there. Empty for a
## cell nobody has run into, and hidden information until they do (GDD section 3).
##
## A BIT MASK RATHER THAN TWO DICTIONARIES, so a boulder -- which both crews can see from the
## first second -- is one entry rather than the same cell recorded twice under different keys.
var _known: Array[Dictionary] = []
## plane -> {cell: team bits}: which crews know a dug cell as part of their own network.
##
## This deliberately does NOT flood-fill through connected floor. If a blue corridor meets a red
## one, the physical routes intersect, but neither crew receives the other side's floor plan for
## free. The shared cell is the seam between the two maps.
var _tunnel_known: Array[Dictionary] = []
## upper plane -> {cell: team bits}: who cut and therefore knows each shaft. Kept separately from
## the landing cell because the surface minimap draws mouths rather than plane-1 floors.
var _shaft_known: Array[Dictionary] = []
## plane -> {cell: true}: dug cells something is standing in the way of. Today that is a
## barricade; a cave-in makes a cell stop existing, which is a different thing entirely.
var _obstructed: Array[Dictionary] = []
var _grids: Array[GridMap] = []
var _walls: Array[MeshInstance3D] = []
## The faces of the wall that turned out to be stone. Drawn separately from the earth walls only
## so they can carry a different material -- geometrically they are the same quads.
var _rock_faces: Array[MeshInstance3D] = []
## The tops of the seams a crew has found, one flat sheet per plane, drawn against the underside of
## that plane's lid. Rebuilt whole when knowledge changes, which is a few times a match.
var _rock_caps: Array[MeshInstance3D] = []
## Whose knowledge the caps are showing. -1 until somebody asks, because a network in a headless
## audit has no player and should draw nothing.
var _cap_team: int = -1
var _bodies: Array[StaticBody3D] = []
var _shapes: Array[CollisionShape3D] = []
var _floor_materials: Array[StandardMaterial3D] = []
var _wall_materials: Array[StandardMaterial3D] = []
var _rock_materials: Array[StandardMaterial3D] = []
## One texel per cell, per plane: 255 where dug. Read by earth_cutaway.gdshader to punch the
## lid above that plane. Digging writes a texel instead of rebuilding anything.
var _mask_images: Array[Image] = []
var _mask_textures: Array[ImageTexture] = []
var _lids: Array[MeshInstance3D] = []
var _lamp_roots: Array[Node3D] = []
var _focus: int = 0
var _graph: TunnelGraph


## The cell books, before anything is drawn.
##
## SEPARATE FROM `_ready`, and the reason is node order rather than tidiness. Godot readies a scene
## depth-first, so everything under `Surface` -- including the boulders, which claim cells of
## plane 1
## the moment they exist -- runs before this node's `_ready` does. Left in there, the first boulder
## indexed an empty array and the failure was an out-of-range error in a file that has nothing to do
## with boulders. `_init` runs before any of it, and these are plain dictionaries with nothing to
## build, so there is no reason for them to wait for a renderer.
func _init() -> void:
	for plane in range(PLANE_COUNT):
		_cells.append({})
		_shafts.append({})
		_rock.append({})
		_known.append({})
		_tunnel_known.append({})
		_shaft_known.append({})
		_obstructed.append({})


func _ready() -> void:
	add_to_group(NETWORK_GROUP)
	for plane in range(PLANE_COUNT):
		var floor_material := _make_material(floor_color)
		var wall_material := _make_material(wall_color)
		_floor_materials.append(floor_material)
		_wall_materials.append(wall_material)
		_rock_materials.append(_make_rock_material())

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
			floor_material, _make_material(shaft_down_color, false)
		)
		grid.position = Vector3(0.0, plane_y(plane), 0.0)
		add_child(grid)
		_grids.append(grid)

		var wall := MeshInstance3D.new()
		wall.name = "Walls%d" % plane
		wall.position = Vector3(0.0, plane_y(plane), 0.0)
		add_child(wall)
		_walls.append(wall)

		var stone := MeshInstance3D.new()
		stone.name = "Rock%d" % plane
		stone.position = Vector3(0.0, plane_y(plane), 0.0)
		add_child(stone)
		_rock_faces.append(stone)

		# The vein seen from ABOVE, for the cells this crew has found. Sits just under the lid it
		# is drawn against rather than at the floor, because what it represents is a body of rock
		# filling the earth from one to the other -- and because at this camera angle a mark on the
		# floor of a plane you cannot see into is a mark on nothing.
		var cap := MeshInstance3D.new()
		cap.name = "RockTop%d" % plane
		cap.position = Vector3(0.0, plane_y(plane), 0.0)
		cap.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(cap)
		_rock_caps.append(cap)

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

	_generate_rock()

	# Built last, so it subscribes to a network whose planes all exist. It keeps itself current
	# from here on -- nothing else has to remember to tell it about a dig.
	_graph = TunnelGraph.new(self)
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


# ------------------------------------------------------------------------- rock


## Lay the seams. Once, at startup, per plane, from a seed.
##
## SEEDED AND PER-PLANE, which are the two things that matter. Seeded, because a map you cannot
## replay is a map you cannot learn (GDD section 8 wants layouts to be a recipe plus a seed), and
## because a bug that only happens on one layout is a bug you can only reproduce by luck. Per
## plane, because rock in the same place on every layer is a flat maze drawn three times -- the
## point of section 3's obstructions is that going AROUND one may mean going down.
func _generate_rock() -> void:
	if rock_density <= 0.0:
		return

	for plane in range(1, PLANE_COUNT):
		var rng := RandomNumberGenerator.new()
		# A different stream per plane, derived from one dial. Sharing the generator across planes
		# would work too, but then changing plane 1's density would silently relayout planes 2 and
		# 3 as well, and every screenshot of the deep layers would stop being comparable.
		rng.seed = rock_seed + plane * 7919

		var span := half_extent_cells
		var area := float((span * 2 + 1) * (span * 2 + 1))
		var wanted := int(area * (rock_density + rock_density_deeper * float(plane - 1)))
		var placed := 0
		var attempts := 0
		while placed < wanted and attempts < wanted:
			attempts += 1
			var start := Vector2i(rng.randi_range(-span, span), rng.randi_range(-span, span))
			if not _rock_allowed(plane, start):
				continue
			placed += _grow_seam(plane, start, rng)


## A seam, grown as a random walk rather than as a disc. A disc is a circle, and a circle in the
## ground is the one shape that reads as placed by a level designer; a walk wanders, doubles back
## on itself and leaves the ragged edge a mineral seam actually has.
func _grow_seam(plane: int, start: Vector2i, rng: RandomNumberGenerator) -> int:
	var length := rng.randi_range(rock_seam_cells.x, maxi(rock_seam_cells.x, rock_seam_cells.y))
	var at := start
	var laid := 0
	for i in range(length):
		if _rock_allowed(plane, at):
			_rock[plane][at] = true
			laid += 1
		at += SIDES[rng.randi_range(0, SIDES.size() - 1)]
		if not in_bounds(at):
			break
	return laid


## Whether generation may put rock in this cell.
##
## The nest clearance is the load-bearing one. A crew whose ground is rock to the horizon cannot
## get underground at home, and because the layout is seeded that would happen in exactly the same
## place every single match -- which reads as the map being broken rather than as a hard start.
func _rock_allowed(plane: int, cell: Vector2i) -> bool:
	if not in_bounds(cell) or _rock[plane].has(cell):
		return false
	var here := Vector2(float(cell.x) * CELL, float(cell.y) * CELL)
	if is_inside_tree() and Nest.blocks(get_tree(), here, rock_nest_clearance):
		return false
	return true


## Earth that will never open, however long you hold the button.
func is_rock(plane: int, cell: Vector2i) -> bool:
	return plane >= 0 and plane < PLANE_COUNT and _rock[plane].has(cell)


## Every rock cell on a plane. For the audits, and for anything that wants to draw the layout.
func rock_cells(plane: int) -> Array:
	return _rock[clampi(plane, 0, PLANE_COUNT - 1)].keys()


## Rock that was not there when the map was laid: the cells under a boulder on the lawn.
##
## THE SAME EARTH-THAT-NEVER-OPENS, deliberately, rather than a second kind of obstruction with its
## own queries. Digging, shafts, the wall mesh and the routing graph all already refuse rock in the
## right places, and a boulder that used a parallel mechanism would have to be taught to each of
## them separately -- which is four chances to miss one.
##
## `known` is what makes a boulder feel completely different from a seam despite being the same
## thing underneath. A seam is hidden until somebody pays to find it; a boulder is sitting on the
## lawn in front of you, so the crew that can see it already knows what is under it, and pretending
## otherwise would be a puzzle about the camera rather than about the map.
func add_rock(plane: int, cell: Vector2i, known: bool = false) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT or not in_bounds(cell):
		return false
	# Never over a tunnel somebody already dug. Rock arriving on top of an open corridor would make
	# a cell that is dug AND impassable, which is a state nothing else here handles: the floor is
	# drawn, the graph routes through it, and the dig refuses to reopen it.
	if _cells[plane].has(cell) or _rock[plane].has(cell):
		return false
	_rock[plane][cell] = true
	if known:
		_known[plane][cell] = TEAM_BITS
		_announce_rock(plane, TEAM_BITS)
	return true


## And rock that stops being rock: a boulder broken up, the earth under it ordinary again.
func remove_rock(plane: int, cell: Vector2i) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT or not _rock[plane].has(cell):
		return false
	_rock[plane].erase(cell)
	_known[plane].erase(cell)
	# The face of the seam was drawn in stone by whichever corridors had run up against it, and it
	# is ordinary earth now. Cheap, and only ever on a Brute's last swing.
	_rebuild_walls(plane)
	_announce_rock(plane, TEAM_BITS)
	return true


# ------------------------------------------------------------------------- what a crew knows


## Learn where a vein goes, by running into it.
##
## THE WHOLE CONNECTED VEIN, not the one cell you hit. A seam is grown as a random walk and reads as
## a single object -- the thing you have actually learned when your Engineer's shovel rings off it
## is "this seam is here", and drip-feeding it a tile at a time would mean chipping along a wall to
## map something you can already see the shape of. The cell is the price; the vein is the knowledge.
##
## PER CREW, which is the part that makes it worth storing at all. Rock is hidden information (GDD
## section 3) and the crew that spent the digs is the crew that gets to route around it. This is the
## first per-team knowledge in the game and it is deliberately the small one -- M5 has to do the
## same trick for tunnels and for sightings, and doing it once on something static is how the shape
## gets found before it matters.
func reveal_vein(plane: int, cell: Vector2i, team: int) -> int:
	if plane <= 0 or plane >= PLANE_COUNT or not _rock[plane].has(cell):
		return 0
	var bit := 1 << clampi(team, 0, 1)
	if int(_known[plane].get(cell, 0)) & bit != 0:
		return 0

	# Flood fill over shared faces only, which is the same connectivity the walls and the routing
	# graph use. Eight-way would join two seams that touch at a corner -- and a corner is exactly
	# the place a mouse cannot get through, so they are not one vein to anybody who has to dig.
	var found := 0
	var queue: Array[Vector2i] = [cell]
	var seen := {cell: true}
	while not queue.is_empty():
		var at: Vector2i = queue.pop_back()
		if int(_known[plane].get(at, 0)) & bit == 0:
			_known[plane][at] = int(_known[plane].get(at, 0)) | bit
			found += 1
		for side: Vector2i in SIDES:
			var beside := at + side
			if seen.has(beside) or not _rock[plane].has(beside):
				continue
			seen[beside] = true
			queue.append(beside)

	if found > 0:
		_announce_rock(plane, bit)
	return found


## Somebody's picture of a plane changed. Redraws the caps if it was the crew being drawn for, and
## tells everything else once.
##
## The rebuild is HERE rather than on a connection to this file's own signal, because a listener
## that has to be wired up in `_ready` is a listener somebody can delete and not notice: the caps
## would simply stop updating, which looks exactly like the reveal not working.
func _announce_rock(plane: int, teams: int) -> void:
	if _cap_team >= 0 and teams & (1 << _cap_team) != 0:
		_rebuild_rock_caps(plane)
	rock_revealed.emit(plane, teams)


func is_rock_known(plane: int, cell: Vector2i, team: int) -> bool:
	if plane < 0 or plane >= PLANE_COUNT:
		return false
	return int(_known[plane].get(cell, 0)) & (1 << clampi(team, 0, 1)) != 0


## Every rock cell on a plane that `team` has found. For the cap mesh and the minimap -- the two
## things that draw what a crew knows.
func known_rock_cells(plane: int, team: int) -> Array[Vector2i]:
	var found: Array[Vector2i] = []
	if plane < 0 or plane >= PLANE_COUNT:
		return found
	var bit := 1 << clampi(team, 0, 1)
	for cell: Vector2i in _known[plane]:
		if int(_known[plane][cell]) & bit != 0:
			found.append(cell)
	return found


# ------------------------------------------------------------------------- paving


## Is this cell under paving -- a patio, a path, flagstones (GDD section 3)?
##
## THE SECOND KIND OF OBSTRUCTION, and it is nothing like the first. Rock is a property of one
## cell on one plane and stops you digging SIDEWAYS; paving is a property of the ground above and
## stops you only from breaking through it. So this takes no plane: the earth under a slab is
## ordinary earth on every layer, and the one thing the answer is ever used for is refusing a
## shaft that would touch the surface.
##
## Asked of the map rather than baked into a set here. The footprints are authored nodes, they
## never move during a match, and the question is asked a few times a second at most -- caching
## it would buy nothing and would go stale the first time a map animated a garage door.
func is_sealed(cell: Vector2i) -> bool:
	if not is_inside_tree():
		return false
	# Half a cell of margin, because a mouth is a cell wide and not a point: a shaft whose centre
	# just clears the slab still opens a hole through its edge.
	return NoSurfaceZone.seals(
		get_tree(), Vector2(float(cell.x) * CELL, float(cell.y) * CELL), CELL * 0.5
	)


# ------------------------------------------------------------------------- obstruction


## Something is standing in this cell that a mouse cannot get past (a barricade).
##
## THE CELL IS STILL DUG, and that distinction is the whole reason this is not `collapse`. The
## floor, the walls, the lamps and the cutaway mask are all still correct and none of them is
## rebuilt; the only thing that changes is that nothing may plan a route through here. Making a
## barricade collapse the cell instead would have rebuilt a plane's geometry every time one went
## up, and would have made putting one down indistinguishable from digging a fresh corridor.
func block_cell(plane: int, cell: Vector2i) -> bool:
	if not is_dug(plane, cell) or _obstructed[plane].has(cell):
		return false
	_obstructed[plane][cell] = true
	cell_blocked.emit(plane, cell)
	return true


func unblock_cell(plane: int, cell: Vector2i) -> bool:
	if plane < 0 or plane >= PLANE_COUNT or not _obstructed[plane].has(cell):
		return false
	_obstructed[plane].erase(cell)
	# Only announced if the cell is still there to walk through. A barricade whose floor was caved
	# in from under it un-blocks on the way out, and re-adding that cell to the routing graph
	# would put back a point `collapse` had just correctly removed.
	if is_dug(plane, cell):
		cell_unblocked.emit(plane, cell)
	return true


func is_blocked(plane: int, cell: Vector2i) -> bool:
	return plane >= 0 and plane < PLANE_COUNT and _obstructed[plane].has(cell)


# ------------------------------------------------------------------------- queries


## Audits and authored probe networks omit a crew and are visible to both sides. Live digging
## always supplies the mouse's team through dig_controller.gd.
func _team_bits(team: int) -> int:
	return TEAM_BITS if team < Team.BLUE or team > Team.RED else 1 << team


func _learn_tunnel_cell(plane: int, cell: Vector2i, team: int) -> void:
	if plane <= 0 or plane >= PLANE_COUNT:
		return
	var bits := _team_bits(team)
	# A live dig that breaks into an enemy-only neighbour makes THIS new cell the shared junction.
	# Do not propagate from an already shared neighbour: that would make every later cell in the
	# digger's corridor shared too and quietly reveal the whole route one tile at a time.
	if team >= Team.BLUE and team <= Team.RED:
		var own_bit := 1 << team
		var enemy_bit := 1 << Team.other(team)
		for side: Vector2i in SIDES:
			var neighbour_bits := int(_tunnel_known[plane].get(cell + side, 0))
			if neighbour_bits & enemy_bit != 0 and neighbour_bits & own_bit == 0:
				bits = TEAM_BITS
				break
	var before := int(_tunnel_known[plane].get(cell, 0))
	var after := before | bits
	if before == after:
		return
	_tunnel_known[plane][cell] = after
	tunnel_revealed.emit(plane, bits)


func is_dug(plane: int, cell: Vector2i) -> bool:
	return plane >= 0 and plane < PLANE_COUNT and _cells[plane].has(cell)


func cell_count(plane: int) -> int:
	return _cells[plane].size()


## The network as something you can path through (M4). Owned here rather than wired up in the
## scene because there must be exactly one and it must never disagree with the cells -- a routing
## graph you can forget to add to a map is a map whose bots quietly cannot follow you.
func graph() -> TunnelGraph:
	return _graph


## Every cell on a plane with a shaft leading DOWN from it. At plane 0 these are the entrances:
## the only places anyone gets underground, and therefore the only places a route can.
func shaft_cells(plane: int) -> Array:
	return _shafts[clampi(plane, 0, PLANE_COUNT - 1)].keys()


## Every dug cell on a plane, as Vector2i grid coordinates.
##
## For anything that has to draw or walk the whole network rather than ask about one cell: the
## minimap today, AStar3D pathing for bots at M4. Handing back the keys costs one allocation and
## saves the caller a five-thousand-cell scan of the arena to find a few dozen tiles.
func dug_cells(plane: int) -> Array:
	return _cells[clampi(plane, 0, PLANE_COUNT - 1)].keys()


## The part of a plane that belongs on one crew's minimap.
##
## "Known" here means authored by the crew, not merely connected to it. That distinction is the
## M5 rule: an enemy can break into your corridor without donating the rest of their route.
func known_tunnel_cells(plane: int, team: int) -> Array[Vector2i]:
	var found: Array[Vector2i] = []
	if plane <= 0 or plane >= PLANE_COUNT:
		return found
	var bit := 1 << clampi(team, Team.BLUE, Team.RED)
	for cell: Vector2i in _tunnel_known[plane]:
		if int(_tunnel_known[plane][cell]) & bit != 0:
			found.append(cell)
	return found


func is_tunnel_known(plane: int, cell: Vector2i, team: int) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT:
		return false
	return int(_tunnel_known[plane].get(cell, 0)) & (1 << clampi(team, Team.BLUE, Team.RED)) != 0


## Shaft mouths a crew has made or reached. On the lawn these are the only tunnel information
## the minimap draws, so they need the same ownership boundary as floor cells.
func known_shaft_cells(plane: int, team: int) -> Array[Vector2i]:
	var found: Array[Vector2i] = []
	if plane < 0 or plane >= PLANE_COUNT:
		return found
	var bit := 1 << clampi(team, Team.BLUE, Team.RED)
	for cell: Vector2i in _shaft_known[plane]:
		if int(_shaft_known[plane][cell]) & bit != 0:
			found.append(cell)
	return found


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
func dig(plane: int, cell: Vector2i, team: int = -1) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT or _cells[plane].has(cell):
		return false
	if not in_bounds(cell):
		return false
	# Rock (GDD section 3). Said out loud, because a tile that refuses to open with no explanation
	# is indistinguishable from a dig control that has stopped working -- which is the exact
	# lesson the entrance key taught this file once already.
	if _rock[plane].has(cell):
		dig_refused.emit("solid rock -- go round it, or go under it")
		return false
	_cells[plane][cell] = true
	_learn_tunnel_cell(plane, cell, team)
	_mark_mask(plane, cell, true)
	_refresh_cell(plane, cell)
	_rebuild_walls(plane)
	cell_opened.emit(plane, cell)
	return true


## Bring a cell down: the floor closes, the walls seal around it, and it is earth again.
##
## THE ONLY THING THAT SHRINKS THE NETWORK, which is why it gets its own signal and its own set
## of refusals. Everything else here only ever adds, and a good deal of the code below quietly
## assumes that -- the mask, the graph, the lamps and the wall mesh are all caches over `_cells`,
## and all four are rebuilt from it here rather than patched.
##
## WHY A SHAFT CELL IS REFUSED. A shaft is a hole in one plane's floor and in the ceiling of the
## one below, recorded once. Collapsing either end would leave a shaft that starts or finishes in
## solid earth -- which the audit's SHAFT_ENDS invariant catches, and which in play is a mouse
## pressing E and arriving inside the ground. Bringing the shaft down as well is a bigger design
## decision than this is (it would let one Engineer erase an entrance the whole crew relies on),
## so for now the answer is simply no.
##
## STRANDING IS ALLOWED, and is the point. Sealing a corridor can cut off everything past it, and
## the REACHABLE invariant deliberately is not asserted against live play -- a pocket of tunnel
## nobody can get to is exactly what a cave-in is for. Anyone caught in the cell is scruffed
## (GDD section 3); anyone caught BEYOND it can dig their way out, slowly, or take the six
## seconds. Both are consequences worth having.
func collapse(plane: int, cell: Vector2i) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT or not _cells[plane].has(cell):
		return false
	if _shafts[plane].has(cell) or has_shaft_up(plane, cell):
		dig_refused.emit("the shaft holds this stretch open")
		return false

	_cells[plane].erase(cell)
	_tunnel_known[plane].erase(cell)
	_grids[plane].set_cell_item(Vector3i(cell.x, 0, cell.y), GridMap.INVALID_CELL_ITEM)
	_mark_mask(plane, cell, false)
	_rebuild_walls(plane)
	_relight(plane)
	cell_collapsed.emit(plane, cell)
	tunnel_revealed.emit(plane, TEAM_BITS)
	return true


## Whether this cell could be brought down, without doing it. For a UI that has to say so before
## the player commits, and for the ability's own reach test.
func can_collapse(plane: int, cell: Vector2i) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT or not _cells[plane].has(cell):
		return false
	return not _shafts[plane].has(cell) and not has_shaft_up(plane, cell)


## Sink a shaft from `plane` down to `plane + 1`, at the cell the player is standing on.
func dig_shaft_down(plane: int, cell: Vector2i, team: int = -1) -> bool:
	var refusal := _shaft_refusal(plane, cell)
	if refusal != "":
		dig_refused.emit(refusal)
		return false

	# Open the landing before recording the shaft, so the cell below exists to arrive in. A
	# shaft you drop through onto solid earth is worse than no shaft.
	dig(plane + 1, cell, team)
	# The landing may already be an enemy corridor. Taking a shaft into it reveals the landing
	# cell, not the connected route beyond it.
	_learn_tunnel_cell(plane + 1, cell, team)
	if plane > 0:
		_learn_tunnel_cell(plane, cell, team)
	_shafts[plane][cell] = true
	var bits := _team_bits(team)
	_shaft_known[plane][cell] = int(_shaft_known[plane].get(cell, 0)) | bits
	_refresh_cell(plane, cell)
	_refresh_cell(plane + 1, cell)
	# Both ends of the new shaft change what their plane's lights should look like, and neither
	# gets rebuilt on its own: _rebuild_walls only relights when a FLOOR cell changes, and
	# breaking upward changes no floor on the plane you are standing on. So the beam -- the only
	# thing that says a shaft goes up from here -- did not appear until something else forced a
	# rebuild, which in practice meant climbing up and back down to trip set_focus_plane.
	_relight(plane)
	_relight(plane + 1)
	shaft_opened.emit(plane, cell)
	tunnel_revealed.emit(plane, bits)
	return true


## Sink a shaft from `plane - 1` down to `plane`, authored from below -- the same object as
## dig_shaft_down, just dug by someone standing underneath it.
func dig_shaft_up(plane: int, cell: Vector2i, team: int = -1) -> bool:
	if plane <= 0:
		dig_refused.emit("nothing above to break into")
		return false
	# Rock overhead gets its own refusal. Left to the `dig` below it would come back as "no floor
	# to sink a shaft from", which is true and useless -- the player would go looking for somewhere
	# to stand rather than somewhere the ceiling is soft.
	if is_rock(plane - 1, cell):
		dig_refused.emit("rock overhead -- nothing to break into")
		return false
	# Paving overhead (GDD section 3) gets its own voice for the same reason rock does, and for a
	# sharper one: this refusal is the mechanic. Coming up under a patio has to say "not HERE,
	# keep going" -- a player who reads it as "the key is broken" learns nothing about the map,
	# and the whole value of a no-surface zone is that you know where the enemy has to appear.
	if plane == 1 and is_sealed(cell):
		dig_refused.emit("paving overhead -- keep going until you're clear of it")
		return false
	# The cell above has to be floor to arrive on, unless it is the surface, which is
	# everywhere. Opened first so the shaft below has somewhere to land.
	dig(plane - 1, cell, team)
	return dig_shaft_down(plane - 1, cell, team)


## Why a shaft can't be sunk here, or "" if it can.
func _shaft_refusal(plane: int, cell: Vector2i) -> String:
	if plane < 0 or plane + 1 >= PLANE_COUNT:
		return "nothing below to break into"
	if not in_bounds(cell):
		return "outside the arena"
	# NO-SURFACE ZONES (GDD section 3), and plane 0 is the only place the rule can bite: a shaft
	# recorded at plane 0 is a mouth on the lawn, whichever end it was cut from. Everything deeper
	# passes straight through here, because tunnelling under a patio -- along it, and further down
	# beneath it -- is exactly what the rule leaves you.
	if plane == 0 and is_sealed(cell):
		return "paved over -- there's no digging through the patio"
	# Plane 0 is the surface: standing anywhere on it is standing on solid ground, so an
	# entrance needs no floor cut first. Below that you have to be in a tunnel.
	if plane > 0 and not _cells[plane].has(cell):
		return "no floor to sink a shaft from"
	if _shafts[plane].has(cell):
		return "a shaft is already here"
	# A shaft is only worth sinking if there is somewhere to arrive. Checked HERE rather than being
	# left to the `dig` below, because that call opens the landing before the shaft is recorded --
	# so rock underneath would give you a shaft into solid ground and trip the audit's SHAFT_ENDS
	# rather than a refusal you can act on.
	if _rock[plane + 1].has(cell):
		return "rock below -- nothing to sink into"

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
		_rock_faces[index].visible = focused
		_rock_caps[index].visible = focused
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
	material.set_shader_parameter("dirt", DirtTexture.shared())
	material.set_shader_parameter("dirt_tile", DirtTexture.WORLD_TILE)

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
##
## GRAIN BY DEFAULT. Flat colour at this camera distance reads as card, not as earth: nothing
## says how big a cell is and the mouse looks like it is standing on a colour. The dirt speckle
## is world-mapped and shared with the lawn and the lids, so a trench floor is visibly the same
## material as the ground it is cut into. The one thing that opts out is the shaft marker, which
## is a hole rather than a surface -- texturing it would say there is floor down there.
func _make_material(colour: Color, grain: bool = true) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.95
	material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if grain:
		DirtTexture.apply_to(material)
	return material


## The face of a rock seam. Cool, pale, and FAINTLY SELF-LIT.
##
## The self-lighting is the load-bearing part and it took a screenshot to find out. Everything
## down here is lit by warm lamps, so a plain grey albedo comes back off the wall as brown -- the
## seam ended up the same colour as the earth beside it and the one thing it has to say ("this is
## not going to open") was said in the one channel the lighting had already claimed. A little
## emission holds the hue against the lamp, which is also how actual stone reads next to soil: it
## doesn't take the colour of the light the way loose earth does.
func _make_rock_material() -> StandardMaterial3D:
	var material := _make_material(rock_color)
	material.emission_enabled = true
	material.emission = rock_color
	material.emission_energy_multiplier = 0.22
	return material


## The top of a seam your crew has found. Unshaded, pale stone, and that is the whole trick.
##
## It is drawn a centimetre under a lid that is itself lit by nothing much, so a shaded sheet came
## back almost black and the vein you had paid a dig to learn about was invisible. The cap also
## used to be deliberately dark AND its generated winding faced away from the camera, so back-face
## culling removed it outright from above. Unshaded means the colour on screen is the colour in the
## export; double-sided means a generated quad cannot silently choose the wrong visible side.
func _make_rock_top_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = rock_top_color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	DirtTexture.apply_to(material)
	return material


## Draw the veins `team` has found, on every plane. Called by whatever knows who is looking.
##
## THE VIEWER IS TOLD TO THE NETWORK RATHER THAN LOOKED UP BY IT, because a network that went
## hunting for "the player" would be a rendering object reaching into the match to find out whose
## side it is on -- and at M7 there is no single answer to that question on a server. One caller,
## one line, and the day this is per-client it is the caller that changes.
func show_known_rock(team: int) -> void:
	if team == _cap_team:
		return
	_cap_team = team
	for plane in range(PLANE_COUNT):
		_rebuild_rock_caps(plane)


## One flat sheet per plane, over the cells this crew knows about.
##
## Quads rather than a GridMap or one mesh per cell: a vein is a few dozen cells, the sheet is
## rebuilt a handful of times a match, and a single mesh means the whole thing is one draw call and
## one material to hide when you leave the plane.
func _rebuild_rock_caps(plane: int) -> void:
	if plane < 0 or plane >= _rock_caps.size():
		return
	var cap := _rock_caps[plane]
	if _cap_team < 0 or plane <= 0:
		cap.mesh = null
		return

	var known := known_rock_cells(plane, _cap_team)
	if known.is_empty():
		cap.mesh = null
		return

	# JUST ABOVE THE LID, not just below it, and the first version got this exactly backwards. Under
	# the lid is where a seam's top surface really is -- and it is invisible there, permanently: the
	# lid is opaque earth, and the one thing that ever cuts a hole in it is a cell being DUG. A rock
	# cell is never dug. So the sheet was drawn correctly, hidden under solid ground, on every plane.
	#
	# Above it, the sheet is what it always claimed to be in the comments: a piece of knowledge laid
	# over the world rather than a surface in it. You are looking at the ground your crew has learned
	# there is rock beneath, which is the only reading of "the top of the seam" a camera up here can
	# actually deliver.
	#
	# Measured off SPACING rather than `wall_height`, because the lid sits one plane spacing above
	# the floor whatever the walls have been tuned to -- and a sheet that tracked the wall dial would
	# sink back under the ground the first time somebody shortened it.
	var top := SPACING + 0.02
	var half := CELL * 0.5
	var t := SurfaceTool.new()
	t.begin(Mesh.PRIMITIVE_TRIANGLES)
	for cell: Vector2i in known:
		var centre := Vector3(cell.x * CELL, top, cell.y * CELL)
		_quad(t,
			centre + Vector3(-half, 0.0, half), centre + Vector3(half, 0.0, half),
			centre + Vector3(half, 0.0, -half), centre + Vector3(-half, 0.0, -half))
	t.generate_normals()
	var mesh := t.commit()
	mesh.surface_set_material(0, _make_rock_top_material())
	cap.mesh = mesh
	cap.visible = plane == _focus


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
	# A second surface for the faces that turn out to be stone. Same quads, same collision, drawn
	# apart only so they can be a different material -- which is the entire user interface for
	# rock: you dig into a seam, the corridor ends in grey, and nothing has to explain itself.
	var stone := SurfaceTool.new()
	stone.begin(Mesh.PRIMITIVE_TRIANGLES)

	var collision := PackedVector3Array()
	var half := CELL * 0.5
	var faces := 0
	var stone_faces := 0
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
			if _rock[plane].has(cell + side):
				_quad(stone, a, b, b + up, a + up)
				stone_faces += 1
			else:
				_quad(walls, a, b, b + up, a + up)
				faces += 1
			_collide_quad(collision,
				a, b, Vector3(b.x, barrier, b.z), Vector3(a.x, barrier, a.z))

	var mesh: ArrayMesh = null
	if faces > 0:
		walls.generate_normals()
		mesh = walls.commit()
		mesh.surface_set_material(0, _wall_materials[plane])

	_walls[plane].mesh = mesh

	var stone_mesh: ArrayMesh = null
	if stone_faces > 0:
		stone.generate_normals()
		stone_mesh = stone.commit()
		stone_mesh.surface_set_material(0, _rock_materials[plane])
	_rock_faces[plane].mesh = stone_mesh

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
