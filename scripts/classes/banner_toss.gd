class_name BannerToss
extends MouseControl
## The Generalist's second capability: throw the banner four cells toward the cursor (GDD
## section 4).
##
## THE CORK HAD NO ANSWER, and that is what this is for. GDD section 5's web ends *"Brute corks the
## tunnel -- Generalist takes the surface route with the flag"*, and on the lawn the same body does
## the same job: a Brute standing in a gateway is 0.30 of radius against a runner who cannot fight
## it, cannot get round it, and is carrying the one object in the game that makes it worth
## standing there. Every other class answers a Brute by removing it or going through it. The runner
## answers it by not needing to be the one who gets past.
##
## WHICH MAKES IT A PASS, NOT A LEAP, and every number here exists to keep it one. It cannot be
## caught in the air, and the thrower is bound by the banner's own fumble clock when it lands
## ([method Banner.may_take]) -- so throwing it forward and running under it gets you a banner you
## may not touch for three quarters of a second, in the open, having just announced where it is.
## Thrown to a team mate it is instant and free. **The ability is worth having exactly to the
## extent that somebody else is there**, which is the first thing in this game that is true.
##
## FOUR CELLS, AND THE RANGE IS THE BALANCE. A corridor mouth, a gateway, a Brute -- four metres
## clears the thing in your way and does not clear the mouse behind it. Ten seconds of recharge is
## the other half: long enough that a Generalist cannot bunny-hop the banner across the yard one
## throw at a time, short enough to be available for the one gate that matters on a run.
##
## AIMED WITH THE CURSOR, WHICH IS THE STEERING WHEEL (GDD section 9), so a throw is a moment of
## looking at where the banner is going rather than at where you are running -- the same trade the
## GDD asks for around throwing while fleeing, and the same one [CaveIn] is aimed for.
##
## SHORT OF THE CURSOR IS ALLOWED, PAST IT IS NOT. Aim inside the range and the banner lands under
## the cursor; aim beyond it and it goes as far as it goes in that direction. A throw that refused
## for being aimed too far would be a throw that fails at exactly the moment you are panicking.

signal tossed(banner: Banner, to: Vector3)
signal refused(reason: String)

@export_group("Ability")
@export_enum("Generalist", "Engineer", "Sneak", "Brute") var owner_class: int = MouseClass.GENERALIST
## How far it goes, in cells -- and a cell is a metre (`TunnelChunks.CELL`).
@export var range_cells: float = 4.0
@export var cooldown: float = 10.0
## Seconds in the air. Short: this is a shove of a pole, not a punt.
@export var flight_seconds: float = 0.45

var _cooldown_left: float = 0.0


func _ready() -> void:
	super()
	if _player == null:
		push_warning("banner toss: needs a mouse -- the ability is off")
		set_process(false)
		set_physics_process(false)
		return
	refused.connect(explain)


func _process(delta: float) -> void:
	_cooldown_left = maxf(0.0, _cooldown_left - delta)


func cooldown_left() -> float:
	return _cooldown_left


func is_ready() -> bool:
	return (
		_cooldown_left <= 0.0 and _player != null and not _player.is_scruffed()
		and _player.mouse_class == owner_class and _player.is_carrying()
	)


## Where a throw from here would put it. Flat, and clamped to the range.
##
## PURE, so an audit can ask what a toss WOULD do without a banner having to be in the world -- the
## same reason [method CaveIn.stomp_cells] is pure.
func landing() -> Vector3:
	if _player == null:
		return Vector3.ZERO
	var from := _player.global_position
	var aim := _player.get_aim_point()
	var out := Vector3(aim.x - from.x, 0.0, aim.z - from.z)
	var reach := range_cells * TunnelNetwork.CELL
	if out.length() > reach:
		out = out.normalized() * reach
	elif out.length() < 0.01:
		# A cursor sitting on your own feet is not a direction. Throw it the way you are facing,
		# so the ability never silently drops the banner where it already was.
		out = _player.get_facing_direction() * reach
	return Vector3(from.x + out.x, 0.0, from.z + out.z)


## READ ON THE PHYSICS TICK off the [InputFrame], like every other control -- see [Barricade] for
## why an `_unhandled_input` handler cannot survive a server.
func _physics_process(_delta: float) -> void:
	if _player == null:
		return
	if not _player.input().is_pressed(InputFrame.Action.TOSS):
		return
	if _player.is_scruffed():
		return
	# SILENT ON THE WRONG CLASS, exactly as [Slam] is, and here it is load-bearing rather than
	# tidy: V is one key with two meanings and both nodes are fitted to every mouse, so a Brute
	# pressing it puts this bit down too. A refusal here would tell a Brute what a Generalist can
	# do, every time it shoved somebody.
	if _player.mouse_class != owner_class:
		return

	if not _player.is_carrying():
		refused.emit("nothing in your paws to throw")
		return
	if _cooldown_left > 0.0:
		refused.emit("still getting your grip -- %ds" % ceili(_cooldown_left))
		return

	var banner := _player.get_carried() as Banner
	if banner == null:
		# Carrying something that is not a banner. Nothing does that today; the guard is here so
		# that the day something does, this ability declines rather than crashes on the cast.
		refused.emit("nothing in your paws to throw")
		return

	var to := landing()

	# A PUPPET RUNS ITS COOLDOWN AND THROWS NOTHING (M7). The banner is the server's -- it is the
	# object both crews are making decisions about -- and a client that threw it locally would have
	# it lying in a field the host has never heard of until the next snapshot yanked it back.
	if not acts():
		_cooldown_left = cooldown
		return

	banner.throw(to, flight_seconds)
	_cooldown_left = cooldown
	tossed.emit(banner, to)
	note("you heave the banner clear")
