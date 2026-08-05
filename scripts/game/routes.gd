class_name Routes
extends RefCounted
## Where the scenes are, and the three moves between them.
##
## Through M6 this file had nothing to say: `arena.tscn` was the main scene and that was the
## entire application -- nothing in `scripts/` called `change_scene`, `quit`, or touched `paused`.
## M6.5 makes a match something you enter and leave, and the reason that is worth doing is not the
## title screen. It is that **M7 needs exactly this seam**: joining a server, leaving a match, and
## being handed back to a lobby are all "swap the scene under the player", and a project where
## that has never once happened is a project where it does not work.
##
## So the paths live in one place rather than as string literals in whichever menu happens to need
## them, and `to_match` gets a name now so that the day it takes a server address, there is one
## call site to change.

const TITLE: String = "res://scenes/ui/title.tscn"
const ARENA: String = "res://scenes/maps/arena.tscn"
const LOBBY: String = "res://scenes/ui/lobby.tscn"


## Into a match.
##
## IT STILL TAKES NO SERVER ADDRESS, and that turned out to be the right shape rather than an
## unfinished one. `NetSession` is an autoload, so by the time anybody calls this the socket is
## already open and the seats are already claimed -- the arena has nothing to be told. What M7
## actually wanted was somewhere to stand *between* connecting and playing. See [method to_lobby].
static func to_match(from: Node) -> void:
	_go(from, ARENA)


## The room you wait in with the socket already open.
##
## This is the scene that answers a question the title screen could not: connecting and entering a
## match are separate moments, and somebody who has joined has to be *somewhere* until the host
## starts. `title_screen.gd` has had a comment about that gap since M6.5, and `--play <seconds>` has
## been faking it for the audits ever since — a delay standing in for a room.
static func to_lobby(from: Node) -> void:
	_go(from, LOBBY)


## Why we are being sent back, for the screen that has to explain it.
##
## A STATIC RATHER THAN AN ARGUMENT PASSED ALONG, because the node that knows the reason is being
## freed by the very transition that has to carry it -- there is nobody to hand it to. It lives here
## rather than on `NetSession` because it is a sentence for a human, not a fact about a socket, and
## the session has managed to know nothing about screens so far.
static var _why: String = ""


## Back out to the title screen, optionally saying why. Unpauses on the way, because
## `get_tree().paused` outlives the scene that set it -- quitting to the title from a pause menu
## otherwise lands you on a frozen title screen whose buttons do not respond.
static func to_title(from: Node, why: String = "") -> void:
	_why = why
	from.get_tree().paused = false
	_go(from, TITLE)


## Read once and forgotten. Left lying about, a reason would turn up on the next visit to the title
## screen and explain a disconnection that happened twenty minutes ago.
static func take_why() -> String:
	var was := _why
	_why = ""
	return was


static func _go(from: Node, path: String) -> void:
	# Deferred because both callers are inside an input handler or a button signal, and changing
	# the scene frees the node that is mid-call.
	from.get_tree().call_deferred("change_scene_to_file", path)
