extends Control
## What just happened, and the one thing you must not miss.
##
## THIS FILE USED TO BE THE WHOLE HUD -- score, clock, banner states, feed. The score and the
## clock are furniture that has to be readable at a glance and never moves, so they are now a
## drawn panel (score_bug.gd) alongside a minimap and a crew roster. What is left here is the
## half that is text by nature: a feed of lines that appear and expire, and the announcement
## that takes the middle of the screen.
##
## THE FEED SITS BOTTOM-LEFT OF CENTRE, next to the minimap, which is where the concept art
## always had it. It was parked under the score through M3 for one honest reason -- the bottom
## left was empty and an event nobody reads may as well not fire. The minimap fills that corner
## now, so the feed goes back where it belongs, and it stacks UPWARD from the bottom so the
## newest line is always at the same height: the one your eye is already on.
##
## THE CENTRE LINE IS RESERVED, and stays reserved. Two things only: the match is over, and you
## are flat on your back. Anything else that takes the middle of the screen is competing with
## the reason it is trusted.

@export var director_path: NodePath

@export_group("Feed")
## How many recent events stay on screen.
@export var feed_lines: int = 4
## How long a line lasts before it fades.
@export var feed_seconds: float = 6.0
## Left edge, in pixels. Clear of the minimap panel in the corner.
@export var feed_left: float = 224.0
## Gap between the bottom of the screen and the newest line.
@export var feed_bottom: float = 26.0
@export var feed_spacing: float = 21.0

var _director: MatchDirector
var _centre: Label
var _feed: Array[Label] = []
## {text, age}, newest last.
var _events: Array[Dictionary] = []


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_centre = _label(40, Color(1.0, 0.95, 0.78))
	for i in range(feed_lines):
		_feed.append(_label(16, Color(0.92, 0.90, 0.84)))

	_director = get_node_or_null(director_path) as MatchDirector
	if _director == null:
		push_warning("match HUD: no director at %s" % director_path)
		return
	_director.event.connect(_on_event)


func _on_event(text: String) -> void:
	_events.push_back({"text": text, "age": 0.0})
	while _events.size() > feed_lines:
		_events.pop_front()


func _process(delta: float) -> void:
	if _director == null:
		return
	_centre.text = _centre_line()
	_centre.reset_size()
	var screen := get_viewport_rect().size
	_centre.position = Vector2(
		screen.x * 0.5 - _centre.size.x * 0.5, screen.y * 0.34
	)
	_tick_feed(delta)


## The big line in the middle of the screen. Reserved for the two things you must not miss:
## the match being over, and being flat on your back.
func _centre_line() -> String:
	if not _director.is_playing():
		var winner := _director.get_winner()
		return "DRAW" if winner == MatchDirector.DRAW else "%s WINS" % Team.name_of(winner)

	var player := _director.get_player()
	if player != null and player.is_scruffed():
		return "SCRUFFED  --  back in %d" % ceili(_director.respawn_left(player))
	return ""


func _tick_feed(delta: float) -> void:
	for entry: Dictionary in _events:
		entry["age"] = entry["age"] + delta
	while not _events.is_empty() and _events[0]["age"] > feed_seconds:
		_events.pop_front()

	var bottom := get_viewport_rect().size.y - feed_bottom
	for i in range(_feed.size()):
		var line := _feed[i]
		if i >= _events.size():
			line.text = ""
			continue
		var entry: Dictionary = _events[i]
		line.text = entry["text"]
		# Fades over the last second only, so a line is fully readable for as long as it is
		# worth reading and then leaves without a slow dissolve nobody watches.
		line.modulate.a = clampf((feed_seconds - entry["age"]), 0.0, 1.0)
		line.reset_size()
		# Counted back from the newest, so a line does not slide up the screen as older ones
		# expire underneath it.
		var from_newest := _events.size() - 1 - i
		line.position = Vector2(feed_left, bottom - float(from_newest + 1) * feed_spacing)


func _label(font_size: int, colour: Color) -> Label:
	var settings := LabelSettings.new()
	settings.font_size = font_size
	settings.font_color = colour
	# Outlined rather than shadowed. The arena is bright dirt and dark trenches, and text has to
	# survive both without a panel behind it eating the view.
	settings.outline_size = maxi(4, font_size / 4)
	settings.outline_color = Color(0, 0, 0, 0.8)

	var label := Label.new()
	label.label_settings = settings
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(label)
	return label
