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

## Scurry fired. Player listens to top its sprint stamina back up (GDD section 2: a second wind,
## not a stat buff), and the HUD listens to flash the counter everyone just watched drop.
signal scurried(mouse: Mouse)

## Anything that bends grass (GDD section 8) and anything combat has to consider.
const ACTOR_GROUP: StringName = &"grass_actor"
const MOUSE_GROUP: StringName = &"mouse"

@export_group("Crew")
## Set before the mouse enters the tree where possible; `set_team` handles it afterwards.
@export_enum("Blue", "Red") var team: int = Team.BLUE
## Which of the four this mouse is (GDD section 4). Set it here and the stats below are
## OVERWRITTEN from resources/classes on ready -- see `set_class`. Leave it alone and every mouse
## is a Generalist, which is what the headless audits build.
@export_enum("Generalist", "Engineer", "Sneak", "Brute") var mouse_class: int = MouseClass.GENERALIST
## What the roster calls this mouse. Blank means fall back to the node name, which is what the
## headless audits get -- they build mice directly and have no use for flavour.
@export var display_name: String = ""

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
## Radians per second the body can turn. THE weight dial. Per-class later: the Sneak whips
## around, the Brute commits to a heading.
@export var turn_speed: float = 10.0

@export_group("Carrying")
## How much the banner costs you, as a fraction of your speed. GDD section 2 makes this
## PER-CLASS -- Generalist -10%, Sneak -40% -- and the whole handoff play falls out of the
## spread. One number until classes land at M4, but it is already the right shape.
@export_range(0.0, 0.8, 0.01) var carry_penalty: float = 0.25

@export_group("Scurry")
## The burst, in seconds. Short on purpose (GDD section 2: "~2s"): what a cheese buys is a
## MOMENT -- the two seconds that turn a losing chase into a won one -- and not a movement mode.
@export var scurry_seconds: float = 2.0
## Personal cooldown. Long enough that Scurry cannot be the way you travel, so the pool drains
## through decisions rather than through a habit.
@export var scurry_cooldown: float = 15.0
## What it multiplies your CURRENT speed by, and multiplying is the whole constraint (GDD
## section 2, marked "don't relax it"). A flat top speed would erase the flag-carry penalty and
## make a Scurrying Sneak as good a carrier as a Generalist -- which quietly deletes the handoff
## play. Stacked on top of the ladder, so it is a real step above Sprint's 1.4.
@export_range(1.0, 3.0, 0.05) var scurry_multiplier: float = 1.85

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
## What this mouse is being *told* to do this tick (M7). Empty for a mouse nobody is driving,
## which is the correct answer for a bot -- its decisions are a path, not a set of keypresses --
## and for a seat whose player has dropped.
##
## THIS IS THE SEAM THE WHOLE MILESTONE TURNS ON. `Player` fills it from this machine's keyboard;
## a server will fill it from a packet. Everything that reads it -- the swing, the dig, the four
## abilities -- cannot tell the difference and must never be able to.
var _input: InputFrame = InputFrame.new()
## A mouse this machine does not simulate (M7 step 4). On a client every mouse is one of these,
## including your own: the server owns the world and this end draws what it is told.
##
## NOT A SUBCLASS, because the thing that changes is one branch in the tick and everything else --
## the model, the grass bend, the banner over your head, the swing arc -- has to keep working
## identically. A `PuppetMouse` would have to re-inherit all of that from whichever of `Player` or
## `Bot` it happened to be replacing, and a mouse's authority can change mid-match when somebody
## disconnects and a bot takes their chair.
var _puppet: bool = false
## Where the server last said this mouse was, and where it said so before that. Two, because one
## is a position to snap to and two are something to move between.
var _pose_from: Vector3 = Vector3.ZERO
var _pose_to: Vector3 = Vector3.ZERO
var _facing_from: float = 0.0
var _facing_to: float = 0.0
## 0..1 across the gap between those two poses.
var _pose_blend: float = 1.0
## Whether the last pose said this puppet was mid-swing. Kept separately from `_swing_left`, which
## is the timer a real swing runs on and which a puppet never sets -- what is being tracked here is
## an EDGE in somebody else's state, not a swing of our own.
var _shown_swing: bool = false
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
## Wedges in the paws, 0 or 1. An int rather than a bool because section 2 leaves the door open
## to a class that hauls two, and every caller below already reads it as an amount.
var _wedges: int = 0
var _boost_left: float = 0.0
var _boost_cooldown: float = 0.0
## The swipe. Built here rather than placed in the scenes so bot.tscn, player.tscn and a mouse a
## headless audit builds by hand all telegraph identically -- see swing_arc.gd.
var _swing_arc: SwingArc


func _ready() -> void:
	# BEFORE health is read off it, because this is what sets max_health.
	set_class(mouse_class)
	_health = max_health
	if team_color.a <= 0.0:
		team_color = Team.color_of(team)
	apply_team_color(team_color)
	_facing = _visual.rotation.y
	# On the body, NOT on `_visual`: the visual gets a flat material override walked over every
	# mesh under it by `apply_team_color`, and gets laid on its side when you're scruffed.
	_swing_arc = SwingArc.new()
	_swing_arc.name = "SwingArc"
	add_child(_swing_arc)
	_swing_arc.arm(self)
	add_to_group(ACTOR_GROUP)
	add_to_group(MOUSE_GROUP)
	set_plane(_plane)


# ------------------------------------------------------------------------------ identity


## The name on the roster. Never empty -- a nameless row is worse than an ugly one.
func get_display_name() -> String:
	return display_name if not display_name.is_empty() else String(name)


func get_class_name() -> String:
	return MouseClass.name_of(mouse_class)


## Become one of the four. The definition's numbers are COPIED onto this mouse's own properties
## rather than kept behind a reference, so every system already written -- grass, combat,
## carrying, the HUD, the bots -- gets per-class behaviour without learning what a class is, and
## a mouse built by hand with no class at all still works.
##
## Health is left where it is. A swap point that healed you would make walking home a heal on a
## cooldown, and the GDD is specific that a switch costs tempo and nothing else (section 4) --
## the topping up you get at a nest should come from the nest, when there is one.
func set_class(kind: int) -> void:
	mouse_class = clampi(kind, 0, MouseClass.COUNT - 1)
	var definition := MouseClass.definition_of(mouse_class)
	if definition == null:
		return
	apply_class(definition)
	# Clamped rather than refilled: a Sneak that swaps to a Brute does not deserve sixty free
	# health, and a Brute at 140 that swaps to a Sneak must not walk away on double its maximum.
	_health = minf(_health, max_health)


## Copy a definition onto this mouse. Overridden by Player to pick up the stats only a driven
## mouse has -- see player.gd, which owns sprint.
func apply_class(definition: ClassDefinition) -> void:
	max_health = definition.max_health
	speed = definition.speed
	turn_speed = definition.turn_speed
	attack_damage = definition.attack_damage
	carry_penalty = definition.carry_penalty


## How fast this mouse opens a tile, as a multiplier on the dig controller's own timing.
##
## EVERYBODY DIGS; the Engineer is three times better at it. GDD section 4 made terrain the
## Engineer's exclusive capability and this is a deliberate revision of that -- the note is in
## the GDD. A crew without an Engineer can still get underground, slowly, in a pinch.
func get_dig_speed() -> float:
	return MouseClass.definition_of(mouse_class).dig_speed


## Whether this mouse fits down a shaft at all (GDD section 4 -- the Juggernaut does not).
func can_enter_tunnels() -> bool:
	return MouseClass.definition_of(mouse_class).can_enter_tunnels


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


## The raw angle, for the wire. `get_facing_direction` is the vector everything in the game uses;
## a snapshot wants one float rather than three.
func get_facing_angle() -> float:
	return _facing


func get_facing_direction() -> Vector3:
	return Vector3(-sin(_facing), 0.0, -cos(_facing))


func get_horizontal_speed() -> float:
	return Vector3(velocity.x, 0.0, velocity.z).length()


## Mid-Scurry (GDD sections 2 and 9). Read by grass_camouflage.gd, which pins a boosting mouse
## at full opacity -- buying speed with cheese must never also buy stealth, and that rule was
## written here before there was anything to enforce it against.
func is_boosting() -> bool:
	return _boost_left > 0.0


## Whether Scurry is off cooldown. Says nothing about whether the crew can afford it: the pool
## is the director's, and a mouse has no business reading its team's bank balance.
func scurry_ready() -> bool:
	return _boost_cooldown <= 0.0 and _boost_left <= 0.0 and not _scruffed


## 0 while ready, rising to 1 just after a Scurry. The HUD's dial.
func scurry_cooldown_ratio() -> float:
	return clampf(_boost_cooldown / maxf(scurry_cooldown, 0.001), 0.0, 1.0)


## Go. The CALLER has already paid -- MatchDirector.try_scurry is the only thing that should call
## this, because it owns the pool and the pool is the price. Returns false if the mouse was not
## in a position to spend, so the director can decline to charge for nothing.
func start_scurry() -> bool:
	if not scurry_ready():
		return false
	_boost_left = scurry_seconds
	_boost_cooldown = scurry_cooldown
	scurried.emit(self)
	return true


func get_carried_cheese() -> int:
	return _wedges


func has_free_paws() -> bool:
	return _wedges <= 0 and not is_carrying()


## Take a wedge into your paws. One at a time (GDD section 2), and never alongside a banner --
## the two errands are meant to compete for the same mouse, not stack on one.
func take_wedge() -> bool:
	if not has_free_paws():
		return false
	_wedges = 1
	return true


## Hand over whatever cheese you were carrying, and return how much it was.
func release_wedges() -> int:
	var had := _wedges
	_wedges = 0
	return had


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
	# Swept over the windup, so the ribbon finishes crossing the cone on the frame
	# `_resolve_swing` fires rather than after it.
	if _swing_arc != null:
		_swing_arc.play(attack_windup)
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
	# The swing is cancelled, so the swipe drawing it has to go with it on the same frame.
	if _swing_arc != null:
		_swing_arc.stop()
	# The burst dies with you; the cooldown does not. Being scruffed mid-Scurry has to cost the
	# rest of it, or the safest moment to spend a cheese would be the one just before you lose
	# the fight -- and the cheese stays spent either way.
	_boost_left = 0.0
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

	_resolve_swing_on_breakables(forward, limit)


## The same cone, against the things in the way rather than the people.
##
## A SEPARATE PASS, and separate on purpose. A barricade is not a Mouse and should not have to
## pretend to be one to be hittable -- it has no health bar, no team, no knockback and no scruff,
## and the one question it answers is "was that a Brute". Widening `take_hit` to cover both would
## have made every one of those a null check.
##
## ONE PASS FOR EVERY BREAKABLE THING, though. This was written against barricades specifically,
## and boulders on the lawn would have meant a second copy of it -- at which point every new
## destructible thing costs an edit to this file, and the edit most likely to be forgotten is the
## one that makes it hittable at all. Anything in `Breakable.GROUP` is now in the cone.
func _resolve_swing_on_breakables(forward: Vector3, limit: float) -> void:
	for node in get_tree().get_nodes_in_group(Breakable.GROUP):
		var thing := node as Breakable
		if thing == null or thing.plane != _plane:
			continue
		var to_it := thing.global_position - global_position
		to_it.y = 0.0
		# A shade more generous than against a mouse: the rock fills its cell, so its centre is
		# further away than its face, and a swing that visibly connects should count.
		if to_it.length() > attack_reach + 0.5:
			continue
		if to_it.length_squared() > 0.0001 and forward.angle_to(to_it.normalized()) > limit:
			continue
		thing.hit_by(self)


# -------------------------------------------------------------------------------- the tick


## The template method. Subclasses implement `_control`; nobody overrides this.
func _physics_process(delta: float) -> void:
	_tick_timers(delta)

	# A PUPPET DOES NOT SIMULATE. Not its controller, not its physics, not gravity -- it is shown
	# where the server says it is. Running `move_and_slide` here as well would fight the incoming
	# poses and produce a mouse that jitters against every wall it stands near, which is the
	# classic look of a client that thinks it is also the authority.
	if _puppet:
		_follow_pose(delta)
		return

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


## This tick's intent. Never null — a mouse with no driver returns an empty frame rather than
## making six callers each check.
##
## `Player` overrides this to build the frame from the keyboard on first ask; the base returns
## whatever was last handed in, which is what a server-driven or bot-driven mouse wants.
func input() -> InputFrame:
	return _input


## Hand this mouse somebody's intent. The door a received packet comes through.
func drive(frame: InputFrame) -> void:
	_input = frame if frame != null else InputFrame.new()


## Whether this machine simulates this mouse, or merely draws it.
func set_puppet(on: bool) -> void:
	if _puppet == on:
		return
	_puppet = on
	# A puppet must not be shoved around by anybody else's physics either -- it has no authority
	# to be pushed, and a depenetration here would be a position the server never agreed to.
	set_collision_layer_value(1, not on)
	if on:
		velocity = Vector3.ZERO


func is_puppet() -> bool:
	return _puppet


## What the server says. Called once per snapshot, not once per frame.
##
## The previous target becomes the starting point rather than the mouse's CURRENT position, so a
## packet that arrives late does not restart the blend from wherever the interpolation had got to
## -- that turns every hiccup into a visible stutter backwards.
func apply_pose(at: Vector3, facing: float, flags: int, health: int) -> void:
	# CLASS FIRST, AND THE ORDER IS THE WHOLE REASON IT IS ON THIS LINE. `set_class` is what sets
	# `max_health`, and the health below is a fraction of it -- so applying them the other way
	# round scales a Sneak's ratio by a Brute's maximum for one tick every time somebody swaps.
	# Guarded on change because `set_class` copies a whole definition and this runs thirty times a
	# second.
	var kind := (flags & Snapshot.CLASS_MASK) >> Snapshot.CLASS_SHIFT
	if kind != mouse_class:
		set_class(kind)

	# A RATIO OFF THE WIRE, SCALED BY OUR OWN MAXIMUM. The class table is not replicated, so the
	# packet cannot say "62 points" and be understood -- but every end knows what this mouse's
	# maximum is, and a fraction of it means the same thing everywhere.
	_health = (health / 255.0) * max_health
	_pose_from = _pose_to if _pose_blend < 1.0 else global_position
	_facing_from = _facing_to if _pose_blend < 1.0 else _facing
	_pose_to = at
	_facing_to = facing
	_pose_blend = 0.0

	# THE SWING IS AN EDGE, NOT A STATE, which is why it is the one flag not simply assigned. A
	# swing is an animation with a length of its own; setting a bool every thirtieth of a second
	# would restart the arc four times over the course of one swipe. The damage is not replicated
	# at all and must not be -- it resolved on the server, and this end is drawing what happened.
	#
	# A swing shorter than the snapshot interval could fall between two packets and never be seen.
	# `attack_swing` is an order of magnitude longer than 1/30s, so that is a real limit of this
	# approach and not a live one; a fast attack added later is the thing that would break it.
	var swinging := (flags & Snapshot.Flag.SWINGING) != 0
	if swinging and not _shown_swing and _swing_arc != null:
		_swing_arc.play(attack_windup)
	_shown_swing = swinging

	# Set directly, not through `set_plane`: that is the door the dig controller and the transit
	# use, and on a client neither of them runs. This is the layer this mouse is *on*, decided
	# elsewhere -- and everything that reads it (the cutaway, the grass, the minimap, a defender's
	# "they are three planes down") gets the right answer without knowing where it came from.
	_plane = (flags & Snapshot.PLANE_MASK) >> Snapshot.PLANE_SHIFT

	var down := (flags & Snapshot.Flag.SCRUFFED) != 0
	if down != _scruffed:
		# Set directly rather than through `scruff()`: that is the RULE, and rules resolve on the
		# server. This is the picture of a rule that already resolved somewhere else.
		_scruffed = down

	# A TELEPORT, NOT A GLIDE, when the gap is absurd. Respawns put a mouse most of an arena away
	# and interpolating across that draws it skating through the yard at fifty metres a second --
	# which reads as a bug in the movement rather than as a respawn.
	if global_position.distance_to(at) > POSE_SNAP:
		_pose_from = at
		_facing_from = facing
		_pose_blend = 1.0
		global_position = at
		_face_instantly(facing)


## Metres of disagreement past which a puppet stops interpolating and simply appears. Roughly a
## body length times ten -- comfortably more than a bad frame of lag at sprint speed, comfortably
## less than a respawn.
const POSE_SNAP: float = 4.0

## How much of the remaining gap to close each tick. Not a fixed duration, because snapshots do
## not arrive on a fixed schedule once there is a real network under them; an exponential chase
## degrades into "a bit behind" rather than into "arrived early and stopped".
const POSE_CATCHUP: float = 18.0


func _follow_pose(delta: float) -> void:
	_pose_blend = minf(1.0, _pose_blend + delta * POSE_CATCHUP)
	global_position = _pose_from.lerp(_pose_to, _pose_blend)
	_face_instantly(lerp_angle(_facing_from, _facing_to, _pose_blend))


func _face_instantly(angle: float) -> void:
	_facing = wrapf(angle, -PI, PI)
	if _visual != null:
		_visual.rotation.y = _facing


func _tick_timers(delta: float) -> void:
	_stun_left = maxf(0.0, _stun_left - delta)
	_cooldown_left = maxf(0.0, _cooldown_left - delta)
	_boost_left = maxf(0.0, _boost_left - delta)
	# Ticks while the burst is still running, so the fifteen seconds are counted from the moment
	# you SPENT the cheese and not from the moment the boost ran out. The spend is the thing the
	# cooldown is rationing.
	_boost_cooldown = maxf(0.0, _boost_cooldown - delta)

	if _swing_left > 0.0:
		_swing_left = maxf(0.0, _swing_left - delta)
		if not _swing_hit and _swing_left <= attack_swing - attack_windup:
			_swing_hit = true
			_resolve_swing()
		if _swing_left <= 0.0:
			_cooldown_left = attack_cooldown

	if _scruffed:
		return
	# A PUPPET DOES NOT HEAL, because healing is a rule. Its health arrives with every pose, and a
	# local regeneration on top of that is a second opinion the server never asked for: the bar
	# would creep upward between snapshots and jerk back down on each one, which reads as packet
	# loss and is a client quietly disagreeing about how hurt somebody is.
	if _puppet:
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
	# Underground speed, and it is a BONUS OR NOTHING. GDD section 3 used to scale this inversely
	# with size, which made a Brute in its own tunnel slower than everyone else on the lawn above
	# it -- not a cork, just a class quietly locked out of a third of the map. The floor at 1.0 is
	# deliberately in code rather than only in the resources: a penalty here is a design decision
	# that has already been reversed once, and a stale .tres should not be able to make it again.
	if _plane > 0:
		top *= maxf(1.0, MouseClass.definition_of(mouse_class).tunnel_speed)
	if is_carrying():
		top *= 1.0 - carry_penalty
	if _swing_left > 0.0:
		top *= swing_move_multiplier
	# LAST, and multiplying whatever is left. Every penalty above has already been applied, so a
	# Scurrying carrier is a fast carrier and not a mouse that stopped carrying (GDD section 2).
	if _boost_left > 0.0:
		top *= scurry_multiplier
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
