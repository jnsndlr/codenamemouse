class_name Mouse
extends CharacterBody3D
## Everything a mouse is, regardless of who is driving it.
##
## WHY THIS EXISTS. Through M2 there was one mouse and it was the player, so `player.gd` owned
## locomotion, team colour and the model. M3 adds bots, and a bot needs every one of those and
## none of the input handling. Duplicating the movement into an AI script would mean the two
## kinds of mouse could drift apart -- and the whole grass tell (GDD section 8) rests on a bot
## bending grass exactly as hard as a player moving at the same speed. One body, two drivers.
##
## The split is a template method: this class runs the tick and calls `_control()`, which is
## the ONE thing subclasses implement. Player reads the keyboard there; Bot reads a navigation
## path. Neither can forget to call super, which an overridden `_physics_process` invites.
##
## What lives here and why:
##
##   Locomotion   Acceleration, friction, the capped turn rate that supplies the weight.
##   Health       Damage, regeneration out of combat, and SCRUFFED -- knocked flat, not
##                killed (intent doc: the tone is light and nobody dies).
##   Melee        A short cursor-aimed cone (GDD section 6). Deterministic: no crits, no
##                random damage, no rolls.
##   Displacement Knockback is a separate decaying velocity, not a nudge to the movement
##                one -- see `_knock`. Section 6 says displacement matters more than damage.
##   Carrying     The banner, and the speed penalty it costs you.
##   Collision    Own crew's layer, masking the other crew's, so enemies body-block and
##                allies pass through.

## Emitted when this mouse is knocked flat. `by` may be null -- a cave-in will scruff you at
## M8 and there is nobody to credit. The director listens; nothing here knows about respawns.
signal scruffed(mouse: Mouse, by: Mouse)
## For the HUD and, later, hit sounds. Carries the damage rather than the resulting health so
## a listener can react to the size of the blow.
signal wounded(mouse: Mouse, damage: float)
signal revived(mouse: Mouse)
## The swing itself, not the hits it lands -- a whiff still swings, and animation and audio
## want to know at the moment the paw moves.
signal swung(mouse: Mouse)

## Anything that bends grass (GDD section 8) and anything combat has to consider.
const ACTOR_GROUP: StringName = &"grass_actor"
const MOUSE_GROUP: StringName = &"mouse"

@export_group("Crew")
## Set before the mouse enters the tree where possible; `set_team` handles it afterwards.
@export_enum("Blue", "Red") var team: int = Team.BLUE

@export_group("Movement")
@export var speed: float = 3.0
## Applied on top of `speed`. Slow overrides Sprint while held -- you can't be quiet and
## fast, which is the whole point of the tier.
@export_range(0.1, 1.0, 0.01) var slow_multiplier: float = 0.45
@export_range(1.0, 2.5, 0.05) var sprint_multiplier: float = 1.4
## Sidestepping and backpedalling are slower than running forward. The backpedal number is
## load-bearing: it's what makes turning-to-throw-while-fleeing a real trade rather than a
## free action (GDD section 9).
@export_range(0.1, 1.0, 0.01) var strafe_multiplier: float = 0.85
@export_range(0.1, 1.0, 0.01) var back_multiplier: float = 0.7
## Higher reaches top speed sooner. Kept brisk, because weight now comes from the turn rate
## rather than from a sluggish ramp -- a mouse that's slow to start AND slow to turn just
## feels broken.
@export var acceleration: float = 30.0
## Higher stops you sooner. Above acceleration so stopping reads crisper than starting.
@export var friction: float = 34.0
## Radians per second the body can turn. THE weight dial. Per-class later: the Scout whips
## around, the Bruiser commits to a heading.
@export var turn_speed: float = 10.0

@export_group("Carrying")
## How much the banner costs you, as a fraction of your speed. GDD section 2 makes this
## PER-CLASS -- Generalist -10%, Scout -40% -- and the whole handoff play falls out of the
## spread. One number until classes land at M4, but it is already the right shape.
@export_range(0.0, 0.8, 0.01) var carry_penalty: float = 0.25

@export_group("Health")
@export var max_health: float = 100.0
## Quiet time before health starts coming back (GDD section 6).
@export var regen_delay: float = 5.0
## Health per second once regeneration starts. A full refill takes about six seconds, so
## disengaging is a real option and a wounded mouse is still worth chasing.
@export var regen_rate: float = 18.0

@export_group("Melee")
## Damage per connected swing. Four swings to scruff -- long enough that a scrap has a shape
## and either mouse can decide to leave, short enough that ganging up is decisive.
@export var attack_damage: float = 26.0
## Seconds from pressing to the swing finishing.
@export var attack_swing: float = 0.4
## How far into the swing the hit resolves. The rest is recovery, which is what makes a
## whiffed swing punishable.
@export_range(0.05, 1.0, 0.01) var attack_windup: float = 0.16
@export var attack_cooldown: float = 0.28
## Generous, deliberately (GDD section 6). At mouse scale a stingy hitbox reads as broken.
@export var attack_reach: float = 0.95
@export var attack_arc_degrees: float = 110.0
## Metres per second imparted to whoever you hit. Displacement over damage: this is what
## knocks someone off a ledge, out of a doorway, or off the banner.
@export var attack_knockback: float = 4.5
## How much of your speed you keep mid-swing. Committing to a swing should cost a little
## mobility, or there is no reason not to swing constantly while running.
@export_range(0.1, 1.0, 0.01) var swing_move_multiplier: float = 0.55

@export_group("Displacement")
## How fast knockback bleeds off. Separate from friction on purpose -- being shoved should
## carry you, and normal friction (34) would eat the whole push inside two frames.
@export var knock_damping: float = 6.0
## Seconds you cannot steer after being hit. Short: long stuns are miserable and this is a
## game about scraps, not stunlocks.
@export var stun_seconds: float = 0.18

@export_group("Appearance")
## Applied over whatever the model ships with rather than baked into the mesh, so the same
## asset serves both crews and, later, all four classes.
@export var team_color: Color = Color(0, 0, 0, 0)

@onready var _visual: Node3D = $Visual
@onready var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 20.0)

## Y rotation of the visual. Forward is its local -Z, per Godot's convention and per how
## mouse.blend is actually built -- nose at -Z, tail at +Z.
var _facing: float = 0.0
## Where the driver wants to go this tick, in world space, already scaled for strafe and
## backpedal penalties. Subclasses set this in `_control`.
var _wish: Vector3 = Vector3.ZERO
## Which tunnel layer this mouse is on. STATE, not a reading taken off its height -- see
## dig_controller.gd for the bug that taught us the difference.
var _plane: int = 0
var _health: float = 0.0
var _scruffed: bool = false
var _since_damage: float = 999.0
var _swing_left: float = 0.0
var _swing_hit: bool = false
var _cooldown_left: float = 0.0
var _knock: Vector3 = Vector3.ZERO
var _stun_left: float = 0.0
var _carrying: Node3D = null
var _body_material: StandardMaterial3D


func _ready() -> void:
	_health = max_health
	if team_color.a <= 0.0:
		team_color = Team.color_of(team)
	apply_team_color(team_color)
	_facing = _visual.rotation.y
	add_to_group(ACTOR_GROUP)
	add_to_group(MOUSE_GROUP)
	set_plane(_plane)


# ------------------------------------------------------------------------------ identity


func set_team(side: int) -> void:
	team = side
	apply_team_color(Team.color_of(side))
	set_plane(_plane)


## Flat tint across every mesh in the model. Deliberately crude for now -- once classes exist
## this wants two tones (fur and tunic) so silhouette AND colour both carry identity at
## isometric distance.
func apply_team_color(colour: Color) -> void:
	team_color = colour
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.85
	# Real alpha, at last. This was TRANSPARENCY_ALPHA, then a dither, then a recolour, each
	# because the pixel pass ran before transparency and erased anything translucent. The pass
	# is a CompositorEffect now and runs after it, so ordinary blending simply works.
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_body_material = material
	for node in _visual.find_children("*", "MeshInstance3D", true, false):
		(node as MeshInstance3D).material_override = material


## The one material every part of the mouse shares, so concealment can fade the whole body
## without walking the model.
func get_body_material() -> StandardMaterial3D:
	return _body_material


# ---------------------------------------------------------------------------- collision


## Which layer this mouse's geometry collides with, and who can body-block it.
##
## Two jobs in one call. The plane bit is the tunnel layer (see TunnelNetwork.plane_bit) --
## a mouse only ever meets the geometry of the layer it is standing on. The crew bits are
## GDD section 6's recommendation: you sit on your own crew's layer and mask the other's, so
## an enemy is a wall and a teammate is not.
func set_plane(plane: int) -> void:
	_plane = clampi(plane, 0, TunnelNetwork.PLANE_COUNT - 1)
	collision_layer = 0 if _scruffed else Team.layer_bit(team)
	collision_mask = (
		TunnelNetwork.WORLD_BIT
		| TunnelNetwork.plane_bit(_plane)
		| Team.layer_bit(Team.other(team))
	)


func get_plane() -> int:
	return _plane


# ------------------------------------------------------------------------------- queries


## Where the cursor sits on the ground plane. Meaningless for a bot, which is why the base
## answers with the nose -- anything aiming (thrown acorns, barricades) then works for both.
func get_aim_point() -> Vector3:
	return global_position + get_facing_direction() * 2.0


func get_facing_direction() -> Vector3:
	return Vector3(-sin(_facing), 0.0, -cos(_facing))


func get_horizontal_speed() -> float:
	return Vector3(velocity.x, 0.0, velocity.z).length()


## Scurry (GDD section 9) doesn't exist until the cheese economy at M6. Answered here rather
## than assumed by callers, because the answer is a design decision: buying speed with cheese
## must never also buy stealth.
func is_boosting() -> bool:
	return false


func is_scruffed() -> bool:
	return _scruffed


func get_health_ratio() -> float:
	return clampf(_health / maxf(max_health, 0.001), 0.0, 1.0)


func is_carrying() -> bool:
	return _carrying != null


func get_carried() -> Node3D:
	return _carrying


func is_swinging() -> bool:
	return _swing_left > 0.0


# ------------------------------------------------------------------------------- carrying


## Told to the mouse by the director, which owns the rules. The mouse only has to know it is
## slower and that it cannot go underground.
func take_carry(what: Node3D) -> void:
	_carrying = what


func release_carry() -> Node3D:
	var was := _carrying
	_carrying = null
	return was


# ---------------------------------------------------------------------------------- combat


## Start a swing, if one isn't already going and the recovery has finished. Returns whether
## the swing actually started, so a controller can play a "not yet" cue rather than guessing.
func swing() -> bool:
	if _scruffed or _swing_left > 0.0 or _cooldown_left > 0.0:
		return false
	_swing_left = attack_swing
	_swing_hit = false
	swung.emit(self)
	return true


## Take a blow. `from` is where it came from, which is what turns damage into displacement.
func take_hit(damage: float, from: Vector3, knockback: float, by: Mouse = null) -> void:
	if _scruffed:
		return
	_health = maxf(0.0, _health - damage)
	_since_damage = 0.0
	wounded.emit(self, damage)

	var push := global_position - from
	push.y = 0.0
	if push.length_squared() < 0.0001:
		push = -get_facing_direction()
	_knock += push.normalized() * knockback
	_stun_left = maxf(_stun_left, stun_seconds)

	if _health <= 0.0:
		_scruff(by)


## Knocked flat: no steering, no collision with anyone, and the model on its side. The
## director puts you back on your feet at your nest.
##
## NOT a death (intent doc). Nothing about this reads as fatal -- the mouse lies there looking
## annoyed until it respawns, and the cost is a cheese from the team pool once M6 lands.
func _scruff(by: Mouse) -> void:
	if _scruffed:
		return
	_scruffed = true
	_health = 0.0
	_swing_left = 0.0
	_cooldown_left = 0.0
	velocity = Vector3.ZERO
	_knock = Vector3.ZERO
	_wish = Vector3.ZERO
	# Layer cleared so a scruffed mouse stops being a wall. A body on the floor blocking a
	# doorway for six seconds is a bug that reads as one.
	collision_layer = 0
	_visual.rotation.z = PI * 0.5
	scruffed.emit(self, by)


## Back on your feet somewhere. The director decides where; the mouse only knows how to stand.
func revive_at(place: Vector3, facing: float = 0.0) -> void:
	global_position = place
	velocity = Vector3.ZERO
	_knock = Vector3.ZERO
	_stun_left = 0.0
	_health = max_health
	_since_damage = 999.0
	_scruffed = false
	_facing = facing
	_visual.rotation = Vector3(0.0, facing, 0.0)
	set_plane(0)
	revived.emit(self)


## Everyone this swing connects with.
##
## Cone rather than a shape cast, and iterating the group rather than asking the physics
## server. At 4v4 that is eight distance checks -- cheaper than a shape query, deterministic
## for the same inputs, and free of the "did the capsule tunnel through" failure a fast cast
## has. It also makes the SAME-PLANE rule trivial, and that rule matters: without it you can
## swing at someone standing on the lawn from a tunnel directly beneath them.
func _resolve_swing() -> void:
	var forward := get_facing_direction()
	var limit := deg_to_rad(attack_arc_degrees) * 0.5
	for node in get_tree().get_nodes_in_group(MOUSE_GROUP):
		var other := node as Mouse
		if other == null or other == self or other.team == team or other.is_scruffed():
			continue
		if other.get_plane() != _plane:
			continue
		var to_them := other.global_position - global_position
		to_them.y = 0.0
		if to_them.length() > attack_reach + 0.16:
			continue
		if to_them.length_squared() > 0.0001 and forward.angle_to(to_them.normalized()) > limit:
			continue
		other.take_hit(attack_damage, global_position, attack_knockback, self)


# -------------------------------------------------------------------------------- the tick


## The template method. Subclasses implement `_control`; nobody overrides this.
func _physics_process(delta: float) -> void:
	_tick_timers(delta)

	if _scruffed:
		# Still falls, still slides off whatever it was knocked onto. A scruffed mouse frozen
		# in mid-air is the sort of thing you notice from across the arena.
		velocity.x = 0.0
		velocity.z = 0.0
		velocity.y = 0.0 if is_on_floor() else velocity.y - _gravity * delta
		move_and_slide()
		return

	_wish = Vector3.ZERO
	_control(delta)
	if _stun_left > 0.0:
		_wish = Vector3.ZERO
	_apply_motion(delta)


## What the driver wants. Set `_wish` (world space, magnitude 0..1) and call `_face_toward`.
func _control(_delta: float) -> void:
	pass


func _tick_timers(delta: float) -> void:
	_stun_left = maxf(0.0, _stun_left - delta)
	_cooldown_left = maxf(0.0, _cooldown_left - delta)

	if _swing_left > 0.0:
		_swing_left = maxf(0.0, _swing_left - delta)
		if not _swing_hit and _swing_left <= attack_swing - attack_windup:
			_swing_hit = true
			_resolve_swing()
		if _swing_left <= 0.0:
			_cooldown_left = attack_cooldown

	if _scruffed:
		return
	_since_damage += delta
	if _since_damage >= regen_delay and _health < max_health:
		_health = minf(max_health, _health + regen_rate * delta)


## Top speed right now, after every penalty that applies. One place, so nothing has to
## remember that the flag and a swing stack.
##
## Read by the grass through `get_horizontal_speed`, never asked for directly -- which is why
## carrying the banner automatically makes you quieter and harder to see without a line of
## code saying so.
func move_speed() -> float:
	var top := speed * _tier_multiplier()
	if is_carrying():
		top *= 1.0 - carry_penalty
	if _swing_left > 0.0:
		top *= swing_move_multiplier
	return top


## The speed ladder. Base sits at Run; Player overrides for Slow and Sprint.
func _tier_multiplier() -> float:
	return 1.0


## Turn toward a world direction at the capped rate. The cap is where the weight comes from.
func _face_toward(direction: Vector3, delta: float) -> void:
	if direction.is_zero_approx():
		return
	var wanted := atan2(-direction.x, -direction.z)
	var difference := angle_difference(_facing, wanted)
	var step := turn_speed * delta
	_facing = wrapf(_facing + clampf(difference, -step, step), -PI, PI)
	_visual.rotation.y = _facing


func _apply_motion(delta: float) -> void:
	var horizontal := Vector3(velocity.x, 0.0, velocity.z) - _knock

	if _wish.length_squared() > 0.0:
		horizontal = horizontal.move_toward(_wish * move_speed(), acceleration * delta)
	else:
		horizontal = horizontal.move_toward(Vector3.ZERO, friction * delta)

	# Knockback rides ON TOP of the movement velocity and decays on its own clock, so being
	# shoved carries you even while you're running the other way. Folded into the movement
	# velocity instead, ordinary friction would eat the whole push inside two frames and
	# displacement would stop being a mechanic.
	_knock = _knock.lerp(Vector3.ZERO, 1.0 - exp(-knock_damping * delta))

	velocity.x = horizontal.x + _knock.x
	velocity.z = horizontal.z + _knock.z
	velocity.y = 0.0 if is_on_floor() else velocity.y - _gravity * delta

	move_and_slide()
