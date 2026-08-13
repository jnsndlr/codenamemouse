extends Control
## Health, drawn over the mouse it belongs to.
##
## SAME CONVENTION AS THE CONTEXTUAL HINT (GDD section 10, and contextual_hint.gd): information
## that is about a particular mouse right now goes above that mouse's head, not in a corner. In
## a scrap you have no attention to spend looking away, and a bar parked at the edge of the
## screen tells you someone is nearly out of health at the exact moment you are least able to
## read it.
##
## ONLY WHEN IT MATTERS -- FOR HEALTH. A bar over a mouse at full health is clutter -- eight of
## them turn the arena into a spreadsheet -- so a bar appears when its owner has been hurt and
## fades out again once they're whole. That includes your own, which means an untouched field is
## completely clean and any health bar you can see is a fight in progress.
##
## YOUR OWN STAMINA IS THE EXCEPTION, and always drawn. It hid itself whenever it was full, on
## the same argument, and the argument does not hold for it: a full health bar is the ABSENCE of
## news, but a full stamina bar is the answer to "can I make that run" -- which you want in the
## second BEFORE you commit, not after, and by then the bar you needed has already appeared and
## started draining. Its readings are also relative, so a bar you only ever see part-empty gives
## you nothing to judge a half-full one against. One bar, four pixels tall, over your own mouse.
##
## Drawn immediately rather than built from nodes. It is a rectangle per wounded mouse, it
## changes every frame, and `_draw` on one Control is both less code and less garbage than a
## pool of ColorRects being reparented.

## Where on the mouse the bar hangs, in metres. Above the ears and above a carried banner would
## be too high -- this sits on the shoulders, under the pole.
const HEAD: float = 0.46

@export var director_path: NodePath

@export_group("Bar")
@export var bar_size: Vector2 = Vector2(30.0, 4.0)
## Pixels between the projected point and the bar. On top of the world-space lift, because the
## camera's pitch squashes vertical distance on screen.
@export var screen_lift: float = 16.0
## How long a bar lingers after the last damage, so you can read the result of an exchange
## rather than watching it vanish the instant it stops changing.
@export var linger_seconds: float = 3.0
@export var fade_seconds: float = 0.6

var _director: MatchDirector
## mouse -> seconds since it was last worth showing.
var _shown: Dictionary = {}


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_director = get_node_or_null(director_path) as MatchDirector


func _process(delta: float) -> void:
	var player: Mouse = _director.get_player() if _director != null else null
	for node in get_tree().get_nodes_in_group(Mouse.MOUSE_GROUP):
		var mouse := node as Mouse
		if mouse == null:
			continue
		# Hurt, or flat on your back. Both are states somebody is about to act on -- and your own
		# row is always mounted, because the stamina bar under it is always drawn. `_draw` is what
		# decides the health bar is still not worth showing; keeping the entry here rather than
		# tracking your own anchor separately is what guarantees the stamina bar sits in the exact
		# same place whether or not a health bar happens to be above it.
		if mouse == player or mouse.get_health_ratio() < 1.0 or mouse.is_scruffed():
			_shown[mouse] = 0.0
		elif _shown.has(mouse):
			_shown[mouse] = _shown[mouse] + delta
			if _shown[mouse] > linger_seconds + fade_seconds:
				_shown.erase(mouse)
	queue_redraw()


## May a bar be drawn over this mouse at all? See the note in `_draw`.
##
## FAILS OPEN, deliberately, and it is the opposite choice from the backstab's `Mouse._is_unseen`.
## With no spotting node there is no concealment model in this arena, so nobody is hidden and every
## bar should be drawn -- a probe or an audit that lost its health bars because it built a scene
## without a `Spotting` in it would be reporting a bug that does not exist. The backstab fails
## closed for the mirror-image reason: there, the absent model would hand out a *bonus*.
func _crew_can_see(player: Mouse, mouse: Mouse) -> bool:
	if player == null or mouse == null or mouse.team == player.team:
		return true
	var watch := get_tree().get_first_node_in_group(Spotting.SPOTTING_GROUP) as Spotting
	if watch == null:
		return true
	var entry: Variant = watch.contacts_for(player.team).get(mouse)
	# LIVE, NOT MERELY REMEMBERED. A stale contact is a guess about where somebody *was* -- that is
	# the minimap's business and it draws it hollow and fading to say so. A health bar hanging in the
	# air over an empty patch of lawn would be that guess told as a fact, in the world, at full
	# confidence.
	return entry != null and bool((entry as Dictionary).get("live", false))


func _draw() -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return

	var player: Mouse = _director.get_player() if _director != null else null
	# The bars over heads scale too, or they become invisible threads on a large window while the
	# panels around the edge stay legible.
	var ui := HudSkin.scale_for(get_viewport_rect().size)

	for key: Variant in _shown.keys():
		# Validity BEFORE the cast -- `as Mouse` throws on a freed object, so this guard was
		# unreachable for the case it was written for. Same shape as `spotting.gd`'s, and the same
		# reason nobody noticed: nothing freed a mouse mid-match until M7 started swapping a bot
		# out of a chair every time somebody joined.
		if key == null or not is_instance_valid(key):
			_shown.erase(key)
			continue
		var mouse := key as Mouse
		if mouse == null:
			_shown.erase(key)
			continue

		# `[ADDED]` NO BAR OVER SOMEBODY YOUR CREW CANNOT SEE, and this is a leak rather than a
		# polish note. A bar is drawn over any hurt mouse, which was harmless while the only way to
		# be concealed was to stand still in grass -- a mouse you cannot quite resolve is a mouse
		# whose bar you were going to notice anyway, at the same spot, at the same time.
		#
		# The Sneak's third milestone broke that in two directions at once. A faded Sneak
		# (`fade_glass.gdshader`) is a lens with no colour of its own, and a hurt one was a lens
		# with **a floating health bar over it** -- the one thing on screen that says exactly where
		# an invisible mouse is standing. A [DustScreen] is worse: the bar is a `Control` drawn on
		# top of the whole 3D frame, so it sails over a cloud that is otherwise total.
		#
		# ASKED OF `spotting.gd` RATHER THAN OF THE ABILITIES, which is what makes this one line
		# instead of two and keeps it right for whatever conceals somebody next. The contact book is
		# already the answer to "does my crew know this mouse is there", and it is already the answer
		# the minimap draws -- so the bar over a head and the dot on the map now appear and vanish
		# together, which they visibly did not before.
		#
		# YOUR OWN CREW IS NEVER GATED. They are drawn on the minimap unconditionally, they are
		# standing in front of you in team colour, and a Sneak crew mate who fades is somebody you
		# still need to be able to keep track of.
		if not _crew_can_see(player, mouse):
			continue

		# Scaled by the body under it: `HEAD` was measured against a mouse that was the same size
		# for everybody, and on a Brute the unscaled figure puts the bar inside its own head.
		var head := mouse.global_position + Vector3.UP * HEAD * mouse.height_ratio()
		# Behind the camera projects to a point that is still on screen, mirrored. Without this
		# a mouse at your back draws a bar floating over the far side of the arena.
		if camera.is_position_behind(head):
			continue

		var fade := 1.0 - clampf(
			(_shown[mouse] - linger_seconds) / maxf(fade_seconds, 0.001), 0.0, 1.0
		)
		if fade <= 0.0:
			continue

		var at := camera.unproject_position(head) - Vector2(bar_size.x * ui * 0.5, screen_lift * ui)
		var mine := mouse == player
		# Your own entry stays in `_shown` for the stamina bar's sake, so the health bar has to ask
		# the question again for itself -- unhurt, it is the clutter the linger rule exists to
		# stop, and no more worth drawing over your own head than over anybody else's.
		if not mine or mouse.get_health_ratio() < 1.0 or mouse.is_scruffed():
			_bar(at, mouse.get_health_ratio(), Team.color_of(mouse.team), fade, ui)

		# Stamina under your own bar, and only yours -- it is personal and never shown for
		# anyone else (GDD section 9).
		if mine and mouse.has_method("get_stamina_ratio"):
			_bar(
				at + Vector2(0.0, (bar_size.y + 2.0) * ui), mouse.call("get_stamina_ratio"),
				Color(0.85, 0.82, 0.55), fade * 0.9, ui, bar_size.y * 0.6
			)
			_scurry_pip(mouse, at, fade, ui)
			_wedge_count(mouse, at, fade, ui)
			_cast_bar(mouse, at, fade, ui)


## Whether your Scurry is off cooldown, as a wedge beside your own bars.
##
## NEXT TO STAMINA AND NOT ON THE SCORE BUG, because they answer different questions. The team's
## cheese count is up top where everyone's eyes go for the score -- that is the crew's health bar
## and a shared fact. Whether YOU can spend one right now is personal, moment-to-moment, and
## wanted in the half-second before you commit to a chase, which is the same argument GDD section
## 10 makes for keeping stamina down here.
##
## Drawn dim and empty while recharging rather than hidden, so the gap between pressing Space and
## nothing happening is never a mystery.
func _scurry_pip(mouse: Mouse, at: Vector2, alpha: float, ui: float) -> void:
	if not mouse.has_method("scurry_ready"):
		return
	var ready: bool = mouse.scurry_ready()
	var spot := at + Vector2((bar_size.x + 5.0) * ui, bar_size.y * 0.5 * ui)
	var size := bar_size.y * 1.5 * ui
	if ready:
		HudSkin.cheese(self, spot, size, alpha)
		return
	# Recharging: the same wedge, faded, with the cooldown draining out of it.
	var left: float = 1.0 - mouse.scurry_cooldown_ratio()
	HudSkin.cheese(self, spot, size, alpha * 0.22)
	if left > 0.0:
		HudSkin.cheese(self, spot, size * left, alpha * 0.5)


## The shore-up hold, filling, above your own bars.
##
## TWO READINGS OF ONE CAST, ON PURPOSE, AND THE OTHER ONE IS THE PRIMARY. `ShoreUp._show` lights
## the cell itself with the dig cursor, which is the right instrument and answers the question this
## bar cannot: **which cell**. That one is not in trouble -- a screenshot said it was faint, the
## screenshot turned out to be of a cast that had already been abandoned by a harness bug, and the
## real thing floods a whole cubic metre of corridor in gold.
##
## What this adds is the number. A wireframe filling with light is unmistakable and imprecise, and
## three seconds is long enough to want to know whether you are at a third or nearly there -- the
## same reason the dig has a cursor AND digging has a feel. It is four pixels tall and it goes where
## this file's header says everything about one mouse right now goes: above that mouse.
##
## ABOVE THE BARS RATHER THAN BELOW, unlike the wedge count. Health and stamina are *states* and
## stack downward from the anchor; this is an *action in progress*, it exists for three seconds and
## then never again until you press the key, and putting it on top keeps it from shoving the
## permanent readings around every time it appears.
##
## YOURS ONLY, for now, and that is a hidden-information decision rather than a HUD one: an enemy
## Engineer's cast bar visible across a corridor would be a free tell that somebody is fortifying,
## which is exactly the sort of thing §3 wants you to have to go and look at.
func _cast_bar(mouse: Mouse, at: Vector2, alpha: float, ui: float) -> void:
	var shore := mouse.get_node_or_null("ShoreUp")
	if shore == null:
		return
	var done: float = shore.call("progress")
	if done <= 0.0:
		return
	_bar(
		at - Vector2(0.0, (bar_size.y + 3.0) * ui), done,
		Color(0.98, 0.74, 0.24), alpha, ui, bar_size.y * 0.8
	)


## What you are hauling, as a wedge and a number, under your own bars.
##
## YOURS ONLY, AND THAT IS THE WHOLE SPECIFICATION FOR NOW. What an enemy is carrying is worth
## knowing -- it is the difference between a mouse worth chasing and one worth ignoring -- and
## putting it over their head is a decision about hidden information (GDD section 3) rather than a
## HUD decision, so it is deliberately not made here. A wedge on a mouse is also a thing that could
## be shown in the WORLD, on the mouse, which is a better answer than a number and is somebody
## else's afternoon.
##
## HIDDEN AT ZERO, unlike the stamina bar beside it. The two are asked at different moments:
## stamina answers *can I make that run* before you commit, so it must be readable when full,
## whereas this answers *have I got anything to lose*, and the answer when you are carrying nothing
## is the absence of the icon. That is the same argument the health bar's linger rule makes.
##
## THE COOLDOWN IS DRAWN AS A DIM EXTRA WEDGE rather than as a bar or a number of seconds. It is
## the answer to *why did walking over that cache do nothing*, which is a question you ask for
## about a second and never want a readout for -- and the ghost wedge filling in says both what is
## happening and what you get at the end of it.
func _wedge_count(mouse: Mouse, at: Vector2, alpha: float, ui: float) -> void:
	if not mouse.has_method("get_carried_cheese"):
		return
	var held: int = mouse.get_carried_cheese()
	var waiting: float = mouse.wedge_wait() if mouse.has_method("wedge_wait") else 0.0
	if held <= 0 and waiting <= 0.0:
		return

	var size := bar_size.y * 1.6 * ui
	# Under the stamina bar, left-aligned with both bars above it, so the three readings that
	# belong to you and nobody else stack in one column.
	var spot := at + Vector2(0.0, (bar_size.y * 1.6 + 5.0) * ui)
	HudSkin.cheese(self, spot, size, alpha)

	if held > 0:
		HudSkin.text(
			self, Rect2(spot + Vector2(size * 1.7, -size * 0.15), Vector2(size * 3.0, size * 1.3)),
			"%d/%d" % [held, mouse.carry_capacity], maxi(9, roundi(size * 0.95)),
			Color(1.0, 0.96, 0.82, alpha)
		)

	if waiting <= 0.0 or mouse.wedge_room() <= 0:
		return
	# The next one, arriving: an empty ghost that fills as the stow clock runs down.
	var ghost := spot + Vector2(size * (3.0 if held > 0 else 1.7), 0.0)
	var ready: float = 1.0 - clampf(waiting / maxf(mouse.wedge_cooldown, 0.001), 0.0, 1.0)
	HudSkin.cheese(self, ghost, size, alpha * 0.20)
	if ready > 0.0:
		HudSkin.cheese(self, ghost, size * ready, alpha * 0.5)


func _bar(
	at: Vector2, fill: float, colour: Color, alpha: float, ui: float, height: float = -1.0
) -> void:
	var tall := (bar_size.y if height < 0.0 else height) * ui
	var wide := bar_size.x * ui
	var frame := Rect2(at, Vector2(wide, tall))
	draw_rect(frame.grow(1.0 * ui), Color(0.0, 0.0, 0.0, 0.55 * alpha), true)
	draw_rect(
		Rect2(at, Vector2(wide * clampf(fill, 0.0, 1.0), tall)),
		Color(colour.r, colour.g, colour.b, alpha), true
	)
