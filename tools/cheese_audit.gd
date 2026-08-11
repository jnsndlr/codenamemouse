extends SceneTree
## Invariant audit for the cheese economy (GDD section 2). The bargain tools/match_audit.gd
## struck, applied to M6's rules.
##
##   godot --headless --script res://tools/cheese_audit.gd
##
## An economy fails quietly. A wedge that banks twice, a raid that credits the raider without
## debiting the victim, a broke crew billed the long respawn for the death it could still afford
## -- none of those look like a bug from inside a match, they look like the numbers being a bit
## off. Every one of them is a specific sequence nobody will hit in the first ten matches, and
## every one changes what the milestone's question is being asked of.

var _checks: int = 0
var _failures: Array[String] = []

var _scene: Node
var _director: MatchDirector
var _blue: Mouse
var _red: Mouse


func _initialize() -> void:
	await _arena()

	await _check_bank_once()
	await _check_wedge_conservation()
	await _check_raid_is_a_transfer()
	await _check_paws_are_full()
	_check_capacity_is_per_class()
	await _check_drop_on_scruff()
	await _check_an_armful_scatters()
	await _check_drops_merge()
	_check_broke_respawn()
	_check_ceiling()
	await _check_scurry_costs_and_gates()
	await _check_scurry_multiplies()
	await _check_cache_replication()

	print("\n" + "=".repeat(78))
	if _failures.is_empty():
		print("ALL CHEESE INVARIANTS HOLD across %d checks." % _checks)
	else:
		print("%d of %d CHEESE CHECKS FAILED:" % [_failures.size(), _checks])
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
	_director = get_first_node_in_group(MatchDirector.DIRECTOR_GROUP) as MatchDirector
	# Let the director seat its crews, then take two mice off opposite sides to push around.
	for i in range(30):
		await process_frame
	for node in get_nodes_in_group(Mouse.MOUSE_GROUP):
		var mouse := node as Mouse
		if mouse == null:
			continue
		if mouse.team == Team.BLUE and _blue == null:
			_blue = mouse
		elif mouse.team == Team.RED and _red == null:
			_red = mouse


## Park a mouse somewhere and hold it there long enough for the director to see it.
##
## HELD, not teleported once. A nest has a crew standing in it, and dropping a mouse into five
## bodies means physics depenetration shoves it back out -- possibly before the director's own
## `_physics_process` gets a look. Re-asserting the position every frame for a stretch is what
## makes "this mouse is standing in that nest" a fact the rules can actually observe.
func _park(mouse: Mouse, at: Vector3, frames: int = 30) -> void:
	for i in range(frames):
		mouse.global_position = at
		mouse.velocity = Vector3.ZERO
		await process_frame


## Hold until this mouse can stow another wedge, or give up.
##
## `[ADDED with capacity]` EVERY CHECK BELOW THAT PICKS UP TWICE NEEDS THIS, and finding that out
## is what the failure looked like: five checks went red at once, all of them for the same reason,
## and none of them about the thing they were testing. A mouse now waits `wedge_cooldown` between
## wedges (GDD section 2), so an audit that walks a mouse from cache to nest and back in twenty
## frames is an audit measuring nothing but its own impatience.
##
## BOUNDED, and it reports rather than hangs. An audit that spins forever on a rule that quietly
## stopped ticking is worse than one that fails: it produces no output at all, on a machine nobody
## is watching.
func _wait_to_stow(mouse: Mouse, frames: int = 900) -> bool:
	for i in range(frames):
		if mouse.has_room():
			return true
		await process_frame
	return false


func _fresh_cache(at: Vector3, wedges: int = 3) -> CheeseCache:
	var cache := Node3D.new()
	cache.set_script(load("res://scripts/game/cheese_cache.gd"))
	cache.wedges = wedges
	_scene.add_child(cache)
	cache.global_position = at
	return cache


## The STORE, not the nest centre -- that is where cheese is banked and raided from, and
## the nest centre is where their banner stands waiting to be picked up instead.
func _stores_of(side: int) -> Vector3:
	return _director.nest_of(side).stores_point()


# ------------------------------------------------------------------------------- the checks


## A wedge banks once and then you are empty-pawed. Standing in your own nest holding cheese is
## a state that lasts exactly one frame, and if it did not, a mouse could idle at home printing
## cheese out of a single wedge.
func _check_bank_once() -> void:
	print("\n-- banking is once per wedge")
	var cache := _fresh_cache(_stores_of(Team.BLUE) + Vector3(4.0, 0.0, 0.0))
	await _park(_blue, cache.global_position)
	_ok("took a wedge from a cache", _blue.get_carried_cheese() == 1)

	var before := _director.cheese_of(Team.BLUE)
	await _park(_blue, _stores_of(Team.BLUE), 30)
	_ok("banked exactly one", _director.cheese_of(Team.BLUE) == before + 1,
		"%d -> %d" % [before, _director.cheese_of(Team.BLUE)])
	_ok("paws are empty after banking", _blue.get_carried_cheese() == 0)


## Every wedge that leaves a cache arrives somewhere. Emptying a pile of three into the pool
## must move the pool by exactly three -- no more, and none lost in the walk.
func _check_wedge_conservation() -> void:
	print("\n-- wedges are conserved between cache and pile")
	var cache := _fresh_cache(_stores_of(Team.BLUE) + Vector3(5.0, 0.0, 0.0), 3)
	var before := _director.cheese_of(Team.BLUE)
	for trip in range(3):
		await _wait_to_stow(_blue)
		await _park(_blue, cache.global_position)
		await _park(_blue, _stores_of(Team.BLUE), 20)
	_ok("three wedges banked three cheese", _director.cheese_of(Team.BLUE) == before + 3,
		"%d -> %d" % [before, _director.cheese_of(Team.BLUE)])
	_ok("the cache is gone once emptied", not is_instance_valid(cache) or cache.is_empty())


## A raid is a TRANSFER, not a spawn. Their pile goes down when you take it and yours goes up
## only when you get it home -- the gap between those is the whole risk of raiding.
func _check_raid_is_a_transfer() -> void:
	print("\n-- raiding moves cheese, it does not create it")
	var theirs_before := _director.cheese_of(Team.RED)
	var ours_before := _director.cheese_of(Team.BLUE)
	await _wait_to_stow(_blue)
	await _park(_blue, _stores_of(Team.RED))
	_ok("the raider is carrying", _blue.get_carried_cheese() == 1,
		"stood at %s, their nest is at %s" % [_blue.global_position, _stores_of(Team.RED)])
	_ok("their pile went down", _director.cheese_of(Team.RED) == theirs_before - 1,
		"%d -> %d" % [theirs_before, _director.cheese_of(Team.RED)])
	_ok("ours has NOT gone up yet", _director.cheese_of(Team.BLUE) == ours_before,
		"credited before the wedge got home")

	await _park(_blue, _stores_of(Team.BLUE), 30)
	_ok("ours goes up on arrival", _director.cheese_of(Team.BLUE) == ours_before + 1)


## `[REVISED]` What stops a mouse hoovering a cache, now that the answer is no longer "you may
## hold exactly one thing".
##
## THIS CHECK USED TO ASSERT TWO RULES THAT ARE GONE. A mouse holding a wedge may now take another
## up to its class's `carry_capacity`, and a banner carrier may hold cheese as well -- both
## deliberate (see [method Mouse.has_room] for the argument about the second one). What replaces
## them is the pair of limits that actually ration hauling: the capacity, and the seconds between
## wedges. So the check tests the same PROPERTY it always did -- a mouse cannot empty a pile by
## standing on it -- against the rules that now provide it.
func _check_paws_are_full() -> void:
	print("\n-- capacity and the stow clock, not one-at-a-time")
	var cache := _fresh_cache(_stores_of(Team.BLUE) + Vector3(6.0, 0.0, 0.0), 8)
	_blue.release_wedges()
	await _wait_to_stow(_blue)
	await _park(_blue, cache.global_position)
	var left: int = cache.wedges
	_ok("took one on arrival", _blue.get_carried_cheese() == 1)

	# THE IMPORTANT ONE. Standing in the pile does nothing until the clock runs out, which is what
	# keeps a cache a place you commit to rather than a button you walk over.
	await _park(_blue, cache.global_position, 20)
	_ok("the stow clock refuses a second wedge on the spot", cache.wedges == left,
		"cache went %d -> %d while the clock was still running" % [left, cache.wedges])
	_ok("still carrying exactly one", _blue.get_carried_cheese() == 1)

	# Held there long enough to fill up, and then held longer. A Generalist is three.
	var room: int = _blue.carry_capacity
	for i in range(room + 2):
		await _wait_to_stow(_blue)
		await _park(_blue, cache.global_position, 4)
	_ok("fills to capacity and stops", _blue.get_carried_cheese() == room,
		"carrying %d of a capacity of %d" % [_blue.get_carried_cheese(), room])

	# A CARRIER MAY HAUL. The reverse of what this file used to assert, and the reason is in
	# `Mouse.has_room`: the two errands still compete through the walk, which has not changed.
	_blue.release_wedges()
	_blue.take_carry(_director.banner_of(Team.RED))
	await _wait_to_stow(_blue)
	await _park(_blue, cache.global_position)
	_ok("a banner carrier may still pick cheese up", _blue.get_carried_cheese() == 1)
	_blue.release_carry()
	_blue.release_wedges()


## Per-class capacity (GDD sections 2 and 4). Read off the definitions rather than off a mouse, so
## this fails when somebody edits a `.tres` rather than when a haul happens to go wrong.
func _check_capacity_is_per_class() -> void:
	print("\n-- capacity is a class stat")
	var expected := {
		MouseClass.SNEAK: 1, MouseClass.ENGINEER: 2,
		MouseClass.GENERALIST: 3, MouseClass.BRUTE: 5,
	}
	for kind: int in expected:
		var definition := MouseClass.definition_of(kind)
		_ok("%s carries %d" % [definition.display_name, expected[kind]],
			definition.carry_capacity == expected[kind],
			"the resource says %d" % definition.carry_capacity)

	# And the number actually reaches the mouse. A stat that lives only in a resource is a stat
	# nothing reads -- which is the failure mode `class_definition.gd`'s own header is about.
	var was := _blue.mouse_class
	_blue.set_class(MouseClass.BRUTE)
	_ok("a Brute mouse carries five", _blue.carry_capacity == 5,
		"the mouse says %d" % _blue.carry_capacity)
	_blue.set_class(MouseClass.SNEAK)
	_ok("a Sneak mouse carries one", _blue.carry_capacity == 1,
		"the mouse says %d" % _blue.carry_capacity)
	_blue.set_class(was)


## Scruffed mice drop what they were hauling, where they fell (GDD section 2).
func _check_drop_on_scruff() -> void:
	print("\n-- a scruffed mouse drops its wedge")
	var cache := _fresh_cache(_stores_of(Team.BLUE) + Vector3(7.0, 0.0, 0.0))
	await _wait_to_stow(_blue)
	await _park(_blue, cache.global_position)
	_ok("carrying before the scruff", _blue.get_carried_cheese() == 1)

	var fell_at := _blue.global_position
	_blue.take_hit(9999.0, fell_at + Vector3(1.0, 0.0, 0.0), 0.0, _red)
	await process_frame
	await process_frame
	_ok("paws empty after the scruff", _blue.get_carried_cheese() == 0)

	var dropped := CheeseCache.nearest(self, fell_at)
	_ok("a wedge is lying where they fell",
		dropped != null and dropped.global_position.distance_to(fell_at) < 1.0,
		"nearest pile is %s" % ("none" if dropped == null else str(dropped.global_position)))

	# It waits. No clock, no fade, no quiet disappearance -- a pile you can win by ignoring is
	# not an objective, and the whole reason drops stay is to grow interaction points the map
	# never authored.
	if dropped != null:
		var was: int = dropped.wedges
		for i in range(120):
			await process_frame
		_ok("the pile is still there a good while later", is_instance_valid(dropped))
		_ok("and has not quietly shrunk", is_instance_valid(dropped) and dropped.wedges == was)

	_blue.revive_at(_stores_of(Team.BLUE))
	await process_frame


## A full load goes down as a mess, not as a parcel (GDD section 2).
##
## THE INVARIANT IS CONSERVATION FIRST AND SPREAD SECOND, in that order, because the two can fail
## independently and only one of them costs anybody anything. Four wedges must still be four wedges
## on the ground -- a scatter that rounded one away would be cheese leaving the economy through a
## cosmetic feature. That they landed in more than one place is the design on top.
func _check_an_armful_scatters() -> void:
	print("\n-- a full load scatters rather than landing as one parcel")
	var was := _blue.mouse_class
	_blue.set_class(MouseClass.BRUTE)
	# Well clear of every other pile this file has made, so `drop_merge_radius` is not quietly
	# doing the collecting for us and the check calling that a pass.
	var here := _stores_of(Team.BLUE) + Vector3(26.0, 0.0, 26.0)
	await _park(_blue, here, 4)

	var load := 4
	_blue.release_wedges()
	for i in range(load):
		# The stow clock is reached past on purpose. What is being tested is the drop, and making
		# the audit sit through twenty seconds of cooldown to reach it would be testing patience.
		_blue._wedge_wait = 0.0
		_blue.take_wedge()
	_ok("a Brute is holding an armful", _blue.get_carried_cheese() == load,
		"carrying %d" % _blue.get_carried_cheese())

	_blue.take_hit(9999.0, here + Vector3(1.0, 0.0, 0.0), 0.0, _red)
	await process_frame
	await process_frame

	var found := 0
	var piles := 0
	for node in get_nodes_in_group(CheeseCache.GROUP):
		var pile := node as CheeseCache
		if pile == null or pile.global_position.distance_to(here) > 8.0:
			continue
		found += pile.wedges
		if pile.wedges > 0:
			piles += 1
	_ok("every wedge is still on the map", found == load,
		"%d of %d wedges landed" % [found, load])
	_ok("and they did not all land in one spot", piles > 1,
		"%d wedges in %d pile(s)" % [found, piles])

	_blue.set_class(was)
	_blue.revive_at(_stores_of(Team.BLUE))
	await process_frame


## Two mice scruffed on the same ground leave ONE growing pile, not a scatter of single wedges.
## Permanent drops without this turn a contested corridor into litter.
func _check_drops_merge() -> void:
	print("\n-- drops on the same ground join up")
	var spot := Vector3(3.0, 0.0, 12.0)
	var before := CheeseCache.nearest(self, spot)
	var piles_before := get_nodes_in_group(CheeseCache.GROUP).size()

	_director.call("_drop_cheese", spot, 1)
	await process_frame
	var pile := CheeseCache.nearest(self, spot)
	_ok("the first drop makes a pile", pile != null and pile != before)
	var after_first: int = pile.wedges

	_director.call("_drop_cheese", spot + Vector3(0.6, 0.0, 0.0), 1)
	await process_frame
	_ok("the second joins it rather than starting another",
		get_nodes_in_group(CheeseCache.GROUP).size() == piles_before + 1,
		"%d piles before, %d now" % [piles_before, get_nodes_in_group(CheeseCache.GROUP).size()])
	_ok("and the pile grew", pile.wedges == after_first + 1,
		"%d -> %d" % [after_first, pile.wedges])

	# Far enough away is its own pile, or merging would swallow the whole map into one dot.
	_director.call("_drop_cheese", spot + Vector3(0.0, 0.0, 14.0), 1)
	await process_frame
	_ok("a drop well clear starts its own",
		get_nodes_in_group(CheeseCache.GROUP).size() == piles_before + 2)


## Six seconds while you can pay, twenty while you cannot -- and the crew on its LAST cheese
## still gets the short one, because it could afford the death it just took.
func _check_broke_respawn() -> void:
	print("\n-- the broke respawn")
	var side := Team.RED
	while _director.cheese_of(side) > 1:
		_director.call("_spend_cheese", side, _director.cheese_of(side) - 1)
	_ok("a crew on its last cheese waits the short time",
		is_equal_approx(_director.respawn_wait(side), _director.respawn_seconds),
		"%.1fs at %d cheese" % [_director.respawn_wait(side), _director.cheese_of(side)])

	_director.call("_spend_cheese", side, 1)
	_ok("a broke crew waits the long time",
		is_equal_approx(_director.respawn_wait(side), _director.broke_respawn_seconds),
		"%.1fs at %d cheese" % [_director.respawn_wait(side), _director.cheese_of(side)])
	_ok("broke is survivable, not terminal", _director.broke_respawn_seconds < 60.0)


## The pile has a lid, so hauling cheese cannot become a way to win by not fighting.
func _check_ceiling() -> void:
	print("\n-- the ceiling")
	_director.gain_cheese(Team.RED, 9999)
	_ok("cheese stops at the ceiling",
		_director.cheese_of(Team.RED) == _director.cheese_ceiling,
		"%d vs ceiling %d" % [_director.cheese_of(Team.RED), _director.cheese_ceiling])


## Scurry costs exactly one, is refused when the crew is broke, and is refused on cooldown --
## and a refusal must never charge for nothing.
func _check_scurry_costs_and_gates() -> void:
	print("\n-- Scurry is a spend, and a gated one")
	_director.gain_cheese(Team.BLUE, 10)
	var before := _director.cheese_of(Team.BLUE)
	_ok("it fires", _director.try_scurry(_blue))
	_ok("it cost exactly one", _director.cheese_of(Team.BLUE) == before - 1,
		"%d -> %d" % [before, _director.cheese_of(Team.BLUE)])
	_ok("the mouse is boosting", _blue.is_boosting())

	var during := _director.cheese_of(Team.BLUE)
	_ok("a second press on cooldown is refused", not _director.try_scurry(_blue))
	_ok("the refusal charged nothing", _director.cheese_of(Team.BLUE) == during)

	# Broke: refused, and still nothing charged.
	while _director.cheese_of(Team.RED) > 0:
		_director.call("_spend_cheese", Team.RED, _director.cheese_of(Team.RED))
	_ok("a broke crew cannot Scurry", not _director.try_scurry(_red))
	_ok("and is not billed for being told no", _director.cheese_of(Team.RED) == 0)
	_ok("nor did the mouse start boosting", not _red.is_boosting())


## It MULTIPLIES current speed (GDD section 2, "don't relax it"). A flat top speed would erase
## the flag-carry penalty and make a Scurrying Sneak as good a carrier as a Generalist, which
## quietly deletes the handoff play.
func _check_scurry_multiplies() -> void:
	print("\n-- Scurry multiplies rather than sets")
	_director.gain_cheese(Team.RED, 10)
	_red.release_wedges()
	if _red.is_carrying():
		_red.release_carry()

	var plain := _red.move_speed()
	_red.take_carry(_director.banner_of(Team.BLUE))
	var burdened := _red.move_speed()
	_ok("carrying is slower", burdened < plain, "%.2f vs %.2f" % [burdened, plain])

	_ok("Scurry fires while carrying", _director.try_scurry(_red))
	var boosted := _red.move_speed()
	_ok("the boost is real", boosted > burdened, "%.2f vs %.2f" % [boosted, burdened])
	_ok("but it did NOT erase the carry penalty",
		boosted < plain * _red.scurry_multiplier - 0.001,
		"boosted carrier %.2f is not far off an unburdened %.2f" % [
			boosted, plain * _red.scurry_multiplier
		])
	_red.release_carry()


## The cheese world crosses as a complete, replaceable picture. Exercise the wire format and the
## reconciliation together: one authored-looking pile changes count, one disappears, and one new
## dropped pile appears. Those are the three transitions that used to exist only on the server.
func _check_cache_replication() -> void:
	print("\n-- the cheese lying in the world can be reproduced")
	var first := CheeseState.new()
	first.revision = 41
	first.add(Vector3(31.0, 0.0, -31.0), 2, 0.22)
	first.add(Vector3(-31.0, 0.0, 31.0), 4, 0.34)
	var bytes := first.to_bytes()
	var decoded := CheeseState.from_bytes(bytes)
	_ok("a complete cache picture survives bytes", decoded != null
		and decoded.revision == 41 and decoded.caches.size() == 2)
	_ok("the packet carries place, count and look", decoded != null
		and decoded.caches[0].position.is_equal_approx(Vector2(31.0, -31.0))
		and decoded.caches[0].wedges == 2
		and is_equal_approx(decoded.caches[0].spread, 0.22))
	_ok("a truncated cache picture is refused",
		CheeseState.from_bytes(bytes.slice(0, bytes.size() - 1)) == null)
	var padded := bytes.duplicate()
	padded.append(0)
	_ok("a padded cache picture is refused", CheeseState.from_bytes(padded) == null)

	_director.set_simulating(false)
	_director.adopt_cheese_caches(decoded)
	await process_frame
	var first_a := CheeseCache.nearest(self, Vector3(31.0, 0.0, -31.0))
	var first_b := CheeseCache.nearest(self, Vector3(-31.0, 0.0, 31.0))
	_ok("the client picture replaces its local cache set",
		get_nodes_in_group(CheeseCache.GROUP).size() == 2)
	_ok("a server pile is created at its authoritative position and count", first_a != null
		and first_a.global_position.distance_to(Vector3(31.0, 0.0, -31.0)) < 0.01
		and first_a.wedges == 2)

	var second := CheeseState.new()
	second.revision = 42
	second.add(Vector3(31.0, 0.0, -31.0), 7, 0.22)
	second.add(Vector3(29.0, 0.0, 29.0), 1, 0.22)
	_director.adopt_cheese_caches(second)
	await process_frame
	var changed := CheeseCache.nearest(self, Vector3(31.0, 0.0, -31.0))
	var spawned := CheeseCache.nearest(self, Vector3(29.0, 0.0, 29.0))
	_ok("a count update changes the existing pile rather than duplicating it",
		changed == first_a and changed.wedges == 7)
	_ok("a new dropped pile appears", spawned != null and spawned.wedges == 1)
	_ok("a pile absent from the next picture is removed",
		not is_instance_valid(first_b)
		and get_nodes_in_group(CheeseCache.GROUP).size() == 2)
