class_name DirtTexture
extends RefCounted
## The grain that makes a flat colour read as ground.
##
## Every earth surface in the game -- the lawn, the trench floors, the walls, the lids -- was a
## single albedo colour, which at this camera distance is a sheet of card. Nothing tells you how
## big a cell is, nothing catches the light differently as you cross it, and the mouse reads as
## standing ON a colour rather than on dirt. The reference art this project is chasing solves it
## the cheapest possible way: speckle. Small tonal grains, a broad mottle underneath them, and
## the shading does the rest.
##
## GENERATED, NOT IMPORTED, and deliberately so at this stage. A dirt texture is a single seeded
## function, it costs a millisecond, there is no import step to get wrong, and -- most usefully --
## the grain size is a number you can change and press play. When the look settles, bake it.
##
## SEAMLESS BY CONSTRUCTION rather than by blending. The mottle is a lattice whose indices wrap,
## so the far edge interpolates back into the near one; the grain and the pebbles are per-texel
## and independent, so they have no spatial correlation to break at the seam. Godot's
## NoiseTexture2D would do the first part with `seamless`, but it generates on a thread and hands
## back an empty texture for the first few frames -- which is a race the audits would win about
## half the time.
##
## GREYSCALE, so it MULTIPLIES the colour it is given rather than replacing it. One texture serves
## the lawn, the tunnel floor, the walls and both lids, each keeping its own tint, and a material
## that wants no grain simply doesn't ask for it.

## Side of the generated square, in texels. Small on purpose: it is tiled across the world at
## `WORLD_TILE`, and a big texture would only make the repeat harder to see, not the dirt better.
const SIZE: int = 64
## How many world units one tile of the texture covers. With SIZE 64 that is a texel every 6cm --
## about a third of a mouse -- which lands the grain at the same scale as the pixel pass rather
## than under it, where it would only shimmer.
const WORLD_TILE: float = 4.0
## Side of the low-frequency lattice, in cells of the texture. Broad patches of lighter and darker
## earth: this is what stops the speckle reading as uniform noise.
const LATTICE: int = 8

## Darkest and lightest the mottle goes. Kept ABOVE nothing and BELOW one, because this multiplies
## an albedo that is already the colour somebody tuned -- the grain should texture that colour, not
## re-decide it.
const MOTTLE_LOW: float = 0.80
const MOTTLE_HIGH: float = 1.00
## Per-texel jitter on top of the mottle. The fine sand.
const GRAIN: float = 0.05
## Fraction of texels that become a distinct speck, and how far they stray. These are the grit and
## the little stones -- the thing you actually notice moving over.
const PEBBLE_CHANCE: float = 0.05
const PEBBLE_DEPTH: float = 0.22

## Seeded, so the grain is identical every run and one screenshot is comparable to the last.
const DEFAULT_SEED: int = 0xD147


## One shared texture, built on first use. Every earth material in the scene wants the same grain,
## and a copy each would be a copy of identical bytes.
static var _shared: ImageTexture = null


static func shared() -> ImageTexture:
	if _shared == null:
		_shared = build(DEFAULT_SEED)
	return _shared


static func build(seed_value: int) -> ImageTexture:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value

	# The lattice is sampled with wrapping indices, so the tile joins itself.
	var lattice: Array[float] = []
	for i in range(LATTICE * LATTICE):
		lattice.append(rng.randf())

	var image := Image.create_empty(SIZE, SIZE, false, Image.FORMAT_RGB8)
	for y in range(SIZE):
		for x in range(SIZE):
			var value := _mottle(lattice, float(x) / float(SIZE), float(y) / float(SIZE))
			value += rng.randf_range(-GRAIN, GRAIN)
			if rng.randf() < PEBBLE_CHANCE:
				value += PEBBLE_DEPTH * (1.0 if rng.randf() < 0.4 else -1.0)
			var shade := clampf(value, 0.0, 1.0)
			image.set_pixel(x, y, Color(shade, shade, shade, 1.0))

	return ImageTexture.create_from_image(image)


## Bilinear sample of the wrapping lattice, remapped into the mottle's range.
static func _mottle(lattice: Array[float], u: float, v: float) -> float:
	var fx := u * float(LATTICE)
	var fy := v * float(LATTICE)
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	# Smoothstep on the interpolant, or the lattice reads as a grid of diamonds.
	tx = tx * tx * (3.0 - 2.0 * tx)
	ty = ty * ty * (3.0 - 2.0 * ty)

	var a := _at(lattice, x0, y0)
	var b := _at(lattice, x0 + 1, y0)
	var c := _at(lattice, x0, y0 + 1)
	var d := _at(lattice, x0 + 1, y0 + 1)
	var top := lerpf(a, b, tx)
	var bottom := lerpf(c, d, tx)
	return lerpf(MOTTLE_LOW, MOTTLE_HIGH, lerpf(top, bottom, ty))


static func _at(lattice: Array[float], x: int, y: int) -> float:
	return lattice[(y % LATTICE) * LATTICE + (x % LATTICE)]


## Hand a material the grain, mapped in WORLD space rather than through UVs.
##
## TRIPLANAR, and that is not laziness about unwrapping. The meshes this goes on are generated --
## floor slabs from TunnelChunks, wall quads from TunnelNetwork -- and none of them carries a UV
## set. Triplanar also means a wall and the floor it stands on share one continuous grain instead
## of meeting at a visible seam, and that a corridor dug north looks like one dug east.
##
## NEAREST filtering, deliberately: the whole look is a pixel pass, and a smoothly interpolated
## speckle would be the one soft thing on screen.
static func apply_to(material: StandardMaterial3D) -> void:
	material.albedo_texture = shared()
	material.uv1_triplanar = true
	material.uv1_scale = Vector3.ONE / WORLD_TILE
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	material.texture_repeat = true
