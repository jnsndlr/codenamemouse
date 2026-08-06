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


func _ready() -> void:
	_player = get_node_or_null(player_path) as Mouse
	if _player == null:
		# THE PARENT, which is the whole point of the file. A control with no path is a control
		# fitted to a mouse, and there is exactly one mouse it could mean.
		_player = get_parent() as Mouse
	_network = get_node_or_null(network_path) as TunnelNetwork
	if _network == null:
		_network = get_tree().get_first_node_in_group(TunnelNetwork.NETWORK_GROUP) as TunnelNetwork


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
