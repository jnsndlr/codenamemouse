class_name Fade
extends MouseControl
## The Sneak's second ability: ten seconds of glass (GDD section 4).
##
## V has one meaning per class. For a Brute it is [Slam] and for a Generalist it is [BannerToss];
## for a Sneak it is this. **It was the last ability GDD section 4 named that nothing implemented**
## -- sonar, the stomp, the cave-in, Second Wind, shoring and the toss all arrived before it, and
## the class whose entire fantasy is *the one you don't see* spent six milestones being a mouse with
## slightly less health than the others.
##
## A TIMED ABILITY RATHER THAN A STANCE, and that is a revision of what section 4 wrote down. The
## original is a passive: hard to see while moving slowly, broken by attacking or sprinting -- which
## is very nearly the grass model (section 8) with the Sneak's name on it, and the grass model
## already applies to the Sneak. Two systems that both mean "go slowly and be harder to see" would
## have left the class ability doing nothing a patch of lawn does not already do, and doing it
## worse, because the lawn does not run out.
##
## Ten seconds on a cooldown is a different verb: it is a DECISION, made at a moment, with a clock
## on it. What the Sneak buys is not concealment -- the grass sells that to everybody -- but
## concealment **in the open**, where nobody else can have it, for long enough to cross a lane or
## sit out a search. And because it is spent rather than held, the counterplay is a real one: an
## enemy that suspects a Sneak is faded can wait, and the ability has an end.
##
## IT DOES NOT BREAK ON ATTACKING OR SPRINTING, which is the one part of section 4's version that
## was deliberately dropped rather than reshaped, and the open question is written up in the GDD.
## Ten flat seconds is the version that got built because it is the one that can be tuned by a
## single number; break conditions are a second design, and the first thing to try if a faded Sneak
## turns out to be able to simply walk into a nest and stand there.
##
## THE BACKSTAB IS NOT HERE. Striking from concealment is a passive on [Mouse] (`_resolve_swing`)
## and reads the same `hidden` predicate the minimap and the bots read, so it fires from a grass
## ambush exactly as it fires from a fade. Putting the multiplier in this file would have made it
## an effect of *this ability* rather than a property of being unseen, and the Sneak would have lost
## the version of the play that costs no cooldown at all.

## Went to glass, and for how long. For a HUD, and for an audit that would rather not read a float.
signal faded(seconds: float)
## The last of it wore off.
signal surfaced()
signal refused(reason: String)

@export_group("Ability")
## Which class may do this. An export like [Slam]'s and [SecondWind]'s, for the same reason: "who
## owns this capability" is a design question, and in this project that answer has form for moving.
@export_enum("Generalist", "Engineer", "Sneak", "Brute") var owner_class: int = MouseClass.SNEAK
## Seconds between fades. Set against the duration rather than against the other abilities: at 24
## and 10 a Sneak is invisible a little under half the time it is alive, which is often enough to
## be the class's normal way of crossing the yard and rare enough that a defender who waits one out
## has genuinely won something.
##
## LONGER THAN THE SONAR'S SIX AND SHORTER THAN THE WIND'S FORTY, which is the right neighbourhood:
## the scan is a thing you do repeatedly while playing the class, the wind is a once-per-run answer
## to one bad moment, and this is in between -- an approach, made a few times a life.
@export var cooldown: float = 24.0
## How long the veil lasts. The number the whole ability is, and the one to move first.
@export var duration: float = 10.0


## Whether the mouse was faded last tick, so `surfaced` fires once rather than every frame after.
var _was_faded: bool = false


func _ready() -> void:
	super()
	if _player == null:
		push_warning("fade: needs a mouse -- the ability is off")
		set_process(false)
		set_physics_process(false)
		return
	refused.connect(explain)


## The cooldown is a wall clock and lives on the frame, the same bargain [MouseControl] describes:
## a puppet counts it down and never acts on it, so the person pressing the key sees the HUD grey
## out and come back at the right moments even though the rule resolved somewhere else.
func _process(delta: float) -> void:
	# `super` FIRST: the cooldown lives in [MouseControl] now, and GDScript overrides rather than
	# chains -- an override that forgets this line is an ability that never comes back.
	super(delta)
	var now := _player != null and _player.is_faded()
	if _was_faded and not now:
		surfaced.emit()
	_was_faded = now


func is_ready() -> bool:
	return _cooldown_left <= 0.0 and _player != null and _player.mouse_class == owner_class


## READ ON THE PHYSICS TICK, NOT FROM AN INPUT EVENT -- see the long note in [Sonar], which this
## follows exactly. The short of it: a server has no event stream for a peer three hundred miles
## away, and an idle frame can run twice per physics tick, which fires an ability twice from one
## keypress at 120Hz and once at 60.
func _physics_process(_delta: float) -> void:
	if _player == null:
		return
	if not _player.input().is_pressed(InputFrame.Action.FADE):
		return
	if _player.is_scruffed():
		return
	# V belongs to three classes and means something different to each. A mouse that is not this one
	# leaves the bit alone -- the same class gate [Slam] and [BannerToss] use, and the reason none of
	# the three has to consume the press.
	if _player.mouse_class != owner_class:
		return
	go_to_glass()


## Fire it now. Public so the audits can exercise the rule without faking input routing, exactly as
## [method Sonar.scan] and [method SecondWind.take_breath] are. Returns whether the veil went up.
func go_to_glass() -> bool:
	if _player == null or _player.mouse_class != owner_class or _player.is_scruffed():
		return false
	if _cooldown_left > 0.0:
		refused.emit("still too solid -- %ds" % ceili(_cooldown_left))
		return false
	# CARRIERS ARE VISIBLE (GDD section 2), and the refusal is here as well as inside
	# [method Mouse.set_faded] because the two are answering different people. The mouse enforces the
	# rule; this tells the player why the key did nothing, which is the whole job of [MouseControl]'s
	# `explain`. Without it, a Sneak that had just stolen the banner would press V, watch nothing
	# happen, and reasonably conclude the ability was on cooldown.
	if _player.is_carrying():
		refused.emit("the banner gives you away")
		return false

	# THE CLOCK IS SET ON EVERY MACHINE AND THE VEIL WITH IT, above the puppet check, which is the
	# placement [Slam], [Sonar] and [SecondWind] all argue for. Here it buys the most of any of them:
	# a client's own mouse is a puppet, so a fade gated on `acts()` would leave the person who
	# pressed the key fully visible until a pose came back over the wire -- a third of a second of
	# standing in the open believing you are hidden. The server's FADED bit then simply agrees with
	# what this end already did.
	_cooldown_left = cooldown
	_player.set_faded(duration)
	faded.emit(duration)
	return true
