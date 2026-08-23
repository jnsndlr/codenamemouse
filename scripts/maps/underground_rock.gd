class_name UndergroundRock
extends Breakable
## The Brute's grip on a buried rock: something in `Breakable.GROUP` standing where the stone is.
##
## A NODE WITH NO MESH AND NO COLLIDER, which is worth saying first because every other breakable
## thing in this game has both. A barricade is an object a mouse heaved into a corridor and a
## boulder is an object lying on the lawn, so each has to be drawn and each has to be solid. A rock
## in the earth is neither: it is already drawn -- it is the pale wall the contour wrapped round it
## -- and it is already solid, because that same wall is in the plane's collision trimesh. The one
## thing a shape in a distance field cannot be is a node in a group, and that is the whole of what
## this supplies.
##
## SO THE STONE IS NOT HERE. The rock is a [RockBody] living in the network; this holds its plane
## and its index and asks the network to do things to it. Keeping the geometry out of the scene tree
## is what stops there being two descriptions of a rock -- and it means a rock that loses a lobe
## changes shape in the one place that matters rather than in two places that can disagree.
##
## IT BREAKS A LOBE AT A TIME, and that is the design rather than an implementation detail. Twenty
## swings that end in a rock vanishing is a countdown; four swings that take a bite out of the side
## you are standing on, and then four more, is rock being broken up -- and it is what makes this
## collaboration instead of a chore. The Engineer does not have to wait for the Brute to finish:
## the first bite is often a way through, and going round is still on the table the whole time.
##
## ONLY THE BREAKABLE ONES GET ONE. Bedrock has no node at all, so a Brute swinging at it does not
## get the damage flash, the scale twitch or any other suggestion that the swing was doing
## something. Nothing happening is the honest answer, and the colour said so before the swing.

## Cleared entirely: the last lobe gone. For anything later that wants to credit it.
signal cleared(rock: UndergroundRock, by: Mouse)

## Its own group as well as the breakable one, so the audits and anything counting map obstructions
## can find these without walking every breakable thing in the yard.
##
## NOT called `GROUP`. A constant here that shadows the base class's makes every OTHER file reading
## `Breakable.GROUP` fail to parse, with an error naming neither file -- see breakable.gd.
const ROCK_GROUP: StringName = &"underground_rock"

## How close the Brute's paws have to be to the stone's FACE. Small, because it is measured to the
## surface rather than to the middle -- see [method swing_target], which is the whole reason a
## three-metre lump is hittable at all.
const FACE_ALLOWANCE: float = 0.15

var plane_index: int = 1
## Which rock in the plane's array. Stable for the match and identical on both ends of a wire, since
## the array is grown from the seed in the same order everywhere.
var rock_index: int = 0

var _network: TunnelNetwork
## Where the last swing came from, so the chips fly off the face being worked. `Breakable._on_damaged`
## takes no argument -- it was written for things that shrink, which need to know nothing about who
## hit them -- and widening it for this one case would put a parameter on every breakable thing in
## the game to serve a debris burst.
var _aimed_from: Vector2 = Vector2.ZERO


## Built and placed in one call, like the barricade and the boulder, because a breaker that exists
## and has not chosen a rock is a state nothing wants and everything would have to handle.
static func place(network: TunnelNetwork, rock: RockBody) -> UndergroundRock:
	var node := UndergroundRock.new()
	node.name = "Rock%d_%d" % [rock.plane, rock.index]
	node.plane_index = rock.plane
	node.rock_index = rock.index
	node.hits_to_clear = network.rock_hits_per_lobe
	node._network = network
	network.add_child(node)
	return node


func _ready() -> void:
	super()
	add_to_group(ROCK_GROUP)
	# The layer a swing has to be thrown from. `Breakable.plane` is what `mouse.gd` filters the cone
	# by, and getting it wrong would let somebody on the lawn break a rock three quarters of a metre
	# under their feet.
	plane = plane_index
	if _network == null:
		_network = get_parent() as TunnelNetwork
	_settle()


## Where a swing lands: the nearest point of the stone's own surface, at floor height.
##
## MEASURED TO THE FACE, NOT TO THE CENTRE, and that is not a refinement -- it is the difference
## between a rock that can be broken and one that cannot. A swing is `attack_reach` plus a small
## allowance from the mouse to the target, and these lumps are up to three metres across, so a
## centre-based target puts the biggest and most obstructive rocks permanently out of reach of the
## one class built to shift them.
##
## It also makes the chewing directional: the face nearest you is the face that comes off (see
## [method RockBody.nearest_lobe]), so a Brute opens a passage from the side they are working on
## rather than watching the far side of the rock crumble.
func swing_target(from: Vector3) -> Vector3:
	var rock := _rock()
	if rock == null:
		return global_position
	var at := rock.surface_point(Vector2(from.x, from.z))
	return Vector3(at.x, _network.plane_y(plane_index), at.y)


func swing_allowance() -> float:
	return FACE_ALLOWANCE


## A swing only counts if there is open corridor between the paws and the stone.
##
## THE ONE RULE THE CONE CANNOT EXPRESS. A rock is buried, so a Brute can stand a stride from a
## lump with a solid metre of undug earth in between and still be within reach of its surface --
## and without this they would chip away at it through the earth, which is both nonsense and a way
## to clear an obstruction nobody has found yet. The Engineer has to open the ground first; that is
## the collaboration the rock exists to force.
##
## SAMPLED RATHER THAN RAYCAST, because the gap is at most a paw's length and the field already
## knows the answer exactly. A cast would mean a physics query against the wall trimesh for a
## question about earth.
func hit_by(who: Mouse) -> bool:
	if who == null or _rock() == null:
		return false
	# A CLIENT'S ROCK IS SCENERY WITH A HIT COUNT, not a second simulation. The same boundary
	# `BarricadeRock` draws with its `_replica` flag, drawn here off the network itself because
	# these are grown from the seed on both ends rather than being told about one at a time -- so
	# there is no "am I the copy" to record, only "is this world mine to change".
	#
	# WITHOUT IT the count would run down locally on the machine that cannot act on it: the client
	# would break a lobe its server still has, and from then on the two disagree about where the
	# earth is. That is the one failure a player cannot see and cannot report.
	if _network.is_puppet():
		return false
	if not _exposed_to(who):
		return false
	_aimed_from = Vector2(who.global_position.x, who.global_position.z)
	return super.hit_by(who)


## A swing that landed but did not finish the bite.
##
## THE BASE CLASS SHRINKS ITSELF and there is nothing here to shrink -- no mesh, no collider, only a
## position for the swing cone to measure against -- so scaling this node would be a transform
## nobody can see, quietly moving the thing a Brute is aiming at.
##
## BUT THE FEEDBACK STILL HAS TO EXIST. A boulder on the lawn visibly gets smaller as it goes; a
## rock in the earth cannot, because what is drawn is the wall wrapped round it and the wall does
## not move until a lobe actually comes off. Without something, four swings out of every five land
## on stone and produce nothing at all on screen -- which is exactly what a swing that is being
## IGNORED looks like, and the game already uses "nothing happens" to mean "wrong class, wrong
## rock". So each swing throws a handful of chips off the face. Small ones: this is punctuation
## saying the work is going in, not the bite landing.
func _on_damaged() -> void:
	var rock := _rock()
	if rock == null:
		return
	var face := rock.surface_point(_aimed_from)
	RockDebris.burst(
		_network,
		Vector3(face.x, _network.plane_y(plane_index), face.y),
		RockShell.build(0.09, 0.14, hash(Vector2i(hits_left(), rock_index))),
		_network.rock_color,
		1.0,
		hash(Vector3i(plane_index, rock_index, hits_left()))
	)


## A bite out of the stone. The rock reshapes, the earth reopens, and the node stays unless that
## was the last lobe.
##
## `_left` IS RESET RATHER THAN THE NODE REPLACED, which is what makes a big rock several bites
## instead of one. Nothing else in `Breakable` expects to survive its own break, so this is the one
## place that has to say so.
func _on_broken(by: Mouse) -> void:
	var rock := _rock()
	if rock == null:
		queue_free()
		return
	var paws := Vector2(by.global_position.x, by.global_position.z)
	var lobe := rock.lobes[maxi(rock.nearest_lobe(paws), 0)]
	var burst_at := Vector3(lobe.x, _network.plane_y(plane_index), lobe.y)

	var gone := _network.break_rock_lobe(plane_index, rock_index, paws)
	# The pieces are cut from a lump the size of the bite, so what flies out of the wall reads as
	# the part of the rock that just left it. Seeded off the rock and the lobe, so the same bite
	# always throws the same chips and a screenshot is comparable to the last.
	RockDebris.burst(
		_network,
		burst_at,
		RockShell.build(lobe.z * 0.5, _network.wall_height * 0.6, hash(burst_at)),
		_network.rock_color,
		1.0,
		hash(Vector3i(plane_index, rock_index, int(lobe.z * 100.0)))
	)
	if gone:
		cleared.emit(self, by)
		queue_free()
		return
	# Back up for the next bite. Nothing else in `Breakable` expects to survive its own break, so
	# this is the one place that has to say so out loud.
	_left = hits_to_clear
	_settle()


## Sit where the stone is, so the swing cone has something to measure against and the debris has
## somewhere to come from. Re-asked after every bite, because the middle of a rock moves when a
## lobe comes off it.
func _settle() -> void:
	var rock := _rock()
	if rock == null or _network == null:
		return
	global_position = Vector3(
		rock.centre.x, _network.plane_y(plane_index), rock.centre.y
	)


func _rock() -> RockBody:
	if not is_instance_valid(_network):
		return null
	return _network.rock_body(plane_index, rock_index)


## Is there open ground between this mouse and the face they are swinging at?
##
## ASKED AS "IS ANY OF THIS EARTH", NOT AS "COULD A MOUSE WALK IT". `walkable_between` was the first
## answer and it is the wrong question by exactly the margin that matters: it asks whether a BODY
## fits, so it fails within a body's radius of any wall -- and a Brute working a rock face is
## standing with its nose against one. Every swing was refused, everywhere, which reads as the rock
## being unbreakable rather than as a reach rule.
##
## So the walk is sampled against the field itself. Earth between the paws and the stone is what
## disqualifies a swing; corridor is fine, and so is more stone, because reaching the far lobe of a
## rock through the near one is still hitting the rock.
##
## THE ENDS ARE FORGIVEN, one texel each. The near end is the mouse's own position, which the
## physics is entitled to have pushed a centimetre into a wall on any given frame; the far end is
## the face itself, which is the boundary and reads as solid from whichever side the rounding
## lands. Neither is evidence of earth in between, and failing on either would make the rule
## flicker with the mouse's own footfall.
func _exposed_to(who: Mouse) -> bool:
	var rock := _rock()
	if rock == null:
		return false
	var paws := Vector2(who.global_position.x, who.global_position.z)
	var face := rock.surface_point(paws)
	var span := paws.distance_to(face)
	if span <= TunnelContour.TEXEL:
		return true
	var steps := maxi(2, ceili(span / TunnelContour.TEXEL))
	for i in range(1, steps):
		var at := paws.lerp(face, float(i) / float(steps))
		if _network.is_open_at(plane_index, at) or _network.is_stone_at(plane_index, at):
			continue
		return false
	return true
