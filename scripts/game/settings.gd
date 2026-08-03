class_name Settings
extends RefCounted
## The handful of things a player sets once and expects to stay set.
##
## Written to `user://settings.cfg` rather than held in memory, because the alternative is that
## every launch opens windowed and the tester re-picks fullscreen every time. That is a small
## annoyance here and a real one on a machine that is not this one, where every friction is
## spent out of the same evening the playtest is being run in.
##
## Deliberately NOT a save system and deliberately not an autoload. Two keys, read once when a
## menu opens and written when a menu changes one, is a static function on a class; an autoload
## would be a node in every scene tree for the sake of a boolean.
##
## No volume key, and that absence is on purpose: **there is no audio in this project at all** --
## no `.wav`, no `.ogg`, no `AudioStream` anywhere. A volume slider wired to nothing is worse
## than no slider, because it reads as a promise. It arrives with the first sound.

const PATH: String = "user://settings.cfg"
const SECTION: String = "display"


static func fullscreen() -> bool:
	return _file().get_value(SECTION, "fullscreen", false)


static func set_fullscreen(on: bool) -> void:
	var file := _file()
	file.set_value(SECTION, "fullscreen", on)
	file.save(PATH)
	apply_fullscreen(on)


## Push the stored preference at the window. Called on the way into the title screen, so a
## setting made last session is true again before anything is drawn.
static func apply_fullscreen(on: bool) -> void:
	# EXCLUSIVE_FULLSCREEN rather than FULLSCREEN would take the whole display and break the
	# Mission Control gesture people use to get out of a game that has stopped responding --
	# which, in an alpha, is the gesture that matters most.
	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_FULLSCREEN if on else DisplayServer.WINDOW_MODE_WINDOWED
	)


static func _file() -> ConfigFile:
	var file := ConfigFile.new()
	# A missing or corrupt file is the first-launch case, which is the common one. Defaults.
	file.load(PATH)
	return file
