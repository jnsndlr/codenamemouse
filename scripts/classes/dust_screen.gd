class_name DustScreen
extends Node3D
## A cloud of kicked-up earth four metres across, standing for one second and hiding everything
## inside it. The Sneak's way out (GDD section 4).
##
## NOT [StompDust], AND THE TWO MUST NOT BE MERGED. They look like the same effect described twice
## -- both are dry pale earth thrown up off a lawn -- and the file they would be merged into carries
## a warning that forbids exactly what this one is for. The stomp's dust exists to say *a Brute hit
## the ground here*, and its hardest-won note is that the first version "closed into a single beige
## disc wider than the mouse and hid it completely", which is the bug that had to be tuned out: the
## Brute is the thing you are meant to be watching.
##
## THIS ONE IS THE DISC. Hiding what is inside it is not a side effect to be tuned down, it is the
## entire mechanic, and a shared class would mean one set of numbers being pulled in two directions
## by two abilities that want opposite things. Same material of dust, opposite jobs.
##
## IT OCCLUDES BY BEING GEOMETRY IN THE WAY, not by dimming anything or telling anything to hide. A
## dome of dense billboards stands between the camera -- which looks down at a fixed angle -- and
## whatever is under it, and the renderer does the rest. That matters more than it sounds: nothing
## has to be told the cloud exists, so nothing can be forgotten. A banner dropped inside it, a mouse
## that spawns inside it, an ability effect that fires inside it: all hidden, on the first frame, by
## the same fact.
##
## AND IT BLOCKS THE SWEEP, which is the half that is a rule rather than a picture. `spotting.gd`
## asks whether a live cloud lies across the line between two mice, so a defender loses the contact
## and a bot loses it in exactly the same way and at exactly the same moment. Without that the dust
## would be a screen that works against humans and is invisible to three quarters of the mice in a
## match -- the same failure the grass concealment had before the AI learned to read it.
##
## ONE SECOND, WHICH IS SHORT AND IS MEANT TO BE. Long enough to break a chase or a swing, far too
## short to fight from behind or to hold ground with. Read next to `Spotting.memory_seconds`: the
## contact does not vanish, it goes stale and stays on the map where you were last seen -- so what
## the Sneak buys is a moment in which the other mouse has to guess, and not a disappearance.

## The lawn's own dust, so a screen and a stomp are made of the same earth.
@export var dust_color: Color = Color(0.74, 0.68, 0.55, 1.0)

## The falloff every puff is drawn with: **opaque to `PLATEAU`, then out to nothing**.
##
## NOT [StompDust]'s, AND THIS IS THE THIRD TIME THIS FILE HAS HAD TO DIVERGE FROM IT for the same
## underlying reason. That texture's falloff is `alpha * alpha` -- deliberately, so a puff is dense
## in the middle and gone well before the quad's edge, because a linear ramp leaves a visible
## circular rim and a rim is obviously a *shape*. Perfect for dust you are meant to see the Brute
## through.
##
## Here it was the bug. Squared, only the very centre of a puff is opaque, so a hundred and sixty of
## them overlapping still covered the ground at something like three quarters -- and the third dust
## photograph came back with a thick convincing cloud and both mice legible inside it, measurably
## about 75% washed rather than hidden. Coverage is the mechanic; a falloff tuned for see-through
## cannot deliver it at any count.
##
## A PLATEAU, THEN A SMOOTH EDGE. Each puff is solid across its middle and fades over its outer
## fifth, which is what makes overlapping ones add up to a wall instead of to a haze. The rim
## problem the stomp warns about is real and is solved here by there being a hundred of them at
## random sizes rather than by softening any one.
const PLATEAU: float = 0.62

static var _falloff: ImageTexture


## Generated once for the whole process, like the stomp's. Thirty-two pixels square is plenty for
## something that is never sharp.
static func screen_texture() -> ImageTexture:
	if _falloff != null:
		return _falloff
	var size := 32
	var image := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	var middle := (float(size) - 1.0) * 0.5
	for x in range(size):
		for y in range(size):
			var away := Vector2(float(x) - middle, float(y) - middle).length() / middle
			var alpha := 1.0 - smoothstep(PLATEAU, 1.0, away)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	_falloff = ImageTexture.create_from_image(image)
	return _falloff

## How many puffs make the wall.
##
## FIFTEEN TIMES THE STOMP'S TEN, and the first build of this file used fifty-four on the reasoning
## that fifty-four is obviously a lot more than ten. `tools/dust_shot.gd` photographed the result and
## it was polka dots: a ring of tidy round blobs with both mice perfectly legible between them. The
## arithmetic nobody did is the only one that matters here -- a four metre screen is about fifty
## square metres of ground, a puff whose alpha falls off with the square of its radius contributes
## roughly a quarter of its own area, and *covering* fifty square metres therefore needs several
## times more of them than it looks like it should.
##
## THE COUNT IS NOT SCALED WITH `radius` AND THE SIZE IS, which is the right way round: doubling the
## reach with the same puffs made bigger keeps the cloud exactly as dense, while doubling the count
## makes a small screen needlessly expensive. One hundred and sixty two-triangle quads for one
## second is nothing.
@export var puffs: int = 210
## Puff size as a FRACTION OF THE RADIUS, at birth and at full bloom. A fraction rather than metres
## so a screen tuned to any reach stays as thick as this one: the number that has to hold is how
## many puff-widths across the cloud is, and that is what this expresses.
##
## SET SO THE PICTURE ENDS WHERE THE RULE ENDS. `SPREAD` puts the outermost puff centres at 0.70 of
## the radius and the largest is 0.52 of it across -- so the cloud's own edge lands at about 0.96 of
## `radius`, just inside the circle `blocks` tests. That direction is the one that matters and it was
## wrong at first: with bigger puffs thrown further out, the dust visibly covered a mouse standing at
## five metres while `spotting.gd` went on reporting it in plain sight. A picture more generous than
## its rule is worse than either -- it teaches the player a range that will get them caught.
@export var puff_size: Vector2 = Vector2(0.30, 0.52)

## How far out the puff centres are scattered, as a fraction of the radius. See `puff_size`.
const SPREAD: float = 0.70
## How high the dome stands, in metres. A mouse is 0.4 tall and the camera looks down steeply, so
## this is mostly about not being able to see over the near rim rather than about the cloud's own
## height -- and kept low, because puffs spread through a tall volume are puffs spent where nothing
## is standing. The first build put them up to 1.5m and threw a third of the cloud into the sky.
@export var dome_height: float = 0.9


## The cloud, from the moment it is thrown to the moment it is gone.
##
## THE WHOLE LIFE IS ONE SECOND and the shape of it is not linear. It blooms fast -- a screen that
## faded up over half its life would be a screen you could see through during the half you needed it
## -- holds, then thins out. `bloom` and `hold` below are fractions of `seconds`.
@export var seconds: float = 1.0
## A TENTH OF THE LIFE, which is very fast and has to be. This is the panic button: two tenths spent
## arriving is a fifth of the ability during which the mouse chasing you can still see you, and the
## whole second exists to cover one moment that is already going badly.
@export_range(0.0, 1.0, 0.01) var bloom: float = 0.10
@export_range(0.0, 1.0, 0.01) var hold: float = 0.45

## So `spotting.gd` can find live clouds without being wired to anything that makes them.
const SCREEN_GROUP: StringName = &"dust_screen"

var radius: float = 4.0
var plane: int = 0
var _age: float = 0.0
var _puffs: Array[Dictionary] = []


## Throw a screen at `at`. `seed_value` should be derived from the position so both ends of a wire
## draw the same cloud -- the same bargain [StompDust] makes, and for the same reason: nothing
## compares them, and "identical input, identical picture" is impossible to add back later.
static func raise(
	parent: Node, at: Vector3, seed_value: int, on_plane: int, reach: float
) -> DustScreen:
	if parent == null:
		return null
	var screen := DustScreen.new()
	screen.name = "DustScreen"
	screen.radius = maxf(reach, 0.1)
	screen.plane = on_plane
	parent.add_child(screen)
	# Positioned after entering the tree, so `at` is honoured as a world point whatever transform
	# the parent carries.
	screen.global_position = at
	screen._build(seed_value)
	return screen


## Is this cloud still thick enough to hide anything? Used by the sight test rather than mere
## existence, so the last thin frames of a cloud do not go on blinding a defender.
func is_opaque() -> bool:
	return _age < seconds * (1.0 - (1.0 - hold) * 0.35)


## How far from the middle this cloud reaches on the ground.
func reach() -> float:
	return radius


func _build(seed_value: int) -> void:
	add_to_group(SCREEN_GROUP)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	var quad := QuadMesh.new()
	quad.size = Vector2.ONE

	for index in range(maxi(puffs, 1)):
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(dust_color.r, dust_color.g, dust_color.b, 0.0)
		material.albedo_texture = screen_texture()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		# OFF THE DEPTH BUFFER, exactly as the stomp's puffs are, and for the same reason: several
		# dozen overlapping transparent quads sorted against one another is a flickering mess.
		#
		# WHICH DOES NOT COST THE OCCLUSION, and that is worth stating because it looks as though it
		# should. What hides the mouse is that the puffs are *drawn over* it -- they are in the
		# transparent queue, which runs after the opaque one, so they land on top of whatever solid
		# geometry is behind them whatever the depth buffer says. Writing depth would only make them
		# hide each other.
		material.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		# AFTER THE MICE, WHICH IT DOES NOT GET FOR FREE, and this is the line that makes the
		# ability work at all. A mouse is drawn with `TRANSPARENCY_ALPHA` -- it has to be, because
		# the grass fades it (GDD section 8) -- so mice and dust are both in the transparent queue,
		# and that queue sorts by distance from the camera rather than by what is in front of what.
		# A puff hanging at 60cm is nearer the camera than the mouse beside it and further than the
		# mouse behind it, so the cloud drew *through* the bodies it was covering: the second dust
		# photograph was a thick, convincing cloud with a perfectly legible red mouse inside it.
		#
		# Priority forces the whole cloud to the end of the queue, so every puff lands on top of
		# every mouse. Only the dust needs this, and only the dust should have it -- it is the one
		# translucent thing in the game whose job is to be in the way.
		# AFTER THE MICE, WHICH IT DOES NOT GET FOR FREE. A mouse is drawn with `TRANSPARENCY_ALPHA`
		# -- it has to be, because the grass fades it (GDD section 8) -- so mice and dust are both in
		# the transparent queue, and that queue sorts by distance from the camera rather than by what
		# is in front of what. Priority forces the whole cloud to the end of it, so every puff lands
		# on top of every mouse whatever height it happens to be hanging at.
		#
		# DEPTH TESTING IS LEFT ON, and was briefly turned off while this was being chased. It is not
		# the lever: what was actually leaving mice legible inside a convincing cloud was the puff
		# texture's falloff (see [constant PLATEAU]), and turning the test off changed nothing except
		# to paint dust over the boulders standing in front of it.
		material.render_priority = 8

		var piece := MeshInstance3D.new()
		piece.mesh = quad
		piece.material_override = material
		piece.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

		# SCATTERED THROUGH THE VOLUME RATHER THAN AROUND A RING, which is the other half of the
		# difference from the stomp. A ring is a shock front leaving a point and is meant to be seen
		# past; this has to have no gap anywhere in it, so the puffs fill a squat cylinder -- the
		# square root on the radius spreads them by area rather than by distance, without which
		# every cloud in the game would be dense in the middle and thin exactly where somebody is
		# trying to run out through the rim.
		var angle := rng.randf_range(0.0, TAU)
		var out := sqrt(rng.randf()) * radius * SPREAD
		var lift := rng.randf_range(0.05, dome_height)
		piece.position = Vector3(cos(angle) * out, lift, sin(angle) * out)
		add_child(piece)

		_puffs.append({
			"material": material,
			"node": piece,
			# A slow outward drift and a slow rise, so the wall is not a still image for a whole
			# second. Small: this is dust hanging, not dust being thrown.
			"drift": Vector3(cos(angle), 0.0, sin(angle)) * rng.randf_range(0.12, 0.5)
				+ Vector3.UP * rng.randf_range(0.15, 0.45),
			"size": rng.randf_range(puff_size.x, puff_size.y) * radius,
			# Each puff blooms on its own slightly different clock, so the wall thickens as a cloud
			# rather than as one object being faded in.
			"stagger": rng.randf_range(0.0, 0.35),
			"spin": rng.randf_range(-1.6, 1.6),
		})


func _process(delta: float) -> void:
	_age += delta
	var through := _age / maxf(seconds, 0.01)
	for puff: Dictionary in _puffs:
		var node: MeshInstance3D = puff["node"]
		if not is_instance_valid(node):
			continue
		node.position += (puff["drift"] as Vector3) * delta
		node.rotate_y(float(puff["spin"]) * delta)

		# Bloom, hold, thin. The size keeps growing the whole way -- a cloud that stopped expanding
		# while it faded would read as a texture being turned off rather than as dust dispersing.
		var grown: float = float(puff["size"]) * (0.55 + 0.45 * minf(through * 2.2, 1.0))
		node.scale = Vector3(grown, grown, grown)

		var staggered := maxf(0.0, through - float(puff["stagger"]) * bloom)
		var rising := clampf(staggered / maxf(bloom, 0.01), 0.0, 1.0)
		var going := 1.0 - smoothstep(hold, 1.0, through)
		var material: StandardMaterial3D = puff["material"]
		material.albedo_color.a = dust_color.a * rising * going

	# Freed by the clock, with a moment's grace so the last puff is not cut off mid-fade.
	if _age >= seconds + 0.15:
		queue_free()


## Does this cloud stand between these two points?
##
## THE TEST IS A SEGMENT AGAINST A VERTICAL CYLINDER, flattened to two dimensions -- the same
## simplification `spotting.gd` makes everywhere else, and honest here for the same reason: the
## cloud is as tall as it needs to be to break a sightline in a game watched from above, so its
## height is not a thing anybody can play around.
##
## NEAREST POINT ON THE SEGMENT, not on the infinite line. Two mice standing on the same side of a
## cloud can see each other perfectly well, and a line test would have had the dust blinding people
## who are nowhere near it.
func blocks(from: Vector3, to: Vector3) -> bool:
	if not is_opaque():
		return false
	var here := Vector2(global_position.x, global_position.z)
	var a := Vector2(from.x, from.z)
	var b := Vector2(to.x, to.z)
	var along := b - a
	var length_squared := along.length_squared()
	var nearest := a
	if length_squared > 0.0001:
		nearest = a + along * clampf((here - a).dot(along) / length_squared, 0.0, 1.0)
	return here.distance_to(nearest) <= radius
