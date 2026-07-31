extends Control
## Score, clock, and what just happened.
##
## The GDD's HUD (section 10) is a full screen of furniture -- minimap, cheese ledger, carrier
## portraits, telegraph banners. Almost none of it can be built yet, and building the frame
## before the systems is how you end up maintaining a UI for a game that doesn't exist. What is
## here is exactly what M3's question needs to be answerable: the score, the clock, where both
## banners are, and a line saying what just changed.
##
## TOP CENTRE for the score and clock, per the concept art. The event feed sits under it rather
## than in the bottom-left the art gives it, because with no minimap yet the bottom-left is
## empty space nobody is looking at, and an event you don't read may as well not fire.
##
## THE BANNER LINE IS THE INTERESTING ONE. "their banner: DROPPED 14s" is a decision for both
## crews -- do you sprint for it or let it return? Neither crew can make that call without the
## number, and it's the one piece of state that isn't obvious from looking at the field.
##
## Built in code rather than authored as a scene, like the rest of the grey box. Six labels
## whose positions are three anchors is less to maintain than a .tscn full of margins.

@export var director_path: NodePath

@export_group("Feed")
## How many recent events stay on screen.
@export var feed_lines: int = 4
## How long a line lasts before it fades.
@export var feed_seconds: float = 6.0
## Where the feed starts, in pixels down the screen. Below the permanent bindings in the
## top-left corner: they are a wide row of text, and a centred feed line at 112 lands on the end
## of it -- two unrelated things overlapping reads as one garbled one.
@export var feed_top: float = 150.0

var _director: MatchDirector
var _score: Label
var _clock: Label
var _banners: Label
var _centre: Label
var _feed: Array[Label] = []
## {text, age}, newest last.
var _events: Array[Dictionary] = []


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_score = _label(30, Color(1, 1, 1))
	_clock = _label(20, Color(0.86, 0.88, 0.92))
	_banners = _label(16, Color(0.82, 0.84, 0.88))
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

	var blue := _director.score_of(Team.BLUE)
	var red := _director.score_of(Team.RED)
	_score.text = "%d   -   %d" % [blue, red]
	_clock.text = _as_clock(_director.time_left())
	_banners.text = _banner_line()
	_centre.text = _centre_line()

	_place(_score, 0.5, 14.0)
	_place(_clock, 0.5, 52.0)
	_place(_banners, 0.5, 80.0)
	_place(_centre, 0.5, get_viewport_rect().size.y * 0.34)

	_tick_feed(delta)


## The one line that says where both objectives are. Written as two clauses, yours first,
## because the question you ask most often in a CTF is "can I score right now?".
func _banner_line() -> String:
	var ours := _director.banner_of(Team.BLUE)
	var theirs := _director.banner_of(Team.RED)
	return "your banner: %s      their banner: %s" % [_state_of(ours), _state_of(theirs)]


func _state_of(banner: Banner) -> String:
	match banner.state:
		Banner.AT_NEST:
			return "home"
		Banner.CARRIED:
			var who := "taken"
			if banner.carrier != null:
				who = "carried by %s" % Team.name_of(banner.carrier.team)
			return who
		_:
			return "dropped, back in %ds" % ceili(banner.return_countdown())


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
		_place(line, 0.5, feed_top + float(i) * 20.0)


## Centred on the VIEWPORT, not on this control's own rect. A Control parented to a CanvasLayer
## reports a zero size until something lays it out, so measuring against `size` piles every
## label into the top-left corner on top of the depth readout -- which is exactly what it did.
func _place(label: Label, at_x: float, at_y: float) -> void:
	label.reset_size()
	var screen := get_viewport_rect().size
	label.position = Vector2(screen.x * at_x - label.size.x * 0.5, at_y)


func _as_clock(seconds: float) -> String:
	var whole := int(ceilf(seconds))
	return "%d:%02d" % [whole / 60, whole % 60]


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
