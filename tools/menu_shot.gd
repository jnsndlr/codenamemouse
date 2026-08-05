extends SceneTree
## Photographs the M6.5 menus at the window sizes the alpha will actually meet, because "test
## common resolutions" is a checklist item nobody performs by resizing a window twenty times.
##
## The thing being checked is `HudSkin.scale_for`. Every piece of furniture in this game is
## written as proportions against a 1280x720 reference and multiplied on the way to the screen,
## and the menus go through the same function so they grow with the HUD -- but the clamp at 0.75
## and 2.5 means the smallest and largest windows are where that stops being true. Those two are
## the shots worth looking at.
##
## Needs a real renderer -- do NOT add --headless, it will hang on the first force_draw.
##   godot --path . --script res://tools/menu_shot.gd

const OUT := "user://"

## The ends of the range and the two sizes in the middle of it. 1280x800 is the MacBook Air
## default scaled logical size, which is the machine M6.5 is aimed at.
const SIZES: Array[Vector2i] = [
	Vector2i(1280, 720),
	Vector2i(1280, 800),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
]


func _initialize() -> void:
	for size: Vector2i in SIZES:
		DisplayServer.window_set_size(size)
		root.content_scale_size = size
		await _shoot(size, "title", false)
		await _shoot(size, "controls", true)
		await _shoot(size, "multiplayer", false, "_show_multiplayer")

	DisplayServer.window_set_size(SIZES[0])
	root.content_scale_size = SIZES[0]
	await _shoot_lobby()
	await _shoot_pause()

	print("written to %s" % ProjectSettings.globalize_path(OUT))
	quit()


## The pause menu over a running match, which is the only place it can be looked at: the scrim
## has to make the yard read as STOPPED rather than as running behind a tint, and that is a
## judgement about a specific pile of bright dirt and dark trenches.
func _shoot_pause() -> void:
	var arena: Node = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(arena)
	for i in range(60):
		await process_frame

	var menu: Node = arena.get_node("PauseMenu")
	menu.call("open")
	for i in range(10):
		await process_frame

	RenderingServer.force_draw()
	root.get_texture().get_image().save_png(OUT + "menu_pause.png")
	print("shot: menu_pause.png (tree paused: %s)" % paused)

	# Un-pause before the next frame runs, or the tool's own awaits never resume.
	menu.call("close")
	arena.queue_free()
	for i in range(5):
		await process_frame


## The host's lobby, which cannot be photographed without a socket: every line on it is read off a
## live session, and a version of this that faked one would be a picture of a different screen. So it
## opens a real one, on a port nothing else in `tools/` uses, and closes it afterwards.
func _shoot_lobby() -> void:
	var net := root.get_node_or_null(^"Net")
	if net == null:
		print("skipped: menu_lobby.png needs the Net autoload")
		return
	if net.call("host", 47899) != OK:
		print("skipped: menu_lobby.png -- could not open a socket to photograph")
		return

	var screen: Node = (load("res://scenes/ui/lobby.tscn") as PackedScene).instantiate()
	root.add_child(screen)
	for i in range(20):
		await process_frame

	RenderingServer.force_draw()
	root.get_texture().get_image().save_png(OUT + "menu_lobby.png")
	print("shot: menu_lobby.png")

	screen.queue_free()
	for i in range(5):
		await process_frame
	net.call("go_offline")


func _shoot(size: Vector2i, what: String, open_controls: bool, page: String = "") -> void:
	var screen: Node = (load("res://scenes/ui/title.tscn") as PackedScene).instantiate()
	root.add_child(screen)
	for i in range(20):
		await process_frame

	if open_controls:
		# The controls sheet has no public opener -- it is a menu button. Reach past that rather
		# than widening the screen's API for a screenshot tool.
		screen.call("_show_controls")
		for i in range(10):
			await process_frame
	elif not page.is_empty():
		screen.call(page)
		for i in range(10):
			await process_frame

	RenderingServer.force_draw()
	var name := "menu_%s_%dx%d.png" % [what, size.x, size.y]
	root.get_texture().get_image().save_png(OUT + name)
	print("shot: %s" % name)
	screen.queue_free()
	for i in range(5):
		await process_frame
