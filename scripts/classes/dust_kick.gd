class_name DustKick
extends MouseControl
## The Sneak's third ability: kick up a screen of earth and be gone (GDD section 4).
##
## X has one meaning per class, the way Q and V do. For an Engineer it is [Barricade]; for a Sneak
## it is this. The Sneak is the first class in the game to want three abilities, which is not
## greed -- it is what a class made entirely of *not being seen* needs in order to have a second
## and a third answer to being seen anyway.
##
## THE THREE ARE DELIBERATELY THREE DIFFERENT VERBS, and that is the argument for building this one
## at all rather than tuning [Fade] harder:
##
##   Q [Sonar]  -- **before**. What is down there, and who is near me.
##   V [Fade]   -- **during**. Cross ground you could not otherwise cross.
##   X this one -- **after**. It has gone wrong and you are leaving.
##
## Fade cannot do this job and should not be made able to. It takes a quarter of a second to arrive,
## it is refused while carrying, and it is beaten at arm's length -- all correct for an approach and
## all useless with a Brute already on top of you. What the moment needs is something that works
## instantly, at contact range, against something that is already looking at you. So: a wall you
## cannot see through, for one second.
##
## ONE SECOND IS THE WHOLE BALANCE, and the number was chosen against `Spotting.memory_seconds`
## rather than against a feeling. A contact does not disappear when the cloud goes up -- it goes
## stale and stays pinned where you last were, fading over fifteen seconds. So the dust does not buy
## an escape, it buys **one second in which the other mouse has to guess which way you went**, and
## everything after that is the ordinary business of having broken line of sight. A screen long
## enough to actually lose somebody in would be a different and much worse ability.
##
## IT HIDES YOUR ENEMY FROM YOU TOO, and that is a feature rather than an oversight worth
## engineering around. The cloud is geometry in the world; it does not know who threw it. A Sneak
## that pops it and stays to fight is fighting blind, which is the reason this is an exit rather
## than a duelling tool -- and it is why the ability needs no cost beyond its cooldown.

signal kicked(at: Vector3)
signal refused(reason: String)

@export_group("Ability")
@export_enum("Generalist", "Engineer", "Sneak", "Brute") var owner_class: int = MouseClass.SNEAK
## Seconds between screens. Between the sonar's six and the fade's twenty-four: this is the panic
## button, and a panic button on a long cooldown is one you hoard rather than use. Twelve is about
## two engagements.
@export var cooldown: float = 12.0
## How far the cloud reaches, in metres. **Four**, which is a starting number and expected to move
## -- it is a little under half of `Spotting.sight_range` and about ten body lengths, so it fills the
## space around a scrap without walling off a lane.
@export var radius: float = 4.0


func _ready() -> void:
	super()
	if _player == null:
		push_warning("dust kick: needs a mouse -- the ability is off")
		set_process(false)
		set_physics_process(false)
		return
	refused.connect(explain)


func is_ready() -> bool:
	return _cooldown_left <= 0.0 and _player != null and _player.mouse_class == owner_class


## READ ON THE PHYSICS TICK, NOT FROM AN INPUT EVENT -- see the long note in [Sonar], which this
## follows exactly.
func _physics_process(_delta: float) -> void:
	if _player == null:
		return
	if not _player.input().is_pressed(InputFrame.Action.DUST):
		return
	if _player.is_scruffed():
		return
	# X belongs to two classes now. An Engineer's press builds a barricade and a Sneak's throws
	# this, and neither node has to consume the press because only one `owner_class` can match.
	if _player.mouse_class != owner_class:
		return
	kick()


## Throw it now. Public so the audits can exercise the rule without faking input routing, exactly as
## [method Sonar.scan] and [method Fade.go_to_glass] are.
func kick() -> bool:
	if _player == null or _player.mouse_class != owner_class or _player.is_scruffed():
		return false
	if _cooldown_left > 0.0:
		refused.emit("the dust has not settled -- %ds" % ceili(_cooldown_left))
		return false

	# AT YOUR FEET, NOT AT THE CURSOR, and that is the one place this ability differs from every
	# other aimed thing a mouse does. The cursor is the steering wheel (GDD section 9), so aiming
	# means turning to look at where you are throwing -- which is precisely what somebody running
	# away cannot afford to do, and this is the ability for somebody running away. A thrown screen
	# would also be a screen you could put between two OTHER mice, which is a different and much
	# stronger ability than the one being built.
	var at := _player.global_position

	# THE CLOUD GOES UP ON EVERY MACHINE, above the puppet check, which is the placement [Slam],
	# [Sonar] and [Fade] all argue for -- and it carries further here than in any of them. This is
	# the panic button: a client whose screen appeared a third of a second late, after a pose came
	# back over the wire, would be a player who pressed X, watched nothing happen, and got scruffed.
	# The dust is a thing that happened to the world and the world is on every machine.
	_raise_screen(at)
	_cooldown_left = cooldown

	if not acts():
		return true
	kicked.emit(at)
	return true


## The screen itself. Parented to the tunnel network rather than to the mouse, because a cloud is a
## thing standing in a place -- a child of the Sneak would follow it out of its own dust.
func _raise_screen(at: Vector3) -> void:
	var parent: Node = _network if _network != null else _player.get_parent()
	if parent == null:
		return
	# Seeded from the position, rounded to the centimetre first: a raw float seed differs in its
	# last bit between two machines that agree about everything a player could see. The same line
	# [Slam] uses, for the same reason.
	var seed_value := int(at.x * 100.0) * 73856093 ^ int(at.z * 100.0)
	DustScreen.raise(parent, at, seed_value, _player.get_plane(), radius)
