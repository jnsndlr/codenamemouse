class_name CheeseCache
extends Node3D
## A pile of cheese on the ground, and the only way a crew ever gets a life back (GDD section 2).
##
## THE SAME CLASS IS ALSO A DROPPED WEDGE. A scruffed mouse drops what it was carrying where it
## fell, and what lands there is a pile with one wedge in it. Giving that its own class would mean
## two things a mouse can walk into and take cheese from, two pickup radii to keep in step, and
## two places to change when picking up stops being automatic. A cache with `wedges = 1` already
## IS that thing -- which is also the honest description of what a dropped wedge is.
##
## NOTHING ROTS. A dropped pile waits until somebody comes and gets it, however long that takes.
## An earlier pass gave drops a timer, on the theory that a wedge lying where somebody died is a
## contested object and a clock makes it urgent. That had it backwards: a pile that expires is a
## pile you can win by ignoring, and the only thing on this map anybody was ever obliged to
## contest was the flag. Cheese that stays put turns every fight that happened into somewhere
## worth going back to -- a second class of objective the map grows on its own.
##
## WEDGES ARE TAKEN ONE AT A TIME, and that is the whole shape of the economy rather than a
## detail. Section 2 says cheese is "carried home one wedge at a time", so a fat cache is not a
## prize you grab, it is a trip you make repeatedly across ground somebody else wants. Emptying
## one is a commitment measured in walks, which is what makes the bankruptcy play -- pull
## everyone off defence and go refill -- a real decision with a real window for the other crew.
##
## The rule is the pile and its count. The wedges you can see are placeholder art parented
## underneath, same bargain as no_surface_zone.gd's grey slab: real cheese becomes a child and
## `show_wedges` goes off, and nothing that enforces anything changes.

## So the director can find every cache without being wired to any particular map. Joined in
## `_enter_tree` for the reason no_surface_zone.gd spells out: Godot runs `_enter_tree` across a
## whole subtree before a single `_ready`, so a cache is findable no matter where a map put it.
const GROUP: StringName = &"cheese_cache"

signal emptied(cache: CheeseCache)
signal taken(cache: CheeseCache, left: int)

## How many wedges are left. The pile shrinks as it goes, so a cache you have been working reads
## as one from across the yard -- that is information the other crew is entitled to.
@export var wedges: int = 6:
	set(value):
		wedges = maxi(value, 0)
		if is_inside_tree():
			_build()

## How close you have to be to take one. Matched to the banner's pickup radius by default so
## "walk into the thing" means one distance everywhere in the game.
@export var reach: float = 0.85

@export_group("Look")
@export var show_wedges: bool = true
## Warm and light, so a wedge reads against both the dirt and the grass without being a UI dot.
@export var cheese_color: Color = Color(0.93, 0.78, 0.32)
@export var wedge_size: float = 0.16
## The pile's footprint. Wedges are scattered inside this rather than stacked, because a stack
## reads as one object and the count is the thing worth reading.
@export var spread: float = 0.34

var _wedges_node: Node3D


func _enter_tree() -> void:
	add_to_group(GROUP)


func _ready() -> void:
	_build()


func is_empty() -> bool:
	return wedges <= 0


## Take one wedge. Returns whether there was one to take.
##
## The caller charges nothing and credits nothing -- a wedge in the hand is not a wedge in the
## crew's pile, and the walk between those two facts is the entire mechanic. MatchDirector is
## what knows the difference.
func take() -> bool:
	if wedges <= 0:
		return false
	wedges -= 1
	taken.emit(self, wedges)
	if wedges <= 0:
		emptied.emit(self)
		queue_free()
	return true


## The pile as the minimap draws it. Same shape contract as the boulders and the paving, so a
## cache is on the map for the same reason and by the same route as everything else out there.
##
## EVERY PILE, ALWAYS, FOR BOTH CREWS -- authored caches and whatever got dropped in a fight
## alike. That is a deliberate exception to M5's whole instinct that information is something you
## go and get, and it buys two things.
##
## The bankruptcy play (GDD section 2) is a PLAN: disengage, concede a capture, go and refill. A
## plan has to be makeable from the nest before you commit, and a cheese hunt you can only run by
## remembering where the wedges were is homework rather than a decision.
##
## And a dropped pile on the map is an INTERACTION POINT the match grew by itself. This game has
## exactly one place both crews are obliged to care about, and it is the flag. A wedge lying where
## somebody died is a second one -- small, temporary in the sense that somebody will take it, and
## somewhere neither crew chose in advance. Hiding those would waste the best thing about them.
##
## What stays hidden is how much is left in a pile, which is the part worth scouting.
func minimap_shapes() -> Array[Dictionary]:
	if is_empty():
		return []
	return [{
		"kind": &"circle",
		"style": &"cheese",
		"position": Vector2(global_position.x, global_position.z),
		"radius": maxf(reach, 0.6),
		"min_radius_px": 3.0,
	}]


## Is `at` close enough to work this pile?
func within(at: Vector3) -> bool:
	var gap := Vector2(at.x - global_position.x, at.z - global_position.z)
	return gap.length() <= reach


## Every cache on the map, nearest first to `at`. Nearest first because a mouse standing between
## two piles should work the one it is actually on, and because the director asks this per mouse
## per frame -- sorting a handful of caches is cheaper than the wrong answer.
static func nearest(tree: SceneTree, at: Vector3) -> CheeseCache:
	var best: CheeseCache = null
	var closest := INF
	for node in tree.get_nodes_in_group(GROUP):
		var cache := node as CheeseCache
		if cache == null or cache.is_empty():
			continue
		var gap := at.distance_to(cache.global_position)
		if gap < closest:
			closest = gap
			best = cache
	return best


## Add to this pile. Used when somebody is scruffed on ground where cheese is already lying.
func add_wedges(amount: int) -> void:
	if amount <= 0:
		return
	wedges += amount


## Take an authoritative cache reading off the wire. Kept on the cache so changing its count and
## changing the mesh cannot become two operations a caller forgets to keep together.
func adopt(amount: int, width: float) -> void:
	spread = maxf(width, 0.0)
	wedges = maxi(amount, 0)  # The setter rebuilds the visible pile.


func _build() -> void:
	if _wedges_node != null:
		_wedges_node.queue_free()
		_wedges_node = null
	if not show_wedges or wedges <= 0:
		return

	var material := StandardMaterial3D.new()
	material.albedo_color = cheese_color
	material.roughness = 0.85

	# A prism on its side is a cheese wedge: triangular face forward, rectangular back. Cheap,
	# and at fat-pixel scale it is the silhouette that has to carry it, not the holes.
	var mesh := PrismMesh.new()
	mesh.size = Vector3(wedge_size, wedge_size, wedge_size * 0.7)
	mesh.material = material

	_wedges_node = Node3D.new()
	_wedges_node.name = "Wedges"
	add_child(_wedges_node)

	# Seeded off the pile's own position, so a cache looks the same every run without an
	# exported seed, and two caches side by side do not look like copies of each other.
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector2i(roundi(global_position.x * 8.0), roundi(global_position.z * 8.0)))

	# Only ever draw a handful. The count is read off the HUD and the pile's rough size, and
	# forty individually placed wedges is a lot of nodes to say "plenty".
	for i in range(mini(wedges, 8)):
		var wedge := MeshInstance3D.new()
		wedge.mesh = mesh
		var away := rng.randf_range(0.0, spread) if i > 0 else 0.0
		var around := rng.randf_range(0.0, TAU)
		wedge.position = Vector3(
			cos(around) * away, wedge_size * 0.5, sin(around) * away
		)
		wedge.rotation.y = rng.randf_range(0.0, TAU)
		wedge.rotation.z = rng.randf_range(-0.12, 0.12)
		_wedges_node.add_child(wedge)
