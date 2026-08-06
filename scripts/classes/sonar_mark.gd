class_name SonarMark
extends MeshInstance3D
## A piece of Sneak cant scratched onto the floor above a detected tunnel.
##
## It is world information, not a private HUD ping. The owning crew can always read it; an enemy
## can only see it while playing a Sneak, which is also the only class allowed to erase it.
##
## `[REVISED]` IT NOW SAYS WHOSE TUNNEL, and that is what turns cant from a note into an order.
## Until this, a mark said "a way runs beneath this place" and stopped -- which is a fine thing for
## a scout to write and a useless thing for a Brute to read, because the one question a Brute has
## before it puts a foot through a roof is *whose roof*. Collapsing your own crew's corridor is a
## thing you can now do on purpose and by accident, and a mark that would not tell you which was
## which made the counterplay web's newest link (GDD section 5) a coin toss.
##
## TWO CHANNELS, TWO FACTS, AND THEY ARE DELIBERATELY NOT THE SAME FACT. The **colour** is the
## crew whose tunnel it is. The **glyph** is whether that crew is the one who scratched the mark.
## Reading them together answers both halves at a glance and neither needs a legend: a red target
## on a blue crew's map is *their* tunnel, go and stand on it.

const MARK_GROUP: StringName = &"sonar_mark"

## A cell both crews know: a junction, or a corridor somebody broke into. Sits alongside
## `Team.BLUE` and `Team.RED` as a third value of `tunnel_team`, which is why it is 2 -- it is an
## extension of that enum rather than a separate idea, and it travels in the same byte.
const SHARED: int = 2

var owner_team: int = Team.BLUE
var plane: int = 0
var target_plane: int = 1
var cell: Vector2i = Vector2i.ZERO
## Whose corridor was found: `Team.BLUE`, `Team.RED`, or [constant SHARED].
var tunnel_team: int = SHARED


## Which crew a cell of tunnel belongs to, from the knowledge bits the network keeps.
##
## THE KNOWLEDGE BITS ARE THE RIGHT SOURCE, and it is worth saying why rather than adding a
## "dug_by" field to the network. A cell's bits are set to its digger's crew and widened to both
## when the two networks meet (`_learn_tunnel_cell`), so they already answer "whose corridor is
## this" including the case that matters most -- the junction where the answer is *both*. A
## separate record of who cut it first would disagree with the bits at exactly those cells, and
## the bits are what every other part of the game reasons about.
##
## STATIC AND HERE rather than on the network, because the encoding is this file's: BLUE, RED and
## SHARED are what a mark stores, what the wire carries, and what the glyph switches on. One
## definition, three users.
static func team_of_bits(bits: int) -> int:
	var blue := bits & (1 << Team.BLUE) != 0
	var red := bits & (1 << Team.RED) != 0
	if blue and red:
		return SHARED
	if blue:
		return Team.BLUE
	if red:
		return Team.RED
	# A dug cell nobody knows about should not exist -- `dig` always attributes. SHARED is the
	# reading that claims least: it says "contested" rather than naming a crew that may be wrong.
	return SHARED


## BLUE / RED / SHARED, for logs and audits. `Team.name_of` cannot answer this: SHARED is not a
## crew, and clamping it into one is how a junction would come to be reported as somebody's.
static func team_label(whose: int) -> String:
	return "SHARED" if whose == SHARED else Team.name_of(clampi(whose, Team.BLUE, Team.RED))


func configure(
	network: TunnelNetwork, side: int, source_plane: int, target: Vector2i, whose: int = SHARED
) -> void:
	owner_team = clampi(side, Team.BLUE, Team.RED)
	plane = clampi(source_plane, 0, TunnelNetwork.PLANE_COUNT - 1)
	target_plane = mini(plane + 1, TunnelNetwork.PLANE_COUNT - 1)
	cell = target
	tunnel_team = clampi(whose, Team.BLUE, SHARED)
	name = "SonarMark_%s_%d_%d_%d" % [Team.name_of(owner_team), plane, cell.x, cell.y]
	position = network.cell_to_world(plane, cell) + Vector3.UP * 0.035
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# HIDDEN UNTIL SOMEBODY'S EYES ASK FOR IT. `MeshInstance3D` arrives visible, and the one thing
	# that corrects that is the watched mouse's `Sonar._process` -- so a mark drawn its own default
	# is a mark that assumed a watcher exists. Since M7 a client BUILDS these from a packet, own
	# crew cant arrives on planes the viewer is not standing on, and `local_mouse()` is briefly null
	# across a respawn or a seat handover. Visible-by-default plus no watcher is a glyph on a floor
	# two layers down.
	visible = false
	add_to_group(MARK_GROUP)
	mesh = _glyph()


## Is this cant pointing at somebody else's corridor -- i.e. is it a target rather than a note?
##
## ASKED FROM THE SCRATCHING CREW'S SIDE, always, and never from the viewer's. A mark is a thing
## one crew wrote on the floor, and it means what its author meant no matter who is standing over
## it. An enemy Sneak reading it therefore sees a glyph that is inverted from their point of view
## -- a target drawn on their own tunnel -- which is the correct and rather good reading: you are
## looking at somebody else's plan for you.
func marks_enemy_ground() -> bool:
	return tunnel_team != owner_team


## MAY THIS PLAYER KNOW THIS MARK EXISTS -- and the only place that answers it.
##
## `tunnel_view.gd` is the one place that decides what a client may know about the ground, and cant
## needed the same treatment for the same reason: the rule had four implementations, the one on the
## wire was written out longhand, and a visibility rule with four copies is how M5's whole class of
## bug gets in. They agreed, which is the least reassuring way for four copies of a rule to be.
##
## Own crew cant CARRIES ACROSS DEPTHS, because it is crew knowledge -- a Generalist standing on the
## surface still knows where its own Sneaks scratched. Enemy cant is class knowledge and is legible
## only on the plane it was scratched into: a Sneak reads the floor it is standing on, not the one
## two layers down.
##
## `tunnel_team` RIDES THIS RULE AND ADDS NOTHING TO IT. Whose corridor a mark names is part of the
## mark, so anyone allowed to read the mark is allowed to read that too -- which is the boundary
## sonar has always drawn: a PLACE, and now the crew standing behind it, but never the route.
func can_be_read_by(viewer_team: int, viewer_class: int, viewer_plane: int) -> bool:
	if viewer_team == owner_team:
		return true
	return viewer_class == MouseClass.SNEAK and viewer_plane == plane


## Is it on screen right now -- which is [method can_be_read_by] plus "and not through a layer of
## earth". Reading own cant on another depth is knowledge; DRAWING it there would put a glyph on a
## floor the viewer is not standing on.
func can_be_seen_by(viewer_team: int, viewer_class: int, viewer_plane: int) -> bool:
	return viewer_plane == plane and can_be_read_by(viewer_team, viewer_class, viewer_plane)


## Remove from readers immediately, then leave tree teardown to the end of the frame. Used by
## both authoritative erasure and complete-picture reconciliation.
func discard() -> void:
	remove_from_group(MARK_GROUP)
	queue_free()


## The crew colour of the corridor underneath, pulled toward chalk so it still reads as something
## scratched into the floor rather than as a painted icon.
##
## PULLED LESS FAR THAN IT USED TO BE (0.32, from 0.58). The old blend was tuned when the colour
## carried nothing -- it was the scratcher's crew, which the reader already knew, so washing it out
## cost no information and made the glyph sit into the ground. Now the hue IS the message, and a
## Brute glancing down at a mark has to be able to name the crew from across a corridor.
##
## SHARED SPLITS THE DIFFERENCE, which is the honest picture of a junction: neither crew's colour,
## visibly not either one.
func tunnel_color() -> Color:
	var base := (
		Team.color_of(Team.BLUE).lerp(Team.color_of(Team.RED), 0.5) if tunnel_team == SHARED
		else Team.color_of(tunnel_team)
	)
	return base.lerp(Color(0.92, 0.89, 0.72), 0.32)


func _glyph() -> ArrayMesh:
	var colour := tunnel_color()
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.vertex_color_use_as_albedo = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED

	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	tool.set_material(material)
	if marks_enemy_ground():
		_target_glyph(tool, colour)
	else:
		_ours_glyph(tool, colour)
	return tool.commit()


## OURS: a forked downward rune -- "a way runs beneath this place". The original mark, kept
## unchanged for the case it was drawn for, because a note about your own tunnels is exactly what
## it always was.
func _ours_glyph(tool: SurfaceTool, colour: Color) -> void:
	_bar(tool, Vector2(-0.34, -0.18), Vector2(0.0, 0.17), 0.075, colour)
	_bar(tool, Vector2(0.0, 0.17), Vector2(0.34, -0.18), 0.075, colour)
	_bar(tool, Vector2(0.0, 0.18), Vector2(0.0, -0.36), 0.075, colour)


## THEIRS: four corner brackets closing on a centre spot. A reticle, deliberately -- this is the
## one glyph in the game that is an instruction rather than an observation, and what it is telling
## a Brute to do is stand here.
##
## BRACKETS RATHER THAN A RING, because a ring at this size on a dirt floor reads as a hole, and
## the game already has holes in floors that mean something entirely different. Corners read as
## framing at any scale and cannot be mistaken for terrain.
func _target_glyph(tool: SurfaceTool, colour: Color) -> void:
	var out := 0.34
	var arm := 0.15
	var width := 0.07
	var corners: Array[Vector2] = [
		Vector2(-1.0, -1.0), Vector2(1.0, -1.0), Vector2(1.0, 1.0), Vector2(-1.0, 1.0)
	]
	for corner: Vector2 in corners:
		var at := corner * out
		_bar(tool, at, at - Vector2(corner.x * arm, 0.0), width, colour)
		_bar(tool, at, at - Vector2(0.0, corner.y * arm), width, colour)
	# The spot in the middle: a small square, which is the cell you are being pointed at.
	_bar(tool, Vector2(0.0, -0.07), Vector2(0.0, 0.07), 0.14, colour)


func _bar(tool: SurfaceTool, a: Vector2, b: Vector2, width: float, colour: Color) -> void:
	var direction := (b - a).normalized()
	var across := Vector2(-direction.y, direction.x) * width * 0.5
	var points := [a + across, b + across, b - across, a - across]
	for index in [0, 1, 2, 0, 2, 3]:
		var point: Vector2 = points[index]
		tool.set_normal(Vector3.UP)
		tool.set_color(colour)
		tool.add_vertex(Vector3(point.x, 0.0, point.y))
