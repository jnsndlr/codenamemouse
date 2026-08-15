class_name MouseControl
extends Node
## One control, on one mouse: the half the dig controller and the four abilities have in common.
##
## THEY WERE FIVE SINGLETONS IN THE ARENA, EACH POINTED AT `../Player` -- *the* player, from back
## when there was one. That was the last thing in the game still assuming a single human, and it is
## exactly why a client could hold the dig button and watch nothing happen: a remote player's mouse
## is spawned into a chair at runtime, three hundred miles from the keyboard that drives it, and
## there was no dig controller anywhere near it. The intent had crossed the wire since step 2; the
## thing missing was somebody on the server to consume it.
##
## THE FIX IS NOT NETCODE. Every one of these five is a rule about an actor, and the survey said so
## in as many words: *"which mouse is this ability attached to" is not the same question as "whose
## eyes am I behind"*. So they are children of a mouse now. A mouse a person drives carries its own
## set, wherever that person is sitting, and the server runs a received DIG bit through the same
## code a local one goes through -- which is the same argument step 2 made for the input frame and
## step 4 made for putting a `Player` rather than a `Bot` in a remote seat.
##
## TWO QUESTIONS, AND KEEPING THEM APART IS THE WHOLE OF THIS FILE.
##
## - [method acts] -- *does this machine decide what happens to this mouse?*
## - [method watched] -- *is this the mouse this machine is looking at?*
##
## They were one question while there was one player on one machine, and they are not one question
## now. A host runs the rules for four people and draws a cursor for one. A client draws a cursor
## for a mouse whose rules resolve somewhere else entirely. So:
##
## - **Rules run where the simulation is.** A puppet's controls still aim, still measure reach,
##   still refuse -- what they must not do is *change* anything, because the change either already
##   happened elsewhere or is about to, and a second opinion arriving locally is a disagreement
##   dressed up as responsiveness.
## - **Presentation runs where the eyes are.** Cursors, the sonar echo, and the one line of text
##   that explains why a key did nothing belong to the local viewer alone. A remote player's
##   refusal printed on the host's HUD is the same species of bug as their dig cursor drawn in the
##   host's yard: correct code, pointed at the wrong person.
##
## A PUPPET STILL RUNS ITS COOLDOWNS AND NEVER ACTS ON THEM, which is not prediction and is the
## same shape checkpoint 3 already settled for the banner: both crews make decisions off a
## countdown, so it has to keep counting on every machine, and what a client must not do is let it
## expire into an action. An ability whose cooldown only existed on the server would leave the
## person pressing the key with a HUD that never greys out.

## Optional. Left empty by [MouseControls], which parents these to the mouse they belong to; an
## authored map may still point one at something by hand.
@export var player_path: NodePath
@export var network_path: NodePath

var _player: Mouse
var _network: TunnelNetwork
## Looked up rather than wired, and re-looked-up whenever it goes stale: the audits build and throw
## away several arenas in one process, and a cached freed director is a crash in the one place that
## answers "is anybody looking at this".
var _director: MatchDirector

## Seconds until this control may fire again, or 0 when it is up.
##
## `[MOVED HERE]` LIVED IN EIGHT SUBCLASSES AND WAS THE SAME THREE LINES IN EACH -- the same
## declaration, the same `maxf(0.0, _cooldown_left - delta)` in `_process`, and the same
## `cooldown_left()` accessor. Eight copies of a counter is eight places to remember when the rule
## about the counter changes, and the rule did change: **it has to go back to zero when you
## respawn**. One counter here means that is one line in [method _on_revived] and it cannot miss an
## ability, including one written next year. That is the whole argument -- not tidiness, but that
## the failure mode of the copies is silent.
##
## STILL SET BY THE SUBCLASSES, each to its own number and at its own moment, which is the part
## that genuinely differs: [CaveIn] charges two different lengths out of this one counter depending
## on whether the Brute was standing on the lawn.
##
## [ShoreUp] and [DigController] have no cooldown at all and simply never touch it. They do now
## carry the base `_process` that ticks it, which is one `maxf` on a float that is already zero --
## the price of the counter being in one place, and it is the right price.
var _cooldown_left: float = 0.0


func _ready() -> void:
	_player = get_node_or_null(player_path) as Mouse
	if _player == null:
		# THE PARENT, which is the whole point of the file. A control with no path is a control
		# fitted to a mouse, and there is exactly one mouse it could mean.
		_player = get_parent() as Mouse
	_network = get_node_or_null(network_path) as TunnelNetwork
	if _network == null:
		_network = get_tree().get_first_node_in_group(TunnelNetwork.NETWORK_GROUP) as TunnelNetwork
	if _player != null:
		_player.revived.connect(_on_revived)


## A WALL CLOCK, AND ON EVERY MACHINE. Cooldowns tick in `_process` rather than `_physics_process`
## for the reason each ability's own note gives: a countdown does not care how many physics steps
## the frame contained. And a puppet runs it too -- see the note at the top of this file -- so the
## person pressing the key has a HUD that greys out even though the ability itself resolves on the
## host.
##
## SUBCLASSES THAT WANT THEIR OWN `_process` MUST CALL `super(delta)`, which four of them do;
## GDScript overrides rather than chains. That is the one sharp edge of moving the counter up here,
## and it is why `match_audit.gd`'s respawn check ends by asserting that a cooldown still runs down
## on its own -- an override that forgot the line would otherwise pass every reset test in the file
## by never being on the clock at all.
func _process(delta: float) -> void:
	_cooldown_left = maxf(0.0, _cooldown_left - delta)


## Seconds until this control is ready. Zero means now.
func cooldown_left() -> float:
	return _cooldown_left


## Back on your feet, and everything you were waiting for is off the clock.
##
## `[ADDED]` EVERY ABILITY COMES BACK WITH YOU. A mouse that went down mid-fight had spent whatever
## it spent trying not to, and the six seconds it waits at the nest is already the price of losing
## -- serving the tail of a 40-second Second Wind on top of that is the same setback charged twice,
## and it is charged hardest on exactly the mouse that is having the worst time. Coming out of your
## own nest with your kit is what makes the respawn a fresh start rather than a partial one.
##
## FIRED ON BOTH MACHINES, which is why `Mouse` emits `revived` from `apply_pose` as well as from
## `revive_at` (see the note there). A host that reset the counters while the client went on
## counting would leave the person at that keyboard looking at chips that were grey for up to forty
## seconds after the ability had come back -- and the ability would work, which is worse than it
## not working: the HUD would be teaching them not to press a key that was ready.
##
## VIRTUAL ON PURPOSE, and nothing overrides it yet. [Barricade] is the near miss and stays as it
## is: its supply is not a counter but the boulders it has standing in the world, counted where they
## stand -- and three rocks wedged across three corridors are three rocks wedged across three
## corridors whether or not the Engineer who set them has since been scruffed. Getting up is not a
## reason for a wall somebody else is walking around to disappear.
func _on_revived(_mouse: Mouse) -> void:
	_cooldown_left = 0.0


## Does this machine decide what happens to this mouse?
##
## False on every mouse on a client, including the one the person at that keyboard is driving --
## `net_match.gd` makes them all puppets, and their rules resolve on the host.
func acts() -> bool:
	return _player != null and not _player.is_puppet()


## The match this control's mouse is in, or null in an arena a probe built without one.
##
## FOUND BY GROUP AND RE-FOUND WHENEVER IT GOES STALE. A control cannot be wired to a director at
## author time -- most mice in a match are spawned into a chair long after the scene was saved --
## and the audits stand up several arenas in one process, so a cached freed director would be a
## crash in the one call that answers "is anybody looking at this".
func director() -> MatchDirector:
	if not is_instance_valid(_director):
		_director = (
			get_tree().get_first_node_in_group(MatchDirector.DIRECTOR_GROUP) as MatchDirector
		)
	return _director


## Is this the mouse this machine is looking at?
##
## True when there is no director at all, because that is a probe or an audit that built an arena
## with one mouse in it -- and a suite that could not see its own cursor would be testing less than
## it thinks.
func watched() -> bool:
	if _player == null:
		return false
	var match_director := director()
	return match_director == null or match_director.local_mouse() == _player


## Say why a control did nothing -- to the local viewer, and to nobody else.
##
## Rides `dig_refused`, which is named for digging and is really the one line on screen that
## explains a control that just did nothing. Every refusal in these five files is that.
func explain(reason: String) -> void:
	if _network != null and watched():
		_network.dig_refused.emit(reason)


## Say what a control just DID -- to the local viewer, and to nobody else.
##
## THE OTHER VOICE, and a separate door because the HUD reads the two differently: a refusal is
## labelled and a note is not. [method explain] would have carried these too, and the first build
## of the stomp used it -- which is how "the ground gives way beneath you" came to be printed on
## screen under the word BLOCKED.
func note(what: String) -> void:
	if _network != null and watched():
		_network.dig_noted.emit(what)
