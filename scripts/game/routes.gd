class_name Routes
extends RefCounted
## Where the scenes are, and the two moves between them.
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


## Into a match. Takes no arguments today; at M7 this is where a seat or a server address goes.
static func to_match(from: Node) -> void:
	_go(from, ARENA)


## Back out to the title screen. Unpauses on the way, because `get_tree().paused` outlives the
## scene that set it -- quitting to the title from a pause menu otherwise lands you on a frozen
## title screen whose buttons do not respond.
static func to_title(from: Node) -> void:
	from.get_tree().paused = false
	_go(from, TITLE)


static func _go(from: Node, path: String) -> void:
	# Deferred because both callers are inside an input handler or a button signal, and changing
	# the scene frees the node that is mid-call.
	from.get_tree().call_deferred("change_scene_to_file", path)
