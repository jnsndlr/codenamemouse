class_name Slam
extends MouseControl
## The Brute's second capability: put everyone around you on the back foot, and make a carrier
## drop what they are holding (GDD section 4).
##
## THE ONE ABILITY IN THE GAME THAT DOES NO DAMAGE, and that is the design rather than a gap.
## Section 6 says displacement matters more than damage, and every other thing in the project
## agrees with that sentence while still taking health off somebody -- a swing knocks you back on
## its way to the four-hit scruff, a collapse buries you outright. This moves you and stops there.
## What it costs the person on the receiving end is *tempo*: two and a half metres in the wrong
## direction, a fifth of a second of no control, and the banner on the floor behind them.
##
## WHY THE BRUTE NEEDED IT. The class is "not through here" and it had exactly one way to say so:
## bring the roof down, on a ten-second cooldown, on a plane you might not be standing on. Against
## a Generalist already past it and running, a Brute could do nothing at all -- it cannot chase
## (slowest in the game), cannot flank (turn rate), and the swing that would catch a runner is a
## 110-degree cone on something faster than you. Slam is the answer to a mouse that is ALREADY
## THROUGH, which is the only moment a wall is any use.
##
## A CIRCLE, NOT A CONE, and it is the only attack in the game that is. The swing is aimed because
## a swipe has a direction; a mouse throwing its whole weight into the floor does not, and more to
## the point, the situation this exists for is *somebody got past you*, which by definition is
## behind. An aimed version would be a worse swing on a longer cooldown.
##
## SAME PLANE ONLY, like the swing and the spotting sweep -- see `Mouse._resolve_swing`, which
## makes the same check for the same reason. Without it a Brute on the lawn shoves a mouse in a
## corridor beneath its feet, through 0.65m of earth, which is the one thing the tunnel layer
## exists to prevent.
##
## THE PRESENTATION IS THE STOMP'S, deliberately: the same dust, the same shape of camera thump,
## the same falloff. They are the same mouse doing the same thing to the same ground, and two
## different dusts for one gesture would read as two different mechanics. What differs is scale --
## the ring is drawn at the slam's own reach, so the effect teaches the range.

## Landed, and how many it caught. Zero is a perfectly ordinary answer: the ability fires into
## empty air whenever it is used as a threat rather than as a hit.
signal slammed(hit: int)
## A carrier was put down. Separate from `slammed` because it is the half GDD section 4 names,
## and because a HUD may well want to shout about this one and not the other.
signal dropped_carrier(who: Mouse)
signal refused(reason: String)

@export_group("Ability")
## Which class may do this. An export for the same reason [CaveIn] has one: "who owns this
## capability" is a design question, and in this project that answer has form for moving.
@export_enum("Generalist", "Engineer", "Sneak", "Brute") var owner_class: int = MouseClass.BRUTE
## Seconds between slams. Shorter than either form of the cave-in, because this one takes nothing
## off the map -- what it spends is a moment, and the counterplay to it is the eight seconds you
## are without it afterwards.
@export var cooldown: float = 8.0
## How far the shove reaches, in metres. Comfortably past the 0.95 of a swing, because it has to
## catch somebody who has just run past you rather than somebody you are facing -- and comfortably
## short of anything you could call zoning: a mouse is 0.32 across and the arena is 68 wide.
@export var radius: float = 1.6

@export_group("Force")
## The impulse handed to [method Mouse.shove]. Distance is roughly this over `knock_damping`, so
## 15 against the default 6 is about **2.5 metres**.
##
## THAT NUMBER IS THE ABILITY, and it is set against one other: the director's `pickup_radius` is
## 0.85m and there is no grace period on a dropped banner -- whoever is nearest simply takes it.
## A swing's 4.5 moves you 0.75m, which is INSIDE that circle, so a Slam tuned like a punch would
## drop the banner and hand it straight back on the next tick. Three times the pickup radius is
## what makes the drop mean something: enough for the Brute or a crew mate to get to it first, not
## so much that a runner is thrown off the map.
@export var knockback: float = 15.0

@export_group("Feel")
## Camera trauma at the Brute's own feet, 0..1. Half the stomp's, and the gap is honest -- a stomp
## is a hole opening under the world, this is a mouse hitting the floor hard.
@export_range(0.0, 1.0, 0.05) var shake: float = 0.45
## How far away the thump is still felt, in metres. Shorter than the stomp's 14, for the same
## reason the trauma is lower: it is a body, not the earth.
@export var shake_range: float = 8.0

var _cooldown_left: float = 0.0


func _ready() -> void:
	super()
	if _player == null:
		push_warning("slam: needs a mouse -- the ability is off")
		set_process(false)
		set_physics_process(false)
		return
	refused.connect(explain)


func _process(delta: float) -> void:
	_cooldown_left = maxf(0.0, _cooldown_left - delta)


## 0 when ready, counting down otherwise. For a HUD that wants to draw the wait.
func cooldown_left() -> float:
	return _cooldown_left


func is_ready() -> bool:
	return _cooldown_left <= 0.0 and _player != null and _player.mouse_class == owner_class


## Everyone this slam would catch, without slamming them.
##
## PURE AND PUBLIC, exactly like [method CaveIn.stomp_cells] and for exactly that reason: the
## audits need to know what a slam WOULD reach without a mouse having to stand there and press V,
## and a bot weighing the ability one day will want the same question answered the same way.
##
## The allowance is the other mouse's OWN radius -- the same one the swing makes, so a slam that
## visibly touches somebody counts rather than measuring centre to centre and missing by a whisker
## of capsule. Asked of them rather than assumed, because a Brute is twice the width of a Sneak.
func targets() -> Array[Mouse]:
	var found: Array[Mouse] = []
	if _player == null:
		return found
	for node in _player.get_tree().get_nodes_in_group(Mouse.MOUSE_GROUP):
		var other := node as Mouse
		if other == null or other == _player or other.team == _player.team:
			continue
		if other.is_scruffed() or other.get_plane() != _player.get_plane():
			continue
		var to_them := other.global_position - _player.global_position
		to_them.y = 0.0
		if to_them.length() > radius + other.body_radius:
			continue
		found.append(other)
	return found


## READ ON THE PHYSICS TICK, NOT FROM AN INPUT EVENT -- see the long note in [CaveIn], which this
## follows exactly. The short of it: a server has no event stream for a peer three hundred miles
## away, and an idle frame can run twice per physics tick, which fires an ability twice from one
## keypress at 120Hz and once at 60.
func _physics_process(_delta: float) -> void:
	if _player == null:
		return
	if not _player.input().is_pressed(InputFrame.Action.SLAM):
		return
	if _player.is_scruffed():
		return
	# V is the Brute's, and a mouse that is not one leaves the bit alone -- the same class gate Q's
	# two owners use, and the reason neither of them has to consume the press.
	if _player.mouse_class != owner_class:
		return
	_slam()


func _slam() -> void:
	if _cooldown_left > 0.0:
		refused.emit("still finding your feet -- %ds" % ceili(_cooldown_left))
		return

	# THE DUST AND THE THUMP GO OFF ABOVE THE PUPPET CHECK, the same placement [CaveIn._stomp]
	# argues for at length. Here it buys something slightly different: a slam that caught nobody
	# has no result to look at, and a client's slam has no result to look at *yet*. Firing the
	# presentation before either question is asked means the key never reads as broken, and there
	# is no branch a hit could take that a miss could not.
	_kick_up_dust()

	if not acts():
		_cooldown_left = cooldown
		return

	var caught := targets()
	for other: Mouse in caught:
		other.shove(_player.global_position, knockback)
		# THE HALF THE GDD NAMES. A banner is dropped where its carrier was standing, and the
		# shove has already been applied -- but `_knock` is integrated over the following frames
		# rather than teleporting them, so the banner lands under their feet and they are carried
		# away from it, which is the picture the ability is meant to produce.
		var banner := other.get_carried() as Banner
		if banner != null:
			banner.drop()
			dropped_carrier.emit(other)

	_cooldown_left = cooldown
	slammed.emit(caught.size())


## The floor answering a Brute's whole weight: the stomp's dust, drawn at this ability's reach.
##
## SHARED WITH THE STOMP RATHER THAN COPIED. [StompDust] already is "a Brute hits the ground" and
## it is parameterised by nothing except where -- so a second dust class would be the same physics
## with a different set of tuning mistakes in it. The `spread` argument is the whole difference:
## the ring is drawn at the slam's own radius, so what you see is what it reached.
##
## SPAWNED IN THE WORLD, WATCHED OR NOT, and the SHAKE is viewer-local -- the same split [CaveIn]
## makes, for the same reasons. One camera on this machine, one dust cloud in everybody's yard.
##
## GATED ON THE PLANE, which the stomp's is not, and the difference is the mechanic. A stomp is
## the earth moving and is *supposed* to be felt through a floor; this is a body hitting one. A
## viewer on another plane cannot see the dust anyway (`depth_focus.gd` hides what is not their
## layer), so a shake without it would be a thump from nowhere -- and, worse, a free tell that
## somebody is directly above or below you.
func _kick_up_dust() -> void:
	var at := _player.global_position
	var parent: Node = _network if _network != null else _player.get_parent()
	if parent != null:
		# Seeded from the position so both ends of a wire draw the same cloud, like the stomp.
		# Rounded to the centimetre first: a raw float seed differs in its last bit between two
		# machines that agree about everything a player could see.
		var seed_value := int(at.x * 100.0) * 73856093 ^ int(at.z * 100.0)
		StompDust.burst(parent, at + Vector3.UP * 0.02, seed_value, radius)

	var rig := get_tree().get_first_node_in_group(CameraRig.RIG_GROUP) as CameraRig
	var watcher := director().local_mouse() if director() != null else _player
	if rig == null or watcher == null or watcher.get_plane() != _player.get_plane():
		return
	# Squared falloff, so the strong half of the curve is close in -- a linear one has the whole
	# yard feeling a faint tremor, which is noise at best and a position tell at worst.
	var distance := watcher.global_position.distance_to(at)
	var nearness := 1.0 - clampf(distance / maxf(shake_range, 0.01), 0.0, 1.0)
	rig.shake(shake * nearness * nearness)
