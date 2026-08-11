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

var team: int = Team.BLUE
var state: int = AT_NEST
var carrier: Mouse = null

var _home: Vector3 = Vector3.ZERO
var _left_alone: float = 0.0
## Who it fell from, and how long ago. Cleared the moment anybody picks it up, so it can never
## outlive the drop it describes.
var _fumbled_by: Mouse = null
var _age: float = 0.0
## Seconds of arc still to run, and the two ends of it. Airborne is not a STATE -- see
## [method throw] for why the banner is already DROPPED at its destination while it is still in
## the air.
var _flight_left: float = 0.0
var _flight_time: float = 0.0
var _flight_from: Vector3 = Vector3.ZERO
var _flight_to: Vector3 = Vector3.ZERO
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


func is_airborne() -> bool:
	return _flight_left > 0.0


func take(by: Mouse) -> void:
	carrier = by
	state = CARRIED
	_left_alone = 0.0
	_fumbled_by = null
	by.take_carry(self)
	taken.emit(self, by)


## Put down where it is -- scruffed, or carried somewhere the banner may not go.
##
## `scatter` throws it a metre or two in a direction nobody chose. **Zero by default and supplied
## only by the scruff**, which is the distinction: a banner that could not go underground is being
## *set down* by a rule, and it should land where the rule caught you. A banner coming off a mouse
## somebody just put on its back is being *dropped*, and it should skitter.
##
## WHY THAT IS WORTH A RANDOM NUMBER. The banner used to land exactly on the fallen carrier's feet,
## which quietly made every scruff into a stand-off on one square metre: the killer is standing on
## it, `recovery_seconds` does not bind them, and there is no ground to contest. A metre of skid
## turns that into a scramble, gives an arriving team mate somewhere to reach for, and -- the part
## that matters against a Brute -- means a carrier scruffed at a chokepoint does not hand the
## banner to whoever is holding it.
##
## SERVER-SIDE ONLY IN PRACTICE, and it needs no seed. A client is a puppet whose banner position
## arrives in the next snapshot, so the two machines cannot disagree about where it went for longer
## than a tick.
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
	_flight_left = 0.0
	var here := Vector3(at.x, 0.0, at.z)
	if scatter > 0.0:
		var angle := randf() * TAU
		# Square-rooted so the landing spots are spread evenly over the disc rather than bunched at
		# its centre, which is what a raw `randf()` radius gives you.
		var reach := sqrt(randf()) * scatter
		here += Vector3(cos(angle), 0.0, sin(angle)) * reach
	global_position = here
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
## NOBODY MAY TAKE IT UNTIL IT LANDS -- see [method may_take]. That is what stops the destination
## being pickable before the thing visibly arrives there, which would be the one place this
## shortcut could have been felt.
func throw(to: Vector3, flight: float = 0.45) -> void:
	var from := carrier.global_position if carrier != null else global_position
	if carrier != null:
		_fumbled_by = carrier
		carrier.release_carry()
		carrier = null
	state = DROPPED
	_left_alone = 0.0
	_flight_from = Vector3(from.x, 0.0, from.z)
	_flight_to = Vector3(to.x, 0.0, to.z)
	_flight_time = maxf(flight, 0.01)
	_flight_left = _flight_time
	global_position = _flight_from
	dropped.emit(self, _flight_to)


func send_home() -> void:
	if carrier != null:
		carrier.release_carry()
		carrier = null
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
		# The arc, on every machine. A puppet runs it too: its banner is DROPPED at the far end
		# already, so without this it would appear at the destination while the thrower's own
		# screen still had it in the air, and the two would disagree about the only part of a toss
		# anybody actually watches.
		if _flight_left > 0.0:
			_flight_left = maxf(0.0, _flight_left - delta)
			var travelled := 1.0 - _flight_left / _flight_time
			global_position = _flight_from.lerp(_flight_to, travelled)
			# A parabola that is zero at both ends and peaks halfway. Height scales with the throw,
			# so a short toss is a flick and a full-range one is a proper heave.
			position.y = (
				_flight_from.distance_to(_flight_to) * 0.22
				* travelled * (1.0 - travelled) * 4.0
			)
			rotation.y = _age * idle_spin * 3.0
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
