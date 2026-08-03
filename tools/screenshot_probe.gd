extends SceneTree
## Presses the screenshot key and checks a PNG lands, because the one failure mode that matters
## here looks exactly like success.
##
## The rule half of this feature is four lines and obviously correct. The half that can break
## silently is everything around it: the action never registered, so the key does nothing; the
## viewport handed back a null or blank image, so the file is written and empty; the folder was
## not created, so `save_png` returned an error nobody read. **In every one of those the tester
## presses P, sees nothing wrong, and comes back from the playtest with no evidence** -- which is
## the exact outcome the key exists to prevent, arriving quietly.
##
## So this asserts the artefact, not the call: a file that did not exist before exists after, and
## it decodes to an image the size of the window with something other than one colour in it.
##
## It also checks the toast is NOT in its own shot. That is the one piece of ordering in the
## feature -- dismiss, await `frame_post_draw`, capture -- and getting it wrong stamps a filename
## across the corner of every screenshot after the first.
##
## Needs a real renderer -- do NOT add --headless, the viewport hands back nothing.
##   godot --path . --script res://tools/screenshot_probe.gd

const SIZE := Vector2i(1280, 720)

var _failures: int = 0


func _initialize() -> void:
	DisplayServer.window_set_size(SIZE)
	root.content_scale_size = SIZE

	# Autoload nodes are parented before `_initialize` runs but have NOT had `_enter_tree` yet, so
	# the InputMap is still empty here -- `input_setup.gd` registers every action there. Asking
	# one frame early reports that nothing in the game is bound, which is alarming and wrong.
	await process_frame

	var shots: Node = root.get_node_or_null(^"Screenshot")
	if shots == null:
		print("BROKEN: no /root/Screenshot -- the autoload is not registered")
		quit(1)
		return

	_check("the action exists", InputMap.has_action("screenshot"))
	_check("it is bound to something", not InputMap.action_get_events("screenshot").is_empty())

	var folder: String = shots.call("folder")
	var before := _listing(folder)

	# Something with contrast in it, so "the image is blank" is a distinguishable failure from
	# "the image is fine". A title screen is a logo on a flat backdrop -- enough.
	var screen: Node = (load("res://scenes/ui/title.tscn") as PackedScene).instantiate()
	root.add_child(screen)
	for i in range(20):
		await process_frame

	await _press(shots)
	var first := _new_file(folder, before)
	_check("pressing the key wrote a file", first != "")
	if first != "":
		_check_image("the shot", folder.path_join(first))

	# Immediately again, while the first toast is still on screen. This is the ordering check.
	var between := _listing(folder)
	await _press(shots)
	var second := _new_file(folder, between)
	_check("pressing it again wrote a second file", second != "")
	if second != "" and first != "":
		_check("the two shots have different names", first != second)
		_check(
			"the second shot does not contain the first one's toast",
			not _differs_in_corner(folder.path_join(first), folder.path_join(second))
		)

	screen.queue_free()
	for i in range(5):
		await process_frame

	print("")
	if _failures > 0:
		print("=== %d FAILED. The screenshot key is not keeping evidence. ===" % _failures)
		quit(1)
		return
	print("=== the screenshot key writes real images to %s ===" % folder)
	quit()


## Send the key the way the player does, rather than calling `_capture` -- half the things that
## can break live between the keypress and the call.
func _press(shots: Node) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = KEY_P
	event.pressed = true
	Input.parse_input_event(event)
	# The capture awaits `frame_post_draw` and then writes; a handful of frames covers both, and
	# the toast is still up at the end of them.
	for i in range(10):
		await process_frame
		RenderingServer.force_draw()


# ------------------------------------------------------------------------------------- checking


## The top-left corner, where the toast is drawn. If the second shot caught the first shot's
## toast, this region differs between them; the rest of the frame is the same static menu.
func _differs_in_corner(one: String, two: String) -> bool:
	var a := Image.load_from_file(one)
	var b := Image.load_from_file(two)
	if a == null or b == null:
		return false
	var corner := Rect2i(0, 0, mini(420, a.get_width()), mini(90, a.get_height()))
	for y: int in range(corner.position.y, corner.end.y, 4):
		for x: int in range(corner.position.x, corner.end.x, 4):
			if a.get_pixel(x, y) != b.get_pixel(x, y):
				return true
	return false


func _check_image(what: String, path: String) -> void:
	var image := Image.load_from_file(path)
	if image == null:
		_check("%s decodes as a PNG" % what, false)
		return
	_check(
		"%s is the size of the window (%dx%d)" % [what, image.get_width(), image.get_height()],
		image.get_width() == SIZE.x and image.get_height() == SIZE.y
	)

	# A blank capture is the failure that writes a perfectly valid file, so "is there more than
	# one colour in it" is the assertion that separates a photograph from a rectangle.
	var first := image.get_pixel(0, 0)
	var varied := false
	for y: int in range(0, image.get_height(), 16):
		for x: int in range(0, image.get_width(), 16):
			if image.get_pixel(x, y) != first:
				varied = true
				break
		if varied:
			break
	_check("%s has something in it rather than one flat colour" % what, varied)


func _check(what: String, ok: bool) -> void:
	print("   %s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


# -------------------------------------------------------------------------------------- the disk


func _listing(folder: String) -> PackedStringArray:
	var dir := DirAccess.open(folder)
	if dir == null:
		return PackedStringArray()
	return dir.get_files()


func _new_file(folder: String, before: PackedStringArray) -> String:
	for name: String in _listing(folder):
		if not before.has(name):
			return name
	return ""
