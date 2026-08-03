extends CanvasLayer
## A key that keeps evidence, because one playtest otherwise produces one set of it and then it
## is gone.
##
## M6.5 hands a build to somebody on another Mac, and the whole value of that evening is the
## report that comes back. File logging is on (`project.godot`, `[debug]`) so a crash leaves a
## trace; this is the other half, for everything that goes wrong *without* crashing -- geometry
## that looks wrong, a HUD that lands off-screen at their resolution, the pixel pass rendering
## differently on their GPU. None of those raise anything. All of them photograph.
##
## AN AUTOLOAD, and that is a deliberate departure from `settings.gd`, which argues at length that
## two keys read on demand are a static function and that an autoload would be "a node in every
## scene tree for the sake of a boolean". Both halves of that reasoning invert here: this
## genuinely has to *be* a node in every scene tree -- it listens for a key and draws a
## confirmation -- and it has to survive `change_scene`, since a tester photographs the title
## screen, the controls sheet and the match, and those are three different scenes.
##
## THE SHOTS AND THE LOG SHARE A FOLDER, on purpose. `user://screenshots/` sits beside Godot's own
## `user://logs/`, so what comes back with the build is *one* folder to zip rather than two places
## to go looking. The toast prints the real absolute path, because `user://` means nothing to
## anybody who has not written a Godot game and on macOS it resolves somewhere inside ~/Library
## that nobody would find by looking.

## Where the shots land, next to `user://logs/`.
const FOLDER: String = "user://screenshots/"
const PREFIX: String = "mouse"

## How long the confirmation stays up: long enough to read a path off, short enough to be gone
## before you have lined up the next shot.
const TOAST_SECONDS: float = 3.5
const TOAST_FADE: float = 0.6

const PAD: float = 12.0
const TEXT_SIZE: int = 14
const MARGIN: float = 16.0

var _line: String = ""
var _bad: bool = false
var _left: float = 0.0
var _panel: Control


func _ready() -> void:
	# The pause menu freezes the tree, and a paused menu is a thing worth photographing -- a HUD
	# that lands wrong is easiest to report with the game held still.
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Above the pause menu's 100: a screenshot of the pause menu should still confirm itself.
	layer = 110

	_panel = Control.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.draw.connect(_draw_toast)
	add_child(_panel)

	visible = false
	set_process(false)


func _input(event: InputEvent) -> void:
	if not event.is_action_pressed("screenshot"):
		return
	get_viewport().set_input_as_handled()
	_capture()


# -------------------------------------------------------------------------------- the capture


func _capture() -> void:
	# The toast must not appear in its own successor. Pressing twice inside three seconds is the
	# ordinary case -- photograph a thing, then photograph it from the other side -- and without
	# this the second shot carries the first one's filename across the corner.
	_dismiss()

	# A viewport texture read before the frame is drawn is the previous frame at best and blank at
	# worst. This is the documented point at which it is neither, and it is also what makes
	# `_dismiss` above actually take effect in the image rather than one frame later.
	await RenderingServer.frame_post_draw

	var image := get_viewport().get_texture().get_image()
	if image == null:
		push_warning("screenshot: the viewport handed back no image")
		_show("Screenshot failed", true)
		return

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(FOLDER))
	var path := _free_path()
	var err := image.save_png(path)
	if err != OK:
		push_warning("screenshot: could not write %s (error %d)" % [path, err])
		_show("Screenshot failed — could not write to %s" % folder(), true)
		return

	# Into the log as well as onto the screen, so a report that arrives as a log file alone still
	# says how many shots were taken and when.
	print("screenshot: %s" % ProjectSettings.globalize_path(path))
	_show("Saved to %s" % folder(), false)


## A name nothing else has. Sortable first -- a session's shots sit in the order they were taken.
##
## THE SUFFIX IS NOT DEFENSIVE, IT IS THE ORDINARY CASE. The system clock reads to the second and
## a tester photographing a thing from two angles does it in well under one, so a bare timestamp
## silently overwrites the first shot with the second. `tools/screenshot_probe.gd` caught exactly
## that, which is the whole argument for a probe here: the key worked, the toast confirmed, the
## file existed, and half the evidence was gone.
func _free_path() -> String:
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_")
	var base := FOLDER.path_join("%s-%s" % [PREFIX, stamp])
	if not FileAccess.file_exists(base + ".png"):
		return base + ".png"
	var n := 2
	while FileAccess.file_exists("%s-%d.png" % [base, n]):
		n += 1
	return "%s-%d.png" % [base, n]


## The real path, for a human to read. Public because the controls sheet says it too -- somebody
## who has not pressed the key yet still needs to know where the shots will be.
func folder() -> String:
	return ProjectSettings.globalize_path(FOLDER)


## The folder holding both `screenshots/` and Godot's own `logs/` -- the one thing to ask a tester
## to zip and send back. Named here rather than derived from `folder()` by walking up two levels,
## which would depend on whether `globalize_path` keeps a trailing slash.
func user_folder() -> String:
	return ProjectSettings.globalize_path("user://")


# ---------------------------------------------------------------------------------- the toast


func _show(body: String, bad: bool) -> void:
	_line = body
	_bad = bad
	_left = TOAST_SECONDS
	visible = true
	_panel.modulate = Color.WHITE
	set_process(true)
	_panel.queue_redraw()


## Off now, not faded out. Called immediately before a capture.
func _dismiss() -> void:
	_left = 0.0
	visible = false
	set_process(false)


func _process(delta: float) -> void:
	_left -= delta
	if _left <= 0.0:
		_dismiss()
		return
	# Faded here rather than in `_draw_toast`, because `HudSkin.panel` paints through a shared
	# static StyleBoxFlat -- tinting the canvas item is the one way to fade it that does not
	# reach into the skin and change the colour of every other panel in the game.
	_panel.modulate = Color(1.0, 1.0, 1.0, clampf(_left / TOAST_FADE, 0.0, 1.0))


func _draw_toast() -> void:
	var s := HudSkin.scale_for(_panel.get_viewport_rect().size)
	var size := int(TEXT_SIZE * s)
	var width := HudSkin.font().get_string_size(_line, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x

	# Top left: the score bug owns top centre, the minimap bottom left and the roster bottom
	# right, so this is the one corner of the HUD with nothing already in it.
	var box := Rect2(
		Vector2(MARGIN * s, MARGIN * s),
		Vector2(width + PAD * s * 2.0, float(size) + PAD * s * 1.6)
	)
	HudSkin.panel(_panel, box, 8.0 * s)
	HudSkin.text(
		_panel,
		box.grow(-PAD * s),
		_line,
		size,
		HudSkin.HEALTH_LOW if _bad else HudSkin.TEXT
	)
