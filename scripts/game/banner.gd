class_name Banner
extends Node3D
## A crew's banner: the thing you steal, carry, and lose (GDD section 2).
##
## Three states and nothing else. AT_NEST is where it starts and where it must be for your
## crew to score; CARRIED is riding above someone's head; DROPPED is lying where they fell,
## counting down to an automatic return.
##
## The RULES about who may pick it up and when it counts live in match_director.gd. This
## class owns the banner's own state, its return clock, and how it looks -- which is the
## division that keeps the director readable as a list of rules rather than a physics object.
##
## IT RIDES ABOVE THE CARRIER'S HEAD, and that is a deliberate design choice rather than a
## convenience. GDD section 2 says carriers are always visible to everyone, no hiding with the
## flag -- a banner on a pole a body-length above the grass line is that rule made visible in
## the world instead of on a minimap. The concealment system reads the same fact and switches
## itself off for a carrier (see grass_camouflage.gd).

signal taken(banner: Banner, by: Mouse)
signal dropped(banner: Banner, at: Vector3)
signal returned(banner: Banner)

enum { AT_NEST, CARRIED, DROPPED }

## How high above a carrier the banner floats. Above the grass (0.44 to 0.68 tall) on purpose.
const CARRY_LIFT: float = 0.62
const POLE_HEIGHT: float = 0.55

## Seconds a dropped banner waits before it goes home by itself (GDD section 2).
@export var return_seconds: float = 20.0
## How long the mouse it was just taken from has to wait before picking it up again.
##
## `[ADDED at M8]` THE SLAM FORCED THIS INTO THE OPEN, and it is a rule the game needed before
## the Brute existed. GDD section 4 says a Slam makes a carrier drop the flag; the shove that does
## it is worth two and a half metres, which is three times the director's `pickup_radius` and
## looked like plenty. It is not, because DISPLACEMENT TAKES TIME AND A PICKUP CHECK DOES NOT: the
## banner hits the ground with the carrier still standing exactly on it, `_check_pickup` runs that
## same tick, and they have it back before they have moved a millimetre. Measured, not reasoned --
## the audit watched the state go DROPPED and then CARRIED again one frame later.
##
## No amount of knockback fixes that; the fix has to be a moment rather than a distance. Three
## quarters of a second is enough for any shove worth the name to clear the circle (2.3m at this
## Slam's force) and short enough that a fumble is not a sentence.
##
## IT BINDS ONLY THE MOUSE IT FELL FROM. Anyone else -- their crew mate, the Brute that swung, a
## defender arriving late -- may take it the instant it lands, because a scramble over a loose
## banner is the good part and this rule exists to prevent a non-event, not a contest.
##
## AND IT APPLIES TO EVERY DROP, not merely to slams. A scruffed carrier respawns at their nest
## and could not have reached it anyway; what it does close is the other degenerate case already
## in the game -- a carrier bouncing on a shaft mouth, dropping the banner it may not take
## underground and taking it straight back, forever.
@export var recovery_seconds: float = 0.75
## Bob and spin at rest, so a banner sitting in long grass across the arena still catches the
## eye. Cheap, and it is the only thing that distinguishes the objective from scenery.
@export var idle_bob: float = 0.05
@export var idle_spin: float = 0.9

@export_group("Falling")
## Metres per second downward while it is loose. Matched to [FlyingWedge] rather than to
## [RockDebris], for the reason that file sets out: cheese and the banner are objectives coming
## loose and both crews are being asked to watch where they go, whereas debris is punctuation. At
## 9.0 a fumbled banner was on the floor in half a second and read as a teleport with a stutter.
@export var gravity: float = 6.0
## How much of its downward speed the banner keeps on hitting the lawn.
##
## LOW, AND LOWER THAN THE CHEESE'S, because this is a pole with a cloth on it and not a wedge. A
## banner that hopped like a ball would read as a pickup item in a different game; what it should
## do is come down, kick once, and flop. It is also what keeps a toss's range honest -- the aim
## point is where it first hits, so anything it gains after that is range the ability did not pay
## for.
@export_range(0.0, 1.0, 0.05) var bounce: float = 0.22
## What a bounce costs it sideways. This is the friction, and it is high for the same reason the
## bounce is low: a flag lands and stops.
@export_range(0.0, 1.0, 0.05) var skid: float = 0.45
## Below this speed, on the ground, it has come to rest.
@export var rest_speed: float = 0.5
## How much further than its ballistic range the bounce and skid carry it.
##
## MEASURED, NOT DERIVED, and it exists so that callers can go on thinking in the distance they
## actually mean. `drop(scatter)` is documented in metres and `MatchDirector.banner_scatter` is a
## design number about how far a fumbled banner ends up -- so the launch is solved backwards from
## a wanted RESTING distance, and this is the correction between where it first hits and where it
## stops. Change `bounce` or `skid` and this wants re-measuring; `match_audit`'s `BANNER_FLOP`
## budget is what will complain if it is not.
@export var flop_stretch: float = 1.15

var team: int = Team.BLUE
var state: int = AT_NEST
var carrier: Mouse = null

var _home: Vector3 = Vector3.ZERO
var _left_alone: float = 0.0
## Who it fell from, and how long ago. Cleared the moment anybody picks it up, so it can never
## outlive the drop it describes.
var _fumbled_by: Mouse = null
var _age: float = 0.0
## How it is moving while it is loose and still settling. Airborne is not a STATE -- see
## [method throw] for why the banner is already DROPPED while it is still in the air.
var _velocity: Vector3 = Vector3.ZERO
## Radians per second of tumble, decaying with every bounce. Not a physics quantity, a legibility
## one: a banner that translated without turning read as a sprite being slid across the lawn.
var _tumble: Vector3 = Vector3.ZERO
var _falling: bool = false
var _cloth: MeshInstance3D
## A banner this machine does not decide anything about (M7). Same three states, same bob and
## spin, same countdown on the HUD -- what stops is the countdown *expiring into an action*.
var _puppet: bool = false


## Built rather than authored, like the rest of the grey box. One less scene to keep in sync
## with the two colours it has to come in.
func setup(side: int, home: Vector3) -> void:
	team = side
	_home = home
	_build()
	send_home()


func set_home(home: Vector3) -> void:
	_home = home


func get_home() -> Vector3:
	return _home


func is_home() -> bool:
	return state == AT_NEST


## Seconds left before an unattended banner returns on its own, or 0 when the clock isn't
## running. The HUD shows it: a dropped banner is a decision for both crews, and neither can
## make it without knowing how long they have.
func return_countdown() -> float:
	if state != DROPPED:
		return 0.0
	return maxf(0.0, return_seconds - _left_alone)


## May this mouse pick it up right now?
##
## THE ONLY THING THIS ANSWERS IS THE FUMBLE. Range, plane, whether they already have one and
## whether it is even loose are the director's questions and stay there -- what the banner knows,
## and nothing else can, is who just dropped it and how long ago.
func may_take(who: Mouse) -> bool:
	# NOBODY CATCHES IT MID-AIR, and that is the one rule the fumble clock could not express. The
	# fumble binds one mouse; this binds everyone, for as long as the banner is off the ground.
	# Without it a Generalist could throw the banner four cells and run under it, which is a
	# self-pass -- the toss would become a way of moving the banner further than you can carry it
	# rather than a way of giving it to somebody else.
	if is_airborne():
		return false
	if who == null or _fumbled_by != who:
		return true
	return _left_alone >= recovery_seconds


## Loose and still moving: thrown, or knocked out of somebody and still bouncing.
##
## `[REVISED]` NOT MERELY "IN THE AIR" ANY MORE, and the widening is deliberate. It used to mean
## "inside the 0.45s of a toss"; it now means "has not come to rest", which also covers the tumble
## after a scruff and the skid after a throw lands. That makes the rule in [method may_take] the
## one it always should have been -- **you cannot grab a banner that is still bouncing** -- and
## costs a scrambling crew about half a second, during which the thing they are scrambling for is
## visibly not yet on the floor.
func is_airborne() -> bool:
	return _falling


func take(by: Mouse) -> void:
	carrier = by
	state = CARRIED
	_left_alone = 0.0
	_fumbled_by = null
	by.take_carry(self)
	taken.emit(self, by)


## Put down where it is -- scruffed, or carried somewhere the banner may not go.
##
## `scatter` throws it clear in a direction nobody chose. **Zero by default and supplied only by
## the scruff**, which is the distinction: a banner that could not go underground is being *set
## down* by a rule and should land where the rule caught you. A banner coming off a mouse somebody
## just put on its back is being *dropped*, and it should tumble.
##
## WHY THAT IS WORTH A RANDOM NUMBER. The banner used to land exactly on the fallen carrier's feet,
## which quietly made every scruff a stand-off on one square metre: the killer is standing on it,
## `recovery_seconds` does not bind them, and there is no ground to contest. A metre or two of
## tumble turns that into a scramble, gives an arriving team mate somewhere to reach for, and --
## the part that matters against a Brute -- means a carrier scruffed at a chokepoint does not hand
## the banner straight to whoever was holding it.
##
## `[REVISED]` IT IS THROWN NOW RATHER THAN TELEPORTED. `scatter` used to be a landing point picked
## with a random number and assigned on the spot; it is a *distance to throw it* now, and where it
## stops is whatever the bounce and the friction decide. The rest of the argument above is
## unchanged, because it was never about the arithmetic.
##
## SERVER-SIDE, AND THE CLIENTS GET IT FREE. A banner's position has always been three floats in
## every snapshot, so a puppet does not simulate any of this -- it is handed the tumble a frame at
## a time, which is why [method _process] leaves a puppet's height alone.
func drop(scatter: float = 0.0) -> void:
	var at := global_position
	if carrier != null:
		at = carrier.global_position
		# Remembered BEFORE the handle is cleared, which is the whole of `recovery_seconds`: the
		# banner lands on the carrier's own feet, so without this the next tick gives it back.
		_fumbled_by = carrier
		carrier.release_carry()
		carrier = null
	state = DROPPED
	_left_alone = 0.0
	global_position = Vector3(at.x, 0.0, at.z)
	if scatter > 0.0 and not _puppet:
		var heading := randf() * TAU
		# Square-rooted so the landing spots spread evenly over the disc rather than bunching at
		# its centre, which is what a raw `randf()` radius gives you. Divided by `flop_stretch`
		# because `scatter` is where it should END UP and the launch only decides where it first
		# comes down.
		_start_falling(_ballistic(heading, sqrt(randf()) * scatter / maxf(flop_stretch, 0.01)))
	dropped.emit(self, global_position)


## Throw the banner to a spot on the ground: the Generalist's second capability (GDD section 4).
##
## ALREADY DROPPED, AND AT THE FAR END, WHILE IT IS STILL IN THE AIR. That is the whole trick of
## this method and it is worth being explicit about, because the alternative looks more honest and
## is not. A fourth state -- FLYING -- would have to cross the wire, which means a new value in the
## snapshot, a new branch in [method adopt], and a client that is one build behind reading somebody
## else's state number. What travels instead is the truth the rules care about: the banner is loose,
## and it is *there*. The arc is presentation, and it reaches a client for free because the host
## sends the banner's position every tick anyway.
##
## NOBODY MAY TAKE IT UNTIL IT COMES TO REST -- see [method may_take]. That is what stops the
## destination being pickable before the thing visibly arrives there, which would be the one place
## this shortcut could have been felt.
##
## `[REVISED]` BALLISTIC RATHER THAN INTERPOLATED. This used to lerp along a hand-drawn parabola
## for a fixed 0.45s and then simply stop, which is the one moment of a throw everybody watches and
## it looked like the banner had been switched off. It is a launch velocity now, solved so the
## banner is back at ground level after `flight` seconds, and what happens when it gets there is
## whatever [method _fall] decides -- a low kick and a short skid.
##
## THE AIM POINT IS WHERE IT FIRST HITS, NOT WHERE IT STOPS, and that is a design decision rather
## than an approximation. `bounce` is deliberately low so the difference is a few tens of
## centimetres; making it zero would mean a banner that lands like a dropped brick, and solving the
## launch backwards from a wanted resting place would put the arithmetic back that the change was
## made to remove. Four cells is four cells, plus a flop.
func throw(to: Vector3, flight: float = 0.45) -> void:
	var from := carrier.global_position if carrier != null else global_position
	if carrier != null:
		_fumbled_by = carrier
		carrier.release_carry()
		carrier = null
	state = DROPPED
	_left_alone = 0.0
	global_position = Vector3(from.x, 0.0, from.z)
	if _puppet:
		# A puppet is told where the banner is thirty times a second and simulates none of it. It
		# still has to leave the carrier's hands, which the lines above have done.
		dropped.emit(self, Vector3(to.x, 0.0, to.z))
		return

	var span := maxf(flight, 0.05)
	var across := Vector3(to.x - from.x, 0.0, to.z - from.z) / span
	# The vertical that brings it back to the floor after exactly `span` seconds: rise and fall are
	# symmetric, so the launch speed is half of what gravity takes away over the whole flight.
	_start_falling(across + Vector3.UP * gravity * span * 0.5)
	dropped.emit(self, Vector3(to.x, 0.0, to.z))


## The launch velocity that lands `reach` metres away along `heading`.
##
## FIFTY DEGREES, and the same reasoning [FlyingWedge] gives: 45 maximises range and skims, which
## at mouse scale reads as the banner being kicked rather than thrown. Slightly steeper buys enough
## time in the air to see it turning over.
##
## Used by the fumble and not by the toss, because the two are asking different questions. A
## fumble knows how FAR it wants the banner to go and does not care how long it takes; a throw
## knows where it is going and wants to be there in a fixed moment, so it solves for a flight time
## instead. Sharing one solver between them would mean one of the two lying about its inputs.
func _ballistic(heading: float, reach: float) -> Vector3:
	# 58 degrees, steepened alongside `gravity` for the same reason [FlyingWedge] steepens: for a
	# wanted distance, angle and gravity are the two levers on flight time and neither of them
	# touches where it lands.
	var angle := deg_to_rad(58.0)
	var speed := sqrt(maxf(reach, 0.05) * gravity / maxf(sin(angle * 2.0), 0.01))
	return (
		Vector3(cos(heading), 0.0, sin(heading)) * speed * cos(angle)
		+ Vector3.UP * speed * sin(angle)
	)


## Arm the tumble. The one door into it, so a drop and a throw cannot drift into having different
## ideas about what "loose and still moving" means.
func _start_falling(velocity: Vector3) -> void:
	_velocity = velocity
	_falling = true
	# Turned mostly about the upright, with a wobble on the other two: a banner spins on its pole
	# far more readily than it cartwheels, and the first version tumbled it evenly on all three
	# axes, which read as a thrown stick.
	_tumble = Vector3(
		randf_range(-1.4, 1.4), randf_range(-5.0, 5.0), randf_range(-1.4, 1.4)
	)


## One tick of being loose. Gravity, a low kick off the lawn, and friction until it stops.
##
## HAND-INTEGRATED, NO RIGID BODY, exactly as [RockDebris] and [FlyingWedge] are, and here the case
## is stronger than for either of them: the banner is the object both crews are making decisions
## about, its position is in every snapshot, and handing that to a physics engine would mean the
## thing the match is *about* moves for reasons the rules cannot see. Four lines of integration
## are four lines everybody can read.
func _fall(delta: float) -> void:
	_velocity.y -= gravity * delta
	global_position += _velocity * delta
	rotation += _tumble * delta

	if global_position.y > 0.0:
		return

	global_position.y = 0.0
	_velocity.y = -_velocity.y * bounce
	_velocity.x *= skid
	_velocity.z *= skid
	_tumble *= skid
	# ON THE FLOOR AND SLOW ENOUGH. Asked only on contact, because a banner at the top of its arc is
	# momentarily this slow and would otherwise come to rest in mid-air.
	if _velocity.length() >= rest_speed:
		return
	_velocity = Vector3.ZERO
	_tumble = Vector3.ZERO
	_falling = false
	# Set flat rather than left wherever the tumble finished. A banner is read at a glance from
	# across a yard and it has one correct silhouette; letting it come to rest at whatever pitch it
	# happened to stop at made half of them look like litter.
	rotation = Vector3(0.0, rotation.y, 0.0)


func send_home() -> void:
	if carrier != null:
		carrier.release_carry()
		carrier = null
	_falling = false
	_velocity = Vector3.ZERO
	_tumble = Vector3.ZERO
	rotation = Vector3.ZERO
	state = AT_NEST
	_left_alone = 0.0
	_fumbled_by = null
	global_position = _home
	returned.emit(self)


## Whether this machine decides where this banner goes, or is told.
##
## A PUPPET STILL RUNS ITS CLOCK, and that is the distinction worth keeping straight. The HUD shows
## a dropped banner's countdown and both crews are making a decision from it, so it has to keep
## counting on every machine; what a puppet must not do is *act* when it reaches zero. The server
## will send it home and say so, and a client that sent it home too would be right by luck for as
## long as the two numbers happened to agree.
func set_puppet(on: bool) -> void:
	_puppet = on


## What the server says: the state, who is holding it, and where it is.
##
## Applied through the same three methods the rules use rather than by poking the fields, so a
## carried banner really does get attached to its carrier and `is_carrying()` is true on a puppet
## for the ordinary reason. That is what lets the grass camouflage and the roster keep working on a
## client without either of them hearing about the network.
func adopt(what: int, by: Mouse, at: Vector3) -> void:
	match what:
		CARRIED:
			if by != null and carrier != by:
				take(by)
		DROPPED:
			if state != DROPPED:
				drop()
			# THE HEIGHT IS KEPT, and it used to be flattened to zero. Nothing about a banner lying
			# in grass minded -- the bob was regenerated locally from `_age`, so the y the server
			# sent was the same bob a tick out of date. A thrown one minds a great deal: the arc IS
			# height, it is computed on the host, and the whole of what carries it to a client is
			# that a banner's position has always been three floats rather than two.
			global_position = at
		AT_NEST:
			if state != AT_NEST:
				send_home()


func _process(delta: float) -> void:
	_age += delta

	if state == CARRIED:
		if carrier == null or not is_instance_valid(carrier):
			# The carrier went away without telling anyone -- freed, or scruffed by something
			# that forgot to say so. Dropping is the safe failure: the banner stays playable.
			# Safe on a puppet too: a banner riding a mouse that no longer exists is worse than a
			# banner in the wrong place, and the next state message corrects it either way.
			drop()
		else:
			# Scaled by the carrier, so the pole clears a Brute's shoulders as well as a Sneak's.
			global_position = (
				carrier.global_position + Vector3.UP * CARRY_LIFT * carrier.height_ratio()
			)
			rotation.y = 0.0
			return

	if state == DROPPED:
		_left_alone += delta
		if _left_alone >= return_seconds and not _puppet:
			send_home()
		# STILL MOVING, so nothing below this runs -- not the idle spin, not the bob, and not the
		# resting height, all three of which would fight the tumble for the same three floats.
		# A puppet never gets here: `drop` and `throw` do not arm the fall on one, because its
		# banner's whole trajectory arrives in the snapshots a frame at a time.
		if _falling:
			_fall(delta)
			return

	# At rest, and only at rest. A carried banner spinning on someone's back reads as a pickup
	# they haven't collected yet.
	rotation.y = _age * idle_spin
	# A PUPPET KEEPS THE HEIGHT IT WAS SENT. Now that `adopt` no longer flattens y, generating the
	# bob locally as well would apply it twice -- and would overwrite the arc of a toss thrown on
	# the host with a resting bob, which is exactly the frame anyone is looking at.
	if _puppet:
		return
	position.y = maxf(_home.y, 0.0) + absf(sin(_age * 2.0)) * idle_bob


func _build() -> void:
	var colour := Team.color_of(team)

	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.018
	pole_mesh.bottom_radius = 0.022
	pole_mesh.height = POLE_HEIGHT
	pole_mesh.radial_segments = 6
	var pole_material := StandardMaterial3D.new()
	pole_material.albedo_color = Color(0.32, 0.25, 0.17)
	pole_material.roughness = 1.0
	pole_mesh.material = pole_material

	var pole := MeshInstance3D.new()
	pole.name = "Pole"
	pole.mesh = pole_mesh
	pole.position.y = POLE_HEIGHT * 0.5
	add_child(pole)

	var cloth_mesh := BoxMesh.new()
	cloth_mesh.size = Vector3(0.30, 0.20, 0.012)
	var cloth_material := StandardMaterial3D.new()
	cloth_material.albedo_color = colour
	# Faintly emissive, because a banner has to be findable in a dark corner of the yard and
	# under the lamps of a tunnel mouth. It is the one object in the match everyone is looking
	# for at once.
	cloth_material.emission_enabled = true
	cloth_material.emission = colour
	cloth_material.emission_energy_multiplier = 0.55
	cloth_material.roughness = 0.9
	cloth_mesh.material = cloth_material

	_cloth = MeshInstance3D.new()
	_cloth.name = "Cloth"
	_cloth.mesh = cloth_mesh
	_cloth.position = Vector3(0.16, POLE_HEIGHT - 0.12, 0.0)
	add_child(_cloth)
