class_name Nest
extends Node3D
## A crew's home: where you spawn, where your banner stands, and where a steal becomes a
## capture (GDD section 2).
##
## One node with three jobs, because in the fiction they are one place and separating them
## would immediately invite them to drift apart -- a capture zone that isn't where the banner
## stands is a bug you can only find by playing.
##
## It builds its own banner. The banner spends most of the match somewhere else entirely, but
## it BELONGS here: `send_home` needs an address, and having the nest own it means there is no
## way to wire up a scene where the blue banner returns to the red nest.
##
## Grey box, deliberately (implementation plan): a tinted disc on the ground and a stand. The
## real nest is a heap of chewed cardboard and stolen insulation, and that is an M9 problem.

## How far from the middle counts as home. Generous -- a capture that needs you to thread a
## precise spot at a dead run is a frustration, not a skill.
@export var radius: float = 2.6
## Where a respawning mouse appears, relative to the nest. Behind the banner stand rather than
## on top of it, so you don't spawn inside your own objective.
@export var spawn_offset: Vector3 = Vector3(0.0, 0.25, 1.1)
## Where the crew's cheese is piled, relative to the nest (GDD section 8: a nest is a base, a
## banner spawn AND a cheese store).
##
## A SEPARATE SPOT FROM THE BANNER, and it has to be. Section 2 makes enemy stores raidable, but
## a store at the banner's own feet is a store nobody ever raids: standing there while their
## banner is home means you pick up the banner instead, every time, because it is worth more.
## Raiding would then only be possible in the one situation -- their banner already out -- where
## you have far better things to do. Splitting the two puts a second thing in the nest worth
## standing on, which is also what makes defending one a real job rather than one radius.
@export var stores_offset: Vector3 = Vector3(1.35, 0.0, -1.35)
## How close to the pile you have to be to bank a wedge or take one. Deliberately tighter than
## `radius`: the nest is where you are safe, the store is a specific place inside it.
@export var stores_reach: float = 1.0
@export_enum("Blue", "Red") var team: int = Team.BLUE

var _banner: Banner


func _ready() -> void:
	_build()
	_banner = Banner.new()
	_banner.name = "Banner"
	add_child(_banner)
	_banner.setup(team, banner_stand())


func get_banner() -> Banner:
	return _banner


## Where the banner stands when it's home. Raised a little: the pole is planted in a mound.
func banner_stand() -> Vector3:
	return global_position + Vector3.UP * 0.08


func spawn_point() -> Vector3:
	return global_position + spawn_offset


## Where the crew's cheese sits. Banked here, and raided from here.
func stores_point() -> Vector3:
	return global_position + stores_offset


## Is `at` close enough to work this crew's pile?
func at_stores(at: Vector3) -> bool:
	var pile := stores_point()
	return Vector2(at.x - pile.x, at.z - pile.z).length() <= stores_reach


## Which way a mouse faces when it spawns -- out of the nest, toward the middle of the arena.
## Spawning with your back to the match is disorienting for exactly as long as it takes to
## turn around, which is long enough to be worth this one line.
func spawn_facing() -> float:
	var out := -global_position
	out.y = 0.0
	if out.length_squared() < 0.001:
		return 0.0
	out = out.normalized()
	return atan2(-out.x, -out.z)


## Ground the scatterers must leave alone, as a flat radius around the middle.
##
## Wider than the pad itself. A boulder on the capture disc is ugly; a boulder on the spawn
## point is a bot standing still for a whole match, and the scatter is seeded, so it would be
## reproducible and mysterious rather than occasional and obvious.
static func blocks(tree: SceneTree, spot: Vector2, margin: float = 0.0) -> bool:
	for node in tree.get_nodes_in_group(&"nest"):
		var nest := node as Nest
		if nest == null:
			continue
		var away := Vector2(spot.x - nest.global_position.x, spot.y - nest.global_position.z)
		if away.length() < nest.radius + 0.9 + margin:
			return true
	return false


func contains(at: Vector3) -> bool:
	return Vector2(at.x - global_position.x, at.z - global_position.z).length() <= radius


func _build() -> void:
	var colour := Team.color_of(team)

	var pad_mesh := CylinderMesh.new()
	pad_mesh.top_radius = radius
	pad_mesh.bottom_radius = radius
	pad_mesh.height = 0.05
	pad_mesh.radial_segments = 24
	var pad_material := StandardMaterial3D.new()
	# Mostly dirt, with just enough of the crew's colour to say whose it is. A saturated disc
	# reads as a UI decal painted on the lawn -- the first pass mixed half and half and looked
	# like a selection highlight from a strategy game.
	pad_material.albedo_color = colour.lerp(Color(0.34, 0.28, 0.20), 0.78)
	pad_material.roughness = 1.0
	pad_mesh.material = pad_material

	# The mound keeps the colour the pad gave up. Identity belongs at the banner, which is the
	# thing you are actually looking for, and a small bright object reads from further away than
	# a large dull one.
	var mound_material := StandardMaterial3D.new()
	mound_material.albedo_color = colour.lerp(Color(0.34, 0.28, 0.20), 0.25)
	mound_material.roughness = 0.95

	var pad := MeshInstance3D.new()
	pad.name = "Pad"
	pad.mesh = pad_mesh
	# Just proud of the ground. Flush, it z-fights the lawn across the whole disc.
	pad.position.y = 0.026
	add_child(pad)

	var mound_mesh := CylinderMesh.new()
	mound_mesh.top_radius = 0.28
	mound_mesh.bottom_radius = 0.42
	mound_mesh.height = 0.1
	mound_mesh.radial_segments = 10
	mound_mesh.material = mound_material

	var mound := MeshInstance3D.new()
	mound.name = "Stand"
	mound.mesh = mound_mesh
	mound.position.y = 0.05
	add_child(mound)

	_build_stores()


## A saucer where the crew's cheese is piled. Drawn, not just declared, because a raidable store
## the enemy cannot SEE is not a target -- it is a coordinate you have to be told about, and this
## game's whole information layer is about things you find out by looking.
##
## Deliberately not a wedge count. What is in the pile is on the HUD for your own crew and is
## exactly the sort of thing the other crew should have to guess at.
func _build_stores() -> void:
	var saucer := CylinderMesh.new()
	saucer.top_radius = stores_reach * 0.62
	saucer.bottom_radius = stores_reach * 0.72
	saucer.height = 0.05
	saucer.radial_segments = 14
	var material := StandardMaterial3D.new()
	# The cheese colour, knocked back toward dirt. Bright enough to read as "cheese lives here",
	# dull enough not to compete with the banner, which is the thing you are actually hunting.
	material.albedo_color = Color(0.93, 0.78, 0.32).lerp(Color(0.34, 0.28, 0.20), 0.42)
	material.roughness = 1.0
	saucer.material = material

	var pile := MeshInstance3D.new()
	pile.name = "Stores"
	pile.mesh = saucer
	pile.position = stores_offset + Vector3(0.0, 0.03, 0.0)
	add_child(pile)
