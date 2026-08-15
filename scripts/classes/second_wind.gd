class_name SecondWind
extends MouseControl
## The Generalist's class ability: get up off the floor without leaving the fight (GDD section 4).
##
## Q has one meaning per class. For a Brute it is [CaveIn], for a Sneak it is [Sonar], and for the
## Generalist it is this: a lungful of air that puts health back on while somebody is still chasing
## you, and hands you a fresh sprint to spend it on.
##
## WHY A HEAL HAD TO MEAN SOMETHING MORE THAN HEALTH. Every mouse already regenerates -- 18 a second
## after five seconds of quiet (`Mouse._tick_timers`) -- so an ability that simply adds health is an
## ability that gives you, early, a thing you were going to get anyway. What no mouse in this game
## can do is heal WHILE BEING HIT. `regen_delay` is reset by every point of damage, which means the
## passive is only ever collected by a mouse that has already broken off. This one does not look at
## `_since_damage` at all and is not interrupted by taking a blow, and that single difference is the
## whole ability: it is the only health in the game you can collect during a chase.
##
## WHICH IS WHY IT BELONGS TO THE RUNNER. The Generalist's job is to be carrying the banner while
## the other crew is trying to take it off them (GDD section 4) -- a job made entirely of *being
## caught up with and not stopping*. A burst heal for a duel would have been the Brute's ability
## written on the wrong class; this is the ability of somebody who is losing a race and refuses to
## be finished.
##
## IT REFILLS THE SPRINT TANK TOO, and that is the name rather than a bonus. GDD section 2 already
## defines the phrase in this game: Scurry "refills sprint stamina on use, which is what makes it
## feel like a second wind rather than a stat buff". The ability that took the name has to do the
## thing the name means. It does not overlap Scurry -- Scurry is speed, costs the crew a respawn,
## and belongs to everybody; this is endurance, costs nothing, and belongs to one class -- but the
## two share the sentence they came out of.
##
## HEALED OVER TWO SECONDS RATHER THAN AT THE KEYPRESS, and the delay is counterplay rather than
## polish. An instant 45 is a number that happens between two frames: the mouse chasing you sees a
## health bar jump and has no move to make about it. Spread over two seconds it is a window -- press
## harder and you can still out-damage it, back off and you have lost the mouse. It also means the
## ring below is describing something that is still happening, instead of decorating something that
## already finished.
##
## AND NOTHING CANCELS IT EXCEPT GOING DOWN. An interrupt-on-damage rule is the obvious next line
## and it is the one that would delete the ability: it would restrict the heal to moments when
## nobody is hitting you, which is exactly the moment the free passive already covers. Being
## scruffed ends it, because there is nothing left to heal.

## Fired, and how much health it will hand back over the seconds that follow. Zero is possible --
## a Generalist at full health may still want the legs.
signal caught_breath(healing: float)
## The last of it went in. For a HUD or an animation that wants the end rather than the start.
signal wind_ran_out()
signal refused(reason: String)

@export_group("Ability")
## Which class may do this. An export like [Slam]'s and [CaveIn]'s, for the same reason: "who owns
## this capability" is a design question, and in this project that answer has form for moving.
@export_enum("Generalist", "Engineer", "Sneak", "Brute") var owner_class: int = MouseClass.GENERALIST
## Seconds between winds. THE LONGEST COOLDOWN IN THE GAME, and deliberately in a different league
## from the other three (sonar 6, slam 8, cave-in 10). Those are things you do repeatedly while
## playing your class; this is the once-per-run answer to a single moment that was going badly. At
## anything under about half a minute it stops being that moment and becomes a health total.
@export var cooldown: float = 40.0

@export_group("Wind")
## Total health handed back, out of a hundred. Not quite half a bar, which is set against the swing:
## `attack_damage` is 26 and four connected swings scruff you, so this is a shade under two swings'
## worth -- enough that a mouse who has been caught once can still finish the run, and not enough to
## win a stand-up fight that was already lost.
@export var heal_amount: float = 45.0
## How long it takes to arrive. See the note above: this is the window the other mouse gets to do
## something about it, and it is the reason the ability has a shape rather than a value.
@export var heal_seconds: float = 2.0

@export_group("Feel")
## The rings that run up the mouse while the wind is in it. Two, staggered, so it reads as breathing
## rather than as a single hoop passing by.
@export var ring_count: int = 2
## How far up the body they travel, as a multiple of the mouse's drawn radius.
##
## AND THE CAMERA TURNS MOST OF THAT INTO SIZE RATHER THAN HEIGHT, which `tools/wind_shot.gd` is how
## we know. This game is watched from almost overhead, so vertical travel is squashed into very
## little screen distance and what actually reads is the widening -- the effect is a ring pulsing
## around the mouse, not a hoop climbing it. The lift still earns its place: without it the rings sit
## on the floor, where they look like something drawn on the ground rather than something happening
## to a mouse, and they would be hidden by the body from every angle except directly above.
@export var ring_lift: float = 3.4
## The same pale gold as the stamina bar over your own head (`vitals.gd`), and that is a deliberate
## rhyme rather than a coincidence of taste: this ability refills that bar, and the two should look
## like one another. Green -- the reflex colour for a heal -- is the one hue that cannot be used
## here, because the arena is a lawn.
@export var ring_color: Color = Color(0.93, 0.87, 0.52, 0.75)

var _wind_left: float = 0.0
## Health per second while the wind lasts. Kept rather than recomputed so a tuning change mid-wind
## cannot make the second half of a heal a different size from the first.
var _heal_rate: float = 0.0
var _rings: Array[MeshInstance3D] = []
var _ring_material: StandardMaterial3D


func _ready() -> void:
	super()
	if _player == null:
		push_warning("second wind: needs a mouse -- the ability is off")
		set_process(false)
		set_physics_process(false)
		return
	refused.connect(explain)


## The cooldown is a wall clock and the rings are a picture, so both live on the frame. The HEALING
## does not -- it is a rule, and rules run on the physics tick with everything else.
func _process(delta: float) -> void:
	# `super` FIRST: the cooldown lives in [MouseControl] now, and GDScript overrides rather than
	# chains -- an override that forgets this line is an ability that never comes back.
	super(delta)
	_animate_rings()


## Seconds of healing still to come, or 0. Public for the same reason: the wind is a state a player
## is in, and it is the half of this ability worth showing.
func wind_left() -> float:
	return _wind_left


func is_ready() -> bool:
	return _cooldown_left <= 0.0 and _player != null and _player.mouse_class == owner_class


## READ ON THE PHYSICS TICK, NOT FROM AN INPUT EVENT -- see the long note in [Sonar], which this
## follows exactly. The short of it: a server has no event stream for a peer three hundred miles
## away, and an idle frame can run twice per physics tick, which fires an ability twice from one
## keypress at 120Hz and once at 60.
func _physics_process(delta: float) -> void:
	if _player == null:
		return
	_tick_wind(delta)
	if not _player.input().is_pressed(InputFrame.Action.ABILITY):
		return
	if _player.is_scruffed():
		return
	# Q belongs to three classes and means something different to each. A mouse that is not this one
	# leaves the bit alone -- the same class gate the other two owners use, and the reason none of
	# them has to consume the press.
	if _player.mouse_class != owner_class:
		return
	take_breath()


## Fire it now. Public so the audit can exercise the rule without faking input routing, exactly as
## [method Sonar.scan] is. Returns whether the wind started.
func take_breath() -> bool:
	if _player == null or _player.mouse_class != owner_class or _player.is_scruffed():
		return false
	if _cooldown_left > 0.0:
		refused.emit("still catching your breath -- %ds" % ceili(_cooldown_left))
		return false

	# REFUSED WHEN IT WOULD DO NOTHING AT ALL, which is a narrower rule than "refused at full
	# health" and the narrowness is the point. A whole Generalist with an empty tank has a perfectly
	# good reason to press this -- the legs are half the ability. What is worth protecting the player
	# from is spending the longest cooldown in the game on a keypress with no effect whatsoever.
	var missing := _player.max_health * (1.0 - _player.get_health_ratio())
	var winded := _player.get_stamina_ratio() < 0.999
	if missing <= 0.01 and not winded:
		refused.emit("you have breath to spare")
		return false

	# THE CLOCK IS SET BEFORE THE RINGS ARE RAISED, and that is a rule rather than tidiness. Every
	# ring reads its position off `_wind_left` -- so raised against a wind that has not started yet,
	# they are placed by the same function that decides a finished wind has no rings and are freed on
	# the line after they are made. Which is exactly what the first build of this did: an ability
	# that healed correctly, in complete silence.
	_wind_left = maxf(heal_seconds, 0.01)
	_heal_rate = heal_amount / _wind_left
	_cooldown_left = cooldown
	# AND THEY GO UP BEFORE THE PUPPET CHECK, the same placement [Slam] and [Sonar] both argue for.
	# A client's own mouse is a puppet and its healing resolves on the host, so an effect gated on
	# `acts()` would leave the person who pressed the key with nothing on screen until a pose came
	# back over the wire -- which is the exact shape of "the key is broken".
	_raise_rings()

	if not acts():
		return true

	# THE LEGS ARRIVE AT ONCE AND THE HEALTH DOES NOT, and the split is the design. Stamina is what
	# you are about to spend -- a tank that filled over two seconds would be a tank you could not
	# start running on, which is the one thing this ability exists to let you do. Health is what the
	# mouse behind you is trying to take off faster than you gain it.
	_player.refill_stamina()
	caught_breath.emit(heal_amount)
	return true


## Hand over this tick's share of the wind.
##
## RUN ON EVERY MACHINE AND APPLIED ON ONE. The clock ticks everywhere, because a puppet with rings
## up its sides has to put them down again at the right moment and because `wind_left` is read by
## presentation on both ends -- the same bargain [MouseControl] describes for cooldowns. The health
## is only ever written where the simulation is; [method Mouse.heal] refuses on a puppet as well, so
## the rule is stated twice on purpose.
func _tick_wind(delta: float) -> void:
	if _wind_left <= 0.0:
		return
	# Going down ends it. There is no half-healed state to preserve -- a scruffed mouse is put back
	# together whole by the director, and a wind that survived would spend its last second topping
	# up a mouse that had just been refilled anyway.
	if _player.is_scruffed():
		_wind_left = 0.0
		_drop_rings()
		wind_ran_out.emit()
		return
	var slice := minf(delta, _wind_left)
	_wind_left -= slice
	if acts():
		_player.heal(_heal_rate * slice)
	if _wind_left <= 0.0:
		_drop_rings()
		wind_ran_out.emit()


# ------------------------------------------------------------------------------ the rings


## Rings around the mouse for as long as the wind lasts, and no longer.
##
## DRAWN FOR EVERYBODY, and that is a rule rather than a default. Every other piece of ability
## presentation in this project is either private to one viewer ([Sonar]'s echo, which is
## information) or a thing that happened to the world ([StompDust], which is the ground). This is a
## TELL: a mouse you are chasing has just started to get better, and if the only person who can see
## that is the mouse doing it, the other crew's whole read of the fight -- how many more swings, is
## it worth staying -- is quietly wrong. So the rings are children of the mouse and visible to
## anyone looking at it, on any machine that ran the ability.
##
## CHILDREN OF THE BODY RATHER THAN OF `_visual`, which is laid on its side when a mouse is scruffed
## and turned every frame by the facing. A ring has no facing, and a ring that rolled over with the
## corpse would be the last thing anybody saw of an ability that had already ended.
func _raise_rings() -> void:
	_drop_rings()
	if _player == null:
		return
	_ring_material = StandardMaterial3D.new()
	_ring_material.albedo_color = ring_color
	_ring_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Shadows off, depth test left ALONE. Unshaded geometry casting a shadow is a shadow with no
	# light behind it, and a ring drawn through the earth would be a free tell that a Generalist is
	# on the layer under your feet -- which is the one thing the tunnel layer exists to prevent.
	var mesh := _ring_mesh()
	for index in range(maxi(ring_count, 1)):
		var ring := MeshInstance3D.new()
		ring.name = "SecondWindRing%d" % index
		ring.mesh = mesh
		ring.material_override = _ring_material
		ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_player.add_child(ring)
		_rings.append(ring)
	_animate_rings()


func _drop_rings() -> void:
	for ring: MeshInstance3D in _rings:
		if is_instance_valid(ring):
			ring.queue_free()
	_rings.clear()


## Walk each ring up the body on its own offset phase, growing and thinning as it goes.
##
## THE PHASE IS DERIVED FROM `_wind_left` RATHER THAN ACCUMULATED, so a ring cannot drift out of step
## with the heal it is describing -- and so a puppet whose wind was started by a packet lands its
## rings in the same place as the host's.
func _animate_rings() -> void:
	if _rings.is_empty():
		return
	if _wind_left <= 0.0 or _player == null:
		_drop_rings()
		return
	var through := 1.0 - _wind_left / maxf(heal_seconds, 0.01)
	var wide := _player.model_radius
	for index in range(_rings.size()):
		var ring: MeshInstance3D = _rings[index]
		if not is_instance_valid(ring):
			continue
		# Each ring is a full trip up the body, staggered so one is always low. Two trips over the
		# whole wind, which at two seconds is a breath in and a breath out.
		var phase := fmod(through * 2.0 + float(index) / float(_rings.size()), 1.0)
		ring.position = Vector3(0.0, wide * ring_lift * phase, 0.0)
		# Opening out as it rises: a column would read as a beam, and a mouse is not a lighthouse.
		var spread := wide * (1.3 + 1.1 * phase)
		ring.scale = Vector3(spread, 1.0, spread)
		# Faded at both ends of the trip, so a ring is never seen appearing at the floor or being
		# cut off at the top -- and faded out over the last of the wind, so the ability stops on
		# screen at the moment it stops in the rules.
		var edges := sin(phase * PI)
		var ending := clampf(_wind_left / 0.35, 0.0, 1.0)
		var alpha := ring_color.a * edges * ending / float(_rings.size())
		# One material for every ring, so the alpha is written by the LAST one and read by all of
		# them -- which would flicker. Set per instance instead.
		ring.transparency = 1.0 - clampf(alpha / maxf(ring_color.a, 0.01), 0.0, 1.0)


## A flat annulus, lying face up, one metre across at scale 1. Built per activation rather than
## kept: this fires once every forty seconds, and a mesh held for the whole match to save a
## SurfaceTool is the wrong side of that trade.
##
## TRIANGLES RATHER THAN A LINE LOOP, and [Sonar] has the receipts: `PRIMITIVE_LINES` draws a
## hairline one pixel wide at any zoom, and a pixel of pale gold over a mouse the same size as it is
## invisible in a screenshot and worse in motion.
func _ring_mesh() -> ArrayMesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segments := 28
	var inner := 0.80
	for index in range(segments):
		var a := TAU * float(index) / float(segments)
		var b := TAU * float(index + 1) / float(segments)
		var outer_a := Vector3(cos(a), 0.0, sin(a))
		var outer_b := Vector3(cos(b), 0.0, sin(b))
		var inner_a := outer_a * inner
		var inner_b := outer_b * inner
		for corner: Vector3 in [inner_a, outer_a, outer_b, inner_a, outer_b, inner_b]:
			tool.set_normal(Vector3.UP)
			tool.add_vertex(corner)
	return tool.commit()
