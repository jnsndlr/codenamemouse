extends SceneTree
## Does the island cull swallow the scraps, keep the pillars, and agree with itself across a chunk
## border?
##
##   godot --headless --path . --script tools/island_probe.gd
##
## WHY THIS IS NOT PART OF tunnel_audit.gd. The audit asks whether the world is SOUND -- no gaps, no
## walls inside corridors, collision under every floor -- and a chamber full of undiggable crumbs
## passes every one of those. The cull is about whether the world is USABLE, which is a different
## question and needs its own answers.
##
## The four that matter, in the order they can fail:
##
##   SIZE      A scrap under `island_max_span` goes; a pillar over it stays. If the threshold does
##             not bite, nothing else here means anything.
##   AREA      `island_max_area` keeps a lump the span would have taken, and never the other way
##             round. A footprint test that could swallow something the span refused would be a
##             BORDER failure waiting for the right scrap to wander across a chunk line.
##   THIN      Earth too thin for a disc to fit in goes even when it is joined to the bulk, and the
##             bulk it is joined to does not so much as flinch. This is the one the other two
##             cannot reach: a cusp between two strokes is attached earth, so no rule about islands
##             will ever see it.
##   BORDER    The same lump gets the same verdict whichever chunk is looking at it. This is the
##             one that would ship: a disagreement leaves HALF an island standing, which is worse
##             than the whole one and only shows up on scraps that happen to straddle a 4m line.
##   ROCK      A nub in a rock cell is the last of a seam and is meant to be permanent. The field
##             cannot tell stone from earth nobody got to yet, so the cull has to be told -- and
##             told twice, once for each rule.
##
## Plus what a dig actually costs, since the cull is paid for by sampling every chunk wider than it
## is drawn.

const PLANE: int = 1


func _initialize() -> void:
	var scene := (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
	var network := scene.get_node("Tunnels") as TunnelNetwork
	network.rock_density = 0.0
	(scene.get_node("MatchDirector") as MatchDirector).crew_size = 1
	root.add_child(scene)
	await process_frame
	await process_frame

	var failures := 0
	failures += _check_size(network)
	failures += _check_area(network)
	failures += _check_thin(network)
	failures += _check_border(network)
	failures += _check_rock(network)
	failures += _check_dig(network)
	scene.free()
	await _report_cost()

	print("")
	if failures == 0:
		print("=".repeat(78))
		print("ISLAND CULL HOLDS: scraps swallowed, pillars kept by span AND footprint,")
		print("borders agree, rock untouched.")
		print("=".repeat(78))
	else:
		printerr("%d island cull checks FAILED" % failures)
	quit(0 if failures == 0 else 1)


## SIZE. A lump under the span goes; a lump over it stays.
func _check_size(network: TunnelNetwork) -> int:
	print("")
	print("-- size")
	var bad := 0
	for span: float in [0.25, 0.5, 0.7]:
		if _earth_after(network, span) > 0:
			printerr("   a %.2fm lump survived a %.2fm cull" % [span, network.island_max_span])
			bad += 1
	for span: float in [1.0, 2.0, 3.0]:
		if _earth_after(network, span) == 0:
			printerr("   a %.2fm pillar was swallowed by a %.2fm cull" % [
				span, network.island_max_span
			])
			bad += 1
	if bad == 0:
		print("   ok -- swallowed under %.2fm, kept over it" % network.island_max_span)
	return bad


## AREA. The footprint dial keeps what the span would have taken, and cannot take what the span
## kept.
##
## CALIBRATED AGAINST THE LUMP RATHER THAN AGAINST ARITHMETIC. A rectangle's footprint in samples
## depends on where its edges fall between them, so "0.7 by 0.7 is 0.49 square metres" is true on
## paper and off by a row either way in the window. Measuring the lump first and setting the dial
## on either side of what it actually covers tests the dial instead of testing the grid.
func _check_area(network: TunnelNetwork) -> int:
	print("")
	print("-- area")
	var kept := network.island_max_area
	var bad := 0

	# A solid post, comfortably inside the span: the span alone swallows it, so it is the footprint
	# and only the footprint deciding here.
	var post := Vector2(0.7, 0.7)
	var covers := float(_earth_count(_box(network, post))) * TunnelContour.TEXEL ** 2

	network.island_max_area = covers * 0.5
	if _earth_after_box(network, post) == 0:
		printerr("   a %.3f sq m post was swallowed under a %.3f sq m limit" % [
			covers, network.island_max_area
		])
		bad += 1

	network.island_max_area = covers * 1.5
	if _earth_after_box(network, post) > 0:
		printerr("   a %.3f sq m post survived a %.3f sq m limit" % [
			covers, network.island_max_area
		])
		bad += 1

	# The same span, two rows of samples thick. Same box, a third of the earth in it -- which is the
	# whole reason the dial exists.
	#
	# THICK ENOUGH TO EXIST, and that is not a detail. Asked at 0.1m the sliver falls between the
	# sample rows entirely, the window comes back with no earth in it at all, and a test for "was it
	# swallowed" passes without anything having been there to swallow. `_earth_before` is what says
	# so out loud rather than letting the check go quiet.
	var sliver := Vector2(0.7, 0.25)
	bad += _earth_before(network, sliver)
	network.island_max_area = covers * 0.5
	if _earth_after_box(network, sliver) > 0:
		printerr("   a sliver inside the span survived a %.3f sq m limit" % network.island_max_area)
		bad += 1

	# AND THE DIRECTION THAT MUST NEVER WORK. A bar wider than the span has a small footprint and no
	# bound at all on where it wanders, so no amount of allowance may swallow it.
	var bar := Vector2(3.0, 0.25)
	bad += _earth_before(network, bar)
	network.island_max_area = 100.0
	if _earth_after_box(network, bar) == 0:
		printerr("   a bar wider than the span was swallowed on its footprint alone")
		bad += 1

	network.island_max_area = kept
	if bad == 0:
		print("   ok -- footprint narrows the span's verdict, never widens it")
	return bad


## Earth left in a window holding one square lump of the given size, alone in open tunnel.
func _earth_after(network: TunnelNetwork, metres: float) -> int:
	return _earth_after_box(network, Vector2(metres, metres))


func _earth_after_box(network: TunnelNetwork, size: Vector2) -> int:
	var values := _box(network, size)
	network._cull_islands(
		PLANE, values, _wide(network), Vector2.ZERO, network._cull_pad(),
		TunnelContour.CHUNK_TEXELS
	)
	return _earth_count(values)


## A window of open tunnel with one rectangular lump of earth standing in the middle of it.
func _box(network: TunnelNetwork, size: Vector2) -> PackedFloat32Array:
	var wide := _wide(network)
	var centre := float(wide) * TunnelContour.TEXEL * 0.5
	return _sample(wide, Vector2.ZERO, func(at: Vector2) -> float:
		var from := at - Vector2(centre, centre)
		return minf(size.x * 0.5 - absf(from.x), size.y * 0.5 - absf(from.y))
	)


## Complains, and counts as a failure, if a lump this test is about to reason over is too thin to
## put a single sample on the grid.
func _earth_before(network: TunnelNetwork, size: Vector2) -> int:
	if _earth_count(_box(network, size)) > 0:
		return 0
	printerr("   a %v lump falls between the samples -- the check below would prove nothing" % size)
	return 1


func _wide(network: TunnelNetwork) -> int:
	return TunnelContour.CHUNK_TEXELS + 1 + network._cull_pad() * 2


## THIN. A disc has to fit, and nothing else is asked.
##
## THE WEDGE IS THE ONE THAT MATTERS. A bar is a fair test of the arithmetic, but the artifact this
## rule exists for is a cusp: two strokes meeting at an angle leave a tapering tooth of earth whose
## tip is a few centimetres across and whose base is part of the map. Nothing about size or
## connectedness can tell that tooth from the ground it grows out of. Thickness can, and has to --
## the tip must go, the base must not move.
func _check_thin(network: TunnelNetwork) -> int:
	print("")
	print("-- thin")
	var bad := 0
	var disc := network.earth_min_thickness * 0.5

	# A PLAIN WALL FIRST, because the rule rewrites every sample within a disc of one whether it
	# means to move it or not, and the value it writes has to come out as the value that was already
	# there. Get this wrong and every wall in the game creeps by a few centimetres and wobbles by a
	# few more -- which is not a bug anyone would report as an island cull.
	var straight := _sample(_wide(network), Vector2.ZERO, func(at: Vector2) -> float:
		return at.y - float(_wide(network)) * TunnelContour.TEXEL * 0.5
	)
	var before := straight.duplicate()
	network._thin_earth(PLANE, straight, _wide(network), Vector2.ZERO)
	var moved := 0.0
	for k in range(before.size()):
		moved = maxf(moved, absf(before[k] - straight[k]))
	if moved > 0.001:
		printerr("   a straight wall moved by %.1f mm under the thickness rule" % [
			TunnelContour.decode(0.5 - moved) * 1000.0
		])
		bad += 1
	else:
		print("   straight wall unmoved to within a hundredth of a texel")

	# A bar thinner than the rule, and long enough that no rule about islands would look at it.
	#
	# SIZED OFF THE SETTING, NOT OFF A ROUND NUMBER. The rule is set below what a 20cm wall's
	# deepest SAMPLE reads, so a test bar has to be thinner than the grid's own margin or it walks
	# straight through a rule that is working perfectly.
	var wafer := Vector2(3.0, 0.15)
	bad += _earth_before(network, wafer)
	if _thin_after(network, _box(network, wafer)) > 0:
		printerr("   a %.2fm wafer survived a %.2fm minimum" % [
			wafer.y, network.earth_min_thickness
		])
		bad += 1

	# A slab the disc fits inside. Its edge reads shallower than the disc's radius and is kept anyway
	# on the strength of what stands behind it, which is the whole difference between an opening and
	# simply deleting everything shallow.
	#
	# ITS CORNERS ARE ANOTHER MATTER, and losing them is the rule working. A disc cannot fit into a
	# right-angled corner and still cover the point of it, so an opening rounds every convex corner
	# of the earth to its own radius -- always has, by definition, and here that is a 25cm easing on
	# a corner nobody could tell from a hard one at this scale. So what is asserted is the thing
	# that would actually be a bug: earth the disc DOES fit inside must not be touched.
	var slab := Vector2(3.0, 1.0)
	var eased := _thin_loss(network, _box(network, slab))
	if eased[1] > 0:
		printerr("   a %.2fm slab lost %d samples of solid %.2fm-thick earth" % [
			slab.y, eased[1], disc * 2.0
		])
		bad += 1
	else:
		print("   slab kept, bar %d corner samples eased by the disc" % eased[0])

	# And the cusp. Trimmed back to where the disc first fits, and no further.
	var wedge := _wedge(network, 3.0, deg_to_rad(5.0))
	var whole := _earth_count(wedge)
	var trimmed := _thin_loss(network, wedge)
	if trimmed[1] > 0:
		printerr("   a cusp lost %d samples of solid earth along with its tip" % trimmed[1])
		bad += 1
	elif trimmed[0] == 0:
		printerr("   a tapering cusp kept its tip under a %.2fm minimum" % [
			network.earth_min_thickness
		])
		bad += 1
	elif trimmed[0] == whole:
		printerr("   a tapering cusp was shaved away to nothing, base and all")
		bad += 1
	else:
		print("   cusp trimmed: %d of %d samples gone, the thick base kept whole" % [
			trimmed[0], whole
		])

	if bad == 0:
		print("   ok -- thin earth opened out, thick earth untouched")
	return bad


## A tapering wedge of earth in open tunnel: the shape two strokes leave on the outside of a joint.
func _wedge(network: TunnelNetwork, length: float, half_angle: float) -> PackedFloat32Array:
	var wide := _wide(network)
	var middle := float(wide) * TunnelContour.TEXEL * 0.5
	var apex := Vector2(middle - length * 0.5, middle)
	return _sample(wide, Vector2.ZERO, func(at: Vector2) -> float:
		var along := at.x - apex.x
		var across := absf(at.y - apex.y)
		# Distance to the nearer of the two edges, and to the blunt far end.
		return minf(along * sin(half_angle) - across * cos(half_angle), length - along)
	)


## What the thickness rule took out of a window, as `[samples opened, of which were solid]`. The
## second number is the one that must be zero: earth a disc fits inside is earth the rule has no
## business touching, whatever else it does.
func _thin_after(network: TunnelNetwork, values: PackedFloat32Array) -> int:
	network._thin_earth(PLANE, values, _wide(network), Vector2.ZERO)
	return _earth_count(values)


func _thin_loss(network: TunnelNetwork, values: PackedFloat32Array) -> Array[int]:
	var before := values.duplicate()
	network._thin_earth(PLANE, values, _wide(network), Vector2.ZERO)
	var solid := TunnelContour.encode(network.earth_min_thickness * 0.5)
	var opened := 0
	var wrongly := 0
	for k in range(before.size()):
		if before[k] > TunnelContour.SURFACE or values[k] <= TunnelContour.SURFACE:
			continue
		opened += 1
		if before[k] <= solid:
			wrongly += 1
	return [opened, wrongly]


## BORDER. Two chunks reading the same earth write the same field down the line they share.
##
## THE SHARED COLUMN IS THE WHOLE QUESTION. Chunks are contoured one sample wider than they are
## wide, precisely so the wall on a border is built from the same numbers on both sides; if the two
## write different values there, the two meshes part company and there is a crack in the world.
## Built in WORLD space and sampled twice, which is the only honest way to ask -- the two windows
## have different origins, different edges and a different idea of which texel is theirs, and the
## claim is that none of that reaches the answer.
##
## RUN THROUGH BOTH RULES, in the order a chunk runs them. Each is local for its own reason and the
## reasons are different -- one by a disc's reach, one by a measured span -- so the thing worth
## testing is the pair, not either alone.
func _check_border(network: TunnelNetwork) -> int:
	print("")
	print("-- border")
	var pad := network._cull_pad()
	var n := TunnelContour.CHUNK_TEXELS
	var wide := n + 1 + pad * 2
	var seam := TunnelContour.CHUNK_METRES
	var down := Vector2(seam, seam * 0.5)
	var bad := 0

	# Every shape sits ON the seam, which is where a window-shaped answer would show itself.
	var shapes: Array = [
		["a scrap", func(at: Vector2) -> float: return 0.2 - at.distance_to(down)],
		["a nub", func(at: Vector2) -> float: return 0.35 - at.distance_to(down)],
		["a pillar", func(at: Vector2) -> float: return 1.0 - at.distance_to(down)],
		["a wafer", func(at: Vector2) -> float: return 0.12 - absf(at.y - down.y)],
		["a wall", func(at: Vector2) -> float: return 0.9 - absf(at.y - down.y)],
		["a cusp", func(at: Vector2) -> float:
			var along := at.x - (down.x - 1.5)
			return minf(along * 0.2588 - absf(at.y - down.y) * 0.9659, 3.0 - along)],
	]

	for shape: Array in shapes:
		var columns: Array[PackedFloat32Array] = []
		for chunk in [0, 1]:
			var origin := Vector2(
				float(chunk * n - pad) * TunnelContour.TEXEL, float(-pad) * TunnelContour.TEXEL
			)
			var values := _sample(wide, origin, shape[1] as Callable)
			network._thin_earth(PLANE, values, wide, origin)
			network._cull_islands(PLANE, values, wide, origin, pad, n)
			# The world column both chunks own: chunk 0's last, chunk 1's first.
			var i := n + pad if chunk == 0 else pad
			var column := PackedFloat32Array()
			for j in range(n + 1):
				column.append(values[(j + pad) * wide + i])
			columns.append(column)

		var parted := 0
		for j in range(columns[0].size()):
			var left := columns[0][j]
			var right := columns[1][j]
			# Different sides of the surface is a crack; a hair's difference in the value is float
			# arithmetic on two different origins and moves the wall by nothing anybody can see.
			if (left > TunnelContour.SURFACE) != (right > TunnelContour.SURFACE):
				parted += 1
			elif absf(left - right) > 0.0001:
				parted += 1
		if parted > 0:
			printerr("   %s on the seam: the two chunks disagree at %d of %d shared samples" % [
				shape[0], parted, columns[0].size()
			])
			bad += 1

	if bad == 0:
		print("   ok -- %d shapes on the seam, both chunks write the same column" % shapes.size())
	return bad


## ROCK. A seam's last nub is not a scrap, and its last wafer is not a sliver. Both rules have to
## be told, and neither can work it out from the field -- to these samples stone and untouched earth
## are the same thing.
func _check_rock(network: TunnelNetwork) -> int:
	print("")
	print("-- rock")
	var pad := network._cull_pad()
	var wide := _wide(network)
	var centre := float(wide) * TunnelContour.TEXEL * 0.5
	var cell := network.world_to_cell(Vector3(centre, 0.0, centre))
	var had: bool = network._rock[PLANE].has(cell)
	var bad := 0

	# Small enough for the island rule and thin enough for the thickness rule, so one nub in one
	# rock cell asks both questions at once. It has to survive both.
	var nub := _box(network, Vector2(0.15, 0.15))
	network._rock[PLANE][cell] = true
	network._thin_earth(PLANE, nub, wide, Vector2.ZERO)
	if _earth_count(nub) == 0:
		printerr("   a wafer of stone was opened out by the thickness rule")
		bad += 1
	network._cull_islands(PLANE, nub, wide, Vector2.ZERO, pad, TunnelContour.CHUNK_TEXELS)
	if _earth_count(nub) == 0:
		printerr("   a nub standing in a rock cell was swallowed")
		bad += 1
	if not had:
		network._rock[PLANE].erase(cell)

	if bad == 0:
		print("   ok -- stone left where it stands, by both rules")
	return bad


## The whole path, through a real dig: strokes that pinch off a scrap, and the dig rule agreeing
## afterwards that there is nothing there to take out.
##
## WITH THE THICKNESS RULE HELD OFF, because it gets to the scrap first. A pinched-off crumb is
## both small and thin, so with both rules running the thinning opens it out before the island walk
## ever sees it, and the bookkeeping this check exists for -- the boxes a swallowed island leaves
## behind, and `_is_earth` reading them -- is never exercised at all. That is fine in play and
## useless in a test.
func _check_dig(network: TunnelNetwork) -> int:
	print("")
	print("-- dig")
	network.earth_min_thickness = 0.0
	# A tight ring of strokes, each starting where the last ended and turning by an eighth of the
	# quantised circle. Five sides of a pentagon-ish loop close on themselves closely enough to pinch
	# off the middle -- a scrap a few texels across, which is exactly the shape this exists to catch.
	var at := Vector2(-14.0, 12.0)
	var turn := TunnelNetwork.ANGLE_STEPS / 5
	var angle := 0
	for i in range(6):
		if not network.dig_segment(PLANE, at, angle % TunnelNetwork.ANGLE_STEPS, Team.BLUE):
			break
		at = TunnelNetwork.segment_end(
			TunnelNetwork.segment_id(at, angle % TunnelNetwork.ANGLE_STEPS)
		)
		angle += turn

	var islands := 0
	for key: int in network._chunk_cache[PLANE]:
		var boxes: PackedFloat32Array = network._chunk_cache[PLANE][key]["islands"]
		islands += boxes.size() / 4
	if islands == 0:
		print("   no scrap pinched off by the ring -- the loop closed clean, nothing to report")
		return 0

	print("   %d scrap(s) swallowed by the ring" % islands)
	# And the dig rule has to have heard about it. A swallowed scrap that still measures as earth is
	# the same complaint one step along: the stroke is offered, spent, and nothing moves.
	var bad := 0
	for key: int in network._chunk_cache[PLANE]:
		var boxes: PackedFloat32Array = network._chunk_cache[PLANE][key]["islands"]
		for b in range(0, boxes.size(), 4):
			var middle := Vector2((boxes[b] + boxes[b + 2]) * 0.5, (boxes[b + 1] + boxes[b + 3]) * 0.5)
			if network._is_earth(PLANE, middle):
				printerr("   swallowed ground at %v still reports as diggable earth" % middle)
				bad += 1
	if bad == 0:
		print("   ok -- swallowed ground reports as dug, so no stroke is offered into it")
	return bad


## What the wider sampling costs, measured the way it is paid: the same corridor cut into the same
## empty map, timed at each setting.
##
## A NETWORK PER SETTING, WHICH IS NOT FUSSINESS. Timed one after another in one network this said
## the cull cost three times nothing, and said it just as confidently with the settings in reverse
## order -- because a dig re-assembles the whole plane's mesh from its chunks, so the honest signal
## here is drowned by how much tunnel happens to be on the map already. Same map, same strokes, one
## variable, or the number means nothing.
func _report_cost() -> void:
	print("")
	print("-- cost")
	# Each dial alone before the pair, since they stack: both widen the window a chunk samples, and
	# the window is where nearly all of this is spent.
	var settings: Array = [
		["both off", 0.0, 0.0],
		["islands 0.75m", 0.75, 0.0],
		["thickness 0.08m", 0.0, 0.075],
		["both", 0.75, 0.075],
		["both, generous", 1.0, 0.25],
	]
	for setting: Array in settings:
		var scene := (load("res://scenes/maps/arena.tscn") as PackedScene).instantiate()
		var network := scene.get_node("Tunnels") as TunnelNetwork
		network.rock_density = 0.0
		network.island_max_span = setting[1]
		network.earth_min_thickness = setting[2]
		(scene.get_node("MatchDirector") as MatchDirector).crew_size = 1
		root.add_child(scene)
		await process_frame
		await process_frame

		var at := Vector2(4.0, -14.0)
		var digs := 0
		var elapsed := 0.0
		for i in range(24):
			var angle := (i * 3) % TunnelNetwork.ANGLE_STEPS
			# TIMED AROUND THE DIG ITSELF, so the aiming arithmetic between strokes stays out of it.
			var start := Time.get_ticks_usec()
			var cut := network.dig_segment(PLANE, at, angle, Team.BLUE)
			elapsed += float(Time.get_ticks_usec() - start) / 1000.0
			if not cut:
				break
			at = TunnelNetwork.segment_end(TunnelNetwork.segment_id(at, angle))
			digs += 1
		print("   %-16s %6.2f ms over %d digs (%.2f ms each)" % [
			setting[0], elapsed, digs, elapsed / maxf(1.0, float(digs))
		])
		scene.free()


## A window of encoded samples from a world-space earth depth: positive is earth, negative is
## tunnel, which is the sense the field stores.
func _sample(wide: int, origin: Vector2, depth: Callable) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	values.resize(wide * wide)
	for j in range(wide):
		for i in range(wide):
			var at := origin + Vector2(float(i), float(j)) * TunnelContour.TEXEL
			values[j * wide + i] = TunnelContour.encode(depth.call(at))
	return values


func _earth_count(values: PackedFloat32Array) -> int:
	var count := 0
	for value: float in values:
		if value <= TunnelContour.SURFACE:
			count += 1
	return count
