extends NavigationRegion3D
## The walkable surface, baked at startup so bots can cross the yard.
##
## BAKED AT RUNTIME rather than saved into the scene, for one reason that will only get more
## true: the arena is procedural. The rock scatter and the grass patches are generated from a
## seed at `_ready`, and GDD section 8 says maps will eventually be generated from a recipe per
## match. A navmesh committed to the .tscn would be a photograph of one arrangement, silently
## wrong the first time a seed changed.
##
## WHAT GETS BAKED IS OPT-IN, by group. Left to parse the whole scene it would swallow 760
## scattered rocks and 63000 grass blades, which takes real time and produces a navmesh full of
## pinholes around pebbles a mouse simply runs over. Only the ground, the perimeter walls and
## the props are tagged -- the things a bot must actually walk around.
##
## The tunnels are deliberately absent. Bots path underground at M4 via AStar3D over dug cells
## (implementation plan), which is a graph, not a mesh -- one source of truth shared with the
## digging rules rather than a navmesh rebaked on every cell.

## Nodes to include. Tagged in the scene rather than listed here, so adding a prop to the arena
## doesn't mean editing a script to make bots aware of it.
const SOURCE_GROUP: StringName = &"nav_source"

## Wider than the mouse's own 0.16 capsule, so a bot aims for gaps it actually fits through
## rather than clipping every corner.
##
## All three of these are whole multiples of the 0.1 voxel size set in project.godot. Off the
## grid they are silently rounded -- ceiled for radius and height, floored for climb -- and the
## bake warns that the number you tuned is not the number it used.
@export var agent_radius: float = 0.2
@export var agent_height: float = 0.5
## The lip a bot will walk up without needing a path around. A shade over the network's own step
## tolerance (0.18), rounded to the voxel grid, so nothing the player can stride over stops a
## bot.
@export var agent_max_climb: float = 0.2
## Vertical slice to bake. Keeps the deep tunnels out of the parse without needing a rule about
## which nodes are underground -- everything below the lawn is simply out of the box.
@export var bake_below: float = -0.5
@export var bake_above: float = 3.0
@export var half_extent: float = 41.0


func _ready() -> void:
	var mesh := NavigationMesh.new()
	# Must match the navigation map's own cell size or the region is rejected wholesale, with a
	# server error and a navmesh that silently never appears.
	mesh.cell_size = ProjectSettings.get_setting("navigation/3d/default_cell_size", 0.25)
	mesh.cell_height = ProjectSettings.get_setting("navigation/3d/default_cell_height", 0.25)
	mesh.agent_radius = agent_radius
	mesh.agent_height = agent_height
	mesh.agent_max_climb = agent_max_climb
	mesh.agent_max_slope = 45.0
	# BOTH, because the ground is a CSG combiner and the props are meshes with their own static
	# bodies. Parsing only colliders misses CSG entirely -- a CSG shape registers its collision
	# straight with the physics server rather than through a CollisionShape3D node, so the
	# collider parser cannot see the lawn and the bake comes back empty.
	#
	# The engine warns that reading meshes back off the GPU stalls rendering, and it is right --
	# but this is one bake at startup over four boxes, and the alternative is a second set of
	# collision bodies duplicating the ground purely to be parsed. Revisit if the map ever
	# rebakes mid-match.
	mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_BOTH
	mesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
	mesh.geometry_source_group_name = SOURCE_GROUP
	mesh.filter_baking_aabb = AABB(
		Vector3(-half_extent, bake_below, -half_extent),
		Vector3(half_extent * 2.0, bake_above - bake_below, half_extent * 2.0)
	)

	navigation_mesh = mesh

	# ONE FRAME LATE, because the lawn does not exist yet. A CSG shape builds its mesh during
	# the frame after it enters the tree, and until it does `get_meshes()` hands back nothing --
	# so baking here in `_ready` produced a navmesh of three polygons floating on top of the
	# props, with no ground under them at all. Bots found no path, stood still, and looked like
	# broken AI. tools/match_audit.gd asserts a nest-to-nest path for exactly this reason.
	await get_tree().process_frame

	# On the main thread, so the match's first physics frame already has somewhere to walk.
	# Threaded, the bots spend their first second with no map at all.
	bake_navigation_mesh(false)
	print("navmesh: %d polygons over the surface" % navigation_mesh.get_polygon_count())
