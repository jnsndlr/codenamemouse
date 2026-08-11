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

## Emitted when this mouse is knocked flat. `by` may be null -- a cave-in can put you down with
## nobody to credit. The director listens; nothing here knows about respawns.
##
## THE CAUSE IS NOT ON THE SIGNAL, it is read off the mouse with [method was_buried]. A second
## argument would have meant touching every listener and every `is_connected` comparison for a
## fact that is a property of the mouse's current state rather than of the event -- and the
## director already reaches back into the mouse for what it was carrying.
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

@export_subgroup("Sprint stamina")
## Seconds of sprint at full stamina. The per-class dial (GDD section 9) -- sprint SPEED is
## uniform, duration is what differs. Sneak 6.0, Brute 1.5.
##
## `[MOVED at M8]` These four lived on `Player`, with a note saying a bot has no stamina to give a
## duration to and the stat would be a property nothing read on three quarters of the mice in the
## match. That was true and it was the bug: bots could not sprint, could not go quiet, and ran
## every step of every match at exactly one speed. A human could sprint away from a defender
## indefinitely and crouch past one that had no idea what crouching was -- two mechanics that
## simply did not apply to three quarters of the mice, which is the definition of the AI playing a
## different game. The ladder belongs to a mouse; who climbs it is the driver's business.
@export var sprint_seconds: float = 4.0
## Quiet time before stamina starts coming back.
@export var stamina_regen_delay: float = 2.0
## Seconds to refill from empty, once regen has started.
@export var stamina_refill_seconds: float = 6.0
## Can't re-engage sprint below this much stamina. Stops stutter-sprinting on fumes.
@export var sprint_minimum: float = 0.35
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
## How many wedges of cheese fit in these paws. Copied off the class (GDD section 2); the default
## is the Generalist's, so a mouse built by hand with no class still hauls sensibly.
@export_range(1, 8, 1) var carry_capacity: int = 3
## Seconds between picking up one wedge and being able to pick up the next.
##
## THE PACING DIAL, and it is what stops capacity from being a free upgrade. Without it a Brute
## walks through a cache and leaves with five wedges in the same instant, which makes a cache a
## button rather than a place -- and makes the biggest number simply the best number. Five seconds
## for five wedges is twenty seconds standing in one spot on the lawn, in the open, with nothing
## to show for it if somebody arrives at second nineteen.
##
## PER MOUSE AND NOT PER CACHE, so it cannot be dodged by walking between two piles -- the limit is
## how fast a mouse can stow cheese, which is a fact about the mouse.
@export var wedge_cooldown: float = 5.0

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

@export_group("Body")
## Half the width of this mouse, in metres, copied off its [ClassDefinition] -- which is where
## the long note about what this number decides lives. Everybody is 0.16 except the Brute.
##
## READ RATHER THAN ASSUMED, by everything that measures against a body. Two places used to
## hard-code 0.16 as "the other mouse's radius" when adding a little slack to a reach, and both
## quietly under-reached against anything wider the moment a class stopped being one size.
@export var body_radius: float = 0.16
## How wide this mouse is DRAWN, which is allowed to differ from how wide it is.
##
## THE BRUTE IS A LITTLE SLIMMER THAN IT COLLIDES, on purpose and after looking at it. The cork
## needs 0.24 of capsule at the very least and 0.30 to seal with any margin (see
## [ClassDefinition.body_radius]); a model drawn at 0.30 reads less like a heavyweight mouse than
## like a different animal. So the body is the number the corridor needs and the model is the
## number the yard wants, and the gap between them is 6cm on one class.
##
## IT IS A DEBT, NOT A FREE LUNCH, and worth saying plainly: a mouse that is wider than it looks
## can block a gap that looked open, which is the oldest complaint in every game that has ever
## done this. 6cm at this scale is a quarter of a body width and lands inside what the eye reads
## as "touching". Anything larger should go the other way -- make the model honest and re-tune the
## corridor -- rather than growing this gap.
@export var model_radius: float = 0.16
## The base a standard mouse is authored at, in both scenes and in `_puppet` fixtures. Only ever
## used as the denominator of a ratio -- this is not a tuning dial.
const STANDARD_RADIUS: float = 0.16
## How tall a mouse is, and it is the same for all four. HELD CONSTANT rather than scaled with the
## width, because it is not a look -- it is what has to fit under the next plane's floor, and the
## margin there is 13cm (see `_fit_body`).
const BODY_HEIGHT: float = 0.4
## How much of the width difference also goes into height. A Brute that grew evenly would be
## twice as TALL as a Sneak, which is a giant rather than a heavyweight -- and this camera reads
## width far better than it reads height anyway, because it looks down at the yard from 48
## degrees. Broad and only a little taller is the silhouette section 4 asks for.
const HEIGHT_SHARE: float = 0.45

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
## Whether the thing that put this mouse down was the roof rather than a paw. See [method bury].
var _buried: bool = false
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
## Seconds left before another wedge may be stowed.
var _wedge_wait: float = 0.0
var _boost_left: float = 0.0
var _boost_cooldown: float = 0.0
var _stamina: float = 0.0
var _regen_timer: float = 0.0
## Spending stamina to run. INTENT, set by whoever is driving -- a double-tapped W for a player, a
## rule in the ranking for a bot -- and cleared here when the tank runs dry. Nothing outside sets
## it directly; see `request_sprint`.
var _sprinting: bool = false
## Deliberately moving quietly: the other half of the ladder, and the one with no meter behind it.
## Slow costs nothing but speed, which is why it is the tier a mouse can hold all match.
var _creeping: bool = false
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
	_stamina = sprint_seconds
	# A SECOND WIND, NOT A STAT BUFF (GDD section 2). Refilling stamina is what stops Scurry from
	# being a boost you tack onto an exhausted sprint and makes it the thing that resets a chase you
	# were losing -- the burst runs out and you still have a sprint left. Connected here rather than
	# on `Player` since M8, because the tank is every mouse's now and a bot spends cheese on the
	# same two moments a human does (see bot.gd's `_consider_scurry`).
	scurried.connect(_on_scurried)


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


## Copy a definition onto this mouse.
func apply_class(definition: ClassDefinition) -> void:
	body_radius = definition.body_radius
	model_radius = definition.model_radius
	_fit_body()
	max_health = definition.max_health
	speed = definition.speed
	turn_speed = definition.turn_speed
	attack_damage = definition.attack_damage
	carry_penalty = definition.carry_penalty
	# NOT CLAMPED, and the wedges are not spilled. Swapping happens at your own nest, which is the
	# one spot on the map where anything you were carrying has already been banked -- and a Brute
	# who somehow arrives holding four and swaps to Sneak simply cannot pick up a fifth until it
	# has put them down. Spilling cheese on the swap disc would be inventing a punishment for the
	# one act GDD section 4 is explicit should cost nothing but the walk home.
	carry_capacity = definition.carry_capacity
	sprint_seconds = definition.sprint_seconds
	# Topped up, not scaled. Swapping class at your own nest is the one moment stamina is
	# uninteresting -- you are standing still, at home, and about to walk somewhere.
	_stamina = sprint_seconds


## How much taller than a standard mouse this one is. 1.0 for three of the four.
##
## Public because three things are drawn ABOVE a mouse's head -- its health bar, the contextual
## hint, and the banner on a carrier's pole -- and every one of them was a constant measured off
## a body that was the same size for everybody. On a Brute those constants land inside the model.
## Off the MODEL rather than the body, because everything that reads this is positioning something
## above what a player can see -- a bar, a hint, a banner on a pole. The collision shape's own
## height never changes at all (see `BODY_HEIGHT`).
func height_ratio() -> float:
	return 1.0 + (model_radius / STANDARD_RADIUS - 1.0) * HEIGHT_SHARE


## Make the collision shape match `body_radius` and the model match `model_radius`.
##
## A CYLINDER RATHER THAN THE AUTHORED CAPSULE, and this is not a preference -- a capsule cannot
## express a wide mouse at all. Godot clamps a capsule's height to at least twice its radius, so
## asking for 0.30 silently grows a 0.40-tall body into a 0.60-tall one. A plane's headroom is
## `PLANE_SPACING - FLOOR_THICKNESS` = **0.53**, so the Brute arrived underground 7cm too tall for
## the corridor it was standing in, wedged between the floor and the slab above and also sunk 10cm
## into the floor, because the shape is centred at 0.2. It could not move. The bug was invisible on
## the lawn, where there is no ceiling, and no audit asks whether a mouse FITS.
##
## A cylinder holds its height whatever the radius does, which is the whole of the fix. Every
## mouse gets one, not just the wide one: a class that slides over a lip differently from the
## other three because of a shape quirk is exactly the sort of difference nobody would ever guess
## at from the outside. The `.tscn` files still author a capsule -- it is the standard size,
## written where a reader looks for it, and this replaces it before the first physics tick.
##
## THE SHAPE IS PER MOUSE, and skipping that would be a bug that is very hard to find: a
## `[sub_resource]` in a `.tscn` is shared by every instance of that scene, so `bot.tscn`'s one
## shape is the SAME object in all six bots. Building a new one here sidesteps that entirely.
##
## THE VISUAL IS SCALED RATHER THAN SWAPPED, because there is one mouse model and this grey box
## has no second one -- and it is scaled to `model_radius`, which is deliberately allowed to
## differ from the body. Height takes `HEIGHT_SHARE` of the width difference.
func _fit_body() -> void:
	for node in find_children("*", "CollisionShape3D", true, false):
		var slot := node as CollisionShape3D
		var barrel := CylinderShape3D.new()
		barrel.radius = body_radius
		barrel.height = BODY_HEIGHT
		slot.shape = barrel

	if _visual != null:
		var wide := model_radius / STANDARD_RADIUS
		_visual.scale = Vector3(wide, height_ratio(), wide)


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
## a mouse only ever meets the geometry of the layer it is standing on. The crew bits say who
## is solid, and the answer is now EVERYBODY.
##
## `[REVISED]` ALLIES COLLIDE TOO, which closes the `[DECIDE]` GDD section 6 has carried since
## M1. It recommended enemies-only, with a footnote that the Brute's cork "should probably block
## allies too, or corking is meaningless" -- and having built the cork, the footnote is the whole
## rule rather than an exception to it. A wall that your own crew walks through is not a wall; it
## is a wall with a door in it that the enemy cannot see, and the class whose entire fantasy is
## *not through here* would have been asking everyone to take its word for it.
##
## It also fixes something with nothing to do with the Brute: mice stood INSIDE one another. Four
## bots defending a nest occupied one point of ground, a crowd read as a single mouse with extra
## outlines, and a teammate could never be in your way -- so nothing about a corridor, a doorway
## or a nest ever had to be shared. Being able to be blocked by your own crew is what makes any of
## that geometry mean anything.
##
## A SCRUFFED MOUSE IS STILL AIR (the `collision_layer = 0` below), which matters more now than it
## did: with everyone solid, a body on the floor of a corridor would otherwise be a cork that
## nobody chose and nobody can move.
func set_plane(plane: int) -> void:
	_plane = clampi(plane, 0, TunnelNetwork.PLANE_COUNT - 1)
	collision_layer = 0 if _scruffed else Team.layer_bit(team)
	collision_mask = (
		TunnelNetwork.WORLD_BIT
		| TunnelNetwork.plane_bit(_plane)
		| Team.layer_bit(team)
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


## How many more would fit right now, ignoring the cooldown.
func wedge_room() -> int:
	return maxi(0, carry_capacity - _wedges)


## Room for another wedge, and enough time has passed since the last one.
##
## `[REVISED]` THIS USED TO BE `has_free_paws`, AND USED TO MEAN SOMETHING NARROWER: one wedge,
## and never while carrying a banner. Both halves have gone.
##
## The one-wedge limit became `carry_capacity`, per class -- see [ClassDefinition]. **The banner
## exclusion went too, and that is the arguable one.** GDD section 2's instinct was that the two
## errands should compete for the same mouse rather than stack on one, and the rule enforcing it
## was a mouse with cheese in its paws being unable to touch a loose banner. That is the wrong
## mouse to punish: the classes with real capacity are the ones least likely to be running a flag
## anyway, and a Brute forced to choose between five wedges and a banner lying at its feet just
## drops the banner -- which is not a decision, it is an inconvenience with an obvious answer. The
## errands still compete, through the thing that was always doing the work: the walk. What you can
## carry home in one trip has not changed; what has changed is that you no longer have to make two
## trips through the same yard to do it.
func has_room() -> bool:
	return _wedges < carry_capacity and _wedge_wait <= 0.0


## Seconds until this mouse can stow another wedge. For a HUD that wants to say why a cache is
## being walked over rather than picked up.
func wedge_wait() -> float:
	return _wedge_wait


## Take a wedge into your paws. One at a time -- capacity is how many you may END UP with, not how
## many a cache hands over at once, and the cooldown between them is the whole pacing of hauling.
func take_wedge() -> bool:
	if not has_room():
		return false
	_wedges += 1
	_wedge_wait = wedge_cooldown
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

	shove(from, knockback)

	if _health <= 0.0:
		_scruff(by)


## Be moved, without being hurt. The displacement half of [method take_hit], on its own.
##
## SPLIT OUT FOR SLAM (GDD section 4), which is a shove with no damage in it at all -- section 6
## says displacement matters more than damage, and the Brute's ability is the one place that is
## the whole of the design rather than a flavour note. `take_hit(0.0, ...)` would have done the
## job and would also have reset the regen timer on its way past, which is a point of damage
## wearing a zero: the shoved mouse heals later than it would have, for reasons nothing on screen
## explains. The one number this ability is not allowed to have is a number.
##
## HOW FAR IT ACTUALLY PUSHES is `force / knock_damping`, near enough -- the impulse is damped
## exponentially and integrated, so a force of 15 against the default damping of 6 carries a mouse
## about two and a half metres. Worth stating because callers pick a distance, not an impulse.
func shove(from: Vector3, force: float) -> void:
	if _scruffed:
		return
	var push := global_position - from
	push.y = 0.0
	if push.length_squared() < 0.0001:
		push = -get_facing_direction()
	var impulse := push.normalized() * force
	_knock += impulse
	# INTO `velocity` AS WELL, and this line is a bug fix rather than bookkeeping.
	#
	# `_apply_motion` separates the two every frame with `horizontal := velocity - _knock`, which
	# is only true if `velocity` already CONTAINS the knock -- and on the tick an impulse is first
	# applied it did not. The subtraction therefore invented an equal and opposite movement
	# velocity out of nothing, pointed straight back at whoever hit you: the mouse was thrown out,
	# and then, as `_knock` decayed and left the phantom behind, it slid part of the way home.
	#
	# NOBODY SAW IT FOR FIVE MILESTONES because a swing's 4.5 buys 0.75m and gives back a fraction
	# of that -- inside the noise of a scrap. Slam is 15, and at 15 the rebound is a mouse visibly
	# walking back toward the Brute that just threw it. The probe measured 1.0m out and 0.81m
	# settled where the arithmetic says 2.5m: two thirds of every shove in the game so far has
	# been quietly cancelled by its own separation term.
	velocity.x += impulse.x
	velocity.z += impulse.z
	_stun_left = maxf(_stun_left, stun_seconds)


## Put health back on. Returns how much actually landed, which is not always what was asked for --
## a mouse two points off full takes two.
##
## IT DOES NOT TOUCH `_since_damage`, and that omission is the whole reason this is a function
## rather than a `take_hit` with a minus sign in front of it. The regen clock measures *quiet*, and
## being healed is not a thing that happened to you in a fight -- resetting it here would mean a
## [SecondWind] pushed your passive regeneration five seconds further away, so the ability would
## give with one hand and take with the other in a way nothing on screen could explain.
##
## A PUPPET DOES NOT HEAL, for the same reason it does not regenerate: healing is a rule, its result
## arrives with every pose, and a local top-up on top of that is a second opinion the server never
## asked for. The rule is stated here as well as at the caller because a heal is the one kind of
## write that looks harmless from the outside -- nobody debugging a drifting health bar would think
## to suspect the thing making it go up.
func heal(amount: float) -> float:
	if _scruffed or _puppet or amount <= 0.0:
		return 0.0
	var landed := minf(amount, max_health - _health)
	_health += landed
	return maxf(landed, 0.0)


## Fill the sprint tank, and start the refill delay over.
##
## TWO CALLERS AND ONE SENTENCE BEHIND BOTH. GDD section 2 says a refilled tank is what makes Scurry
## "a second wind rather than a stat buff", and [SecondWind] is the ability that took the phrase for
## a name -- so the two do the same thing to the same meter on purpose. What separates them is the
## price: Scurry is speed, costs the crew a respawn and belongs to everybody; the wind is endurance,
## costs nothing and belongs to one class.
func refill_stamina() -> void:
	_stamina = sprint_seconds
	_regen_timer = 0.0


## The roof came in on you. A different way to go down, and it wants a different word.
##
## SCRUFFING IS SOMETHING A MOUSE DOES TO YOU. Four connected swings, a paw on the scruff of your
## neck, and you lie there looking annoyed -- which is the tone the whole game is written in
## (intent doc: nothing here dies). A cave-in is not that. Nobody wrestled you; a cubic metre of
## earth arrived where you were standing, and calling it a scruffing was the one place the word
## was doing no work at all.
##
## MECHANICALLY A SCRUFF, AND THAT IS DELIBERATE RATHER THAN LAZY. You drop what you were holding
## where you fell, the crew pays its cheese, you come back at your nest. The cost of being buried
## is a dial on the director (`buried_extra_seconds`) that starts at zero, so this change is a
## word and a picture until somebody decides it should also be a punishment. Making it hurt more
## is one number; unpicking a balance change nobody asked for is not.
##
## THE FLAG IS SET BEFORE THE DAMAGE, because `take_hit` is what reaches `_scruff` and emits, and
## a listener that read the cause afterwards would be reading it one frame late.
func bury(by: Mouse = null) -> void:
	if _scruffed:
		return
	_buried = true
	take_hit(9999.0, global_position, 0.0, by)


## Was the mouse currently down put there by a collapse? Meaningless while it is on its feet.
func was_buried() -> bool:
	return _scruffed and _buried


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
	# You come back with empty paws (the director scattered what you had where you fell), so the
	# stow clock has nothing left to ration. Leaving it running would spend the first seconds of a
	# fresh life unable to pick up the wedges lying at the nest you respawned on.
	_wedge_wait = 0.0
	_scruffed = false
	_buried = false
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
		# Their radius, not a constant 0.16. Reach is measured centre to centre and a swing that
		# visibly connects should count, so the allowance has to be the body it is landing on --
		# which stopped being one number the moment the Brute got wider than everybody else.
		if to_them.length() > attack_reach + other.body_radius:
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
	# Between the intent and the motion, deliberately -- see `_tick_stamina`.
	_tick_stamina(delta)
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
	# Taken every pose rather than only on the transition, because the two bits are decided one
	# frame apart on the server -- `bury` sets the cause and `take_hit` does the scruffing -- so a
	# pose can legitimately carry SCRUFFED before it carries BURIED. Read only on the edge, that
	# first pose would pin the wrong word on screen for the whole six seconds.
	_buried = down and (flags & Snapshot.Flag.BURIED) != 0

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
	# Ticks while scruffed and on a puppet alike, unlike almost everything below the guards further
	# down. It is a clock rather than a rule -- nothing happens when it reaches zero except that a
	# pickup the DIRECTOR decides becomes possible -- and a client that let it stall would grey out
	# a cache its own server was perfectly willing to let it take from.
	_wedge_wait = maxf(0.0, _wedge_wait - delta)

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


## The speed ladder: Slow, Run, Sprint.
##
## SLOW IS TESTED FIRST, which is the rule `slow_multiplier` has stated since M1 -- *you can't be
## quiet and fast* -- and it had never actually been written down in code. `Player` got the same
## answer by clearing its own sprint flag whenever Slow was held, so the ordering here was
## unreachable and could be either way round without anything noticing. That is exactly the kind of
## rule that breaks the moment a second driver arrives, which is what a bot is: one driver that
## forgets to clear the flag and a mouse sprints at a tenth opacity, invisible to everything except
## somebody wondering why the AI is so hard to see.
func _tier_multiplier() -> float:
	if _creeping:
		return slow_multiplier
	if _sprinting:
		return sprint_multiplier
	return 1.0


## Ask to sprint, or to stop. REFUSED ON AN EMPTY TANK rather than silently granted, which is what
## `sprint_minimum` is for: without it a mouse on fumes stutters in and out of a sprint every frame.
func request_sprint(on: bool) -> void:
	if not on:
		_sprinting = false
		return
	if _stamina >= sprint_minimum:
		_sprinting = true


## Move quietly, or stop. No meter and no refusal -- Slow costs speed and nothing else, which is
## why it is the tier a mouse can hold for a whole match.
func set_creeping(on: bool) -> void:
	_creeping = on


func is_sprinting() -> bool:
	return _sprinting


func is_creeping() -> bool:
	return _creeping


## 0..1, for the HUD. Personal and private -- never shown for anyone else (GDD section 10).
func get_stamina_ratio() -> float:
	return _stamina / maxf(sprint_seconds, 0.001)


func get_walk_speed() -> float:
	return speed


func get_sprint_speed() -> float:
	return speed * sprint_multiplier


## Burn the tank while sprinting, refill it after a quiet spell.
##
## RUN AFTER `_control` AND BEFORE `_apply_motion`, which is the only ordering that works: the
## driver states its intent, the tank is charged for it and may refuse, and only then does the
## speed get read. Charged before the intent and a sprint is free for one frame; charged after the
## motion and an empty tank still moves you.
func _tick_stamina(delta: float) -> void:
	if _sprinting:
		_stamina = maxf(0.0, _stamina - delta)
		_regen_timer = 0.0
		if _stamina <= 0.0:
			_sprinting = false
		return

	_regen_timer += delta
	if _regen_timer >= stamina_regen_delay:
		var rate := sprint_seconds / maxf(stamina_refill_seconds, 0.001)
		_stamina = minf(sprint_seconds, _stamina + rate * delta)


func _on_scurried(_mouse: Mouse) -> void:
	refill_stamina()


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
