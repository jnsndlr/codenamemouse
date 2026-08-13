extends SceneTree
## Invariant audit for the Sneak's four abilities (GDD section 4, milestone 8b).
##
##   godot --headless --script res://tools/sneak_audit.gd
##
## WHAT A HEADLESS AUDIT CAN AND CANNOT SAY ABOUT THIS CLASS, because the split is unusually stark
## here and pretending otherwise would make this file look more complete than it is.
##
## It cannot say whether any of it *works*. The Sneak's whole subject is visibility, and whether a
## faded mouse can be picked out of a lawn or a dust cloud actually hides anybody are questions with
## no answer outside a rendered frame -- `tools/fade_shot.gd` and `tools/dust_shot.gd` are where
## those are asked, and both of them had to be composed carefully before they said anything at all.
##
## What it can say is that the RULES hold, and every one of them is a rule that fails silently. A
## veil that outlives its ten seconds, a backstab that pays out on a swing anybody could see coming,
## a listen that never lapses, a screen that keeps blinding a defender after it has visibly gone --
## none of those look like a bug from inside a match. They look like the class being strong.
##
## THE RULES CLUSTER IN `spotting.gd` RATHER THAN IN THE ABILITIES, which is why several checks
## below reach for the contact book instead of the control that caused it. That is the design: bots
## read that book, so a rule written anywhere else would apply to humans and not to three quarters
## of the mice in a match. Asking the book is asking the question a defender asks.

var _checks: int = 0
var _failures: Array[String] = []

var _scene: Node
var _spotting: Spotting
var _sneak: Mouse
var _mark: Mouse


func _initialize() -> void:
	await _arena()
	if _sneak == null or _spotting == null:
		print("FAIL -- no arena to audit")
		quit(1)
		return

	await _check_fade_hides_and_lapses()
	await _check_fade_is_beaten_at_arms_length()
	await _check_fade_refuses_a_carrier()
	await _check_fade_dies_with_you()
	await _check_backstab_pays_only_when_unseen()
	await _check_backstab_is_the_sneaks_alone()
	await _check_listen_finds_the_hidden()
	await _check_listen_lapses()
	await _check_dust_blocks_and_clears()

	print("\n" + "=".repeat(78))
	if _failures.is_empty():
		print("ALL SNEAK INVARIANTS HOLD across %d checks." % _checks)
	else:
		print("%d of %d SNEAK CHECKS FAILED:" % [_failures.size(), _checks])
		for failure: String in _failures:
			print("  - %s" % failure)
	print("=".repeat(78))
	quit(0 if _failures.is_empty() else 1)


func _ok(what: String, condition: bool, detail: String = "") -> void:
	_checks += 1
	if condition:
		print("   ok  %s" % what)
		return
	_failures.append("%s%s" % [what, "" if detail.is_empty() else "  (%s)" % detail])
	print("   FAIL %s  %s" % [what, detail])


func _arena() -> void:
	_scene = (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	root.add_child(_scene)
	for i in range(4):
		await process_frame
	_spotting = get_first_node_in_group(Spotting.SPOTTING_GROUP) as Spotting
	for i in range(30):
		await process_frame

	# THE PLAYER, because it is the one mouse that carries a control set -- bots do not get one
	# (see [MouseControls]), so a bot cannot be asked to press V.
	_sneak = _scene.get_node("Player") as Mouse
	_sneak.set_class(MouseClass.SNEAK)
	# A red mouse of our own to watch and to hit, rather than whichever bot happens to be nearest.
	# Built by hand for the reason `slam_shot.gd` gives: a check should not be at the mercy of which
	# seat the director filled.
	_mark = _bare_mouse(Team.RED)
	await process_frame


# ------------------------------------------------------------------------------------- fade


## Ten seconds of glass, and then not.
func _check_fade_hides_and_lapses() -> void:
	print("\n-- the veil")
	var fade := _sneak.get_node_or_null("Fade") as Fade
	_ok("the Sneak carries a Fade control", fade != null)
	if fade == null:
		return

	await _stand(_sneak, Vector3(6.0, 0.2, 6.0))
	await _stand(_mark, Vector3(14.0, 0.2, 6.0))
	_ok("a Sneak in the open is not hidden to begin with", not _spotting.hidden(_sneak))

	fade.set("_cooldown_left", 0.0)
	_ok("the fade fires", fade.go_to_glass())
	_ok("and the mouse is faded", _sneak.is_faded())
	# THE SWEEP, NOT THE PREDICATE, and both are asked on purpose. `hidden` is the rule; the book is
	# what a defender and a bot actually read, and the two have disagreed before.
	await _sweep()
	_ok("it is hidden", _spotting.hidden(_sneak))
	_ok(
		"and off the enemy's live contacts",
		not _is_live(Team.RED, _sneak)
	)

	_ok("a second fade is refused while the first is cooling", not fade.go_to_glass())

	# Wound the clock forward rather than waiting ten real seconds, which is the difference between
	# an audit that runs in a minute and one nobody runs.
	_sneak.set_faded(0.05)
	await _sweep()
	_ok("the veil lapses", not _sneak.is_faded())
	_ok("and the mouse comes back", not _spotting.hidden(_sneak))


## The one distance term in the whole concealment model.
func _check_fade_is_beaten_at_arms_length() -> void:
	print("\n-- and arm's length beats it")
	await _stand(_sneak, Vector3(6.0, 0.2, 6.0))
	# Comfortably inside `fade_reveal_range`, and on the same plane, with nothing in between.
	await _stand(_mark, Vector3(6.9, 0.2, 6.0))
	_sneak.set_faded(10.0)
	await _sweep()
	_ok(
		"a faded Sneak within arm's reach is on the enemy's map after all",
		_is_live(Team.RED, _sneak),
		"gap %.2fm, reveal range %.2fm" % [
			_sneak.global_position.distance_to(_mark.global_position),
			_spotting.fade_reveal_range
		]
	)

	# And the same mouse, the same veil, further off.
	await _stand(_mark, Vector3(6.0 + _spotting.fade_reveal_range + 2.0, 0.2, 6.0))
	_sneak.set_faded(10.0)
	await _sweep()
	# NOT MERELY "ABSENT". A contact lingers fifteen seconds after it was last seen, so the check
	# that matters is whether it is LIVE -- an absent-contact test would pass here for the first
	# fifteen seconds whatever the rule did.
	_ok(
		"and off it again once they back away",
		not _is_live(Team.RED, _sneak)
	)
	_sneak.set_faded(0.0)


## Carriers are visible (GDD section 2), and the Sneak is the class most likely to want otherwise.
func _check_fade_refuses_a_carrier() -> void:
	print("\n-- but not with the banner")
	var fade := _sneak.get_node_or_null("Fade") as Fade
	if fade == null:
		return
	var banner := _enemy_banner()
	_ok("there is a banner to steal", banner != null)
	if banner == null:
		return

	await _stand(_sneak, banner.global_position)
	for i in range(40):
		await process_frame
	_ok("the Sneak picked it up", _sneak.is_carrying(), "at %s" % _sneak.global_position)
	if not _sneak.is_carrying():
		return

	fade.set("_cooldown_left", 0.0)
	_ok("a carrier is refused the veil", not fade.go_to_glass())
	# STATED TWICE, IN TWO PLACES, and asserted twice for that reason: the ability refuses so the
	# player is told why, and the mouse refuses so nothing else can set the state behind its back.
	_sneak.set_faded(10.0)
	_ok("and cannot be faded by any other route", not _sneak.is_faded())

	# PUT DOWN, AND THEN WALKED AWAY FROM, AND ONLY THEN BELIEVED. All three steps are load-bearing
	# and the middle one is the one that is easy to miss: pickup is proximity, so a banner dropped
	# at the feet of the mouse that was holding it is a banner the director hands straight back on
	# the next tick. The first version of this dropped it and waited, and the Sneak was still
	# carrying it through every check that followed -- which refused the veil, refused the backstab,
	# and reported four unrelated abilities broken.
	banner.drop()
	await _stand(_sneak, Vector3(6.0, 0.2, 6.0), 0.5)
	_ok("and puts it down again afterwards", not _sneak.is_carrying())


## Going down takes the veil with you.
func _check_fade_dies_with_you() -> void:
	print("\n-- and it does not survive being scruffed")
	await _stand(_sneak, Vector3(6.0, 0.2, 6.0))
	_sneak.set_faded(10.0)
	_ok("faded", _sneak.is_faded())
	_sneak.take_hit(9999.0, _sneak.global_position + Vector3.FORWARD, 0.0, null)
	_ok("scruffed", _sneak.is_scruffed())
	_ok("and no longer faded", not _sneak.is_faded())
	_sneak.revive_at(Vector3(6.0, 0.2, 6.0))
	for i in range(10):
		await process_frame


# --------------------------------------------------------------------------------- backstab


## Double damage from concealment, and ordinary damage otherwise.
func _check_backstab_pays_only_when_unseen() -> void:
	print("\n-- the backstab")
	_ok("the Sneak's multiplier is set", _sneak.unseen_damage > 1.0,
		"%.2f" % _sneak.unseen_damage)

	var seen := await _swing_for_damage(false)
	var unseen := await _swing_for_damage(true)
	_ok("a swing anybody could see coming does its face value", is_equal_approx(
		snappedf(seen, 0.01), snappedf(_sneak.attack_damage, 0.01)
	), "%.1f against %.1f" % [seen, _sneak.attack_damage])
	_ok("and one struck unseen does the multiple", is_equal_approx(
		snappedf(unseen, 0.01), snappedf(_sneak.attack_damage * _sneak.unseen_damage, 0.01)
	), "%.1f against %.1f" % [unseen, _sneak.attack_damage * _sneak.unseen_damage])


## It is the Sneak's, and nobody else's.
func _check_backstab_is_the_sneaks_alone() -> void:
	print("\n-- and it belongs to one class")
	for kind: int in [MouseClass.GENERALIST, MouseClass.ENGINEER, MouseClass.BRUTE]:
		_sneak.set_class(kind)
		var name := MouseClass.definition_of(kind).display_name
		var hit := await _swing_for_damage(true)
		_ok(
			"a concealed %s does no more than its face value" % name,
			is_equal_approx(snappedf(hit, 0.01), snappedf(_sneak.attack_damage, 0.01)),
			"%.1f against %.1f" % [hit, _sneak.attack_damage]
		)
	_sneak.set_class(MouseClass.SNEAK)


## Hit `_mark` once and report what it cost, with the striker concealed or not.
##
## THE VEIL IS THE CONCEALMENT USED, rather than parking the mouse in grass, because grass is a
## place on a map and a map is a thing that changes. What is being tested is that the multiplier
## reads `Spotting.hidden`; which of the several ways of being hidden got it there is that
## predicate's business and is covered by the grass probes.
func _swing_for_damage(concealed: bool) -> float:
	await _stand(_sneak, Vector3(6.0, 0.2, 6.0))
	_sneak.set_faded(10.0 if concealed else 0.0)

	# THE RECOVERY WAIT COMES FIRST AND THE MARK IS PLACED SECOND, which is the opposite of the
	# obvious order and is what makes the reading repeatable. Two reasons, both learned from a
	# failure:
	#
	# LONG ENOUGH FOR THE PREVIOUS SWING'S RECOVERY, in seconds. This is where the frame-count trap
	# bit hardest: `attack_cooldown` is 0.28s of wall clock, twenty-four idle frames in a headless
	# process is nothing like that, and `swing()` simply returned false. The check reported the
	# backstab doing -1 damage -- a number no rule in the game can produce, and the tell that the
	# audit was measuring its own impatience rather than the ability.
	#
	# AND A SWING IS A SHOVE. `take_hit` applies knockback, which is integrated over the frames that
	# follow, so a mark placed *before* the wait spends that wait travelling -- and the next swing
	# reads 0.0 damage because it whiffed at empty air. Placed after, it is standing where it was
	# put on the frame the paw moves.
	await _seconds(maxf(_sneak.attack_swing + _sneak.attack_cooldown, 0.3) + 0.15)

	# PUT BACK ON ITS FEET AT FULL HEALTH BEFORE EVERY SWING. Six of these run in a row and each
	# takes a bite out of the same mouse; without this the mark is scruffed partway through and
	# every reading after it is a swing that connected with a body on the floor.
	_mark.revive_at(_sneak.global_position + _sneak.get_facing_direction() * 0.5)
	await _stand(_mark, _mark.global_position, 0.1)

	# THE SPOT IS RECOMPUTED HERE, ON THE FRAME THE PAW MOVES, AND NOT BEFORE THE SETTLE. The mouse
	# is still being driven while this runs -- `Player._control` turns it toward its aim point every
	# tick, at a capped rate -- so a spot worked out a tenth of a second earlier is a spot the mouse
	# is no longer facing. That cost one class out of four: the Engineer's swing missed by 58 degrees
	# against a 55 degree half-arc, deterministically, and read as the backstab being class-specific
	# when it was the audit aiming at where the mouse used to be looking.
	var spot := _sneak.global_position + _sneak.get_facing_direction() * 0.5
	_mark.global_position = spot

	var before := _mark.get_health_ratio() * _mark.max_health
	if not _sneak.swing():
		return -1.0
	# HELD THROUGH THE WINDUP, not merely placed before it. `_resolve_swing` fires a sixth of a
	# second after the paw moves and measures the cone at *that* moment, so a mark left to its own
	# devices spends the windup settling, sliding off whatever it was revived on top of, or drifting
	# on the last blow's knockback -- and the swing whiffs. That produced a 0.0 for exactly one of
	# the four classes, which is the shape of a flaky check rather than of a rule: the reading was
	# about where a body happened to be, and this is a measurement of damage.
	await _stand(_mark, spot, _sneak.attack_swing + 0.15)
	_sneak.set_faded(0.0)
	return before - _mark.get_health_ratio() * _mark.max_health


# ----------------------------------------------------------------------------------- listen


## The pulse comes back off bodies, including bodies nothing else can find.
func _check_listen_finds_the_hidden() -> void:
	print("\n-- the listen")
	var sonar := _sneak.get_node_or_null("Sonar") as Sonar
	_ok("the Sneak carries a Sonar control", sonar != null)
	if sonar == null:
		return

	await _stand(_sneak, Vector3(6.0, 0.2, 6.0))
	# A FADED MOUSE, which is the hardest case and the one the ability exists for: nothing else in
	# the game finds another Sneak behind its own veil at range.
	await _stand(_mark, Vector3(6.0 + sonar.listen_range() - 1.0, 0.2, 6.0))
	_mark.set_faded(30.0)
	await _sweep()
	_ok("a faded mouse in the open is invisible to the crew", not _is_live(Team.BLUE, _mark))

	sonar.set("_cooldown_left", 0.0)
	sonar.scan()
	_ok("the scan opened a listen", sonar.is_listening())
	await _sweep()
	_ok("and the pulse found them", _is_live(Team.BLUE, _mark))

	# OUT OF RANGE IS STILL OUT OF RANGE. Without this the check would pass for a listen that simply
	# revealed the whole map, which is the one shape this ability must not have.
	await _stand(_mark, Vector3(6.0 + sonar.listen_range() + 4.0, 0.2, 6.0))
	sonar.set("_cooldown_left", 0.0)
	sonar.scan()
	await _sweep()
	_ok("but not one standing beyond it", not _is_live(Team.BLUE, _mark))


func _check_listen_lapses() -> void:
	print("\n-- and it does not last")
	var sonar := _sneak.get_node_or_null("Sonar") as Sonar
	if sonar == null:
		return
	await _stand(_mark, Vector3(6.0 + sonar.listen_range() - 1.0, 0.2, 6.0))
	_mark.set_faded(30.0)
	sonar.set("_cooldown_left", 0.0)
	sonar.scan()
	await _sweep()
	_ok("found while the pulse is live", _is_live(Team.BLUE, _mark))

	sonar.set("_listen_left", 0.0)
	await _sweep()
	_ok("and lost the moment it lapses", not _is_live(Team.BLUE, _mark))
	_mark.set_faded(0.0)


# ------------------------------------------------------------------------------------- dust


## A screen takes the sightline away, and gives it back when it goes.
##
## THE RULE HALF ONLY. Whether the cloud is actually opaque on screen is `tools/dust_shot.gd`'s
## question and cannot be asked here -- but the two halves have to agree, and this is the half a bot
## plays against.
func _check_dust_blocks_and_clears() -> void:
	print("\n-- the dust screen")
	var dust := _sneak.get_node_or_null("DustKick") as DustKick
	_ok("the Sneak carries a DustKick control", dust != null)
	if dust == null:
		return

	# Close enough to be plainly visible, and both in the open, so the ONLY thing that can take the
	# contact away is the cloud. The mark is put back on its feet first: it has just spent six
	# checks being hit, and a scruffed mouse is not a watcher, so the control reading would have
	# been "nobody could see anything" rather than "the dust worked".
	_mark.revive_at(Vector3(9.0, 0.2, 6.0))
	await _stand(_sneak, Vector3(6.0, 0.2, 6.0))
	await _stand(_mark, Vector3(9.0, 0.2, 6.0))
	_sneak.set_faded(0.0)
	_mark.set_faded(0.0)
	await _sweep()
	_ok("the two can see each other to begin with", _is_live(Team.RED, _sneak))

	dust.set("_cooldown_left", 0.0)
	_ok("the screen goes up", dust.kick())
	var clouds := get_nodes_in_group(DustScreen.SCREEN_GROUP)
	_ok("and there is a cloud in the world", clouds.size() > 0)
	_ok(
		"which stands across the line between them",
		clouds.size() > 0 and (clouds[0] as DustScreen).blocks(
			_sneak.global_position, _mark.global_position
		)
	)
	await _sweep()
	_ok("so the contact goes stale", not _is_live(Team.RED, _sneak))

	# AND IT DOES NOT LINGER. A screen that went on blocking after it had visibly cleared would be
	# the same species of bug as one that never blocked -- and far harder to notice, because it
	# only ever helps the mouse that threw it.
	_ok("a second screen is refused while the first is cooling", not dust.kick())
	await _seconds(1.4)
	_ok("the cloud is gone", get_nodes_in_group(DustScreen.SCREEN_GROUP).is_empty())
	await _sweep()
	_ok("and the contact comes back", _is_live(Team.RED, _sneak))


# ------------------------------------------------------------------------------------ tools


## Hold a mouse somewhere long enough for the rules to observe it there.
##
## HELD, NOT TELEPORTED ONCE, for the reason `cheese_audit.gd` spells out: mice are solid to one
## another now, so a body dropped next to another is shoved out by depenetration -- possibly before
## anything has looked at where it was put.
## HELD FOR A DURATION RATHER THAN FOR A COUNT OF FRAMES, for the reason `_sweep` gives at length:
## in a headless process thirty idle frames can be a few milliseconds and contain no physics tick,
## so a frame-counted hold is a hold that never happened.
func _stand(mouse: Mouse, at: Vector3, hold: float = 0.2) -> void:
	var until := Time.get_ticks_msec() + int(maxf(hold, 0.0) * 1000.0)
	while Time.get_ticks_msec() < until:
		mouse.global_position = at
		mouse.velocity = Vector3.ZERO
		await process_frame


## Wait for at least one full sweep of `spotting.gd`, measured in SECONDS rather than in frames.
##
## THIS IS THE SINGLE MOST IMPORTANT LINE IN THE FILE and it cost an afternoon to learn. A headless
## Godot runs idle frames as fast as it can -- thousands a second -- so `await process_frame` thirty
## times can be a few milliseconds of game time and contain no physics tick at all. Every check here
## reads a book that is only written on the sweep, so a frame-counted wait reads the state from
## *before* the thing it just did, reliably, and reports a working rule as broken.
func _sweep() -> void:
	await _seconds(_spotting.interval * 2.5)


func _seconds(how_long: float) -> void:
	await create_timer(how_long).timeout


## Is this mouse in the other crew's book AND seen in the most recent sweep?
##
## LIVE, NOT MERELY PRESENT, everywhere in this file. A contact lingers for `memory_seconds` after
## it was last seen -- that staleness is the mechanic (see `spotting.gd`) -- so "is there an entry"
## answers yes for fifteen seconds after concealment started working perfectly.
func _is_live(side: int, who: Mouse) -> bool:
	var entry: Variant = _spotting.contacts_for(side).get(who)
	return entry != null and bool((entry as Dictionary).get("live", false))


func _enemy_banner() -> Banner:
	var director := get_first_node_in_group(MatchDirector.DIRECTOR_GROUP) as MatchDirector
	if director == null:
		return null
	return director.banner_of(Team.other(_sneak.team))


## A mouse with a body and nothing else -- no controls, no driver. The same construction the shot
## probes use, and for the same reason: a check should not depend on which seat a bot took.
func _bare_mouse(side: int) -> Mouse:
	var mouse := Mouse.new()
	mouse.name = "AuditMark%s" % Team.name_of(side)
	mouse.team = side

	# Before it enters the tree: `@onready var _visual := $Visual` resolves the instant it does.
	var visual := Node3D.new()
	visual.name = "Visual"
	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.16
	capsule.height = 0.4
	body.mesh = capsule
	body.position.y = 0.2
	visual.add_child(body)
	mouse.add_child(visual)

	var shape := CollisionShape3D.new()
	var hull := CapsuleShape3D.new()
	hull.radius = 0.16
	hull.height = 0.4
	shape.shape = hull
	shape.position.y = 0.2
	mouse.add_child(shape)

	_scene.add_child(mouse)
	return mouse
