class_name CollapseCursor
extends Node3D
## Where a cave-in would land, and whether it would go off: a jagged crack drawn on the floor of
## the cell the Brute is aiming at.
##
## `[REVISED]` A CRACK ON THE FLOOR RATHER THAN A BOX ROUND THE AIR, and the reason is that the box
## was indistinguishable from the one digging used to draw. Both were the same wireframe cube from
## [DigCursor], so a Brute walking about underground saw an orange cube track the cursor and read it
## as the dig targeting box -- reported as exactly that, a dig cursor that would not go away, by a
## player who was not digging and could not have been. Two abilities cannot share one shape and
## expect anybody to tell them apart.
##
## AND THE SHAPE NOW SAYS WHAT THE ABILITY DOES. A cube outlines a volume of earth you are about to
## take away, which is digging's sentence, not this one: a cave-in does not remove that cubic metre,
## it drops the ceiling ONTO it. What matters is the patch of floor underneath -- where the roof
## lands and where you should not be standing -- so the mark is flat, sits on that floor, and is
## torn round its edge rather than ruled straight. A crack about to open is the picture.
##
## WHAT IS LEFT OF THE OLD BEHAVIOUR, deliberately, because it was right: COLOUR CARRIES READINESS.
## Warm means the ability will fire; cold means it is still cooling, and the cell is still drawn
## rather than hidden, because "where would this land" does not stop being a useful question while
## you wait. That puts the cooldown in the world rather than only in a line of HUD text.
##
## AND A PULSE MEANS GO ON THEN. Ready breathes; cooling holds still. Same grammar the dig cursor
## used and the one piece of it worth carrying over -- a mark that pulses while the button would do
## nothing is a mark that lies twice a second.

## The aimed cell when the ability is ready.
@export var ready_color: Color = Color(1.00, 0.34, 0.10, 0.95)
## The same cell while it cools. Desaturated rather than merely dimmer: at a glance the difference
## between "hot" and "not yet" should be hue, because brightness is already saying how far the
## lamps reach.
@export var cooling_color: Color = Color(0.42, 0.62, 0.74, 0.80)
## How far each tooth swings either side of the cell's true outline, in metres. This is the whole
## of the "jagged", and it is deliberately a good fraction of the line's own width -- a jag smaller
## than the line it displaces reads as a wobbly rectangle rather than as a tear.
@export var jag: float = 0.06
## How thick the drawn line is, in metres.
@export var line_width: float = 0.05
## Teeth per side of the square. Four is a tear; twenty is a doily, and at this camera distance the
## teeth stop being separable well before that.
@export_range(2, 16) var teeth_per_edge: int = 4
## How far above the floor the mark floats, in metres.
##
## HIGHER THAN THE 0.03 EVERY OTHER FLAT MARK IN THE GAME USES, and the difference is the floor
## itself rather than a preference. Nest pads and cant scratches are drawn on the LAWN, which is a
## plane; this is drawn in a dug corridor, whose floor is contoured and whose edges curve up into
## the walls. At 0.03 the outline was half-buried -- the first screenshot came back as four orange
## fragments with the middle of every side swallowed, which reads as a rendering fault rather than
## as a mark. Clearing the roughness costs nothing, since nothing walks between here and the floor.
@export var clearance: float = 0.07
## How much of the cell the outline is drawn at, as a fraction of its width.
##
## INSET, BECAUSE A FULL-WIDTH SQUARE IS NOT ACTUALLY VISIBLE. A cell is exactly as wide as the
## corridor, so an outline at its true edges lies precisely where the floor turns into wall and
## spends most of its length inside geometry. Pulled in, the whole loop sits on floor you can see.
## It still says which cell -- there is only one cell it could be inside -- and the teeth make the
## boundary read as approximate anyway, which is the honest picture of a collapse.
@export_range(0.4, 1.0, 0.01) var span: float = 0.78

var _mesh: MeshInstance3D
var _material: StandardMaterial3D
## Whether what is currently drawn is the ready colour, which is the only state that pulses.
var _lit: bool = false
var _age: float = 0.0


func _ready() -> void:
	_material = StandardMaterial3D.new()
	_material.albedo_color = ready_color
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# Off the depth WRITE but not the depth test, so the mark is occluded by the earth between it
	# and the camera -- a cave-in cursor visible through a wall would be a free sonar of exactly
	# the kind [CaveIn] refuses to be.
	_material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED

	_mesh = MeshInstance3D.new()
	_mesh.mesh = _build()
	_mesh.material_override = _material
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh)

	visible = false


## Show the cell the cave-in would take, or hide on Vector2i.MAX -- which is what standing on the
## lawn, playing anything but a Brute, or pointing at solid earth all look like.
##
## THE LAWN CASE IS A DESIGN DECISION RATHER THAN AN OMISSION. A Brute up there is not without an
## ability -- Q is the stomp -- but the stomp has no aimed cell, and a mark that lit up only when
## there was something underneath would be a free sonar sweep. See [CaveIn].
func show_target(network: TunnelNetwork, plane: int, cell: Vector2i, is_ready: bool) -> void:
	if cell == Vector2i.MAX:
		visible = false
		return

	visible = true
	global_position = network.cell_to_world(plane, cell) + Vector3.UP * clearance
	if _lit != is_ready:
		_lit = is_ready
		# Restarted so the breath begins at its dimmest the moment the ability comes up, rather
		# than snapping to wherever a free-running clock happened to be.
		_age = 0.0
	_tint()


## The mark itself: a band that runs round the cell's outline, stepping in and out as it goes.
##
## BUILT ONCE AT THE ORIGIN AND MOVED, rather than rebuilt per cell. The shape is the same square
## everywhere; only its position changes, and regenerating twenty triangles every frame the cursor
## slides one cell over would be a lot of allocation for a rectangle.
##
## OFFSET ALONG THE RADIAL rather than along each edge's own normal, which is the one non-obvious
## line here. Per-edge normals flip at the corners, so consecutive teeth either side of a corner
## push in unrelated directions and tear a visible notch out of the band. The direction from the
## cell's centre turns smoothly through the corner instead, so the outline stays closed -- the
## teeth just get a diagonal lean where the corners are, which is what a real crack does anyway.
func _build() -> Mesh:
	var half := TunnelChunks.CELL * 0.5 * span
	var corners: Array[Vector2] = [
		Vector2(-half, -half), Vector2(half, -half), Vector2(half, half), Vector2(-half, half)
	]

	# Sampled along each edge WITHOUT its end point, so the corner is contributed once by the edge
	# that starts there and the loop closes on itself with no doubled vertex.
	var points: Array[Vector2] = []
	for index in range(corners.size()):
		var from: Vector2 = corners[index]
		var to: Vector2 = corners[(index + 1) % corners.size()]
		for step in range(maxi(teeth_per_edge, 2)):
			points.append(from.lerp(to, float(step) / float(maxi(teeth_per_edge, 2))))

	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var count := points.size()
	for index in range(count):
		var here: Vector2 = points[index]
		var next: Vector2 = points[(index + 1) % count]
		var rim: Array[Vector3] = [
			_edge(here, index, 1.0), _edge(next, index + 1, 1.0),
			_edge(next, index + 1, -1.0), _edge(here, index, -1.0)
		]
		for corner: int in [0, 1, 2, 0, 2, 3]:
			tool.set_normal(Vector3.UP)
			tool.add_vertex(rim[corner])
	return tool.commit()


## One side of the band at `point`: pushed out on even teeth and in on odd ones, then half the
## line's width further out or in depending on `side`.
##
## The count of points is always four times `teeth_per_edge` and therefore even, so the alternation
## closes cleanly where the loop meets itself. An odd count would put two out-teeth side by side at
## the seam, which is a flat spot in exactly the place the eye follows round.
func _edge(point: Vector2, index: int, side: float) -> Vector3:
	var out := point.normalized()
	var swing := jag if index % 2 == 0 else -jag
	var at := point + out * (swing + side * line_width * 0.5)
	return Vector3(at.x, 0.0, at.y)


func _process(delta: float) -> void:
	if not visible:
		return
	_age += delta
	if _lit:
		_tint()


## GO ON THEN, at a breath and a half a second. Written into the alpha rather than the colour so
## the mark dims toward the floor it is drawn on instead of drifting toward some other hue, and
## floored well above nothing -- a cursor that vanishes at the bottom of every pulse reads as a
## flicker, not a heartbeat.
func _tint() -> void:
	var base := ready_color if _lit else cooling_color
	if not _lit:
		_material.albedo_color = base
		return
	var breath := 0.78 + 0.22 * sin(_age * TAU * 1.5)
	_material.albedo_color = Color(base.r, base.g, base.b, base.a * breath)
