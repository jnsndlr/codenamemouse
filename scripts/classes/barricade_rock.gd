class_name BarricadeRock
extends Breakable
## A boulder wedged across a tunnel. The Engineer's second capability (GDD section 4), and the
## first thing in this game that one class builds and another class removes.
##
## A ROCK RATHER THAN A BUILT BARRIER, and that is a rule about what this world is made of. There
## is no lumber at mouse scale and nothing here manufactures anything; what an Engineer can
## actually do is heave something into a gap. It also makes the counterplay obvious without a
## legend: it is a rock, it is enormous, and the mouse built like a brick is the one who shifts it.
##
## THREE THINGS AT ONCE, and all three have to agree or the object lies about itself:
##
##   Physical   A collider on the plane's own layer, so only mice down there meet it.
##   Routed     The cell leaves the routing graph, so bots plan around it instead of walking
##              into it and grinding against the collider looking broken.
##   Removable  Brute swings only. Anyone else may hit it all day.
##
## The routed part is the one that would be easy to forget and impossible to see: a bot pathing
## through a cell it cannot enter does not error, it just stands there vibrating, which reads as
## the AI being stupid rather than the map having changed under it.
##
## SEEDED SHAPE, from the cell it sits in. Two barricades side by side are visibly different
## rocks, the same cell always grows the same rock, and a screenshot is comparable to the last --
## the same bargain the shaft marker and the rock scatter already make.

## Cleared, by whom. Kept alongside the base class's `broken` because the ability listens for its
## own boulders specifically -- and because "cleared" is what this one means: a corridor reopened.
signal cleared(rock: BarricadeRock, by: Mouse)

## Its own group as well as the breakable one. The swing finds it through `Breakable.GROUP` like
## everything else; this is for the ability, which counts the barricades IT has standing and must
## not be able to see a boulder lying on the lawn.
##
## NOT called `GROUP`, and that is not a style choice: a constant here that shadows one in the base
## class makes every OTHER file that reads `BarricadeRock.GROUP` fail to parse, with an error that
## names neither file. See breakable.gd.
const BARRICADE_GROUP: StringName = &"barricade"

## Radius as a fraction of the cell. Wide enough that the gap left either side is narrower than a
## mouse: a barricade you can squeeze past is a decoration.
@export_range(0.2, 0.5, 0.01) var fill: float = 0.42
## How much of the trench height it fills. Under one, so you can see over it and read the corridor
## beyond -- being able to see what you cannot reach is most of what makes it frustrating in the
## right way.
@export_range(0.3, 1.0, 0.01) var height_fraction: float = 0.78
@export var rock_color: Color = Color(0.42, 0.43, 0.46)

var cell: Vector2i = Vector2i.ZERO
## Who put it there, for anything later that wants to credit it.
var owner_mouse: Mouse = null

var _network: TunnelNetwork
## Kept so the pieces can be cut from the boulder's own triangles when it goes. See rock_debris.gd.
var _shell: ArrayMesh
## A client-side transcription of a server rock. It draws and collides, but it never edits the
## route graph and cannot take a locally resolved hit; both decisions belong to the server.
var _replica: bool = false


## Built and placed in one call, because a barricade that exists but has not yet chosen a cell is
## a state nothing needs and everything would have to handle.
static func place(
	network: TunnelNetwork, at_plane: int, at_cell: Vector2i, by: Mouse
) -> BarricadeRock:
	var rock := BarricadeRock.new()
	# Three swings is two seconds of a Brute's whole attention, which is the price the ability is
	# really costing the other crew -- not the damage, the delay. Set here rather than left to the
	# base class's default, which is for the map's own rock.
	rock.hits_to_clear = 3
	rock.plane = at_plane
	rock.cell = at_cell
	rock.owner_mouse = by
	rock._network = network
	network.add_child(rock)
	return rock


## Reproduce a server-owned rock without acquiring authority over the tunnel beneath it.
static func reproduce(
	network: TunnelNetwork,
	at_plane: int,
	at_cell: Vector2i,
	by: Mouse,
	hits_left: int,
	hits_total: int
) -> BarricadeRock:
	var rock := BarricadeRock.new()
	rock._replica = true
	rock.hits_to_clear = maxi(hits_total, 1)
	rock.plane = at_plane
	rock.cell = at_cell
	rock.owner_mouse = by
	rock._network = network
	network.add_child(rock)
	rock.adopt_replica(by, hits_left, hits_total)
	return rock


func _ready() -> void:
	super()
	add_to_group(BARRICADE_GROUP)
	if _replica:
		# Puppet mice never resolve their swing, but removing this from the generic target set makes
		# that authority boundary structural rather than dependent on every mouse staying a puppet.
		remove_from_group(Breakable.GROUP)
	if _network == null:
		_network = get_parent() as TunnelNetwork
	global_position = _network.cell_to_world(plane, cell)

	var span := TunnelNetwork.CELL * fill
	var tall := _network.wall_height * height_fraction
	_build_mesh(span, tall)
	_build_body(span, tall)

	if not _replica:
		# The cell leaves the routing graph for as long as this stands. A replica deliberately does
		# not: its TunnelNetwork is a puppet and the client never makes routing decisions anyway.
		_network.block_cell(plane, cell)
		# An Engineer can bring down the ground a barricade is standing on. Nothing catches that on
		# the way past, so the rock listens for its own floor disappearing -- otherwise it hangs in
		# the air over a sealed cell, still blocking a route that no longer exists.
		_network.cell_collapsed.connect(_on_cell_collapsed)


func _exit_tree() -> void:
	# Guarded for the case where the whole scene is going down and the network is already gone --
	# which is every scene change and every audit teardown, and would otherwise be an error printed
	# after the run has finished, where nobody reads it.
	if not _replica and is_instance_valid(_network):
		_network.unblock_cell(plane, cell)


## A replica is scenery with collision, not a second simulation target.
func hit_by(who: Mouse) -> bool:
	if _replica:
		return false
	return super.hit_by(who)


## Apply the fields that can change while a barricade stands. Scaling is the base Breakable's
## damage language, repeated here because calling `_on_damaged` after setting the count keeps the
## client at exactly the same visual stage without emitting an authoritative damage signal.
func adopt_replica(by: Mouse, hits_left: int, hits_total: int) -> void:
	if not _replica:
		return
	owner_mouse = by
	hits_to_clear = maxi(hits_total, 1)
	_left = clampi(hits_left, 1, hits_to_clear)
	_on_damaged()


## Remove immediately from both presentation groups, then defer freeing like every other world
## object. There is deliberately no debris burst here: absence can mean either "the Brute broke
## it" or "your crew forgot that enemy corridor", and inventing an explosion for the latter would
## leak information the filter just took away.
func discard_replica() -> void:
	if not _replica:
		return
	remove_from_group(BARRICADE_GROUP)
	remove_from_group(Breakable.GROUP)
	queue_free()


## THE ROCK DIES NOW; the pieces are somebody else's problem. Handing the break to a separate node
## is what lets the cell go back to being walkable while the bits are still in the air -- a Brute
## who has just earned the corridor must not be stopped by a rock that is visibly in pieces, and a
## bot re-planning mid-animation must not be told the way is still shut.
##
## Unblocked HERE rather than left to `_exit_tree`, because `queue_free` is deferred to the end of
## the frame and "the way is open" should not be, either for the router or for the physics. The
## call in `_exit_tree` stays as the catch-all for every other way this node can die; it is
## idempotent, so doing it twice costs nothing.
func _on_broken(by: Mouse) -> void:
	remove_from_group(BARRICADE_GROUP)
	if is_instance_valid(_network):
		_network.unblock_cell(plane, cell)
	RockDebris.burst(
		_network, global_position, _shell, rock_color, scale.x,
		hash(Vector3i(plane, cell.x, cell.y))
	)
	cleared.emit(self, by)
	queue_free()


func _on_cell_collapsed(at_plane: int, at_cell: Vector2i) -> void:
	if at_plane == plane and at_cell == cell:
		queue_free()


## The lump itself comes from RockShell, shared with the boulders on the lawn -- a barricade is a
## rock a mouse heaved into a gap, and if the two were generated separately they would drift into
## being different materials. Seeded from the cell, so the same spot always grows the same rock and
## two neighbours are visibly different.
func _build_mesh(span: float, tall: float) -> void:
	_shell = RockShell.build(span, tall, hash(Vector3i(plane, cell.x, cell.y)))
	var mesh := MeshInstance3D.new()
	mesh.mesh = _shell
	mesh.material_override = RockShell.material_for(rock_color)
	add_child(mesh)


## Collision is a plain cylinder, not the lumpy mesh. The lumps are a look; what the rules need is
## "a mouse cannot get past this", and a convex primitive says that without a trimesh's habit of
## letting a fast body tunnel through a facet.
func _build_body(span: float, tall: float) -> void:
	var shape := CylinderShape3D.new()
	shape.radius = span
	shape.height = tall

	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.position = Vector3(0.0, tall * 0.5, 0.0)

	var body := StaticBody3D.new()
	# ITS OWN PLANE'S LAYER, exactly like the tunnel geometry. A barricade on plane 2 must not be
	# a wall for somebody walking the lawn above it, and per-plane layers are what make that free.
	body.collision_layer = TunnelNetwork.plane_bit(plane)
	body.collision_mask = 0
	body.add_child(collision)
	add_child(body)
