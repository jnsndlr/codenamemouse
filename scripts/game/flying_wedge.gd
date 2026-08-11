class_name FlyingWedge
extends Node3D
## One wedge of cheese in the air: thrown clear of a mouse that went down, bouncing, skidding, and
## coming to rest somewhere nobody chose (GDD section 2).
##
## THE PILE DOES NOT EXIST UNTIL THIS LANDS, and that is the whole reason this is an object rather
## than an animation played over one. `MatchDirector._scatter_cheese` used to pick landing spots
## with a random number and create the caches on the same frame -- the wedges were simply *there*,
## a metre away, on the tick somebody was scruffed. Choosing where a wedge ends up and then playing
## a movie of it going there is two systems that have to agree; letting it fall and asking it
## afterwards is one. So this reports where it stopped, and the director banks it then.
##
## NO PHYSICS BODIES, exactly as [RockDebris] argues at length and for the same reasons. A handful
## of rigid bodies per scruff, on their own layer, for half a second of decoration, is a great deal
## of machinery to buy a bounce that four lines of integration give you -- and a wedge that could
## shove a mouse would be a mechanic, which this is not. Nothing collides with these. They fall,
## they hit the lawn, they keep a quarter of it, and they skid to a stop.
##
## THE FLOOR IS THE LAWN, ALWAYS, EVEN WHEN YOU DIED UNDERGROUND. Cheese has never gone down a
## hole -- `MatchDirector._drop_cheese` has always flattened a drop to y=0 -- so a mouse scruffed
## three planes down still spills its wedges onto the grass above. That is a rule this file
## inherits rather than invents, and it is why the launch point is the surface over where you fell
## rather than where you actually were.
##
## IT IS THE HOST'S PICTURE. Caches reach a client as a complete world state twice a second
## (`CheeseState`), so a client sees the pile appear when it appears and never sees the throw. That
## is the same boundary [CaveIn] draws around its stomp dust and is deliberately not fixed here:
## the fix is a one-shot world event on the wire, and it is a bigger question than a bouncing
## wedge. **What a client is never wrong about is where the cheese ended up**, because that is the
## only part that was ever authoritative.

## Where it stopped. The director listens for this and turns it into a pile -- see
## [method MatchDirector._scatter_cheese].
signal settled(wedge: FlyingWedge, at: Vector3)

## So anything can ask whether cheese is still in the air.
##
## THE AUDITS ARE THE REASON THIS EXISTS, and it is worth saying why that is a good reason rather
## than a smell. Between a scruff and a landing there is cheese that is on nobody's books, and
## `cheese_audit`'s central invariant is that wedges are conserved -- so a suite that counted piles
## two frames after a mouse went down would now be counting a world mid-flight and calling the
## difference a leak. It needs to be able to wait for exactly this, and "wait two seconds and hope"
## is the kind of sleep that passes for a year and then fails on somebody's slower machine.
const FLYING_GROUP: StringName = &"flying_wedge"

## Metres per second downward.
##
## LIGHTER THAN [RockDebris]'s 9.0, ON PURPOSE, and the difference is what the two things are for.
## Debris is punctuation -- a rock has broken, the corridor is open, look somewhere else -- so it
## wants to be down and gone. A wedge of cheese is an *objective coming loose*, and both crews are
## being asked to notice where it went. At 9.0 the whole throw was over in half a second and read
## as the pile teleporting with a stutter. Six buys about a third more time in the air for the
## same distance travelled, because for a fixed range the flight time goes as `1/sqrt(g)`.
@export var gravity: float = 6.0
## How much of its downward speed a wedge keeps when it hits the lawn. Low, because a wedge of
## cheese is not a ball -- one visible hop and a skid is the whole performance.
@export_range(0.0, 1.0, 0.05) var bounce: float = 0.38
## What a bounce costs it sideways. This is the friction, and it is what stops a wedge sliding
## across the yard after its last hop.
@export_range(0.0, 1.0, 0.05) var skid: float = 0.62
## How fast it turns end over end, in radians per second.
@export var spin_speed: float = 7.0
## Below this speed, on the ground, it has stopped. Generous: chasing a wedge down to zero costs
## a second of nothing happening, and a pile that appears while the wedge is still visibly
## twitching is worse than one that appears a frame early.
@export var rest_speed: float = 0.55
## How high off the lawn it rests, so the wedge is not half inside the grass.
@export var rest_height: float = 0.02
## The longest a wedge may stay in the air before it is put down wherever it is.
##
## THE SAFETY NET, AND THE REASON IS CONSERVATION. A wedge in flight is cheese that is on nobody's
## books: it has left the mouse and has not become a pile. If anything ever stopped this settling
## -- a bounce that never damps, a node parked outside the tree -- the cheese would leave the
## economy silently, which is the one failure `cheese_audit` was written to catch. A hard ceiling
## means the worst case is a wedge landing in a slightly odd place.
@export var max_flight: float = 3.0

var _velocity: Vector3 = Vector3.ZERO
var _spin: Vector3 = Vector3.ZERO
var _age: float = 0.0
var _done: bool = false


## Joined in `_enter_tree` rather than `_ready`, for the reason `cheese_cache.gd` spells out: Godot
## runs `_enter_tree` across a whole subtree before a single `_ready`, so a wedge is findable from
## the moment it exists rather than from the frame after.
func _enter_tree() -> void:
	add_to_group(FLYING_GROUP)


## Is any cheese still in the air anywhere?
static func any_in_flight(tree: SceneTree) -> bool:
	return tree != null and not tree.get_nodes_in_group(FLYING_GROUP).is_empty()


## Throw one wedge from `at`, travelling `reach` metres before its first bounce.
##
## AIMED BY RANGE RATHER THAN BY SPEED, because the number the design cares about is *how far the
## cheese ends up*, and speed is two solves away from that. At a fixed launch angle the ballistic
## range is `v^2 sin(2t) / g`, so the speed that produces a wanted range is one square root -- and
## the caller gets to think in metres, which is what `MatchDirector.cheese_scatter` is measured in.
##
## The bounces carry it a little further than `reach`; the director allows for that when it picks
## one. Exactly how much further is a property of `bounce` and `skid` and is deliberately not
## solved for here -- a scatter tuned to land on a computed spot would be the arrangement this
## whole file exists to replace.
static func toss(
	parent: Node, at: Vector3, heading: float, reach: float, colour: Color, size: float
) -> FlyingWedge:
	var wedge := FlyingWedge.new()
	parent.add_child(wedge)
	# Placed after entering the tree so `at` is the world point it says it is, whatever transform
	# the cheese field happens to carry -- the same note [RockDebris.burst] makes.
	wedge.global_position = Vector3(at.x, maxf(at.y, wedge.rest_height), at.z)
	wedge._build(colour, size)
	wedge._launch(heading, maxf(reach, 0.05))
	return wedge


## The same prism [CheeseCache] draws its piles out of, at the same size, on purpose: a wedge in
## the air and a wedge on the ground have to be the same object or the landing reads as a swap.
func _build(colour: Color, size: float) -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.85

	var mesh := PrismMesh.new()
	mesh.size = Vector3(size, size, size * 0.7)
	mesh.material = material

	var piece := MeshInstance3D.new()
	piece.mesh = mesh
	piece.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(piece)


## 62 degrees, which is well past the 45 that maximises range, and that is the point rather than an
## error. For a wanted distance the flight time goes as `sqrt(tan(angle))`, so steepening is the
## other half of the same lever `gravity` pulls: it buys air time without buying reach. A flatter
## throw at this scale skims the grass and reads as the wedge being kicked along it.
func _launch(heading: float, reach: float) -> void:
	var angle := deg_to_rad(62.0)
	var speed := sqrt(reach * gravity / maxf(sin(angle * 2.0), 0.01))
	var out := Vector3(cos(heading), 0.0, sin(heading))
	_velocity = out * speed * cos(angle) + Vector3.UP * speed * sin(angle)
	_spin = Vector3(
		randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)
	).normalized() * spin_speed * randf_range(0.6, 1.3)


## `_physics_process` RATHER THAN `_process`, which is the opposite of [RockDebris] and is not a
## style difference. Debris is decoration on a fixed timer and nothing waits for it. This one
## produces a *rule* when it stops -- a pile of cheese somebody can pick up -- and a thing that
## changes the world should do it on the tick the world is being simulated on, at a delta that
## does not vary with the frame rate of whoever is watching.
func _physics_process(delta: float) -> void:
	if _done:
		return
	_age += delta

	_velocity.y -= gravity * delta
	position += _velocity * delta
	rotation += _spin * delta

	if position.y <= rest_height:
		position.y = rest_height
		_velocity.y = -_velocity.y * bounce
		_velocity.x *= skid
		_velocity.z *= skid
		_spin *= skid
		# ON THE GROUND AND SLOW ENOUGH. Asked here rather than every tick, because a wedge at the
		# top of its arc is momentarily slow in exactly this sense and would settle in mid-air.
		if _velocity.length() < rest_speed:
			_settle()
			return

	if _age >= max_flight:
		_settle()


func _settle() -> void:
	if _done:
		return
	_done = true
	# LEFT THE GROUP BEFORE THE SIGNAL, so anything waiting on `any_in_flight` cannot see this
	# wedge as airborne on the same tick the director is already banking it. `queue_free` is
	# deferred to the end of the frame and a check running in between would be told cheese is still
	# in the air that has, by then, definitely landed.
	remove_from_group(FLYING_GROUP)
	settled.emit(self, Vector3(global_position.x, 0.0, global_position.z))
	queue_free()
