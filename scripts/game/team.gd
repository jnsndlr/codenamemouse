class_name Team
extends RefCounted
## Which crew you belong to, and everything that follows from it.
##
## Two crews, blue and red (GDD section 1). Small enough to be an enum, but it earns a file
## because three separate things have to agree on it and none of them should be the owner:
## the tint on a mouse, the collision layer that makes ENEMIES body-block while allies pass
## through (GDD section 6), and which nest and banner are yours.
##
## Kept as static functions on a RefCounted rather than as an autoload. There is no state
## here -- a team is a number and a few lookups -- and an autoload would invite someone to
## start storing the match in it, which is the director's job.

enum { BLUE, RED }

## The crew colours. Deliberately not the same blue the concept art uses for the sky, because
## at isometric distance a mouse is a few dozen pixels and the only thing separating it from
## the background is hue.
const COLORS: Array[Color] = [
	Color(0.30, 0.50, 0.86),
	Color(0.84, 0.34, 0.28),
]

const NAMES: Array[String] = ["BLUE", "RED"]

## Collision layer bits, one per crew, well clear of the world bit and the four plane bits
## TunnelNetwork owns (1 and 2..5).
##
## `[REVISED at M8]` A mouse now masks BOTH crews, so every mouse is solid to every other one --
## see the long note on `Mouse.set_plane`. These stay one bit per crew even though nothing
## currently distinguishes them, because the two are still separately addressable and the day
## something wants to (a Juggernaut its own crew can shelter behind, a hazard that only reads one
## side) it should be a mask change rather than a new layer scheme.
const LAYER_BITS: Array[int] = [1 << 6, 1 << 7]


static func other(side: int) -> int:
	return RED if side == BLUE else BLUE


static func color_of(side: int) -> Color:
	return COLORS[side]


static func name_of(side: int) -> String:
	return NAMES[side]


static func layer_bit(side: int) -> int:
	return LAYER_BITS[side]
