extends SceneTree
## Invariant audit for the tunnel network. Finds the holes instead of falling through them.
##
##   godot --headless --path . --script tools/tunnel_audit.gd
##
## Every "I fell out of the world" bug has been found by playing until it happened, then
## reasoning backwards about which face failed to get a wall. That doesn't scale: the network
## gains new ways to have gaps every time it grows, and the bad configurations are exactly the
## ones a human wouldn't think to try. So state the invariants once, build the awkward
## configurations deliberately, and let the machine check them.
##
## The invariants, and what each one is really protecting:
##
##   SHAFT_ENDS      Both ends of every shaft are somewhere you can stand.
##   NO_STACK        No cell has a shaft above AND below it. This is what keeps E a single
##                   key with a single destination, and what stops a well being drilled
##                   straight from the lawn to the bottom.
##   SHAFT_SPACING   No two shaft mouths within the exclusion radius of each other on the
##                   same plane. NO_STACK stops the well going straight down; this stops it
##                   going down a 2x2 staircase instead, and keeps each beam of daylight a
##                   distinct "the way out is HERE" rather than one merged bright patch.
##   PLANE_LAYERS    Each plane's collision is on its own layer, so a mouse only ever meets
##                   the geometry of the layer it's standing on.
##   REACHABLE       Every dug cell can be got to from a surface entrance.
##   BOUNDS          No cell outside the diggable arena.
##   FLOOR_PHYSICS   Something solid exists under every dug cell, at the height the renderer
##                   claims. Guards the render/collision split.
##   HEADROOM        The mouse fits, standing, in every cell it can dig.
##   CONTAINMENT     From every dug cell, anywhere the player's own capsule can actually
##                   slide to has ground under it. This is the fall-out-of-the-world check,
##                   and it is deliberately the one that asks the PHYSICS ENGINE rather than
##                   the cell data -- every other check can only find mistakes I already know
##                   how to describe.
##
## Four invariants RETIRED with ramps: RAMP_PAIRS, RAMP_ENDS, OPEN_FACES and VERTICAL. Each
## guarded a hazard that only sloped, two-cell, downward-hanging geometry could create. They
## weren't fixed, they became unrepresentable.
##
## Exit code is non-zero if any invariant fails, so this can gate a commit.

## Nodes stripped from the scene before auditing. The ground slab and the perimeter walls must
## stay -- they are load-bearing for containment. Everything else is either irrelevant or
## actively in the way: the rock scatter's colliders would BLOCK containment casts and quietly
## turn a real hole into a pass, and a live player wandering the arena makes it non-deterministic.
const STRIP: Array[String] = [
	"Player", "CameraRig", "DigController", "DepthFocus", "FallGuard", "HUD", "Surface/Rocks"
]

const REACH: float = 0.7
const MAX_DROP: float = TunnelChunks.PLANE_SPACING + 0.3
## How far ABOVE the landing spot to start the downward ray. Every floor is flush with every
## other now, so this only has to clear the capsule's own resting offset.
const RAY_RISE: float = 0.3
## Step along a containment path. Well under the capsule's 0.16 radius, so nothing thin can
## slip between two samples.
const STEP: float = 0.05
## A settled body rests a hair above the floor rather than embedded in it. Without this every
## cell reports as crushed, because a capsule whose lowest point is exactly on a zero-thickness
## trimesh quad counts as intersecting it.
const STAND_EPSILON: float = 0.02

var _findings: Array[String] = []
var _scene: Node
var _network: TunnelNetwork
var _space: PhysicsDirectSpaceState3D
var _total_failures: int = 0


func _initialize() -> void:
	var scenarios: Array = [
		["entrance_and_corridor", _build_entrance_and_corridor],
		["descend_to_the_bottom", _build_descend_to_the_bottom],
		["climb_back_up", _build_climb_back_up],
		["stacked_shaft_refused", _build_stacked_shaft_refused],
		["shaft_without_floor", _build_shaft_without_floor],
		["shaft_from_deepest_plane", _build_shaft_from_deepest_plane],
		["corridor_under_own_entrance", _build_corridor_under_own_entrance],
		["stacked_corridors", _build_stacked_corridors],
		["shaft_over_existing_corridor", _build_shaft_over_existing_corridor],
		["corridor_to_every_boundary", _build_corridor_to_every_boundary],
		["shaft_at_boundary", _build_shaft_at_boundary],
		["wide_chamber", _build_wide_chamber],
		["two_entrances", _build_two_entrances],
		["crowded_entrances_refused", _build_crowded_entrances_refused],
	]

	for scenario: Array in scenarios:
		var label: String = scenario[0]
		await _fresh_network()
		(scenario[1] as Callable).call()
		for i in range(3):
			await process_frame
			await physics_frame
		_audit(label)

	await _check_dig_flow()

	print("")
	print("=".repeat(78))
	if _total_failures == 0:
		print("ALL INVARIANTS HOLD across %d scenarios, plus the dig flow." % scenarios.size())
	else:
		print("%d failures across %d scenarios plus the dig flow." % [
			_total_failures, scenarios.size()
		])
	print("=".repeat(78))
	quit(1 if _total_failures > 0 else 0)


## A brand new scene per scenario. Sharing one would let an earlier scenario's cells leak into
## a later one's audit, and the whole point is knowing which build broke what.
##
## The REAL scene, not a bare TunnelNetwork. A bare network has no ground slab, so containment
## on the surface is meaningless and the lawn -- which is plane 1's ceiling, and once crushed
## the mouse flat -- would never be tested at all.
func _fresh_network() -> void:
	if _scene != null:
		_scene.free()
	_scene = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(_scene)
	for path: String in STRIP:
		var node: Node = _scene.get_node_or_null(path)
		if node != null:
			node.free()
	_network = _scene.get_node("Tunnels") as TunnelNetwork
	await process_frame
	await physics_frame
	_space = _scene.get_viewport().world_3d.direct_space_state


## Does aiming at a tile and holding the button actually open it?
##
## Every other check in this file inspects a network somebody built by calling dig() directly.
## None of them would notice if the CONTROLS were broken -- if the reach test rejected every
## cell, or progress never accumulated, or the target reset each frame. That is a whole half of
## the feature living with no coverage at all, and it is the half the player touches.
##
## Driven by calling the controller's own update rather than by faking mouse input, because
## warping a cursor and unprojecting a camera in a headless run tests the harness more than the
## game. The aim point is set directly and the player and controller are taken off physics
## processing first, so nothing overwrites it behind us.
func _check_dig_flow() -> void:
	if _scene != null:
		_scene.free()
	_scene = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(_scene)
	await process_frame
	await physics_frame

	var network: TunnelNetwork = _scene.get_node("Tunnels")
	var player: Node3D = _scene.get_node("Player")
	var controller: Node = _scene.get_node("DigController")
	network.dig_shaft_down(0, Vector2i(0, 0))
	await process_frame
	await physics_frame

	player.set_physics_process(false)
	controller.set_physics_process(false)
	player.global_position = network.cell_to_world(1, Vector2i(0, 0)) + Vector3.UP * 0.05
	controller._plane = 1

	_findings.clear()
	var neighbour := Vector2i(0, 1)
	var far := Vector2i(0, 9)

	# Adjacent, within reach, undug: should open after dig_seconds of holding.
	player._aim_point = network.cell_to_world(1, neighbour)
	Input.action_press("dig")
	for i in range(40):
		controller._update_dig(1.0 / 60.0)
	if not network.is_dug(1, neighbour):
		_fail("DIG_FLOW", "holding the dig button on an adjacent tile did not open it")

	# Out of reach: must stay shut no matter how long you hold.
	player._aim_point = network.cell_to_world(1, far)
	for i in range(60):
		controller._update_dig(1.0 / 60.0)
	if network.is_dug(1, far):
		_fail("DIG_FLOW", "a tile %s cells away was diggable" % far.length())
	Input.action_release("dig")

	# Not holding: nothing opens however long you point at it.
	var another := Vector2i(1, 0)
	player._aim_point = network.cell_to_world(1, another)
	for i in range(40):
		controller._update_dig(1.0 / 60.0)
	if network.is_dug(1, another):
		_fail("DIG_FLOW", "a tile opened without the dig button held")

	print("")
	print("-- dig_flow")
	if _findings.is_empty():
		print("   ok")
		return
	for finding: String in _findings:
		print("   FAIL %s" % finding)
	_total_failures += _findings.size()


# ---------------------------------------------------------------------------- scenarios


## Drive a corridor from `from` along `step`, stopping at the first cell that won't take.
##
## Models the player rather than the API. A player can only dig where they can stand, so they
## cannot leave a gap behind them and carry on past it -- whereas a bare loop over dig() can,
## and then REACHABLE quite correctly reports the far side as stranded and blames the network
## for what the test did.
func _drive(plane: int, from: Vector2i, step: Vector2i, count: int) -> void:
	for i in range(count):
		var at := from + step * i
		if _network.is_dug(plane, at):
			continue
		if not _network.dig(plane, at):
			return


## Sink a shaft and go down it, the way pressing F then E does.
func _descend(plane: int, cell: Vector2i) -> bool:
	return _network.dig_shaft_down(plane, cell)


## An entrance from the lawn and a corridor away from it. The shape of the first ten seconds
## of play, and everything else is a variation on it.
func _build_entrance_and_corridor() -> void:
	_descend(0, Vector2i(0, 0))
	_drive(1, Vector2i(0, 0), Vector2i(0, 1), 8)
	_drive(1, Vector2i(0, 7), Vector2i(1, 0), 6)


## All the way to the deepest plane, one shaft at a time, each offset from the last so the
## no-stacking rule is satisfied honestly rather than by luck.
func _build_descend_to_the_bottom() -> void:
	_descend(0, Vector2i(0, 0))
	_drive(1, Vector2i(0, 0), Vector2i(0, 1), 4)
	_descend(1, Vector2i(0, 3))
	_drive(2, Vector2i(0, 3), Vector2i(1, 0), 4)
	_descend(2, Vector2i(3, 3))
	_drive(3, Vector2i(3, 3), Vector2i(0, -1), 4)


## Dug from underneath with R. Same object as a descent, authored from the other end.
func _build_climb_back_up() -> void:
	_descend(0, Vector2i(0, 0))
	_drive(1, Vector2i(0, 0), Vector2i(1, 0), 6)
	# Standing at (5,0) on plane 1, break upward to the surface.
	_network.dig_shaft_up(1, Vector2i(5, 0))


## A shaft down and a shaft up wanting the same cell. Must be refused, or E has two
## destinations and no way to pick.
func _build_stacked_shaft_refused() -> void:
	_descend(0, Vector2i(0, 0))
	_drive(1, Vector2i(0, 0), Vector2i(0, 1), 4)
	# (0,0) on plane 1 already has a shaft coming down into it from the lawn.
	_network.dig_shaft_down(1, Vector2i(0, 0))


## F pressed underground where there is no floor to sink from.
func _build_shaft_without_floor() -> void:
	_descend(0, Vector2i(0, 0))
	_drive(1, Vector2i(0, 0), Vector2i(0, 1), 3)
	_network.dig_shaft_down(1, Vector2i(9, 9))


## F pressed on the bottom plane. Nothing below to break into.
func _build_shaft_from_deepest_plane() -> void:
	_descend(0, Vector2i(0, 0))
	_drive(1, Vector2i(0, 0), Vector2i(0, 1), 3)
	_descend(1, Vector2i(0, 2))
	_drive(2, Vector2i(0, 2), Vector2i(1, 0), 3)
	_descend(2, Vector2i(2, 2))
	_drive(3, Vector2i(2, 2), Vector2i(0, 1), 3)
	_network.dig_shaft_down(3, Vector2i(2, 4))


## Running a corridor back underneath your own entrance. Used to be a trap -- the entrance
## RAMP filled plane 1's headroom at two cells and the corridor could not pass. A shaft
## occupies nothing, so this is now simply a corridor.
func _build_corridor_under_own_entrance() -> void:
	_descend(0, Vector2i(0, 0))
	_drive(1, Vector2i(0, 0), Vector2i(1, 0), 5)
	_drive(1, Vector2i(4, 0), Vector2i(0, -1), 5)
	_drive(1, Vector2i(4, -4), Vector2i(-1, 0), 6)
	_drive(1, Vector2i(-1, -4), Vector2i(0, 1), 5)


## Two corridors sharing a footprint on different planes. GDD section 3 makes independent
## per-plane layouts the whole point of having depth, so this must be unremarkable.
func _build_stacked_corridors() -> void:
	_descend(0, Vector2i(-6, 0))
	_drive(1, Vector2i(-6, 0), Vector2i(1, 0), 13)
	_descend(1, Vector2i(6, 0))
	_drive(2, Vector2i(6, 0), Vector2i(-1, 0), 13)


## A shaft sunk directly over a corridor that already exists on the plane below. The old
## VERTICAL invariant existed entirely to forbid this; now it just joins the two.
func _build_shaft_over_existing_corridor() -> void:
	_descend(0, Vector2i(-6, 0))
	_drive(1, Vector2i(-6, 0), Vector2i(1, 0), 10)
	# Clear of the entrance landing: a cell can't be both ends of a shaft, and the exclusion
	# radius keeps the next one off all eight of its neighbours too. At (-5,0) -- one cell
	# along, which is where this sat before the radius existed -- the descent is refused and
	# the rest of the scenario quietly tests nothing.
	_descend(1, Vector2i(-4, 0))
	_drive(2, Vector2i(-4, 0), Vector2i(1, 0), 11)
	# Plane 2 now runs directly under plane 1. Drop a second shaft into the middle of it --
	# the case the retired VERTICAL invariant existed entirely to forbid.
	_network.dig_shaft_down(1, Vector2i(3, 0))


## Corridors driven into all four arena boundaries. What's under test is that the last cell is
## properly walled rather than open to the void.
func _build_corridor_to_every_boundary() -> void:
	var edge := _network.half_extent_cells
	_descend(0, Vector2i(0, 0))
	for step: Vector2i in TunnelNetwork.SIDES:
		_drive(1, Vector2i.ZERO, step, edge + 2)


## A shaft on the very boundary cell, and one outside it.
func _build_shaft_at_boundary() -> void:
	var edge := _network.half_extent_cells
	_descend(0, Vector2i(edge, 0))
	_network.dig_shaft_down(0, Vector2i(edge + 1, 0))


## A wide open room rather than a corridor. Wall generation only emits faces on the outside,
## and the mouse has to fit everywhere inside it.
func _build_wide_chamber() -> void:
	_descend(0, Vector2i(0, 0))
	for x in range(-3, 4):
		_drive(1, Vector2i(x, -3), Vector2i(0, 1), 7)
	_descend(1, Vector2i(2, 2))
	_drive(2, Vector2i(2, 2), Vector2i(1, 0), 4)


## Two entrances into one network, one cell apart.
## Two ways into the same plane. Spaced past the exclusion radius on purpose: put them side by
## side, as this scenario originally did, and the second one is simply refused -- the scenario
## still passes every invariant while quietly testing one entrance instead of two.
func _build_two_entrances() -> void:
	_descend(0, Vector2i(0, 0))
	_descend(0, Vector2i(3, 0))
	_drive(1, Vector2i(0, 0), Vector2i(0, 1), 5)
	_drive(1, Vector2i(3, 0), Vector2i(0, 1), 5)


## Entrances crowding each other. Every cell touching the first one must be refused, including
## the diagonals -- a diagonal pair is still two mouths you can step between in one move.
func _build_crowded_entrances_refused() -> void:
	_descend(0, Vector2i(0, 0))
	for x in range(-1, 2):
		for y in range(-1, 2):
			_network.dig_shaft_down(0, Vector2i(x, y))
	# One clear cell out, which must be allowed, or the radius is off by one.
	_descend(0, Vector2i(2, 0))
	_drive(1, Vector2i(0, 0), Vector2i(0, 1), 4)
	_drive(1, Vector2i(2, 0), Vector2i(0, 1), 4)


# ------------------------------------------------------------------------------- audit


func _audit(label: String) -> void:
	_findings.clear()
	_check_shaft_ends()
	_check_no_stack()
	_check_shaft_spacing()
	_check_plane_layers()
	_check_bounds()
	_check_reachable()
	_check_floor_physics()
	_check_headroom()
	_check_containment()

	var counts: Array = []
	var shafts := 0
	for plane in range(TunnelNetwork.PLANE_COUNT):
		counts.append(_network.cell_count(plane))
		shafts += (_network._shafts[plane] as Dictionary).size()
	print("")
	print("-- %s  cells/plane %s  shafts %d" % [label, counts, shafts])
	if _findings.is_empty():
		print("   ok")
		return
	for finding: String in _findings:
		print("   FAIL %s" % finding)
	_total_failures += _findings.size()


func _fail(check: String, detail: String) -> void:
	_findings.append("[%s] %s" % [check, detail])


## Both ends of a shaft have to be somewhere you can stand: floor below, and floor above
## unless the top is the lawn, which is everywhere.
func _check_shaft_ends() -> void:
	for plane in range(TunnelNetwork.PLANE_COUNT):
		for cell: Vector2i in _network._shafts[plane]:
			if plane > 0 and not _network.is_dug(plane, cell):
				_fail("SHAFT_ENDS", "shaft at plane %d %v has no floor at the top" % [plane, cell])
			if plane + 1 >= TunnelNetwork.PLANE_COUNT:
				_fail("SHAFT_ENDS", "shaft at plane %d %v has no plane below" % [plane, cell])
			elif not _network.is_dug(plane + 1, cell):
				_fail("SHAFT_ENDS", "shaft at plane %d %v lands on solid earth" % [plane, cell])


## Nothing may have a way up AND a way down. E has one key and needs one answer.
func _check_no_stack() -> void:
	for plane in range(TunnelNetwork.PLANE_COUNT):
		for cell: Vector2i in _network._shafts[plane]:
			if plane + 1 < TunnelNetwork.PLANE_COUNT and _network._shafts[plane + 1].has(cell):
				_fail("NO_STACK", "plane %d %v has shafts both up and down" % [plane + 1, cell])


## Shaft mouths keep their distance. Checked across ADJACENT LAYERS as well as within one,
## because a shaft recorded at plane N is a hole in N's floor and a hole in the ceiling of
## N+1 -- so a floor hole and a ceiling hole a cell apart are two mouths in the same corridor
## even though they live in different rows of _shafts.
func _check_shaft_spacing() -> void:
	var reach: int = _network.shaft_exclusion_cells
	if reach <= 0:
		return
	for plane in range(TunnelNetwork.PLANE_COUNT):
		for cell: Vector2i in _network._shafts[plane]:
			for other_plane in range(plane, mini(plane + 2, TunnelNetwork.PLANE_COUNT)):
				for other: Vector2i in _network._shafts[other_plane]:
					if other == cell and other_plane == plane:
						continue
					var gap := maxi(absi(other.x - cell.x), absi(other.y - cell.y))
					if gap > 0 and gap <= reach:
						_fail("SHAFT_SPACING", "shafts %v (plane %d) and %v (plane %d) are %d cell(s) apart" % [
							cell, plane, other, other_plane, gap])


## Each plane's geometry on its own layer, which is what lets a barrier overshoot without
## fencing off the layer above.
func _check_plane_layers() -> void:
	for plane in range(TunnelNetwork.PLANE_COUNT):
		var body := _network.get_node_or_null("Collision%d" % plane) as StaticBody3D
		if body == null:
			_fail("PLANE_LAYERS", "plane %d has no collision body" % plane)
			continue
		var wanted := TunnelNetwork.plane_bit(plane)
		if body.collision_layer != wanted:
			_fail("PLANE_LAYERS", "plane %d is on layer %d, wanted %d" % [
				plane, body.collision_layer, wanted
			])


func _check_bounds() -> void:
	for plane in range(TunnelNetwork.PLANE_COUNT):
		for cell: Vector2i in _network._cells[plane]:
			if not _network.in_bounds(cell):
				_fail("BOUNDS", "plane %d %v is outside the arena" % [plane, cell])


## Walk the network the way a player does and see what can't be got to.
##
## Roots are the surface shafts, since the lawn is walkable everywhere. Any dug cell not
## reached is earth that was removed and can never be stood in.
func _check_reachable() -> void:
	var seen: Dictionary = {}
	var queue: Array[Vector3i] = []
	for cell: Vector2i in _network._shafts[0]:
		var node := Vector3i(0, cell.x, cell.y)
		seen[node] = true
		queue.append(node)

	if queue.is_empty() and _total_dug() > 0:
		_fail("REACHABLE", "network has dug cells but no surface entrance")
		return

	while not queue.is_empty():
		var node: Vector3i = queue.pop_back()
		for next: Vector3i in _walkable_from(node.x, Vector2i(node.y, node.z)):
			if seen.has(next):
				continue
			seen[next] = true
			queue.append(next)

	var unreachable: Array = []
	for plane in range(1, TunnelNetwork.PLANE_COUNT):
		for cell: Vector2i in _network._cells[plane]:
			if not seen.has(Vector3i(plane, cell.x, cell.y)):
				unreachable.append("plane %d %v" % [plane, cell])
	if not unreachable.is_empty():
		_fail("REACHABLE", "%d cells unreachable from any entrance: %s" % [
			unreachable.size(), ", ".join(unreachable.slice(0, 8))
		])


## Independent of the network's own idea of connectivity, on purpose: a check that shares an
## implementation with the thing it checks proves only that the code agrees with itself.
func _walkable_from(plane: int, cell: Vector2i) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	# Plane 0 is the lawn: you can be anywhere on it, so the only edge that matters is down.
	if plane > 0:
		for side: Vector2i in TunnelNetwork.SIDES:
			if _network.is_dug(plane, cell + side):
				out.append(Vector3i(plane, cell.x + side.x, cell.y + side.y))
	if _network.has_shaft_down(plane, cell):
		out.append(Vector3i(plane + 1, cell.x, cell.y))
	if _network.has_shaft_up(plane, cell):
		out.append(Vector3i(plane - 1, cell.x, cell.y))
	return out


## Render and collision are generated from the same cell data but by different code, and they
## have silently disagreed before. Drop a ray on every floor cell and insist.
func _check_floor_physics() -> void:
	var misses: Array = []
	for plane in range(1, TunnelNetwork.PLANE_COUNT):
		for cell: Vector2i in _network._cells[plane]:
			var top := _network.plane_y(plane)
			var at := Vector3(cell.x * TunnelNetwork.CELL, top, cell.y * TunnelNetwork.CELL)
			var query := PhysicsRayQueryParameters3D.create(
				at + Vector3.UP * 0.3, at + Vector3.DOWN * 0.3
			)
			query.collision_mask = _mask_for(plane)
			var hit: Dictionary = _space.intersect_ray(query)
			if hit.is_empty():
				misses.append("plane %d %v" % [plane, cell])
			elif absf((hit["position"] as Vector3).y - top) > 0.05:
				misses.append("plane %d %v at y=%.2f (wanted %.2f)" % [
					plane, cell, (hit["position"] as Vector3).y, top
				])
	if not misses.is_empty():
		_fail("FLOOR_PHYSICS", "%d cells without a floor beneath them: %s" % [
			misses.size(), ", ".join(misses.slice(0, 8))
		])


## Can the mouse actually STAND in every cell it can dig?
##
## The exact failure that lowering PLANE_SPACING invites. Bringing the planes from 1.5 to 0.65
## made the tunnels visible and simultaneously slid every ceiling down onto the mouse's head --
## with a 0.5-thick lawn slab there was 0.15 of air above plane 1's floor and a mouse is 0.4
## tall. Nothing about that shows up as a fall or a hole; the mouse simply spends the whole
## game wedged in the ground, which is why it needs asking directly.
func _check_headroom() -> void:
	var probe := _capsule_probe()
	var squashed: Array = []
	for plane in range(1, TunnelNetwork.PLANE_COUNT):
		probe.collision_mask = _mask_for(plane)
		for cell: Vector2i in _network._cells[plane]:
			var feet := Vector3(
				cell.x * TunnelNetwork.CELL, _network.plane_y(plane), cell.y * TunnelNetwork.CELL
			)
			probe.transform = Transform3D(Basis(), feet + Vector3.UP * (0.2 + STAND_EPSILON))
			probe.motion = Vector3.ZERO
			if not _space.intersect_shape(probe, 1).is_empty():
				squashed.append("plane %d %v in %s" % [
					plane, cell, _blocker(probe, feet, STAND_EPSILON)
				])
	if not squashed.is_empty():
		_fail("HEADROOM", "%d cells the mouse cannot stand up in: %s" % [
			squashed.size(), ", ".join(squashed.slice(0, 5))
		])


## Stand the player's own capsule in every dug cell, slide it eight ways, and check that
## everywhere it can REACH has ground under it.
##
## The only check that can find a hole nobody predicted. The others encode my model of the
## geometry, so they can only catch mistakes that model already anticipates -- and every
## fall-out-of-the-world bug so far has been a case where the model and the collision trimesh
## disagreed. Here the question is put to the physics engine in the terms the player
## experiences it: can I get to a place with nothing to stand on?
func _check_containment() -> void:
	var probe := _capsule_probe()
	var escapes: Array = []
	var unprobed: Array = []

	for plane in range(1, TunnelNetwork.PLANE_COUNT):
		# The player's real mask for this layer. Anything on another plane is not merely
		# ignored here, it genuinely cannot touch a mouse standing on this one.
		probe.collision_mask = _mask_for(plane)
		for cell: Vector2i in _network._cells[plane]:
			var floor_at := Vector3(
				cell.x * TunnelNetwork.CELL, _network.plane_y(plane), cell.y * TunnelNetwork.CELL
			)
			var stand: Variant = _clear_stance(probe, floor_at)
			if stand == null:
				unprobed.append("plane %d %v (blocked by %s)" % [
					plane, cell, _blocker(probe, floor_at, 0.24)
				])
				continue
			var feet: Vector3 = stand
			for direction: Vector3 in _compass():
				if _obstructed(probe, feet, direction):
					continue  # Walled. Contained.
				var landed := feet + direction * REACH
				var down := PhysicsRayQueryParameters3D.create(
					landed + Vector3.UP * RAY_RISE, landed + Vector3.DOWN * MAX_DROP
				)
				down.collision_mask = probe.collision_mask
				if _space.intersect_ray(down).is_empty():
					escapes.append("plane %d %v toward (%.1f,%.1f)" % [
						plane, cell, direction.x, direction.z
					])

	if not escapes.is_empty():
		_fail("CONTAINMENT", "%d ways to walk into open air: %s" % [
			escapes.size(), ", ".join(escapes.slice(0, 6))
		])
	# Reported rather than swallowed. A sample we couldn't stand up in proved nothing, and
	# silently dropping it is how an audit starts lying.
	if not unprobed.is_empty():
		_fail("CONTAINMENT", "%d samples had no collision-free stance: %s" % [
			unprobed.size(), ", ".join(unprobed.slice(0, 6))
		])


## Can the capsule get from `feet` to `feet + direction * REACH`?
##
## Stepped overlap tests rather than one cast_motion sweep, and that is not stylistic.
## cast_motion against these wall quads reported a clear sweep straight THROUGH a wall -- the
## quads are zero-thickness trimesh faces, which is the case swept trimesh queries handle
## worst. intersect_shape at intervals catches them, at the cost of a few thousand extra
## queries nobody is waiting on.
func _obstructed(
	probe: PhysicsShapeQueryParameters3D, feet: Vector3, direction: Vector3
) -> bool:
	probe.motion = Vector3.ZERO
	var travelled := STEP
	while travelled <= REACH:
		var at := feet + direction * travelled
		probe.transform = Transform3D(Basis(), at + Vector3.UP * 0.2)
		if not _space.intersect_shape(probe, 1).is_empty():
			return true
		travelled += STEP
	return false


## Find a pose at or just above `feet` where the capsule isn't already intersecting.
##
## Load-bearing, not defensive politeness: a query started from an INTERSECTING pose reports
## no collision, indistinguishable from open air, so a buried capsule reads as an escape in
## all eight directions. That produced 45 confident false alarms on a network with nothing
## wrong with it.
func _clear_stance(probe: PhysicsShapeQueryParameters3D, feet: Vector3) -> Variant:
	for lift: float in [STAND_EPSILON, 0.06, 0.10, 0.14, 0.18, 0.24]:
		var at := feet + Vector3.UP * lift
		probe.transform = Transform3D(Basis(), at + Vector3.UP * 0.2)
		probe.motion = Vector3.ZERO
		if _space.intersect_shape(probe, 1).is_empty():
			return at
	return null


## What the capsule is buried in, for the report. "No stance" alone sends you reasoning about
## geometry in your head; the collider tells you in one line.
func _blocker(probe: PhysicsShapeQueryParameters3D, feet: Vector3, lift: float) -> String:
	probe.transform = Transform3D(Basis(), feet + Vector3.UP * (0.2 + lift))
	probe.motion = Vector3.ZERO
	var names: Array[String] = []
	for hit: Dictionary in _space.intersect_shape(probe, 4):
		var collider: Object = hit.get("collider")
		if collider is Node:
			names.append((collider as Node).name)
	return ", ".join(names) if not names.is_empty() else "nothing (probe fault)"


## The player's actual collider, so this measures the body that will really be there.
func _capsule_probe() -> PhysicsShapeQueryParameters3D:
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.16
	capsule.height = 0.4
	var probe := PhysicsShapeQueryParameters3D.new()
	probe.shape = capsule
	return probe


func _mask_for(plane: int) -> int:
	return TunnelNetwork.WORLD_BIT | TunnelNetwork.plane_bit(plane)


## Eight directions, because the dig controller cuts on eight and the player moves freely.
func _compass() -> Array:
	var out: Array = []
	for x in [-1, 0, 1]:
		for z in [-1, 0, 1]:
			if x == 0 and z == 0:
				continue
			out.append(Vector3(x, 0.0, z).normalized())
	return out


func _total_dug() -> int:
	var total := 0
	for plane in range(TunnelNetwork.PLANE_COUNT):
		total += _network.cell_count(plane)
	return total
