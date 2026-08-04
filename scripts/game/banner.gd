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
## Bob and spin at rest, so a banner sitting in long grass across the arena still catches the
## eye. Cheap, and it is the only thing that distinguishes the objective from scenery.
@export var idle_bob: float = 0.05
@export var idle_spin: float = 0.9

var team: int = Team.BLUE
var state: int = AT_NEST
var carrier: Mouse = null

var _home: Vector3 = Vector3.ZERO
var _left_alone: float = 0.0
var _age: float = 0.0
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


func take(by: Mouse) -> void:
	carrier = by
	state = CARRIED
	_left_alone = 0.0
	by.take_carry(self)
	taken.emit(self, by)


## Put down where it is -- scruffed, or carried somewhere the banner may not go.
func drop() -> void:
	var at := global_position
	if carrier != null:
		at = carrier.global_position
		carrier.release_carry()
		carrier = null
	state = DROPPED
	_left_alone = 0.0
	global_position = Vector3(at.x, 0.0, at.z)
	dropped.emit(self, global_position)


func send_home() -> void:
	if carrier != null:
		carrier.release_carry()
		carrier = null
	state = AT_NEST
	_left_alone = 0.0
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
			global_position = Vector3(at.x, 0.0, at.z)
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
			global_position = carrier.global_position + Vector3.UP * CARRY_LIFT
			rotation.y = 0.0
			return

	if state == DROPPED:
		_left_alone += delta
		if _left_alone >= return_seconds and not _puppet:
			send_home()

	# At rest, and only at rest. A carried banner spinning on someone's back reads as a pickup
	# they haven't collected yet.
	rotation.y = _age * idle_spin
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
