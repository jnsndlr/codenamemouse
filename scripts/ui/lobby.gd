extends Control
## The room you wait in with the socket already open.
##
## It exists because **connecting and entering a match are two different moments**, and until now
## there was nowhere to stand between them. `title_screen.gd` has carried a comment about that gap
## since M6.5 and the audits have been faking it with `--play <seconds>` ever since — a delay standing
## in for a room. A joining client is seated by `NetSession` the instant it connects, which is before
## the arena it will play in exists; this is the scene that is on screen while that is true.
##
## THE HOST DECIDES WHEN, AND SAYS SO OVER THE WIRE. Pressing Start broadcasts `START` and then loads
## the arena locally — it does not wait for acknowledgement, because there is nothing useful to do
## with a refusal and the message is reliable. Everyone else is sitting in `_on_match_starting`.
##
## IT READS THE ROSTER, IT DOES NOT KEEP ONE. `Net.seats()` is the authority on a host and the seats
## are claimed before anybody reaches this screen, so the list below is a view and `seating_changed`
## is when to redraw it. A client's own copy of the table arrives with `SEATS` once it is in an arena,
## so a client here shows what it honestly knows — that it is connected, and what it is waiting for —
## rather than a roster it would have to invent.
##
## BUILT IN CODE, following `title_screen.gd` and `look_panel.gd`, for the same reason those do: the
## interesting part is a list whose length depends on who turned up, and a scene file cannot express
## that without being hand-edited every time the crew size changes.

const BACKDROP: Color = Color(0.13, 0.06, 0.06)
const GAP: float = 12.0

var _menu: VBoxContainer
var _start: Button
## Grabbed AFTER the column is in the tree. `grab_focus` on a node that has not entered the scene
## does nothing at all, silently, which is why the first version of this drew no focus ring -- the
## title screen already had the order right and this file had copied everything except that.
var _focus_first: Button
## Polled as well as signalled, because "connecting" becoming "connected" is a transport status
## change and nothing emits for it.
var _since_poll: float = 0.0
## What the page was last drawn from. **Compared before rebuilding, and that is not an optimisation.**
## A poll that rebuilds unconditionally throws the menu away twice a second, and with it whichever
## button had keyboard focus -- so Start Match loses its focus ring half a second after the lobby
## opens, and a pad user watching for it has nothing to follow.
var _drawn: String = ""


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	get_tree().paused = false

	var backdrop := ColorRect.new()
	backdrop.color = BACKDROP
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(backdrop)

	_rebuild()
	# A resize forces a redraw whatever the session says; everything else asks first.
	get_viewport().size_changed.connect(_rebuild)
	Net.seating_changed.connect(_refresh)
	Net.match_starting.connect(_on_match_starting)
	Net.wire_lost.connect(_on_wire_lost)

	# A LOBBY WITH NO SOCKET IS A DEAD END, and reaching one means somebody navigated here by hand or
	# a host failed between the button and this scene. Going back beats sitting in a room that can
	# never start.
	if not Net.is_online():
		Routes.to_title(self)
		return
	# Said out loud because the audits have to know this scene was reached rather than the title, and
	# because "which room was I in" is the first question of any report about a match that never
	# started.
	Net.log_line(
		"lobby: hosting on %d, waiting to start" % Net.hosting_port() if Net.is_server()
		else "lobby: joined %s, waiting for the host" % Net.joined_address()
	)
	_apply_command_line()


## `--lobby-start <seconds>`: press Start without a person.
##
## The same argument `--play` makes one screen up, for the one moment that screen cannot reach. Start
## is the only thing in this game a *host* does that a client can observe, and `START` is the only
## message in the protocol whose receiver has no arena — so without a way to press this button
## headlessly, the whole lobby handshake could only ever be demonstrated by hand.
func _apply_command_line() -> void:
	if not Net.is_server():
		return
	var args := OS.get_cmdline_user_args()
	var at := args.find("--lobby-start")
	if at < 0:
		return
	var next := String(args[at + 1]) if at + 1 < args.size() else ""
	get_tree().create_timer(maxf(0.1, next.to_float())).timeout.connect(_on_start)


func _process(delta: float) -> void:
	_since_poll += delta
	if _since_poll >= 0.25:
		_since_poll = 0.0
		_refresh()


## Everything on this page that can change, as one string. Cheap to build, and comparing it is what
## keeps a poll from being a rebuild.
func _fingerprint() -> String:
	var roster := Net.seats()
	return "%s|%s|%s" % [Net.is_established(), roster.describe(), Net.hosting_port()]


func _refresh() -> void:
	if _fingerprint() != _drawn:
		_rebuild()


# ------------------------------------------------------------------------------------------ the room


func _rebuild() -> void:
	var s := HudSkin.scale_for(get_viewport_rect().size)
	_drawn = _fingerprint()
	if _menu != null:
		_menu.queue_free()

	_menu = VBoxContainer.new()
	_menu.theme = MenuSkin.theme(s)
	_menu.alignment = BoxContainer.ALIGNMENT_CENTER
	_menu.add_theme_constant_override(&"separation", int(GAP * s))
	_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	_menu.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var heading := Label.new()
	heading.text = "Hosting" if Net.is_server() else "Joining"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_override(&"font", HudSkin.font())
	heading.add_theme_font_size_override(&"font_size", int(MenuSkin.TITLE_SIZE * s))
	heading.add_theme_color_override(&"font_color", HudSkin.GOLD)
	_menu.add_child(heading)

	if Net.is_server():
		_build_host(s)
	else:
		_build_guest(s)

	add_child(_menu)
	move_child(_menu, 1)
	if _focus_first != null:
		_focus_first.grab_focus()


## What to tell your players, and the button that starts it.
##
## THE INSTRUCTIONS ARE HONEST ABOUT WHAT THEY DO NOT KNOW. A LAN address is the only one this machine
## can actually determine; over the internet the useful number is the router's public address with
## this port forwarded, and printing the LAN address alone would be a number that works in one house
## and silently fails everywhere else. So it says both, and says which is which.
func _build_host(s: float) -> void:
	var lan := Net.lan_address()
	var port := Net.hosting_port()
	if lan.is_empty():
		_menu.add_child(_note(
			"Could not work out this machine's address on the network. "
			+ "Hosting on port %d." % port, s, MenuSkin.WARN
		))
	else:
		_menu.add_child(_address_line("%s:%d" % [lan, port], s))
		_menu.add_child(_note(
			"On the same network, that is what your players type. "
			+ "Over the internet they need your router's public address "
			+ "with port %d forwarded to this machine." % port, s
		))

	_menu.add_child(_spacer(s))
	_menu.add_child(_note(_roster_text(), s, HudSkin.TEXT))
	_menu.add_child(_spacer(s))

	_start = MenuSkin.button("Start Match", s)
	_focus_first = _start
	_menu.add_child(_row(_start, _on_start))
	_menu.add_child(_row(MenuSkin.button("Cancel", s), _on_leave))
	_menu.add_child(_note(
		"Empty chairs are filled by bots, so you can start alone.", s
	))


## A guest has nothing to decide and should not be given a button that implies otherwise.
func _build_guest(s: float) -> void:
	var established := Net.is_established()
	_menu.add_child(_address_line(Net.joined_address(), s))
	_menu.add_child(_note(
		"Connected. Waiting for the host to start the match."
		if established else "Connecting...", s,
		HudSkin.TEXT_DIM if established else MenuSkin.WARN
	))
	_menu.add_child(_spacer(s))
	_focus_first = MenuSkin.button("Leave", s)
	_menu.add_child(_row(_focus_first, _on_leave))


## The address, big enough to read off a screen and across a room. This is a number somebody has to
## say out loud over a voice call, so it is the largest thing on the page after the heading.
func _address_line(text: String, s: float) -> Label:
	var made := Label.new()
	made.text = text
	made.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	made.add_theme_font_override(&"font", HudSkin.font())
	made.add_theme_font_size_override(&"font_size", int(MenuSkin.BUTTON_SIZE * 1.5 * s))
	made.add_theme_color_override(&"font_color", HudSkin.TEXT)
	return made


## Who has actually turned up. Counted off the seat table rather than the peer list, because a peer
## the match was full for is connected and is not playing, and the number that matters is chairs.
func _roster_text() -> String:
	var roster := Net.seats()
	var rows := PackedStringArray()
	for side: int in [Team.BLUE, Team.RED]:
		var names := PackedStringArray()
		for seat: int in range(roster.crew_size()):
			names.append("human" if roster.is_human(side, seat) else "bot")
		rows.append("%s  %s" % [Team.name_of(side), " ".join(names)])
	var humans := roster.total_humans()
	return "%d %s in the match\n%s" % [
		humans, "player" if humans == 1 else "players", "\n".join(rows),
	]


## A note in a centring row. The row is load-bearing: an autowrapping `Label` added straight to the
## column gets stretched to the column's width, which is the screen, so it never reaches a wrap point
## and runs off both edges. See the same note on `title_screen._row`.
func _note(text: String, s: float, tone: Color = HudSkin.TEXT_DIM) -> Control:
	return _row(MenuSkin.note(text, s, tone), Callable())


func _spacer(s: float) -> Control:
	var made := Control.new()
	made.custom_minimum_size = Vector2(0.0, GAP * s)
	return made


func _row(what: Control, pressed: Callable) -> Control:
	if what is Button and not pressed.is_null():
		(what as Button).pressed.connect(pressed)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(what)
	return row


# -------------------------------------------------------------------------------------- the moves


## Tell everybody, then go. The order matters: `change_scene_to_file` is deferred, so the broadcast is
## already queued on a transport that is an autoload and keeps pumping across the swap.
func _on_start() -> void:
	Net.start_match()
	Routes.to_match(self)


func _on_match_starting() -> void:
	Routes.to_match(self)


## Leaving is a decision, so the socket closes with it. Without this you would return to a title
## screen still quietly hosting, and the next Play would drop you into a match with a stranger in it.
func _on_leave() -> void:
	Net.go_offline()
	Routes.to_title(self)


func _on_wire_lost() -> void:
	Routes.to_title(self)
