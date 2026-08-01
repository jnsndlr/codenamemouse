class_name BoulderSection
extends Breakable
## One cell of a boulder: the lump you can see, the collider you run into, and the cell of plane 1
## it shuts underneath itself.
##
## THREE THINGS THAT HAVE TO AGREE, the same three a barricade juggles and for the same reason:
##
##   Physical   A collider on the WORLD layer, because a boulder is part of the lawn -- everyone
##              on the surface meets it, whatever plane the tunnel system thinks they are on.
##   Diggable   Its cell is registered as rock on plane 1, so a corridor cannot be driven under it.
##              Known to both crews from the start: it is standing in the open, and pretending you
##              have to discover it would be a puzzle about the camera rather than about the map.
##   Removable  Five Brute swings, and then the cell is ordinary earth again.
##
## The middle one is the one that would be easy to forget and impossible to see, exactly like the
## barricade's routing: nothing errors when a boulder fails to block the earth beneath it, you just
## quietly dig a corridor through solid rock and never find out it should not have worked.
##
## ON THE SURFACE, so `plane` stays 0 and the swing that reaches it is a swing thrown on the lawn.
## A mouse in a tunnel underneath cannot hit it, which is right twice over: they cannot see it, and
## digging is not what shifts rock.

## Which cell of the grid it stands on. The section IS the cell -- there is no offset, no sub-tile
## placement, because what it blocks is a whole cell of digging and a rock that visually straddles
## two while blocking one is a lie you can only find by digging.
var cell: Vector2i = Vector2i.ZERO
var height: float = 0.9
var rock_color: Color = Color(0.38, 0.38, 0.40)
var network: TunnelNetwork
## Where the pieces go when this breaks, and NOT this node's own parent.
##
## The boulder frees itself once its last section is gone, and anything parented to it goes at the
## same moment -- so the final quarter of a rock vanished instead of coming apart, while every
## other quarter broke properly. A one-in-four bug, in the one case that ends the object, which is
## the case a test written around "break a section" never reaches.
var debris_host: Node

## Kept so the pieces can be cut from the boulder's own triangles when it goes. See rock_debris.gd.
var _shell: ArrayMesh
var _blocking: bool = false


func _ready() -> void:
	super()
	# The lawn. Set explicitly rather than left to the default, because "which plane can hit this"
	# is a rule and not an accident of initialisation.
	plane = 0


## Take up the cell: stand on it, and shut the earth under it.
##
## SEPARATE FROM `_ready` because it needs a world position, and a node placed by its parent before
## entering the tree has not got one yet. The barricade gets away with doing this in `_ready`
## because it is added straight to the network; a section is added to a boulder which is added to a
## field, and the transform only settles once all three are in the tree.
func settle() -> void:
	if network == null:
		return
	global_position = Vector3(cell.x * TunnelNetwork.CELL, 0.0, cell.y * TunnelNetwork.CELL)
	# Known to everybody: this rock is visible from the lawn, so both crews already know what is
	# under it. It is the counterweight to the seams, which are known to nobody until dug into.
	_blocking = network.add_rock(1, cell, true)

	var span := TunnelNetwork.CELL * 0.5
	_build_mesh(span)
	_build_body(span)


## The earth under a boulder is ordinary earth again the moment the last piece comes off -- and
## before the pieces have finished falling, exactly as the barricade reopens its corridor on the
## swing that breaks it rather than when the debris settles.
func _on_broken(_by: Mouse) -> void:
	_release()
	var host: Node = debris_host if debris_host != null else get_parent()
	RockDebris.burst(
		host, global_position, _shell, rock_color, scale.x, hash(Vector2i(cell.x, cell.y))
	)
	queue_free()


func _exit_tree() -> void:
	# The catch-all for every other way this node can die -- a scene change, an audit teardown.
	# Idempotent, so running after `_on_broken` costs nothing.
	_release()


func _release() -> void:
	if not _blocking or not is_instance_valid(network):
		return
	_blocking = false
	network.remove_rock(1, cell)


## A lump, from the shared generator, seeded off the cell so the same spot always grows the same
## rock and the four quarters of one boulder are visibly four different stones.
func _build_mesh(span: float) -> void:
	_shell = RockShell.build(span, height, hash(Vector2i(cell.x, cell.y)))
	var mesh := MeshInstance3D.new()
	mesh.mesh = _shell
	mesh.material_override = RockShell.material_for(rock_color)
	add_child(mesh)


## A cylinder rather than the lumpy mesh, like the barricade: the lumps are a look, and what the
## rules need is "a mouse cannot get past this" without a trimesh's habit of letting a fast body
## slip through a facet.
##
## Slightly INSIDE the cell, so two neighbouring sections leave no seam a mouse can be caught on
## and a boulder does not claim ground its own footprint has not blocked.
func _build_body(span: float) -> void:
	var shape := CylinderShape3D.new()
	shape.radius = span * 0.92
	shape.height = height

	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.position = Vector3(0.0, height * 0.5, 0.0)

	var body := StaticBody3D.new()
	# THE WORLD LAYER, not a plane layer. A boulder is part of the lawn like the perimeter wall and
	# the props are, and everything standing on the surface collides with the world whatever the
	# tunnel system has it masked to.
	body.collision_layer = TunnelNetwork.WORLD_BIT
	body.collision_mask = 0
	body.add_child(collision)
	add_child(body)
