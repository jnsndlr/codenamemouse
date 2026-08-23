class_name RockBody
extends RefCounted
## A lump of stone sitting in the earth of one plane, as a shape rather than as a set of tiles.
##
## WHAT THIS REPLACES, AND WHY IT HAD TO. Rock used to be a dictionary of cells: a seam was grown as
## a random walk and every square it stepped on was flagged solid. Digging is not made of squares
## any more -- a stroke is a capsule at a free angle, contoured into a signed distance field at
## 12.5cm -- so the two descriptions of the earth disagreed everywhere they met. A stroke was
## refused if any cell it made walkable held rock, but its BODY is wider than the cells it claims,
## so a corridor run alongside a seam quietly ate a bite out of the stone: the wall was drawn
## through the middle of a rock cell, the mouse walked into ground the rules called permanent, and
## nothing anywhere errored. You could dig INSIDE the rock.
##
## SO THE ROCK IS IN THE FIELD NOW. A rock is a distance function, exactly like a stroke is, and the
## dug region is the strokes MINUS the stone -- one `min` per sample in [method TunnelNetwork.
## _rebuild_chunk]. Everything downstream of the field then agrees for free and without being told
## rock exists: the wall wraps the stone because the contour follows the field, the collision mesh
## is built from the same triangles, the cutaway cuts to the same line, and `walkable_between` --
## which is the whole of the routing graph -- refuses to walk through it because the field says
## there is no room. One description of the earth instead of two.
##
## A UNION OF DISCS, WHICH IS THE WHOLE SHAPE. Three reasons, in order of how much they matter:
##
##   It is a real distance function. `min` of two exact distances is an exact distance to the union,
##   so the field stays 1-Lipschitz -- and the thin-earth pass, the island cull and the wall bevel
##   all read the field as a distance and misbehave in subtle, hard-to-attribute ways if it is not.
##   A wobbled radius (`r * (1 + noise(angle))`) draws the same picture and is not one.
##
##   It is lumpy for free. One disc is a circle, and a circle in the ground is the one shape that
##   reads as placed by a level designer -- the same objection the old random-walk seam existed to
##   answer. Four or five overlapping discs at jittered offsets give the lobed, bulging outline a
##   boulder actually has, and it comes out rounded at every scale because every part of the
##   boundary is an arc.
##
##   It comes apart in pieces. A Brute does not delete a rock, they take a LOBE off it (see
##   [method drop_lobe]) -- so a big stone is chewed through over several swings, the corridor
##   advances a bite at a time, and what the player sees is rock being broken up rather than a
##   countdown ending in an object disappearing. That is the collaboration the design wants: the
##   Engineer routes around a rock, or the Brute opens it while they wait.
##
## SEEDED, like every other layout in this project, because a map you cannot replay is a map you
## cannot learn (GDD section 8) and because a bug on one layout is a bug you can only reproduce by
## luck. It is also what lets the stone cross the network for free: both ends grow the identical
## rocks from `rock_seed` and only the KNOWLEDGE of them is ever sent.

## Lobes a breakable rock is built from. More than a bedrock lump gets, because these are the ones
## the design wants to look hand-broken -- and because the count is also the number of bites it
## takes to chew through one.
const LOBES_BREAKABLE: Vector2i = Vector2i(4, 7)
## Lobes bedrock gets. Fewer and rounder: it is not going anywhere, so its job is to read as one
## solid mass to be gone around rather than as something with parts.
const LOBES_BEDROCK: Vector2i = Vector2i(2, 4)

## How far a lobe's centre may sit from the rock's, as a fraction of the rock's span, and how big a
## lobe is as a fraction of it. Tuned together: the offsets have to stay inside the radii or the
## lobes stop overlapping and the "rock" comes out as a constellation of pebbles.
##
## THE RADIUS RANGE IS WIDE ON PURPOSE. The first version kept every lobe within a fifth of the
## same size and the results read as a cloud -- five identical circles, obviously drawn by a rule.
## What makes a silhouette read as broken stone is one or two big masses with smaller ones crowding
## the gaps, which is what a range this wide produces without any extra machinery.
##
## `[REVISED]` THE NEAR END OF THE OFFSET RANGE HAD TO MOVE OUT, AND IT IS A RULE ABOUT BITES RATHER
## THAN ABOUT LOOKS. A lobe at 0.20 of the span with a radius of 0.26 reaches 0.46 -- which is
## inside [constant CORE_RADIUS], so the lobe was wholly swallowed by the core and contributed
## nothing to the outline. Invisible is the cheap half of the problem. The expensive half is that a
## Brute breaks a rock A LOBE AT A TIME and takes the nearest one, so those buried lobes were four
## swings that opened no ground at all -- and with several of them in a rock the Engineer had
## nothing new to dig either, so the alternation the whole obstruction exists to create simply
## stalled. Every lobe now reaches past the core, so every bite is a bite of something.
const LOBE_OFFSET: Vector2 = Vector2(0.42, 0.78)
const LOBE_RADIUS: Vector2 = Vector2(0.26, 0.68)
## The middle lobe, which every rock gets and which is what stops a ring of outer lobes leaving a
## hole in the centre of the stone.
const CORE_RADIUS: float = 0.58
## Small lumps stuck on the outside, and only breakable rock gets them. Two purposes at once: they
## are what turns a smooth outline into a chipped one, and they are the cheap bites -- a Brute
## working on a rock takes the nubs off first, which is a visible, early reward for starting.
const CHIP_COUNT: Vector2i = Vector2i(1, 3)
const CHIP_RADIUS: Vector2 = Vector2(0.18, 0.34)
## How much of a chip is buried in the mass it is stuck to, as a fraction of its own radius. Placed
## by OFFSET instead, the arithmetic has to guess where the outline is from the lobe ranges, and it
## guessed wrong often enough to leave pebbles floating a handspan off the rock -- which is not a
## chipped rock, it is a second tiny rock the player cannot tell apart from the first.
const CHIP_BITE: float = 0.4

## The span at which a rock gets one lobe, and the span at which it gets the full range of them.
##
## DETAIL SCALES WITH SIZE, AND IT HAS TO. The lobe counts above were written when a rock was one to
## two and a half metres of RADIUS, where seven lobes plus three chips is a lobed outcrop. At the
## size a rock is now, the same counts put eleven overlapping discs inside a lump the width of two
## hands -- and each of those discs comes out a fraction of the 12.5cm the field is stored at, so
## the whole of that detail lands between samples and none of it can be seen. It is not merely
## wasted: every lobe is a disc written over its own square of the field on every rebuild, so a
## pebble was costing what an outcrop costs to draw a shape identical to one circle.
##
## Below [constant SPAN_SIMPLE] a rock is one disc, which at that size is what a stone looks like.
## Above [constant SPAN_DETAILED] it gets the counts in full. In between it grows lobes as it grows.
## TUNED AGAINST THE SIZES ROCKS ACTUALLY COME IN, which is why `SPAN_DETAILED` sits well above the
## top of `rock_span` rather than at it. A rock at the top of the range was coming out with ten
## lobes inside a lump under three metres across, at offsets and radii that made every one of them
## overlap every other -- so the shape was a circle, none of the structure could be seen, and a
## Brute had to eat five bites before any ground opened because the neighbours still covered the
## hole. Landing the biggest rock at about half detail gives three or four lobes, which is the
## fewest that still reads as broken rather than round.
const SPAN_SIMPLE: float = 0.34
const SPAN_DETAILED: float = 2.10
## The smallest a rock has to be before chips are worth sticking on it. Higher than the lobe ramp:
## a chip is a fraction of a lobe, so it falls under the sample spacing sooner.
const SPAN_CHIPPED: float = 0.95

## How tall a rock stands off its plane's floor, as a fraction of its own span.
##
## THE ONE NUMBER THAT DECIDES WHETHER YOU CAN SEE IT, and tying it to the span rather than rolling
## it independently is the whole of the idea. A layer of earth is `PLANE_SPACING` thick; a rock
## taller than that breaks the dirt above it and stands in daylight, and a rock shorter than it is
## buried with nothing on the surface to give it away. Scaled by span, that sorts itself: the big
## lumps show, the small ones ambush you, and the player learns to read "big rock nearby" off the
## surface without anybody writing a rule about it.
##
## The range straddles the layer on purpose. Rolled entirely above or entirely below it, every rock
## would be the same kind of surprise -- and half the point of the two outcomes is not knowing which
## one the ground you are digging into is.
const HEIGHT_OF_SPAN: Vector2 = Vector2(0.45, 1.15)

## Which plane's earth this is in. Rock is per-plane on purpose (GDD section 3): the point of the
## obstructions is that going AROUND one may mean going DOWN, and stone in the same place on every
## layer is a flat maze drawn three times.
var plane: int = 1
## The middle of the rock, in metres. Not snapped to anything -- the grid stopped being where the
## earth is decided, and a rock lined up to it would advertise a lattice that no longer exists.
var centre: Vector2 = Vector2.ZERO
## Whether a Brute can shift it. The one bit of the design a player has to be able to read off the
## rock itself, which is what the two stone colours are for -- see `TunnelNetwork.rock_color` and
## `bedrock_color`.
var breakable: bool = false
## `x, y` centre in metres, `z` radius. The whole shape.
var lobes: Array[Vector3] = []
## The rock's nominal radius, kept because the height and the drawn lumps are both scaled off it and
## reconstructing it from the lobes afterwards gets a different number every time.
var span: float = 1.0
## How far the stone stands off its plane's floor, in metres. COSMETIC AS FAR AS DIGGING GOES -- the
## field is one layer per plane, so a rock shuts its whole footprint through the full thickness of
## the earth however tall it is drawn. What this decides is whether you can SEE it: past the plane
## spacing the lump breaks the dirt above and gives itself away for free. See [constant
## HEIGHT_OF_SPAN].
var height: float = 0.5
## Stable across a match and across both ends of a wire, because it is the rock's place in the
## per-plane array and that array is grown from the seed in the same order on every machine. What a
## broken lobe is addressed by.
var index: int = 0


## Grow one, from a seed.
##
## `span` is the rock's nominal radius in metres; the outer reach comes out a little past it (see
## [method reach]) and is what anything measuring the rock should ask for.
static func grow(
	at_plane: int, at: Vector2, span: float, can_break: bool, rng: RandomNumberGenerator
) -> RockBody:
	var rock := RockBody.new()
	rock.plane = at_plane
	rock.centre = at
	rock.breakable = can_break
	rock.span = span
	rock.height = span * rng.randf_range(HEIGHT_OF_SPAN.x, HEIGHT_OF_SPAN.y)

	# The core, dead centre. Everything else hangs off it, and it is why a rock cannot come out
	# hollow however the outer lobes fall.
	rock.lobes.append(Vector3(at.x, at.y, span * CORE_RADIUS))

	var range_of: Vector2i = LOBES_BREAKABLE if can_break else LOBES_BEDROCK
	# How much of the full lobe count this rock's size earns. Rolled at the rock's own detail rather
	# than clamped afterwards, so a big rock still spans its whole range and a small one is
	# reliably simple rather than occasionally elaborate.
	var detail := clampf(
		(span - SPAN_SIMPLE) / (SPAN_DETAILED - SPAN_SIMPLE), 0.0, 1.0
	)
	var count := int(round(float(rng.randi_range(range_of.x, range_of.y)) * detail))
	# Walked round in even steps with the angle jittered, rather than drawn uniformly. Pure random
	# angles clump -- three lobes in one quadrant and none in the other three is the commonest
	# single outcome at these counts -- and a rock with all its weight on one side reads as a
	# mistake rather than as a shape.
	var turn := rng.randf() * TAU
	for i in range(count):
		var angle := turn + TAU * float(i) / float(count) + rng.randf_range(-0.4, 0.4)
		var away := span * rng.randf_range(LOBE_OFFSET.x, LOBE_OFFSET.y)
		var here := at + Vector2(cos(angle), sin(angle)) * away
		rock.lobes.append(
			Vector3(here.x, here.y, span * rng.randf_range(LOBE_RADIUS.x, LOBE_RADIUS.y))
		)

	if can_break and span >= SPAN_CHIPPED:
		var chips := rng.randi_range(CHIP_COUNT.x, CHIP_COUNT.y)
		for i in range(chips):
			var angle := rng.randf() * TAU
			var radius := span * rng.randf_range(CHIP_RADIUS.x, CHIP_RADIUS.y)
			# PLACED ON THE OUTLINE THE ROCK ALREADY HAS, rather than at a guessed distance. Where
			# the edge is in a given direction depends on which lobes happened to land near it, so
			# it is asked rather than assumed -- see [method edge_along].
			var away := rock.edge_along(angle) - radius * CHIP_BITE
			var here := at + Vector2(cos(angle), sin(angle)) * maxf(away, 0.0)
			rock.lobes.append(Vector3(here.x, here.y, radius))
	return rock


## How far the outline reaches from the middle in one direction, in metres.
##
## BISECTED RATHER THAN SOLVED, because the union of a handful of discs has no closed form worth
## writing and this runs a couple of times per rock, once, at startup. Twelve steps over the outer
## reach settles it to well under a millimetre at these sizes.
func edge_along(angle: float) -> float:
	var direction := Vector2(cos(angle), sin(angle))
	var low := 0.0
	var high := reach()
	for i in range(12):
		var middle := (low + high) * 0.5
		if depth(centre + direction * middle) > 0.0:
			low = middle
		else:
			high = middle
	return low


## How far into the stone this point is, in metres. Zero at the surface, negative outside it.
##
## THE MAXIMUM, because the rock is the UNION of its lobes and the deepest reading is the one
## furthest inside. Negated it is the signed distance to the rock, which is what the field wants.
func depth(point: Vector2) -> float:
	var deepest := -1000.0
	for lobe: Vector3 in lobes:
		var into := lobe.z - point.distance_to(Vector2(lobe.x, lobe.y))
		if into > deepest:
			deepest = into
	return deepest


func holds(point: Vector2) -> bool:
	return depth(point) > 0.0


## The furthest any part of the stone reaches from its centre. What anything gathering rocks by
## proximity has to grow its window by.
func reach() -> float:
	var out := 0.0
	for lobe: Vector3 in lobes:
		out = maxf(out, centre.distance_to(Vector2(lobe.x, lobe.y)) + lobe.z)
	return out


## How far the stone stands proud of a layer of earth `thickness` metres thick, or zero if it does
## not reach the top at all.
##
## THE WHOLE VISIBILITY RULE, in one subtraction. Everything below the dirt is already drawn -- it
## is the stone face the contour wrapped round the rock when somebody dug up to it -- so the only
## part that needs a mesh of its own is the part standing above the ground, and this is how much of
## one there is.
func rise_above(thickness: float) -> float:
	return maxf(height - thickness, 0.0)


func breaks_surface(thickness: float) -> bool:
	return height > thickness


func bounds() -> Rect2:
	var span := reach()
	return Rect2(centre - Vector2(span, span), Vector2(span, span) * 2.0)


## One lobe's own square, for the chunk pass -- which writes each lobe over its own window rather
## than the whole rock's, exactly as it does for each stroke.
static func lobe_bounds(lobe: Vector3, grow_by: float) -> Rect2:
	var span := lobe.z + grow_by
	return Rect2(Vector2(lobe.x - span, lobe.y - span), Vector2(span, span) * 2.0)


## Whichever lobe a mouse standing here is closest to the surface of. What a swing lands on.
##
## MEASURED TO THE SURFACE, NOT TO THE CENTRE, and that is the difference between a rock you break
## from the face you are standing at and a rock whose biggest lobe absorbs every swing wherever you
## hit it. Chewing through a stone should advance from the side you are working on.
func nearest_lobe(from: Vector2) -> int:
	var best := INF
	var found := -1
	for i in range(lobes.size()):
		var lobe: Vector3 = lobes[i]
		var gap := from.distance_to(Vector2(lobe.x, lobe.y)) - lobe.z
		if gap < best:
			best = gap
			found = i
	return found


## The point on the stone's outside nearest to `from` -- what a Brute is actually swinging at, and
## what the reach is measured against.
##
## Approximated as the nearest point on the nearest lobe, which is exact except in the crease where
## two lobes overlap, where it returns a point a little inside the union. Being a centimetre or two
## generous in a crevice costs nothing here: this decides whether a swing is close enough to land,
## and the crease is the one place the stone is unambiguously right in front of you.
func surface_point(from: Vector2) -> Vector2:
	var i := nearest_lobe(from)
	if i < 0:
		return centre
	var lobe: Vector3 = lobes[i]
	var middle := Vector2(lobe.x, lobe.y)
	var away := from - middle
	if away.length_squared() < 0.000001:
		return middle + Vector2(lobe.z, 0.0)
	return middle + away.normalized() * lobe.z


## Take one lobe off. The Brute's swing, and the only thing that ever changes a rock's shape.
func drop_lobe(i: int) -> void:
	if i >= 0 and i < lobes.size():
		lobes.remove_at(i)


func is_gone() -> bool:
	return lobes.is_empty()


## Does the stone reach into this cell's square at all -- not just cover its middle?
##
## THE QUESTION A REVEAL ASKS, and it is deliberately looser than [method cells]. You have learned a
## rock is there when your shovel rings off it, and that happens in whichever square you were
## digging in -- which is very often a square the rock only clips. Circle against axis-aligned
## square, per lobe, which is two clamps and a distance.
func touches_cell(cell_centre: Vector2, half: float) -> bool:
	for lobe: Vector3 in lobes:
		var near := Vector2(
			clampf(lobe.x, cell_centre.x - half, cell_centre.x + half),
			clampf(lobe.y, cell_centre.y - half, cell_centre.y + half)
		)
		if near.distance_to(Vector2(lobe.x, lobe.y)) < lobe.z:
			return true
	return false


## The cells whose CENTRES are inside the stone.
##
## THE COARSE INDEX, and it is honest about being coarse. Everything that has to be exact about
## where the rock is asks [method depth] at a point; this is for the things that are about squares
## anyway -- the minimap, the knowledge sheet, "may a shaft land here", "may a bot plan to dig
## here". A cell the rock only clips is not in this list and should not be: there is diggable earth
## in it, and a bot told otherwise would route round ground it could have taken.
func cells(cell_size: float, limit: int) -> Array[Vector2i]:
	var found: Array[Vector2i] = []
	var box := bounds()
	var low := Vector2i(floori(box.position.x / cell_size), floori(box.position.y / cell_size))
	var high := Vector2i(ceili(box.end.x / cell_size), ceili(box.end.y / cell_size))
	for y in range(low.y, high.y + 1):
		for x in range(low.x, high.x + 1):
			if absi(x) > limit or absi(y) > limit:
				continue
			if holds(Vector2(float(x) * cell_size, float(y) * cell_size)):
				found.append(Vector2i(x, y))
	return found
