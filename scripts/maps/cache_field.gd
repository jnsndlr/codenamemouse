extends Node3D
## Where the cheese is (GDD section 2). Seeded, like every other scatter on this map.
##
## PLACED IN A RING, not sprinkled. Cheese sprinkled evenly is cheese you pick up on the way to
## somewhere else, and then the economy is a tax on walking rather than an errand you choose. A
## ring pushes every cache off the nest-to-nest line, so going for one is a decision to be
## somewhere other than where the flag is -- which is the shape the bankruptcy play needs (§2:
## concede a capture, pull everyone off defence, go and refill). If cheese is on the way, nobody
## ever concedes anything to get it, and the best thing about cheese-as-lives never happens.
##
## SYMMETRIC ABOUT THE DIAGONAL. The nests sit at opposite corners, so caches are mirrored across
## the perpendicular -- neither crew has a shorter walk to the same pile, and the two flanks are
## worth the same. A random scatter gets this wrong often enough to matter and never says so.

@export var cache_seed: int = 20260802
## Caches per side of the diagonal. Six total is enough that two crews cannot hold all of them
## and few enough that emptying one matters.
@export_range(1, 8, 1) var per_side: int = 3
## Wedges in each. The pool starts at 20 and a respawn costs 1, so the yard holding roughly a
## crew's worth of lives is the point: refilling is possible, and never free.
@export var wedges_each: int = 6
## How far out the ring sits. Comfortably past both nests' defended radius (bot.gd's
## `defend_radius` is 9 from a nest at 20,20), so a cache is never inside someone's post.
@export var ring_radius: float = 23.0
## How much the ring is allowed to wander, so it does not read as six points on a circle.
@export var ring_jitter: float = 3.5
## How wide the fan either side of the perpendicular is, in degrees. 120 keeps the outermost
## cache a comfortable 30 degrees off the nest diagonal; widening it past about 150 starts
## putting cheese back on somebody's doorstep.
@export_range(0.0, 150.0, 5.0) var fan_degrees: float = 120.0
## No cache closer than this to either nest, whatever the angles work out to.
##
## A BACKSTOP FOR THE GEOMETRY, and it has earned its place: the ring's first pass was correct
## in intent and wrong by 45 degrees, and nothing about the result looked wrong until a cache
## turned up inside a defender's post. Angles are easy to get subtly wrong; a distance is not.
@export var nest_clear: float = 11.0
## Nothing inside this of the arena centre. The midfield is the contested lane; cheese there
## would be a second banner, and the map already has two.
@export var centre_clear: float = 9.0
@export var scene_half_extent: float = 34.0

## So the director can hang dropped wedges here rather than on itself. They then live under the
## same `surface_clutter` parent the authored caches do, and get hidden with everything else on
## the lawn when the view drops underground.
const GROUP: StringName = &"cheese_field"

var _cache_script := preload("res://scripts/game/cheese_cache.gd")


func _enter_tree() -> void:
	add_to_group(GROUP)


## Wedges are created and emptied during a match -- the director hangs dropped cheese here -- so
## this node's footprint must not be baked into the minimap's scenery layer. Its children publish
## their own shapes through `CheeseCache.GROUP`; what this keeps off the baked layer is the
## automatic AABB fallback that would otherwise freeze the caches at their opening positions.
## See minimap.gd's class comment.
func minimap_dynamic() -> bool:
	return true


func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = cache_seed
	var placed := 0

	# The nests sit on the 45-degree diagonal, so the perpendicular through the middle is at 135.
	# Spots fan out either side of THAT and are then mirrored through the origin, which is what
	# makes the two flanks equal without either one being on the nest-to-nest line.
	#
	# Centring the fan matters more than it looks. The first pass walked the arc from -45 degrees,
	# which put a cache exactly on the diagonal -- five metres from the red nest, inside the
	# defended radius, on the route everybody already runs. That is the one placement the ring
	# exists to prevent, and it shipped looking like a ring.
	var perpendicular := PI * 0.75
	for i in range(per_side):
		var spread := fan_degrees * PI / 180.0
		var step := 0.0 if per_side == 1 else float(i) / float(per_side - 1) - 0.5
		var around := perpendicular + step * spread
		var away := ring_radius + rng.randf_range(-ring_jitter, ring_jitter)
		var spot := Vector2(cos(around) * away, sin(around) * away)
		for mirrored: Vector2 in [spot, -spot]:
			if _place(mirrored, rng):
				placed += 1

	print("cheese: %d caches, %d wedges on the map" % [placed, placed * wedges_each])


func _place(spot: Vector2, rng: RandomNumberGenerator) -> bool:
	if not _allowed(spot):
		# Walk it back toward the ring rather than dropping the cache: a map that silently ships
		# five caches because one landed on the patio is a map whose economy changed without
		# anyone deciding it should.
		for attempt in range(24):
			var nudged := spot.rotated(rng.randf_range(-0.5, 0.5)) * rng.randf_range(0.85, 1.15)
			if _allowed(nudged):
				spot = nudged
				break
		if not _allowed(spot):
			push_warning("cache field: nowhere to put a cache near %s" % spot)
			return false

	var cache := Node3D.new()
	cache.set_script(_cache_script)
	cache.name = "Cache%d_%d" % [roundi(spot.x), roundi(spot.y)]
	cache.wedges = wedges_each
	add_child(cache)
	cache.global_position = Vector3(spot.x, 0.0, spot.y)
	return true


func _allowed(spot: Vector2) -> bool:
	if absf(spot.x) > scene_half_extent or absf(spot.y) > scene_half_extent:
		return false
	if spot.length() < centre_clear:
		return false
	# Well clear of both nests, and not on the paving -- cheese on the patio is cheese nobody can
	# be hidden while taking, which is a different game from the one the ring is for.
	for node in get_tree().get_nodes_in_group(&"nest"):
		var nest := node as Nest
		if nest == null:
			continue
		var home := Vector2(nest.global_position.x, nest.global_position.z)
		if spot.distance_to(home) < nest_clear:
			return false
	return not NoSurfaceZone.seals(get_tree(), spot, 0.5)
