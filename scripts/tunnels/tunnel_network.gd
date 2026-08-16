class_name TunnelNetwork
extends Node3D
## Four planes of dug cells, and everything about how they look.
##
## Storage is one GridMap per plane, as the implementation plan calls for: digging is
## setting a cell, collapse is clearing one, and Godot handles instancing and culling.
##
## The WALLS are not GridMap tiles. Connection-aware tiles would need a variant per
## neighbour mask, and the 8-way rule in GDD section 9 makes that combinatorially silly.
## Instead every dug cell emits a wall quad on each side that has no dug neighbour, all
## batched into one mesh per plane and rebuilt on change. At spike scale that rebuild is
## microseconds, and it means the wall set is always exactly the outline of the network.
##
## HOW DEPTH IS READ. Each layer is drawn as an open TRENCH cut through solid earth. A lid
## sits one plane-spacing above every floor with the layer's own tunnels punched out of it
## (see earth_cutaway.gdshader), walls run the full height from floor to lid, and only the
## focused layer plus a dim hint of the one above it is drawn at all. You cannot see the
## layers below, so they cannot be confused with yours -- which is why the per-depth rim hue
## M2 landed on is gone. It was the right answer to "read four layers at once", and nobody
## needs to; what you want is your own tunnel, on the layer you are in.
##
## VERTICAL TRANSIT IS A SHAFT, not a ramp, and that single change deleted most of this file.
## A ramp was sloped, oriented, two cells long, and it hung down through the whole headroom
## of the plane below -- so it needed stored orientations, per-face height arithmetic, flank
## walls, a rule against digging underneath it, and a graph search on every cut to prove it
## had not sealed a tunnel off. A shaft is a flag on a flat cell. It takes no walkable space
## away and occupies nothing on the plane below, so digging can now only ever ADD
## connectivity, and every one of those mechanisms went with it.

## Why a dig didn't happen. Refusing silently is indistinguishable from the controls being
## broken -- the entrance key spent a whole session looking dead for exactly that reason.
signal dig_refused(reason: String)

## What just happened, when something DID. The same one line of screen, said in the other voice.
##
## SPLIT OUT WHEN THE STOMP ARRIVED, and the reason is worth keeping because it is a small lesson
## about reusing a channel. The stomp is the first control whose *success* needs narrating -- its
## whole result is underground, so "you brought four cells down" and "there was nothing there" are
## both news, and both are outcomes rather than refusals. Sending them down `dig_refused` worked
## exactly as well as the wording of the label allowed, which is to say the HUD cheerfully printed
## **BLOCKED: the ground gives way beneath you**. A channel named for one voice will be read in
## that voice by everything downstream, however carefully the sender phrases it.
signal dig_noted(note: String)
## A cell was opened, or a shaft was sunk through one. The routing graph rides on these rather
## than rescanning: a dig changes one cell out of five thousand, and a graph that rebuilds itself
## to learn that is a graph nobody can afford to keep current.
signal cell_opened(plane: int, cell: Vector2i)
## A stroke of tunnel was cut, or removed. The geometry's own news, alongside the cell signals
## rather than instead of them.
##
## BOTH KINDS EXIST BECAUSE BOTH QUESTIONS DO. Everything that reasons about a PLACE -- the fog,
## the minimap, sonar, the routing graph as it stands -- wants the cells, and gets them. The wire
## is the one thing that has to reproduce the world's SHAPE on another machine, and a cell can no
## longer tell it that: two clients given the same cells would draw different tunnels.
signal segment_opened(plane: int, id: int)
signal segment_closed(plane: int, id: int)
signal shaft_opened(plane: int, cell: Vector2i)
## A cell was brought down. The one thing that makes the network get SMALLER, so it is the one
## thing every cache built on top of it has to hear about.
signal cell_collapsed(plane: int, cell: Vector2i)
## A shaft is gone -- filled in, both ends. Carried alongside the two `cell_collapsed` its ends
## produce rather than instead of them: the graph and the sight only ever cared about the cells,
## and the one thing that needs the shaft ITSELF named is the wire, which has to tell a client to
## stop drawing a ladder that is no longer there.
signal shaft_closed(plane: int, cell: Vector2i)
## A dug cell somebody cannot walk through any more, and then can again -- a barricade going up
## and coming down. Separate from `cell_collapsed` because the cell is still THERE: the floor, the
## walls, the lamps and the mask are all unchanged, and the only thing that has to hear about it
## is anything planning a route. Folding the two together would mean rebuilding a plane's geometry
## every time a boulder moved.
signal cell_blocked(plane: int, cell: Vector2i)
signal cell_unblocked(plane: int, cell: Vector2i)
## Timbers went into a cell, or the timbers were spent stopping a collapse. Two signals rather
## than one with a flag because the two are not opposites in the way `cell_blocked` and
## `cell_unblocked` are: one is an Engineer finishing three seconds of work, the other is a Brute's
## cooldown arriving and being eaten. The props listen to both; the audits listen to the second.
signal cell_shored(plane: int, cell: Vector2i)
signal shoring_broke(plane: int, cell: Vector2i)
## A crew found out where some rock is, or a boulder stopped being rock. Carries the teams affected
## as a bit mask rather than the cells, because both things that listen -- the caps drawn in the
## world and the minimap -- redraw a whole plane anyway, and a per-cell signal would have them
## rebuild the same mesh forty times for one vein.
signal rock_revealed(plane: int, teams: int)
## A crew's map of the tunnel network changed. Tunnel geometry is shared by the world, but the
## minimap is not omniscient: each crew only gets the cells and shafts it cut itself.
signal tunnel_revealed(plane: int, teams: int)

## So anything spawned into the match can find the network without being wired to it. Bots are
## created at runtime and have no scene to hold a NodePath for them.
const NETWORK_GROUP: StringName = &"tunnel_network"

const PLANE_COUNT: int = 4
const SPACING: float = TunnelChunks.PLANE_SPACING
const CELL: float = TunnelChunks.CELL
## Largest height change you can walk over. Every floor is flush with every other floor now,
## so nothing in the network ever exceeds it -- kept because props and map geometry will.
const STEP_TOLERANCE: float = 0.18
## Half-width of the dug field, in METRES. Comfortably past `half_extent_cells` so a tunnel can
## never reach ground the cutaway has no texel for.
const MASK_HALF_CELLS: int = 64

## Side of the dug field in texels. At 8 per metre over 64m each way this is 1024 -- a megabyte
## of R8 per plane, four in total, which buys a wall that is straight at any angle.
const FIELD_TEXELS: int = MASK_HALF_CELLS * 2 * TunnelContour.TEXELS_PER_METRE
## Texel index of world zero.
const FIELD_HALF_TEXELS: int = MASK_HALF_CELLS * TunnelContour.TEXELS_PER_METRE
## Chunks across the field. The rebuild unit; see [TunnelContour].
const FIELD_CHUNKS: int = FIELD_TEXELS / TunnelContour.CHUNK_TEXELS

## How long one stroke of digging is, and how wide the corridor it leaves. Unchanged from the
## cell the tunnel used to be built out of, deliberately: dig pacing, the Engineer's reach and
## every bot timing were tuned against a metre, and the point of this change is the ANGLE.
const SEG_LENGTH: float = 1.0
const SEG_WIDTH: float = 1.0
const SEG_HALF_WIDTH: float = SEG_WIDTH * 0.5

## How far a part-cut stroke has to advance before the physics picture is brought up to date with
## the drawn one. See [method carve] -- the drawing follows every texel, the collision cannot
## afford to, and a quarter of a metre is under the width of the corridor being cut so nothing you
## can walk into is ever more than a step ahead of the shape you walk into it with.
const CARVE_COLLIDE_STEP: float = 0.25

## Directions a segment may point. 64 steps is 5.6 degrees -- past the point where a chain of
## them reads as faceted, and small enough to be one byte on the wire.
##
## QUANTISED AT ALL because the angle has to survive a round trip through the network and come
## back bit-identical: a segment's identity is its origin and its angle (see [method segment_id]),
## and a float that arrives a millionth off is a second segment sitting inside the first one.
const ANGLE_STEPS: int = 64

## Fixed point for a segment's origin: sixteenths of a metre. Fine enough that the start of a
## stroke lands where the player pointed, coarse enough to pack into the id.
const ORIGIN_SCALE: float = 16.0
## Packing for [method segment_id]. Twelve bits per axis covers the field's 64m each way at
## sixteenths, with the bias making the stored halves unsigned.
const ID_BIAS: int = 2048
const ID_MASK: int = 4095

## How deep inside the tunnel a spot has to be before a mouse can stand on it: the body's own
## radius (see [Mouse.body_radius], 0.16) plus a little margin.
const STANDING_CLEARANCE: float = 0.18

## How far from a cell's centre to go looking for somewhere to stand, and how finely.
##
## A CELL IS CLAIMED IF THE TUNNEL PASSES THROUGH IT, NOT IF IT COVERS THE EXACT CENTRE, and
## getting that distinction wrong is what made the first curved tunnel come out as a dotted line.
## A corridor one metre wide, on a grid of one-metre cells, at an angle that is not a multiple of
## ninety degrees, simply cannot cover every cell centre along its path -- the geometry does not
## allow it. Sixteen metres of curve claimed NINE cells in six disconnected pieces: the fog had
## holes in it, the minimap drew dashes, and every one of those cells was, individually, correct.
##
## So the index answers "does the tunnel come through this square", and the places that care where
## a mouse actually STANDS ask [method standing_point] for the spot rather than assuming the
## middle. Two questions, two answers, instead of one answer serving neither.
##
## Stopping short of the cell's full half-width is deliberate: a corridor that merely clips a
## corner has not meaningfully arrived in that cell, and claiming it would swell every diagonal
## tunnel to two cells wide on the minimap.
const CELL_PROBE_REACH: float = 0.4
const CELL_PROBE_STEPS: int = 5

## Bit 1 is the world: ground, arena walls, props, rocks. Everything a mouse collides with
## regardless of depth.
const WORLD_BIT: int = 1

## Both crews, as the bit mask `_known` stores. For the things everybody can see: a boulder is
## rock you learn about by looking at it rather than by digging into it.
const TEAM_BITS: int = 0b11

const SIDES: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)
]

@export_group("Digging")
## How far a new shaft must keep from every existing one, in cells, measured as a square ring
## rather than a circle -- 1 forbids all eight neighbours, 0 turns the rule off.
##
## The GDD (section 3) always said each shaft has to start a tile away from the last; only the
## same-cell case was ever enforced, which let a staircase of shafts be packed into a 2x2 block
## and get you three planes down inside one stride. Spacing them out is what keeps depth a
## HORIZONTAL investment: to go deeper you have to tunnel sideways first, in the open, where it
## costs time and can be seen.
##
## It also fixes a legibility problem. Two mouths a cell apart read as one wide opening, and
## with a light beam falling down each the two pools of daylight merge into a single bright
## patch -- so the thing that is supposed to announce "a way out is HERE" stops saying where.
@export var shaft_exclusion_cells: int = 1

## The largest lump of earth, in metres across, that gets swallowed rather than left standing when
## the strokes around it close in. Zero turns the cull off.
##
## OFF-GRID DIGGING LEAVES CRUMBS. Two strokes meeting at a shallow angle, or a bend cut back on
## itself, pinch off scraps of earth a few texels across -- nubs and wafers in the middle of a
## chamber, floor-height fins standing in an otherwise open room. They read as debris rather than
## as terrain, and worse, most of them cannot be got rid of: [method opens_ground] samples a
## prospective stroke down its spine at plus and minus 0.3m, and a scrap thinner than that sits
## between the samples, so the dig is refused with nothing said. The ones you CAN clear take a
## stroke lined up to the degree. Both readings are the same bug to a player -- ground that
## ignores the dig button.
##
## SO THEY ARE NEVER MADE IN THE FIRST PLACE. Anything under this size is contoured as open from
## the moment it is pinched off, which costs nothing in play -- earth this small is not cover, not
## a route and not a wall -- and it means the geometry, the collision, the cutaway and the dig
## rule all agree that there is nothing there.
##
## SIZED AT THE SPINE SAMPLES, not by eye. 0.75m is comfortably past the 0.6m the offset samples
## span, so everything left standing is something a single well-aimed stroke can take out. Raising
## it eats real pillars; lowering it starts leaving back the scraps this exists to prevent.
##
## THIS IS ALSO WHAT THE CULL COSTS. Every chunk samples this far past its own square (see
## [method _cull_pad]) so that a scrap on a border can be measured whole from either side, so the
## reach is paid for on every dig whether there is anything out there or not. Use
## [member island_max_area] to be fussier WITHIN it; raise this only to reach bigger things.
@export var island_max_span: float = 0.75

## The largest FOOTPRINT, in square metres, that gets swallowed. Zero leaves the call to
## [member island_max_span] alone.
##
## WHAT THE SPAN CANNOT SAY. A box around a lump measures the room it takes up, not how much earth
## is in it, and at these sizes those come apart badly: a 0.7m sliver two texels thick and a solid
## 0.7m post measure identically and are not remotely the same thing. The sliver is debris. The post
## is a pillar you can hide behind, and if the strokes around it happen to close it off, it is the
## most interesting thing in the room. This is the dial that tells them apart -- roughly 0.1 square
## metres keeps anything with a bit of body to it and still takes the wafers.
##
## STRICTER, NEVER LOOSER, and that is a rule rather than a preference. The span is what makes the
## verdict a property of the earth instead of a property of whichever chunk is asking: a scrap
## clipped by a chunk's sampling window necessarily measures wider than the span and is kept, from
## both sides, always. An area test that could swallow something the span would not have would lose
## that -- a long thin snake has a small footprint and no bound at all on how far it wanders -- and
## the failure it buys is half an island, culled by one chunk and left standing by its neighbour.
## So this narrows what the span has already agreed to and cannot widen it.
##
## COUNTED IN SAMPLES, at 12.5cm apiece, so it is quantised in steps of about 0.016 square metres
## and reads a hair small against the interpolated outline the contour actually draws. Fine for a
## threshold; not a number to do arithmetic with.
@export var island_max_area: float = 0.0

## The thinnest earth allowed to stand anywhere, in metres. Zero turns the rule off.
##
## WHAT THE OTHER TWO CANNOT REACH, because both of them work on a lump of earth that has been cut
## off from the rest, and the worst of what off-grid digging leaves is still ATTACHED. A stroke is a
## capsule and a corridor is a chain of them; where two consecutive capsules meet at an angle, the
## outside of the joint leaves a cusp of earth poking into the corridor, tapering to nothing. Cut a
## long run and you get a row of them -- a sawtooth down one wall, every tooth joined to the bulk
## earth at its base, every tooth invisible to a rule about islands.
##
## SO THIS ONE IS ABOUT SHAPE RATHER THAN SIZE. Earth survives here only where a disc of half this
## width fits inside it: teeth, wafers and the tapering end of anything go, the bulk stays exactly
## where it was, and no lump has to be cut off from anything for the rule to see it. Being a purely
## local test it also needs no argument about chunk borders -- every chunk samples the little way
## past its own square that the disc reaches, and two neighbours reading the same earth cannot
## disagree about whether a disc fits in it.
##
## IT WILL ALSO OPEN A WALL. Two corridors dug closer together than this leave a divider too thin to
## survive the rule, and the two become one room. That is the rule working rather than overreaching,
## but it is the reason this is set where it is rather than where it first was.
##
## `[REVISED]` SET UNDER WHAT THE FIELD CAN SEE, WHICH IS NOT WHAT THE EYE CAN. The first value here
## was 0.5, and it ate dividers that were wanted. The arithmetic that decides the ceiling: a 20cm
## wall between two passes is 1.6 samples wide at 12.5cm, and the grid does not put a sample at its
## middle -- so the deepest sample IN a 20cm wall reads between 3.75cm and 10cm depending only on
## where the wall happens to fall. Anything above 0.075 therefore keeps a 20cm wall on some
## alignments and eats it on others, which is the same lottery the whole cull exists to stop.
##
## So the ceiling is not a matter of taste: to keep 20cm walls AT ALL, this has to sit under the
## worst alignment of one. What survives the setting is the honest scope of the rule -- anything
## under 7.5cm goes, anything 20cm or over stays, and the band between is decided by the grid. That
## is a cleanup of earth the field can barely represent rather than a shaping tool, and shaping
## wants a finer field (see [constant TunnelContour.TEXELS_PER_METRE]) rather than a bigger number
## here.
@export var earth_min_thickness: float = 0.075

@export_group("Rock")
## Per-plane rock obstructions (GDD section 3). Solid seams scattered through the earth that stop
## horizontal digging, with A DIFFERENT LAYOUT ON EVERY PLANE -- which is the whole idea. Rock in
## one place on every layer would be a flat maze repeated three times; rock that moves as you go
## down makes getting past an obstruction a question of which LAYER to go around it on, and turns
## map knowledge into four floors of map knowledge rather than one.
##
## A rock cell is not a new kind of thing. It is earth that can never be dug, so it is drawn by
## the same wall the surrounding earth is (in stone, so you can see what stopped you), collides as
## the same wall, and is invisible until somebody digs up against it -- which is exactly right for
## a game about hidden information: you learn where the rock is by paying for the knowledge.
@export var rock_seed: int = 20260801
## Fraction of plane 1 that is rock. Nothing on the surface: the lawn is not diggable in the first
## place, and a "rock" up there is just a prop.
@export_range(0.0, 0.5, 0.01) var rock_density: float = 0.09
## Added per plane below the first. Deeper is rockier, which gives the shallow planes a reason to
## exist once the deep ones are faster to cross -- and it is the same direction section 3 sends
## dig TIMES, so the two dials push the same way instead of cancelling.
@export_range(0.0, 0.2, 0.01) var rock_density_deeper: float = 0.035
## Cells in one seam. Seams rather than single blocked cells, because one cell is a thing you step
## around without noticing and a seam is a thing you have to make a decision about.
@export var rock_seam_cells: Vector2i = Vector2i(3, 11)
## Clear ground around every nest, in metres, so a crew can always get underground at home. A crew
## whose only entrance was blocked by generation would read as the map being broken, and it would
## happen identically every match because the layout is seeded.
@export var rock_nest_clearance: float = 6.0

@export_group("Bounds")
## Half-extent of diggable ground, in cells. Walls stop you WALKING off the arena; this is
## what stops you tunnelling off it. Without both, a tunnel runs out from under the map and
## you surface into open sky. Keep this inside the perimeter wall so tunnels never emerge
## underneath it.
@export var half_extent_cells: int = 37

@export_group("Look")
## Warm, because the tunnel is lit from inside by lamplight and the world above is not. That
## temperature split is doing most of the work of telling you where you are.
@export var floor_color: Color = Color(0.46, 0.32, 0.20)
@export var wall_color: Color = Color(0.19, 0.13, 0.09)
## The earth a layer is cut into, seen from above. Only used for planes 2 and 3 -- plane 1's
## lid is the actual ground of the map, which the scene owns.
@export var lid_color: Color = Color(0.24, 0.18, 0.13)
## The mouth of a shaft leading down. Near-black, because it is a hole.
@export var shaft_down_color: Color = Color(0.05, 0.03, 0.02)
## The face of a rock seam where a tunnel runs into one. Cool and pale against the warm earth --
## the message is "this is not the same stuff, and it is not going to open", and it has to land
## from across a corridor with no legend to read.
@export var rock_color: Color = Color(0.60, 0.64, 0.70)
## The same seam seen from ABOVE, once your crew has found it -- the cap over the solid cube you
## have run into (GDD section 3).
##
## PALE LIKE THE EXPOSED FACE. The old cap was both too dark and back-face culled from above, so a
## rock cube read as stone from the side and earth from the top. Matching the face's cool value
## makes the whole obstruction read as one material. Unknown rock still has no cap at all: this
## improves the revealed object without leaking seams.
@export var rock_top_color: Color = Color(0.60, 0.64, 0.70)

@export_group("Light rays")
## A shaft you can climb announces itself with the light falling out of it, not with a painted
## square. A mark can only say "something is here"; a beam says where it comes from, lights the
## floor it lands on, and reads instantly as a way out because that is what a shaft of daylight
## in a dark place means.
@export var ray_color: Color = Color(1.00, 0.93, 0.70)
@export_range(0.0, 1.0, 0.01) var ray_strength: float = 0.30
## Half-width of the beam where it leaves the ceiling, and where it lands. It widens on the
## way down, like a streetlight.
@export var ray_top_radius: float = 0.20
@export var ray_floor_radius: float = 0.52
@export var ray_light_energy: float = 2.2

@export_group("Shape")
## How far the DRAWN earth face rises above the tunnel floor. A full plane spacing, so the
## wall runs from the floor up to the underside of the lid and the trench is a real cut
## through solid ground rather than a kerb standing on an open plain.
@export var wall_height: float = TunnelChunks.PLANE_SPACING
## How far the INVISIBLE barrier rises. It cannot usefully exceed the plane spacing, because
## the only thing above a wall is the floor of the plane above -- set higher, barriers grow
## through it and fence off the layer above instead. What makes taller containment possible
## is PER-PLANE COLLISION LAYERS, which is what plane_bit below is for: a mouse only collides
## with the layer it is standing on, so a barrier can now overshoot without touching anyone.
@export var barrier_height: float = TunnelChunks.PLANE_SPACING * 2.0

@export_group("Lamps")
## Warm pools along the corridors. This is the single biggest reason the reference art reads
## as an inhabited burrow rather than a hole.
@export var lamp_color: Color = Color(1.00, 0.72, 0.42)
## Kept low with a generous range, rather than bright and tight. A hot little lamp blows out
## the floor directly under it into white and leaves the earth faces black.
@export var lamp_energy: float = 1.7
@export var lamp_range: float = 7.0
## One lamp per this many cells. Sparse on purpose: pools of light with dark between them
## read as depth, an evenly lit corridor reads as a flat texture.
@export var lamp_spacing_cells: int = 4
## Hard ceiling, so a large network can't quietly turn into a thousand-light scene.
@export var lamp_budget: int = 64

## plane -> {segment id: true}. What has actually been dug, and the only thing here that is not
## derived from something else.
##
## THE ID IS THE SEGMENT. It packs the origin and the angle (see [method segment_id]), so there is
## no record to keep beside it and no allocation to synchronise -- a client that receives an
## origin and an angle computes the identical key without being told it. That is what lets the
## wire's already-told diff and the fog's forget path work exactly as they did with cells.
var _segments: Array[Dictionary] = []
## plane -> {cell: {segment id: true}}: which segments pass through each coarse cell.
##
## THE REVERSE INDEX, and it earns its keep twice. It is what makes `_cells` removable exactly --
## a cell stops being dug when the LAST segment through it goes, which a plain flag could not tell
## you and a count could only tell you if every add and remove were perfectly paired. And it is
## what the dig cursor asks, every frame, to find which segments are near where you are pointing;
## without it, free branching would mean scanning every segment on the plane per frame.
var _cell_segments: Array[Dictionary] = []
## plane -> {cell: true}. Which coarse cells any segment passes through.
##
## `[REVISED]` DERIVED NOW, AND KEPT ANYWAY. This used to be the world; it is now an index over
## it, maintained in lockstep with `_cell_segments` by [method _occupy] and nothing else. It stays
## because it is what the rest of the game asks about -- the fog, the minimap, sonar, barricades,
## shoring and the wire all reason about a PLACE, and a metre is the right size for a place. Only
## the geometry needed to stop being square.
##
## IT IS A CONSERVATIVE SUPERSET of the walkable floor: a segment at 30 degrees clips the corner
## of cells whose far side is still earth. That is invisible to everything listed above, and it is
## precisely why bot routing must not stay on it -- see the stage 2 note on [TunnelGraph].
var _cells: Array[Dictionary] = []
## plane -> {cell: true}, meaning a shaft descends from `plane` to `plane + 1` at that cell.
##
## Stored on the UPPER of the two planes it joins, and stored once. A shaft is one object seen
## from two sides: standing on top of it you go down, standing under it you go up. That is
## what makes E unambiguous without a modifier -- there is only ever one shaft touching a
## cell, so there is only ever one direction to go.
var _shafts: Array[Dictionary] = []
## plane -> {cell: true}: earth that will never open. Laid once at startup, and then edited by
## exactly one thing -- a boulder on the lawn adding its footprint to plane 1, and giving it back
## when a Brute breaks it. That was the `[DECIDE]` in GDD section 4 about destructible rock, and
## the answer turned out to be "the rock you can SEE, and only that".
var _rock: Array[Dictionary] = []
## plane -> {cell: team bits}: which crews have found out that a rock cell is there. Empty for a
## cell nobody has run into, and hidden information until they do (GDD section 3).
##
## A BIT MASK RATHER THAN TWO DICTIONARIES, so a boulder -- which both crews can see from the
## first second -- is one entry rather than the same cell recorded twice under different keys.
var _known: Array[Dictionary] = []
## plane -> {cell: team bits}: which crews know a dug cell as part of their own network.
##
## This deliberately does NOT flood-fill through connected floor. If a blue corridor meets a red
## one, the physical routes intersect, but neither crew receives the other side's floor plan for
## free. The shared cell is the seam between the two maps.
var _tunnel_known: Array[Dictionary] = []
## upper plane -> {cell: team bits}: who cut and therefore knows each shaft. Kept separately from
## the landing cell because the surface minimap draws mouths rather than plane-1 floors.
var _shaft_known: Array[Dictionary] = []
## plane -> {cell: true}: enemy cells the VIEWING crew can currently make out, pushed in by
## tunnel_sight.gd. Only ever the one crew's, because this exists to decide what to draw and there
## is one camera -- the authoritative per-crew books live in the sight node, where M7 can filter
## them per client.
var _glimpsed: Array[Dictionary] = []
## plane -> {cell: true}: dug cells something is standing in the way of. Today that is a
## barricade; a cave-in makes a cell stop existing, which is a different thing entirely.
var _obstructed: Array[Dictionary] = []
## plane -> {cell: true}: dug cells an Engineer has put timbers into (GDD section 4).
##
## A THIRD KIND OF PROPERTY ON A CELL, and it is worth saying what makes it its own book rather
## than a flag on one of the other two. Rock is earth that will never open. An obstruction is
## something standing in a cell you could otherwise walk through. Shoring changes NEITHER: the cell
## is dug, walkable, routable and drawn exactly as it was, and the single thing that is different
## about it is what happens the next time somebody tries to bring it down. Nothing that moves a
## mouse or plans a route has any business reading this.
##
## A BOOLEAN AND NOT A COUNT, which is the balance the design asked for rather than a shortcut.
## Shoring absorbs ONE collapse and is gone; an Engineer who wants a cell to survive twice stands
## there for another three seconds after the Brute has spent its cooldown. Making it a depth would
## let an Engineer with time on its paws build a route no Brute could ever answer, and GDD section
## 5 is explicit that every answer in the web costs something and none of them is absolute.
var _shored: Array[Dictionary] = []
## plane -> {chunk key: {"floors":..., "walls":..., "stone":..., "collision":...}}. The contoured
## geometry of each 4m square, cached so a dig re-contours only what it touched.
##
## A CACHE RATHER THAN A SCENE NODE PER CHUNK, which is the cheap half of this design. The
## expensive part of a rebuild is marching squares, and that is what the chunking makes local; the
## concatenation of a few dozen cached triangle arrays into one mesh per plane is a native memcpy
## and costs nothing measurable. Keeping one mesh instance per plane means the node graph, the
## per-plane materials, the focus visibility rules and the collision body are all exactly as they
## were -- so a bug in this work cannot express itself as a scene that no longer matches the
## twenty other files that walk it.
var _chunk_cache: Array[Dictionary] = []

## Strokes part-way cut, per plane, keyed by the stroke: `{id: {"along": float, "team": int}}`.
## See [method carve].
##
## `[REVISED]` KEYED BY THE STROKE RATHER THAN BY WHOEVER IS CUTTING IT, AND KEPT WHEN THE BUTTON
## GOES UP. Both halves of that are the same correction. A carve used to be one digger's transient
## preview of a stroke they had not finished, thrown away the moment they let go or looked
## elsewhere -- so a player who released early watched the trench they had just cut fill back in,
## and a player standing IN it was dropped through the floor that closed under them, because there
## is nothing below a plane's floor to land on.
##
## Filed under the stroke, a part-cut metre is simply earth that is out. It survives the button, it
## survives re-aiming, and pointing back at it resumes rather than restarts -- which is what makes
## digging continuous rather than a series of half-second commitments you can lose.
var _carving: Array[Dictionary] = []

## The disc [method _thin_earth] searches, flattened for one window width, each offset's length in
## metres, and the width and radius the pair was built for.
var _thin_offsets: PackedInt32Array = PackedInt32Array()
var _thin_spans: PackedFloat32Array = PackedFloat32Array()
var _thin_offsets_for: Vector2i = Vector2i(-1, -1)
## plane -> {chunk key: true}: chunks whose cache is stale. Flushed by [method _rebuild_walls].
var _dirty_chunks: Array[Dictionary] = []
## The contoured floor of each plane. This is what the GridMap used to draw, one tile at a time.
var _floors: Array[MeshInstance3D] = []
## Shaft and entrance marks, one small mesh instance each, parented per plane.
var _marks: Array[Node3D] = []
var _mark_nodes: Array[Dictionary] = []
var _shaft_mesh: ArrayMesh
var _entrance_mesh: ArrayMesh
var _walls: Array[MeshInstance3D] = []
## The faces of the wall that turned out to be stone. Drawn separately from the earth walls only
## so they can carry a different material -- geometrically they are the same quads.
var _rock_faces: Array[MeshInstance3D] = []
## The tops of the seams a crew has found, one flat sheet per plane, drawn against the underside of
## that plane's lid. Rebuilt whole when knowledge changes, which is a few times a match.
var _rock_caps: Array[MeshInstance3D] = []
## Whose knowledge the caps are showing. -1 until somebody asks, because a network in a headless
## audit has no player and should draw nothing.
var _view_team: int = -1
var _bodies: Array[StaticBody3D] = []
var _shapes: Array[CollisionShape3D] = []
var _floor_materials: Array[StandardMaterial3D] = []
var _wall_materials: Array[StandardMaterial3D] = []
var _rock_materials: Array[StandardMaterial3D] = []
## One texel per cell, per plane: 255 where dug. Read by earth_cutaway.gdshader to punch the
## lid above that plane. Digging writes a texel instead of rebuilding anything.
var _mask_images: Array[Image] = []
var _mask_textures: Array[ImageTexture] = []
var _lids: Array[MeshInstance3D] = []
var _lamp_roots: Array[Node3D] = []
var _focus: int = 0
var _graph: TunnelGraph
## A network this machine does not decide anything about (M7 step 5).
##
## THE GUARD IS HERE, ON THE THING THAT OWNS THE STATE, and that placement is the whole argument.
## Several separate nodes cut earth -- the dig controller, the cave-in, the shoring, the barricade,
## and a shaft taken by anybody -- and guarding each of them is five chances to miss one and a
## sixth the day somebody adds a rule. Refusing at the state instead makes it structurally
## impossible for a client to change the world: there is no caller that can sneak past, because
## every one of them ends up here.
##
## The `adopt_*` methods deliberately DO NOT check it. They are not callers, they are the wire, and
## everything they write already happened somewhere that was allowed to decide it.
var _puppet: bool = false


## The cell books, before anything is drawn.
##
## SEPARATE FROM `_ready`, and the reason is node order rather than tidiness. Godot readies a scene
## depth-first, so everything under `Surface` -- including the boulders, which claim cells of
## plane 1
## the moment they exist -- runs before this node's `_ready` does. Left in there, the first boulder
## indexed an empty array and the failure was an out-of-range error in a file that has nothing to do
## with boulders. `_init` runs before any of it, and these are plain dictionaries with nothing to
## build, so there is no reason for them to wait for a renderer.
func _init() -> void:
	for plane in range(PLANE_COUNT):
		_segments.append({})
		_cell_segments.append({})
		_carving.append({})
		_chunk_cache.append({})
		_dirty_chunks.append({})
		_mark_nodes.append({})
		_cells.append({})
		_shafts.append({})
		_rock.append({})
		_known.append({})
		_tunnel_known.append({})
		_shaft_known.append({})
		_glimpsed.append({})
		_obstructed.append({})
		_shored.append({})


func _ready() -> void:
	add_to_group(NETWORK_GROUP)
	# One mesh each, shared by every mark on every plane. They carry their own material and are
	# never dimmed individually -- a mark is only ever drawn on the focused plane anyway.
	var mark_material := _make_material(shaft_down_color, false)
	_shaft_mesh = TunnelChunks.shaft_mark(mark_material)
	_entrance_mesh = TunnelChunks.entrance_mark(mark_material)

	for plane in range(PLANE_COUNT):
		var floor_material := _make_material(floor_color)
		var wall_material := _make_material(wall_color)
		_floor_materials.append(floor_material)
		_wall_materials.append(wall_material)
		_rock_materials.append(_make_rock_material())

		# Zero is "far outside the tunnel" once encoded, so an empty plane is a field of solid
		# earth without anything having to say so.
		var mask := Image.create_empty(FIELD_TEXELS, FIELD_TEXELS, false, Image.FORMAT_R8)
		mask.fill(Color(0.0, 0.0, 0.0, 1.0))
		_mask_images.append(mask)
		_mask_textures.append(ImageTexture.create_from_image(mask))

		var floor_mesh := MeshInstance3D.new()
		floor_mesh.name = "Floor%d" % plane
		floor_mesh.position = Vector3(0.0, plane_y(plane), 0.0)
		floor_mesh.material_override = floor_material
		add_child(floor_mesh)
		_floors.append(floor_mesh)

		var marks := Node3D.new()
		marks.name = "Marks%d" % plane
		marks.position = Vector3(0.0, plane_y(plane), 0.0)
		add_child(marks)
		_marks.append(marks)

		var wall := MeshInstance3D.new()
		wall.name = "Walls%d" % plane
		wall.position = Vector3(0.0, plane_y(plane), 0.0)
		add_child(wall)
		_walls.append(wall)

		var stone := MeshInstance3D.new()
		stone.name = "Rock%d" % plane
		stone.position = Vector3(0.0, plane_y(plane), 0.0)
		add_child(stone)
		_rock_faces.append(stone)

		# The vein seen from ABOVE, for the cells this crew has found. Sits just under the lid it
		# is drawn against rather than at the floor, because what it represents is a body of rock
		# filling the earth from one to the other -- and because at this camera angle a mark on the
		# floor of a plane you cannot see into is a mark on nothing.
		var cap := MeshInstance3D.new()
		cap.name = "RockTop%d" % plane
		cap.position = Vector3(0.0, plane_y(plane), 0.0)
		cap.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(cap)
		_rock_caps.append(cap)

		var lamps := Node3D.new()
		lamps.name = "Lamps%d" % plane
		lamps.position = Vector3(0.0, plane_y(plane), 0.0)
		add_child(lamps)
		_lamp_roots.append(lamps)

		# Collision is generated here rather than left to GridMap's MeshLibrary shapes.
		# Those shapes are set and valid but no body ever appears in the physics world, so
		# the player walks straight through the floor. Building one trimesh per plane from
		# the same cell data that drives the walls is deterministic, testable, and keeps
		# collision guaranteed identical to what's drawn. GridMap still does the rendering.
		var body := StaticBody3D.new()
		body.name = "Collision%d" % plane
		body.position = Vector3(0.0, plane_y(plane), 0.0)
		# Each plane on its own layer, and static geometry scans for nobody.
		body.collision_layer = plane_bit(plane)
		body.collision_mask = 0
		add_child(body)
		var shape := CollisionShape3D.new()
		body.add_child(shape)
		_bodies.append(body)
		_shapes.append(shape)

		_build_lid(plane)

	_generate_rock()

	# Built last, so it subscribes to a network whose planes all exist. It keeps itself current
	# from here on -- nothing else has to remember to tell it about a dig.
	_graph = TunnelGraph.new(self)
	set_focus_plane(0)


# ------------------------------------------------------------------------- coordinates


## Depth 0 is the surface. Each plane below sits one SPACING lower.
func plane_y(plane: int) -> float:
	return -SPACING * plane


func world_to_cell(position: Vector3) -> Vector2i:
	return Vector2i(roundi(position.x / CELL), roundi(position.z / CELL))


func cell_to_world(plane: int, cell: Vector2i) -> Vector3:
	return Vector3(cell.x * CELL, plane_y(plane), cell.y * CELL)


## Which plane a world height belongs to. Biased so that standing ON a floor reports that
## floor's plane rather than the one above it.
##
## A fallback rather than the source of truth now. Nothing walks between planes, so the
## controller knows exactly which layer it put you on; this is for anything that only has a
## position to go on.
func plane_at_height(y: float) -> int:
	return clampi(roundi(-y / SPACING), 0, PLANE_COUNT - 1)


## Whether a cell is inside the diggable arena at all.
func in_bounds(cell: Vector2i) -> bool:
	return absi(cell.x) <= half_extent_cells and absi(cell.y) <= half_extent_cells


# ------------------------------------------------------------------------- segments


## A segment's identity, packed: where it starts and which way it points, and nothing else.
##
## ORIGIN SNAPPED TO SIXTEENTHS FIRST, which is what makes the id a real identity rather than a
## hash. Two digs at the same place must produce the same key or the second one lays a duplicate
## segment inside the first -- invisible in the world, twice the geometry, and a cell that needs
## un-digging twice before it closes. Snapping makes "the same place" a decidable question.
static func segment_id(origin: Vector2, angle: int) -> int:
	var x := clampi(roundi(origin.x * ORIGIN_SCALE) + ID_BIAS, 0, ID_MASK)
	var y := clampi(roundi(origin.y * ORIGIN_SCALE) + ID_BIAS, 0, ID_MASK)
	return (x << 18) | (y << 6) | (posmod(angle, ANGLE_STEPS) as int)


static func segment_origin(id: int) -> Vector2:
	return Vector2(
		float(((id >> 18) & ID_MASK) - ID_BIAS) / ORIGIN_SCALE,
		float(((id >> 6) & ID_MASK) - ID_BIAS) / ORIGIN_SCALE
	)


static func segment_angle(id: int) -> int:
	return id & (ANGLE_STEPS - 1)


## A segment's origin in sixteenths of a metre, which is how it travels.
##
## THE WIRE SENDS THE SNAPPED NUMBER, NOT THE FLOAT, and that is what makes a segment's identity
## survive the trip. Sending a float would have the receiving end re-snap it, which is fine until
## a value lands exactly on a boundary and the two machines round it opposite ways -- at which
## point the client is drawing a stroke the server has never heard of, one sixteenth of a metre
## from one it has.
static func segment_fixed(id: int) -> Vector2i:
	return Vector2i(((id >> 18) & ID_MASK) - ID_BIAS, ((id >> 6) & ID_MASK) - ID_BIAS)


static func fixed_origin(fixed: Vector2i) -> Vector2:
	return Vector2(float(fixed.x), float(fixed.y)) / ORIGIN_SCALE


## Which way an angle index points, on the XZ plane.
static func angle_direction(angle: int) -> Vector2:
	var radians := TAU * float(posmod(angle, ANGLE_STEPS)) / float(ANGLE_STEPS)
	return Vector2(cos(radians), sin(radians))


## The nearest angle index to a direction. What the dig controller turns a cursor into.
static func direction_angle(direction: Vector2) -> int:
	if direction.length_squared() < 0.000001:
		return 0
	var step := roundi(direction.angle() / TAU * float(ANGLE_STEPS))
	return posmod(step, ANGLE_STEPS) as int


static func segment_end(id: int) -> Vector2:
	return segment_origin(id) + angle_direction(segment_angle(id)) * SEG_LENGTH


## Every segment on a plane, as ids.
func segments(plane: int) -> Array:
	return _segments[clampi(plane, 0, PLANE_COUNT - 1)].keys()


func has_segment(plane: int, id: int) -> bool:
	return plane >= 0 and plane < PLANE_COUNT and _segments[plane].has(id)


func segment_count(plane: int) -> int:
	return _segments[clampi(plane, 0, PLANE_COUNT - 1)].size()


## The cells a stroke touches. The other direction from [method segments_in_cell], for anything
## that has just cut one and needs to know what it now backs onto.
func segment_cells(id: int) -> Array[Vector2i]:
	return _segment_cells(id)


## Would this stroke actually take any earth out?
##
## THE ONLY HONEST WAY TO ASK "IS THIS DIG WORTH ANYTHING", and the first version of this asked
## something else entirely: whether the CELL the stroke ended in was already dug. That refused the
## one stroke that matters most -- the one that joins two corridors -- because a joining stroke
## always finishes inside the tunnel it is reaching for. Two corridors within a stroke of each
## other could never be connected, at all, ever. You could stand a metre from your own tunnel and
## the game would simply decline, with a cursor that vanished and no reason given.
##
## It was wrong twice over. Judging by the cell also refused strokes with real earth still in the
## way, because a cell counts as dug when a corridor merely passes through it -- so a stroke aimed
## across the untouched half of that square was turned down on the strength of the touched half.
##
## ANY EARTH AT ALL IS ENOUGH. There is no fraction to clear and no minimum bite: if the stroke's
## body contains a single spot that is not already open, there is dirt there and digging it is
## progress. The only thing this refuses is a stroke lying wholly inside tunnel that already
## exists -- pointing back down your own corridor -- which really would do nothing.
##
## SAMPLED AT THE FIELD'S OWN RESOLUTION, which is what makes "any earth" a decidable question
## rather than a matter of luck. A wall thinner than one texel is thinner than the world is stored,
## and the contour has already merged the two sides of it -- so there is nothing left there to dig.
##
## `[REVISED]` A STROKE'S OWN CARVE DOES NOT COUNT AGAINST IT, and forgetting that broke digging
## outright the first time carving was wired up. Part-cut ground reads as dug -- it is, that is the
## whole point -- so once a carve had eaten far enough along its own stroke, the stroke stopped
## opening ground, the cursor stopped offering it, the target reset and the progress with it. The
## dig cancelled itself a few centimetres before finishing, every time, and did it identically for
## every class. What the question means is "is there earth here that this stroke has not had yet",
## so the stroke's own progress is exactly the thing to look past.
func opens_ground(plane: int, origin: Vector2, angle: int) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT:
		return false
	var direction := angle_direction(angle)
	var across := Vector2(-direction.y, direction.x)
	var mine := segment_id(origin, angle)
	var along_steps := maxi(2, ceili(SEG_LENGTH / TunnelContour.TEXEL))
	for i in range(along_steps + 1):
		var spine := origin + direction * (SEG_LENGTH * float(i) / float(along_steps))
		for offset: float in [0.0, -0.6, 0.6]:
			if _is_earth(plane, spine + across * (SEG_HALF_WIDTH * offset), mine):
				return true
	return false


## Is this spot solid ground -- neither already dug, nor stone?
##
## Rock counts as NOT earth here, which reads oddly until you remember what the question is for:
## this decides whether there is anything to be gained by digging, and a seam is the one thing you
## can point at all day and never move. A stroke whose only unopened part is stone is refused for
## being stone (see [method dig_segment]), and it must not be offered on the way there either.
##
## SWALLOWED ISLANDS COUNT AS NOT EARTH FOR THE SAME REASON. A scrap the contour has already opened
## (see [member island_max_span]) still measures as solid against the strokes, because no stroke
## went through it -- so asked of the segments alone this says there is ground there to take out,
## the dig is allowed, and the player spends a stroke on a chamber floor and watches nothing happen.
## Which is the very complaint the cull exists to answer, moved one step along.
## `except` is a stroke whose own carve is to be ignored; see [method opens_ground].
func _is_earth(plane: int, point: Vector2, except: int = -1) -> bool:
	var cell := world_to_cell(Vector3(point.x, 0.0, point.y))
	if _rock[plane].has(cell):
		return false
	if _in_culled_island(plane, point):
		return false
	# Ground somebody is part-way through cutting is ground that is already out. Left in, the dig
	# rule would offer the mouse beside you a stroke through a trench you are standing in cutting.
	for id: int in _carving[plane]:
		if id == except:
			continue
		var start := segment_origin(id)
		var tip := _carve_end(id, carved_along(plane, id))
		if TunnelContour.segment_distance(point, start, tip, SEG_HALF_WIDTH) <= 0.0:
			return false
	for y in range(cell.y - 1, cell.y + 2):
		for x in range(cell.x - 1, cell.x + 2):
			for id: int in segments_in_cell(plane, Vector2i(x, y)):
				var distance := TunnelContour.segment_distance(
					point, segment_origin(id), segment_end(id), SEG_HALF_WIDTH
				)
				if distance <= 0.0:
					return false
	return true


## The point on an existing stroke nearest to `at`, within `reach` of it, and the id it belongs to
## -- or an empty array. What free branching is aimed with: you point at your own tunnel wall and
## the stroke starts from the nearest bit of tunnel there actually is.
##
## SEARCHED THROUGH THE CELL INDEX rather than over every segment on the plane. A late-match plane
## holds hundreds of strokes and this is asked every frame by every mouse being watched; scanning
## them all would make the cursor the most expensive thing in the process.
func nearest_segment_point(plane: int, at: Vector2, reach: float) -> Array:
	if plane <= 0 or plane >= PLANE_COUNT:
		return []
	var best_distance := reach
	var best: Array = []
	var span := ceili(reach / CELL) + 1
	var centre := world_to_cell(Vector3(at.x, 0.0, at.y))
	for y in range(centre.y - span, centre.y + span + 1):
		for x in range(centre.x - span, centre.x + span + 1):
			for id: int in segments_in_cell(plane, Vector2i(x, y)):
				var a := segment_origin(id)
				var b := segment_end(id)
				var along := b - a
				var t := 0.0
				if along.length_squared() > 0.000001:
					t = clampf((at - a).dot(along) / along.length_squared(), 0.0, 1.0)
				var point := a + along * t
				var distance := at.distance_to(point)
				if distance < best_distance:
					best_distance = distance
					best = [point, id]
	return best


## The segments passing through a cell, for anything that has to get from a place to the geometry.
func segments_in_cell(plane: int, cell: Vector2i) -> Array:
	if plane < 0 or plane >= PLANE_COUNT:
		return []
	var here: Variant = _cell_segments[plane].get(cell)
	return [] if here == null else (here as Dictionary).keys()


## Every cell the stroke opens somewhere standable. See [constant CELL_PROBE_REACH].
func _segment_cells(id: int) -> Array[Vector2i]:
	var a := segment_origin(id)
	var b := segment_end(id)
	var reach := SEG_HALF_WIDTH + CELL_PROBE_REACH
	var low := Vector2i(
		floori((minf(a.x, b.x) - reach) / CELL), floori((minf(a.y, b.y) - reach) / CELL)
	)
	var high := Vector2i(
		ceili((maxf(a.x, b.x) + reach) / CELL), ceili((maxf(a.y, b.y) + reach) / CELL)
	)
	var found: Array[Vector2i] = []
	for y in range(low.y, high.y + 1):
		for x in range(low.x, high.x + 1):
			var cell := Vector2i(x, y)
			# FILTERED HERE RATHER THAN REFUSED IN `dig_segment`, and the difference matters at the
			# edge of the map. A stroke's rounded end reaches half a width past its last endpoint,
			# so the outermost legal stroke really does open a little standable ground inside the
			# next square out. Refusing the stroke for it would make the boundary ring undiggable;
			# claiming the cell would put the index outside the arena. The ground is there and the
			# index simply does not name it -- which is exactly what `in_bounds` has always meant.
			if not in_bounds(cell):
				continue
			if _probe_cell(cell, a, b)[1] <= -STANDING_CLEARANCE:
				found.append(cell)
	return found


## The deepest-inside point of one stroke within one cell, as `[Vector2 point, float distance]`.
##
## A GRID SWEEP RATHER THAN AN EXACT CLOSEST-POINT SOLVE. The exact answer is the distance from a
## capsule to an axis-aligned square, which is a fiddly piece of geometry with several cases and
## exactly one purpose. Twenty-five samples give the same answer to within a few centimetres, and
## being a few centimetres conservative here costs nothing -- it can only decline a cell the
## corridor barely reaches, which is the direction [constant CELL_PROBE_REACH] is already leaning.
##
## THE END CAPS DO NOT CLAIM GROUND, and that one rule settles a whole family of problems at once.
## A stroke is a metre of centreline with a half-metre round cap on each end, so its footprint is
## two metres long -- and if the caps count, a single stroke claims the cell in front of it and the
## cell behind it as well as its own. Everything that assumed a dig opens ONE cell then breaks
## together: the count after a collapse, the tile that must stay shut when you are not holding the
## button, and worst, a diagonal chain of strokes reports itself connected through cells that have
## solid earth between them.
##
## The caps are there to make joints smooth -- two strokes meeting at an angle need no mitring if
## their ends are round -- and that is all they are for. Territory belongs to the BODY. Rejecting
## samples that fall past either end restores "one stroke, one cell's worth of corridor" without
## costing a curve anything, because consecutive strokes chain end to end and their bodies cover
## the whole path between them.
static func _probe_cell(cell: Vector2i, a: Vector2, b: Vector2) -> Array:
	var origin := Vector2(float(cell.x) * CELL, float(cell.y) * CELL)
	var along := b - a
	var length_squared := along.length_squared()
	var best := 1000.0
	var at := origin
	var step := CELL_PROBE_REACH * 2.0 / float(CELL_PROBE_STEPS - 1)
	for j in range(CELL_PROBE_STEPS):
		for i in range(CELL_PROBE_STEPS):
			var point := origin + Vector2(
				-CELL_PROBE_REACH + float(i) * step, -CELL_PROBE_REACH + float(j) * step
			)
			if length_squared > 0.000001:
				var t := (point - a).dot(along) / length_squared
				if t < 0.0 or t > 1.0:
					continue
			var distance := TunnelContour.segment_distance(point, a, b, SEG_HALF_WIDTH)
			if distance < best:
				best = distance
				at = point
	return [at, best]


## Where in this cell a mouse would actually be standing -- the spot furthest from any wall.
##
## WHAT THE CENTRE USED TO BE ASSUMED TO BE. A cell is in the index because the tunnel comes
## through it, which on anything but an axis-aligned corridor does not mean the tunnel covers the
## middle of it. Anything placing a body, casting a ray for floor, or measuring headroom wants
## this rather than [method cell_to_world]; anything merely NAMING the cell -- a minimap square, a
## sonar ping, a fog entry -- is right to keep using the centre.
func standing_point(plane: int, cell: Vector2i) -> Vector3:
	var best := 1000.0
	var at := Vector2(float(cell.x) * CELL, float(cell.y) * CELL)
	for id: int in segments_in_cell(plane, cell):
		var probe := _probe_cell(cell, segment_origin(id), segment_end(id))
		if (probe[1] as float) < best:
			best = probe[1]
			at = probe[0]
	return Vector3(at.x, plane_y(plane), at.y)


## Put a segment into the books: the segment set, the reverse index, the derived cell set, and
## the chunks whose geometry it just changed.
##
## Returns the cells that became dug BECAUSE OF THIS SEGMENT, so the caller can announce them.
## Cells already covered by a neighbouring segment are not news and must not be re-announced --
## `cell_opened` is what the routing graph and the sight are built on, and a cell opened twice is
## a graph point added twice.
## TWO SETS OF CELLS, AND THEY ARE NOT THE SAME SET, which is the correction that made curved
## tunnels actually work. `_cell_segments` is a SPATIAL INDEX -- "which strokes are near here" --
## and has to be generous, because it is how a chunk finds the strokes to contour and how the
## cursor finds the tunnel you are pointing at. `_cells` is a claim about STANDING, and has to be
## strict, because everything downstream treats a cell as a place a mouse can be.
##
## Sharing one threshold between them broke both ends at once. Strict for both, and a stroke that
## threads between cell centres -- which happens constantly on a curve, where the tunnel does not
## line up with the grid at all -- registered in no cell, so no chunk ever gathered it and its
## geometry was never drawn. Loose for both, and the ring of cells around every corridor became
## walkable ground the fog uncovered and bots routed through.
func _occupy(plane: int, id: int) -> Array[Vector2i]:
	for cell: Vector2i in _near_cells(id):
		var here: Variant = _cell_segments[plane].get(cell)
		if here == null:
			here = {}
			_cell_segments[plane][cell] = here
		(here as Dictionary)[id] = true
	var fresh: Array[Vector2i] = []
	for cell: Vector2i in _segment_cells(id):
		if not _cells[plane].has(cell):
			_cells[plane][cell] = true
			fresh.append(cell)
	_touch(plane, id)
	return fresh


## The reverse: take a segment out, and report the cells that stopped being dug entirely.
func _vacate(plane: int, id: int) -> Array[Vector2i]:
	# THE INDEX FIRST, so that the standing test below cannot see the stroke being removed.
	for cell: Vector2i in _near_cells(id):
		var here: Variant = _cell_segments[plane].get(cell)
		if here == null:
			continue
		var users := here as Dictionary
		users.erase(id)
		if users.is_empty():
			_cell_segments[plane].erase(cell)

	var emptied: Array[Vector2i] = []
	for cell: Vector2i in _segment_cells(id):
		# THE LAST STROKE OUT CLOSES THE CELL. This is the whole reason the index stores a set of
		# ids rather than a flag: with a flag there is no way to tell "nothing reaches here any
		# more" from "one of the three that did has gone", and the corridor would either linger
		# after a cave-in or vanish a metre either side of it.
		if _cells[plane].has(cell) and not _still_stood_in(plane, cell):
			_cells[plane].erase(cell)
			emptied.append(cell)
	_touch(plane, id)
	return emptied


## Does any remaining stroke still make this cell somewhere you can stand?
func _still_stood_in(plane: int, cell: Vector2i) -> bool:
	return not _segments_standing_in(plane, cell).is_empty()


## The strokes that actually make this cell somewhere you can stand -- the subset of the spatial
## index whose bodies reach it. See [method _segment_cells], which asks the same question the
## other way round.
func _segments_standing_in(plane: int, cell: Vector2i) -> Array[int]:
	var found: Array[int] = []
	for id: int in segments_in_cell(plane, cell):
		var reach: float = _probe_cell(cell, segment_origin(id), segment_end(id))[1]
		if reach <= -STANDING_CLEARANCE:
			found.append(id)
	return found


## Every cell a stroke comes near enough to be worth considering: the spatial index's question,
## not the standing one. Generous on purpose -- a stroke missing from a cell here is a stroke a
## chunk never contours and a cursor never finds.
func _near_cells(id: int) -> Array[Vector2i]:
	var a := segment_origin(id)
	var b := segment_end(id)
	var reach := SEG_HALF_WIDTH + CELL * 0.7072
	var low := Vector2i(
		floori((minf(a.x, b.x) - reach) / CELL), floori((minf(a.y, b.y) - reach) / CELL)
	)
	var high := Vector2i(
		ceili((maxf(a.x, b.x) + reach) / CELL), ceili((maxf(a.y, b.y) + reach) / CELL)
	)
	var found: Array[Vector2i] = []
	for y in range(low.y, high.y + 1):
		for x in range(low.x, high.x + 1):
			var centre := Vector2(float(x) * CELL, float(y) * CELL)
			if TunnelContour.segment_distance(centre, a, b, SEG_HALF_WIDTH) <= CELL * 0.7072:
				found.append(Vector2i(x, y))
	return found


## Mark every chunk a segment's outline could fall in as needing re-contouring.
func _touch(plane: int, id: int) -> void:
	_touch_span(plane, segment_origin(id), segment_end(id))


## The same, for a stretch of ground named directly rather than by a stroke id.
##
## SPLIT OUT FOR CARVING, which changes the field a few centimetres at a time. A growing stroke has
## only altered the earth around the bit it just grew INTO, so re-contouring its whole metre on
## every step is eight times the work for the same picture -- and it is work paid several times a
## second, which the commit path never was.
##
## `cull` is whether to reach out far enough for the field rules to be re-decided at a distance;
## see the reach below for what that costs and [method carve] for why a growing carve declines it.
func _touch_span(plane: int, a: Vector2, b: Vector2, cull: bool = true) -> void:
	# Grown by the half-width plus a texel, so the chunk holding the far side of a rounded end is
	# included. Missing one leaves a notch of un-rebuilt wall that only appears at some angles.
	#
	# AND BY THE CULL'S REACH ON TOP OF THAT, because a stroke changes more than it touches now: the
	# scrap it pinches off can be a whole island away, in a chunk this stroke never enters, and that
	# chunk has to re-contour to notice its earth has become small enough to swallow.
	#
	# WHICH IS ALSO MOST OF WHAT A REBUILD COSTS -- it is a metre of extra reach in every direction,
	# so it is the difference between waking two chunks and waking nine. Declining it leaves the
	# rules a moment out of date at a distance and nothing else: what a carve can pinch off a chunk
	# away is a scrap of earth, and a scrap left standing is the state it was already in.
	#
	# THE COMMIT COLLECTS THE BILL, and now that a carve can be abandoned half-way (see
	# [method carve]) it is worth saying what happens when no commit comes: the scrap stands until
	# the next stroke cut anywhere near it reaches out in full and swallows it. That is a crumb
	# nobody can see for as long as nobody digs there, against paying a nine-chunk rebuild eight
	# times a stroke on the chance that there is one.
	var reach := SEG_HALF_WIDTH + TunnelContour.TEXEL * 2.0
	if cull:
		reach += float(_cull_pad()) * TunnelContour.TEXEL
	var low := _chunk_at(Vector2(minf(a.x, b.x) - reach, minf(a.y, b.y) - reach))
	var high := _chunk_at(Vector2(maxf(a.x, b.x) + reach, maxf(a.y, b.y) + reach))
	for cy in range(low.y, high.y + 1):
		for cx in range(low.x, high.x + 1):
			if cx < 0 or cy < 0 or cx >= FIELD_CHUNKS or cy >= FIELD_CHUNKS:
				continue
			_dirty_chunks[plane][cy * FIELD_CHUNKS + cx] = true


## Which chunk a world point falls in.
func _chunk_at(point: Vector2) -> Vector2i:
	return Vector2i(
		floori((point.x * TunnelContour.TEXELS_PER_METRE + float(FIELD_HALF_TEXELS))
			/ float(TunnelContour.CHUNK_TEXELS)),
		floori((point.y * TunnelContour.TEXELS_PER_METRE + float(FIELD_HALF_TEXELS))
			/ float(TunnelContour.CHUNK_TEXELS))
	)


# ------------------------------------------------------------------------- collision


## The collision layer a plane's geometry lives on.
##
## PER-PLANE LAYERS, so a mouse only ever collides with the layer it is standing on. Without
## this every barrier is a barrier for everyone: raise plane 2's walls above the spacing and
## they grow through plane 1's floor and fence off a player up there who cannot see what is
## stopping them. It is also what lets barriers overshoot the wall height freely, which is
## what GDD section 6's displacement will need -- knockback has to be unable to throw a mouse
## out of its own tunnel.
static func plane_bit(plane: int) -> int:
	return 1 << (plane + 1)


## Set a body to collide with the world and with exactly one tunnel layer.
func apply_plane_collision(body: CollisionObject3D, plane: int) -> void:
	body.collision_mask = WORLD_BIT | plane_bit(clampi(plane, 0, PLANE_COUNT - 1))


# ------------------------------------------------------------------------- rock


## Lay the seams. Once, at startup, per plane, from a seed.
##
## SEEDED AND PER-PLANE, which are the two things that matter. Seeded, because a map you cannot
## replay is a map you cannot learn (GDD section 8 wants layouts to be a recipe plus a seed), and
## because a bug that only happens on one layout is a bug you can only reproduce by luck. Per
## plane, because rock in the same place on every layer is a flat maze drawn three times -- the
## point of section 3's obstructions is that going AROUND one may mean going down.
func _generate_rock() -> void:
	if rock_density <= 0.0:
		return

	for plane in range(1, PLANE_COUNT):
		var rng := RandomNumberGenerator.new()
		# A different stream per plane, derived from one dial. Sharing the generator across planes
		# would work too, but then changing plane 1's density would silently relayout planes 2 and
		# 3 as well, and every screenshot of the deep layers would stop being comparable.
		rng.seed = rock_seed + plane * 7919

		var span := half_extent_cells
		var area := float((span * 2 + 1) * (span * 2 + 1))
		var wanted := int(area * (rock_density + rock_density_deeper * float(plane - 1)))
		var placed := 0
		var attempts := 0
		while placed < wanted and attempts < wanted:
			attempts += 1
			var start := Vector2i(rng.randi_range(-span, span), rng.randi_range(-span, span))
			if not _rock_allowed(plane, start):
				continue
			placed += _grow_seam(plane, start, rng)


## A seam, grown as a random walk rather than as a disc. A disc is a circle, and a circle in the
## ground is the one shape that reads as placed by a level designer; a walk wanders, doubles back
## on itself and leaves the ragged edge a mineral seam actually has.
func _grow_seam(plane: int, start: Vector2i, rng: RandomNumberGenerator) -> int:
	var length := rng.randi_range(rock_seam_cells.x, maxi(rock_seam_cells.x, rock_seam_cells.y))
	var at := start
	var laid := 0
	for i in range(length):
		if _rock_allowed(plane, at):
			_rock[plane][at] = true
			laid += 1
		at += SIDES[rng.randi_range(0, SIDES.size() - 1)]
		if not in_bounds(at):
			break
	return laid


## Whether generation may put rock in this cell.
##
## The nest clearance is the load-bearing one. A crew whose ground is rock to the horizon cannot
## get underground at home, and because the layout is seeded that would happen in exactly the same
## place every single match -- which reads as the map being broken rather than as a hard start.
func _rock_allowed(plane: int, cell: Vector2i) -> bool:
	if not in_bounds(cell) or _rock[plane].has(cell):
		return false
	var here := Vector2(float(cell.x) * CELL, float(cell.y) * CELL)
	if is_inside_tree() and Nest.blocks(get_tree(), here, rock_nest_clearance):
		return false
	return true


## Earth that will never open, however long you hold the button.
func is_rock(plane: int, cell: Vector2i) -> bool:
	return plane >= 0 and plane < PLANE_COUNT and _rock[plane].has(cell)


## Every rock cell on a plane. For the audits, and for anything that wants to draw the layout.
func rock_cells(plane: int) -> Array:
	return _rock[clampi(plane, 0, PLANE_COUNT - 1)].keys()


## Rock that was not there when the map was laid: the cells under a boulder on the lawn.
##
## THE SAME EARTH-THAT-NEVER-OPENS, deliberately, rather than a second kind of obstruction with its
## own queries. Digging, shafts, the wall mesh and the routing graph all already refuse rock in the
## right places, and a boulder that used a parallel mechanism would have to be taught to each of
## them separately -- which is four chances to miss one.
##
## `known` is what makes a boulder feel completely different from a seam despite being the same
## thing underneath. A seam is hidden until somebody pays to find it; a boulder is sitting on the
## lawn in front of you, so the crew that can see it already knows what is under it, and pretending
## otherwise would be a puzzle about the camera rather than about the map.
func add_rock(plane: int, cell: Vector2i, known: bool = false) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT or not in_bounds(cell):
		return false
	# Never over a tunnel somebody already dug. Rock arriving on top of an open corridor would make
	# a cell that is dug AND impassable, which is a state nothing else here handles: the floor is
	# drawn, the graph routes through it, and the dig refuses to reopen it.
	if _cells[plane].has(cell) or _rock[plane].has(cell):
		return false
	_rock[plane][cell] = true
	if known:
		_known[plane][cell] = TEAM_BITS
		_announce_rock(plane, TEAM_BITS)
	return true


## And rock that stops being rock: a boulder broken up, the earth under it ordinary again.
func remove_rock(plane: int, cell: Vector2i) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT or not _rock[plane].has(cell):
		return false
	_rock[plane].erase(cell)
	_known[plane].erase(cell)
	# The face of the seam was drawn in stone by whichever corridors had run up against it, and it
	# is ordinary earth now. Cheap, and only ever on a Brute's last swing.
	_rebuild_walls(plane)
	_announce_rock(plane, TEAM_BITS)
	return true


# ------------------------------------------------------------------------- what a crew knows


## Learn where a vein goes, by running into it.
##
## THE WHOLE CONNECTED VEIN, not the one cell you hit. A seam is grown as a random walk and reads as
## a single object -- the thing you have actually learned when your Engineer's shovel rings off it
## is "this seam is here", and drip-feeding it a tile at a time would mean chipping along a wall to
## map something you can already see the shape of. The cell is the price; the vein is the knowledge.
##
## PER CREW, which is the part that makes it worth storing at all. Rock is hidden information (GDD
## section 3) and the crew that spent the digs is the crew that gets to route around it. This is the
## first per-team knowledge in the game and it is deliberately the small one -- M5 has to do the
## same trick for tunnels and for sightings, and doing it once on something static is how the shape
## gets found before it matters.
func reveal_vein(plane: int, cell: Vector2i, team: int) -> int:
	if _puppet:
		return 0
	if plane <= 0 or plane >= PLANE_COUNT or not _rock[plane].has(cell):
		return 0
	var bit := 1 << clampi(team, 0, 1)
	if int(_known[plane].get(cell, 0)) & bit != 0:
		return 0

	# Flood fill over shared faces only, which is the same connectivity the walls and the routing
	# graph use. Eight-way would join two seams that touch at a corner -- and a corner is exactly
	# the place a mouse cannot get through, so they are not one vein to anybody who has to dig.
	var found := 0
	var queue: Array[Vector2i] = [cell]
	var seen := {cell: true}
	while not queue.is_empty():
		var at: Vector2i = queue.pop_back()
		if int(_known[plane].get(at, 0)) & bit == 0:
			_known[plane][at] = int(_known[plane].get(at, 0)) | bit
			found += 1
		for side: Vector2i in SIDES:
			var beside := at + side
			if seen.has(beside) or not _rock[plane].has(beside):
				continue
			seen[beside] = true
			queue.append(beside)

	if found > 0:
		_announce_rock(plane, bit)
	return found


## Somebody's picture of a plane changed. Redraws the caps if it was the crew being drawn for, and
## tells everything else once.
##
## The rebuild is HERE rather than on a connection to this file's own signal, because a listener
## that has to be wired up in `_ready` is a listener somebody can delete and not notice: the caps
## would simply stop updating, which looks exactly like the reveal not working.
func _announce_rock(plane: int, teams: int) -> void:
	if _view_team >= 0 and teams & (1 << _view_team) != 0:
		_rebuild_rock_caps(plane)
	rock_revealed.emit(plane, teams)


func is_rock_known(plane: int, cell: Vector2i, team: int) -> bool:
	if plane < 0 or plane >= PLANE_COUNT:
		return false
	return int(_known[plane].get(cell, 0)) & (1 << clampi(team, 0, 1)) != 0


## Every rock cell on a plane that `team` has found. For the cap mesh and the minimap -- the two
## things that draw what a crew knows.
func known_rock_cells(plane: int, team: int) -> Array[Vector2i]:
	var found: Array[Vector2i] = []
	if plane < 0 or plane >= PLANE_COUNT:
		return found
	var bit := 1 << clampi(team, 0, 1)
	for cell: Vector2i in _known[plane]:
		if int(_known[plane][cell]) & bit != 0:
			found.append(cell)
	return found


# ------------------------------------------------------------------------- paving


## Is this cell under paving -- a patio, a path, flagstones (GDD section 3)?
##
## THE SECOND KIND OF OBSTRUCTION, and it is nothing like the first. Rock is a property of one
## cell on one plane and stops you digging SIDEWAYS; paving is a property of the ground above and
## stops you only from breaking through it. So this takes no plane: the earth under a slab is
## ordinary earth on every layer, and the one thing the answer is ever used for is refusing a
## shaft that would touch the surface.
##
## Asked of the map rather than baked into a set here. The footprints are authored nodes, they
## never move during a match, and the question is asked a few times a second at most -- caching
## it would buy nothing and would go stale the first time a map animated a garage door.
func is_sealed(cell: Vector2i) -> bool:
	if not is_inside_tree():
		return false
	# Half a cell of margin, because a mouth is a cell wide and not a point: a shaft whose centre
	# just clears the slab still opens a hole through its edge.
	return NoSurfaceZone.seals(
		get_tree(), Vector2(float(cell.x) * CELL, float(cell.y) * CELL), CELL * 0.5
	)


# ------------------------------------------------------------------------- obstruction


## Something is standing in this cell that a mouse cannot get past (a barricade).
##
## THE CELL IS STILL DUG, and that distinction is the whole reason this is not `collapse`. The
## floor, the walls, the lamps and the cutaway mask are all still correct and none of them is
## rebuilt; the only thing that changes is that nothing may plan a route through here. Making a
## barricade collapse the cell instead would have rebuilt a plane's geometry every time one went
## up, and would have made putting one down indistinguishable from digging a fresh corridor.
func block_cell(plane: int, cell: Vector2i) -> bool:
	if _puppet:
		return false
	if not is_dug(plane, cell) or _obstructed[plane].has(cell):
		return false
	_obstructed[plane][cell] = true
	cell_blocked.emit(plane, cell)
	return true


func unblock_cell(plane: int, cell: Vector2i) -> bool:
	if _puppet:
		return false
	if plane < 0 or plane >= PLANE_COUNT or not _obstructed[plane].has(cell):
		return false
	_obstructed[plane].erase(cell)
	# Only announced if the cell is still there to walk through. A barricade whose floor was caved
	# in from under it un-blocks on the way out, and re-adding that cell to the routing graph
	# would put back a point `collapse` had just correctly removed.
	if is_dug(plane, cell):
		cell_unblocked.emit(plane, cell)
	return true


func is_blocked(plane: int, cell: Vector2i) -> bool:
	return plane >= 0 and plane < PLANE_COUNT and _obstructed[plane].has(cell)


# ---------------------------------------------------------------------------- shoring


## Put timbers into a dug cell: the next collapse aimed at it is spent breaking them (GDD
## section 4). Returns false if there is nothing to shore or it is shored already.
##
## THE ONE THING IN THIS FILE THAT MAKES A CELL HARDER TO REMOVE, and it is the Engineer's answer
## to having lost its escape button when un-digging went to the Brute. What it is NOT is a way to
## make a corridor permanent -- see `_shored` for why this is a boolean.
func shore(plane: int, cell: Vector2i) -> bool:
	if _puppet:
		return false
	if not is_dug(plane, cell) or _shored[plane].has(cell):
		return false
	_shored[plane][cell] = true
	cell_shored.emit(plane, cell)
	return true


func is_shored(plane: int, cell: Vector2i) -> bool:
	return plane >= 0 and plane < PLANE_COUNT and _shored[plane].has(cell)


## The timbers give, and the cell stays. Returns whether there was anything to break.
##
## CALLED BY `collapse` RATHER THAN BY THE BRUTE, which is the same argument `_puppet` makes two
## hundred lines up: five things in this project bring earth down, and a shoring check written into
## each of them is four chances to miss one. Everything that collapses a cell arrives here first.
func break_shoring(plane: int, cell: Vector2i) -> bool:
	if _puppet:
		return false
	if plane < 0 or plane >= PLANE_COUNT or not _shored[plane].has(cell):
		return false
	_shored[plane].erase(cell)
	shoring_broke.emit(plane, cell)
	return true


func shored_cells(plane: int) -> Array:
	return _shored[clampi(plane, 0, PLANE_COUNT - 1)].keys()


# ------------------------------------------------------------------------- queries


## Audits and authored probe networks omit a crew and are visible to both sides. Live digging
## always supplies the mouse's team through dig_controller.gd.
func _team_bits(team: int) -> int:
	return TEAM_BITS if team < Team.BLUE or team > Team.RED else 1 << team


func _learn_tunnel_cell(plane: int, cell: Vector2i, team: int) -> void:
	if plane <= 0 or plane >= PLANE_COUNT:
		return
	var bits := _team_bits(team)
	# A live dig that breaks into an enemy-only neighbour makes THIS new cell the shared junction.
	# Do not propagate from an already shared neighbour: that would make every later cell in the
	# digger's corridor shared too and quietly reveal the whole route one tile at a time.
	if team >= Team.BLUE and team <= Team.RED:
		var own_bit := 1 << team
		var enemy_bit := 1 << Team.other(team)
		for side: Vector2i in SIDES:
			var neighbour_bits := int(_tunnel_known[plane].get(cell + side, 0))
			if neighbour_bits & enemy_bit != 0 and neighbour_bits & own_bit == 0:
				bits = TEAM_BITS
				break
	var before := int(_tunnel_known[plane].get(cell, 0))
	var after := before | bits
	if before == after:
		return
	_tunnel_known[plane][cell] = after
	# The viewing crew just gained a cell it did not have -- a junction an enemy broke into, or a
	# landing a shaft dropped onto ground that was already open. `dig_segment` dirties its own
	# chunks, but neither of those goes through it, and a cell that is on your map and not in your
	# cutaway is a corridor you can route through and cannot see.
	if _view_team >= 0 and _cells[plane].has(cell):
		var eye := 1 << _view_team
		if before & eye == 0 and after & eye != 0:
			for id: int in segments_in_cell(plane, cell):
				_touch(plane, id)
	tunnel_revealed.emit(plane, bits)


func is_dug(plane: int, cell: Vector2i) -> bool:
	return plane >= 0 and plane < PLANE_COUNT and _cells[plane].has(cell)


func cell_count(plane: int) -> int:
	return _cells[plane].size()


## The network as something you can path through (M4). Owned here rather than wired up in the
## scene because there must be exactly one and it must never disagree with the cells -- a routing
## graph you can forget to add to a map is a map whose bots quietly cannot follow you.
func graph() -> TunnelGraph:
	return _graph


## Every cell on a plane with a shaft leading DOWN from it. At plane 0 these are the entrances:
## the only places anyone gets underground, and therefore the only places a route can.
func shaft_cells(plane: int) -> Array:
	return _shafts[clampi(plane, 0, PLANE_COUNT - 1)].keys()


## Every dug cell on a plane, as Vector2i grid coordinates.
##
## For anything that has to draw or walk the whole network rather than ask about one cell: the
## minimap today, AStar3D pathing for bots at M4. Handing back the keys costs one allocation and
## saves the caller a five-thousand-cell scan of the arena to find a few dozen tiles.
func dug_cells(plane: int) -> Array:
	return _cells[clampi(plane, 0, PLANE_COUNT - 1)].keys()


## The part of a plane that belongs on one crew's minimap.
##
## "Known" here means authored by the crew, not merely connected to it. That distinction is the
## M5 rule: an enemy can break into your corridor without donating the rest of their route.
func known_tunnel_cells(plane: int, team: int) -> Array[Vector2i]:
	var found: Array[Vector2i] = []
	if plane <= 0 or plane >= PLANE_COUNT:
		return found
	var bit := 1 << clampi(team, Team.BLUE, Team.RED)
	for cell: Vector2i in _tunnel_known[plane]:
		if int(_tunnel_known[plane][cell]) & bit != 0:
			found.append(cell)
	return found


## The raw mask for one cell, for the one caller that must copy it rather than ask about it.
##
## `is_tunnel_known` answers a question about one crew and is what the game asks. Replication is
## not asking a question -- it is transcribing this end's answer so the other end has the same one
## -- so it wants the bits themselves. Deliberately three narrow accessors rather than one that
## hands out the dictionaries: a caller with the dictionary can write to it.
func tunnel_known_bits(plane: int, cell: Vector2i) -> int:
	if plane < 0 or plane >= PLANE_COUNT:
		return 0
	return int(_tunnel_known[plane].get(cell, 0))


func shaft_known_bits(plane: int, cell: Vector2i) -> int:
	if plane < 0 or plane >= PLANE_COUNT:
		return 0
	return int(_shaft_known[plane].get(cell, 0))


func rock_known_bits(plane: int, cell: Vector2i) -> int:
	if plane < 0 or plane >= PLANE_COUNT:
		return 0
	return int(_known[plane].get(cell, 0))


func is_tunnel_known(plane: int, cell: Vector2i, team: int) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT:
		return false
	return int(_tunnel_known[plane].get(cell, 0)) & (1 << clampi(team, Team.BLUE, Team.RED)) != 0


## Shaft mouths a crew has made or reached. On the lawn these are the only tunnel information
## the minimap draws, so they need the same ownership boundary as floor cells.
func known_shaft_cells(plane: int, team: int) -> Array[Vector2i]:
	var found: Array[Vector2i] = []
	if plane < 0 or plane >= PLANE_COUNT:
		return found
	var bit := 1 << clampi(team, Team.BLUE, Team.RED)
	for cell: Vector2i in _shaft_known[plane]:
		if int(_shaft_known[plane][cell]) & bit != 0:
			found.append(cell)
	return found


## A shaft leading DOWN from this cell, to `plane + 1`.
func has_shaft_down(plane: int, cell: Vector2i) -> bool:
	return plane >= 0 and plane < PLANE_COUNT and _shafts[plane].has(cell)


## A shaft leading UP from this cell -- the same object, seen from underneath.
func has_shaft_up(plane: int, cell: Vector2i) -> bool:
	return has_shaft_down(plane - 1, cell)


## Where E takes you from here, or -1 for nowhere.
##
## At most one shaft can touch a cell (see the no-stacking rule in _shaft_refusal), so this
## never has to choose. That is the whole reason one key can do both jobs.
func shaft_target(plane: int, cell: Vector2i) -> int:
	if has_shaft_down(plane, cell):
		return plane + 1
	if has_shaft_up(plane, cell):
		return plane - 1
	return -1


## Whether this cell is, or could become, walkable floor on `plane`.
func can_stand(plane: int, cell: Vector2i) -> bool:
	return plane > 0 and plane < PLANE_COUNT and in_bounds(cell)


# ------------------------------------------------------------------------- digging


## Cut one stroke of tunnel: a capsule [constant SEG_LENGTH] long and [constant SEG_WIDTH] wide,
## starting at `origin` and running along `angle`.
##
## THE ONE PLACE EARTH OPENS. Returns false if the stroke was already there -- so callers can tell
## a fresh cut from a no-op without re-querying -- and also if it was refused outright.
##
## ROCK IS CHECKED ALONG THE WHOLE STROKE, not at a single point, which is the one rule that had
## to grow a dimension. A metre of tunnel at a free angle can clip the corner of a seam without
## either of its ends being inside it, and a stroke that quietly cut through stone would make the
## seam a suggestion. Refused whole for now; stopping short at the stone is stage 3's job, and is
## the better answer.
func dig_segment(plane: int, origin: Vector2, angle: int, team: int = -1) -> bool:
	if _puppet:
		return false
	if plane <= 0 or plane >= PLANE_COUNT:
		return false
	var id := segment_id(origin, angle)
	if _segments[plane].has(id):
		return false

	# BOUNDS ARE GEOMETRY, ASKED IN METRES. Asked as cells it was wrong in both directions: cell
	# `world_to_cell(37.5)` rounds to 38, so testing the endpoints' cells made the outermost legal
	# ring undiggable and a boundary shaft landed in solid earth -- and testing every touched cell
	# did the same thing for the same reason. The diggable ground really is a square of side
	# `half_extent_cells + 0.5` metres, because cell 37 owns out to 37.5, so that is what to say.
	var limit := float(half_extent_cells) * CELL + CELL * 0.5
	var far := segment_end(id)
	if maxf(absf(origin.x), absf(origin.y)) > limit:
		return false
	if maxf(absf(far.x), absf(far.y)) > limit:
		return false

	# ROCK IS ASKED OF THE CELLS THE STROKE WOULD MAKE WALKABLE, which is the meaningful question:
	# you cannot turn stone into floor. Asked of anything looser it refused the corridor you are
	# MEANT to be able to run alongside a seam, because a stroke's rounded end reaches into the
	# neighbouring square without making any of it walkable.
	#
	# Said out loud, because ground that refuses to open with no explanation is indistinguishable
	# from a dig control that has stopped working -- the exact lesson the entrance key taught this
	# file once already.
	var cells := _segment_cells(id)
	for cell: Vector2i in cells:
		if _rock[plane].has(cell):
			dig_refused.emit("solid rock -- go round it, or go under it")
			return false

	# A stroke that would take no earth out is a no-op, and saying so here rather than only in the
	# controller is what keeps `dig`'s old contract -- "false if it was already dug" -- true for
	# bots and for every audit scenario that builds a network by naming cells twice.
	#
	# AFTER THE STONE, AND THAT ORDER IS LOAD-BEARING. `opens_ground` counts rock as nothing to be
	# gained, quite correctly -- so asked first it swallows a dig aimed squarely at a seam and
	# returns a silent false, and the player holds the button on rock and is told nothing. Which is
	# the exact failure the seam's spoken refusal exists to prevent, reintroduced by a reordering.
	if not opens_ground(plane, origin, angle):
		return false

	_segments[plane][id] = true
	# Whatever was part-cut here is now cut in full, and leaving the carve behind would keep a
	# duplicate of the same capsule in the field for every chunk to union in for nothing.
	_drop_carve(plane, id)
	for cell: Vector2i in _occupy(plane, id):
		_learn_tunnel_cell(plane, cell, team)
	_rebuild_walls(plane)
	# A corridor lights itself as it is cut. This used to wait for the next focus change, which
	# meant digging away from your last lamp ran out of light and stayed dark until you climbed a
	# shaft and came back down -- survivable while every cell was lit anyway, and not survivable
	# now that a lit cell is what tells your own network apart from theirs.
	_relight(plane)
	for cell: Vector2i in cells:
		if _cells[plane].has(cell):
			cell_opened.emit(plane, cell)
	segment_opened.emit(plane, id)
	return true


## Cut part of a stroke: the earth comes out as the digger works along it, rather than a metre at a
## time when they finish.
##
## THE UNIT OF DIGGING IS UNCHANGED, AND THAT IS THE POINT OF DOING IT THIS WAY. A carve claims no
## cells, joins no graph, teaches no crew anything and never crosses the wire. Everything the game
## is balanced on -- what a stroke costs, what it opens, who learns about it, what a bot counts --
## still happens exactly once, in [method dig_segment], when the stroke is finished. What changes is
## only what the earth LOOKS and FEELS like on the way there, which is the whole of the complaint:
## a corridor that arrives a metre at a time reads as tiles popping, and one that arrives
## continuously reads as digging.
##
## SO A CARVE IS PURE GEOMETRY. It goes into the field, so it is contoured, collided and cut out of
## the lid like anything else -- you can walk into the part you have cut -- and it goes into
## [method _is_earth], so the dig rule cannot offer you ground you have already taken out. Nothing
## else in the file knows carves exist.
##
## `[REVISED]` AND IT ONLY EVER GROWS. Earth that has come out stays out: there is no shrinking, no
## abandoning and no un-digging, which is what makes this continuous rather than a half-second bet
## you can lose by breathing on the mouse. Two bugs came out of the old rule together and both were
## the same bug -- a released button filled the trench back in, and a player standing in that trench
## when it filled was pushed into solid ground with no floor under it and fell out of the world.
##
## RESUMED BY ASKING [method carved_along], which is the other half. Progress belongs to the STROKE
## now, not to the hold, so looking away and back picks the same stroke up where it was left rather
## than starting it again.
##
## QUANTISED TO A TEXEL, WHICH IS WHAT MAKES IT AFFORDABLE. The field cannot represent anything
## finer than 12.5cm, so advancing by less than that is a chunk rebuild for a picture nobody can
## tell from the last one. At a stroke every half second that is sixteen rebuilds a second instead
## of one per frame, and each is confined to the chunks around the few centimetres just cut.
##
## NOT REFUSED ON A PUPPET, unlike every other way of moving earth. A carve only ever takes out
## ground the server is about to take out anyway, it can never run more than one stroke ahead, and
## it is dropped the moment that stroke resolves -- so a client predicting its own digging cannot
## drift, and without it the one machine whose feel this was written for is the one that does not
## get it.
## SEEN BY THE CREW CUTTING IT AND BY NOBODY ELSE, which is why the team comes in. Visibility for a
## committed stroke is a question about CELLS -- has your crew learnt this square (see
## [method _segment_wants]) -- and asking it of a carve gets the answer exactly backwards: a stroke
## being cut into fresh ground is by definition in a cell nobody has learnt yet, so the lid over it
## stays shut, and the digger cannot see the trench they are standing in cutting. Whose carve it is
## settles it instead, and settles the other half too: an enemy's carve stays dark until it becomes
## a stroke and comes under the ordinary fog, rather than leaking a metre of their corridor in real
## time.
func carve(plane: int, id: int, along: float, team: int = -1) -> void:
	if plane <= 0 or plane >= PLANE_COUNT:
		return
	if _segments[plane].has(id):
		return
	var stop := floorf(clampf(along, 0.0, SEG_LENGTH) / TunnelContour.TEXEL) * TunnelContour.TEXEL
	var before := carved_along(plane, id)
	if stop <= before:
		return
	_carving[plane][id] = {"along": stop, "team": team}
	# ONLY THE STRETCH JUST CUT, which is the difference between carving being affordable and not.
	# The field behind the tip has not moved, so re-contouring the whole stroke is eight rebuilds of
	# the same picture -- and unlike a commit, this is paid several times a second. The cull's reach
	# is declined for the same reason (see [method _touch_span]): a scrap a metre away can wait for
	# the commit, which always reaches out in full.
	_touch_span(plane, _carve_end(id, before), _carve_end(id, stop), false)
	# COLLISION FOLLOWS THE TRENCH NOW, AT A QUARTER OF A METRE. It used to wait for the commit, on
	# the argument that the only mouse who could walk into a carve was the one standing still cutting
	# it -- which stopped being true the moment carving became digging rather than a preview of it.
	# You are meant to walk forward into what you are cutting, and ground you can see through and
	# cannot enter is the same complaint as ground that does not open. Throttled rather than every
	# step because a concave shape rebuilds its whole tree whenever it is set (see
	# [method _rebuild_walls]), so this is four physics rebuilds per stroke rather than eight.
	var collide := floori(stop / CARVE_COLLIDE_STEP) > floori(before / CARVE_COLLIDE_STEP)
	_rebuild_walls(plane, collide)


## How far along a stroke has already been cut, or zero. What lets a dig be picked up where it was
## put down; see [method carve].
func carved_along(plane: int, id: int) -> float:
	if plane <= 0 or plane >= PLANE_COUNT:
		return 0.0
	var carve: Variant = _carving[plane].get(id)
	return 0.0 if carve == null else (carve as Dictionary)["along"] as float


## Every part-cut stroke on a plane, as `{"along": float, "team": int}` keyed by stroke id.
func carving(plane: int) -> Dictionary:
	if plane < 0 or plane >= PLANE_COUNT:
		return {}
	return _carving[plane]


## Where a stroke has been cut to, in world terms.
static func _carve_end(id: int, along: float) -> Vector2:
	return segment_origin(id) + angle_direction(segment_angle(id)) * along


## Forget the part-cut record of a stroke, because the stroke itself now exists. The geometry does
## not change -- a finished stroke covers everything its carve did -- so nothing has to be touched.
func _drop_carve(plane: int, id: int) -> void:
	_carving[plane].erase(id)


## Forget part-cut strokes that floor a cell being brought down, so a cave-in does not leave a stub
## of open trench behind in ground it has just closed.
func _drop_carves_in(plane: int, cell: Vector2i) -> void:
	for id: int in _carving[plane].keys():
		var along := carved_along(plane, id)
		if _probe_cell(cell, segment_origin(id), _carve_end(id, along))[1] > -STANDING_CLEARANCE:
			continue
		_carving[plane].erase(id)
		_touch_span(plane, segment_origin(id), _carve_end(id, along))


## Cut a stroke centred on a cell, pointing along whichever axis joins it to tunnel it already
## touches. The cell-shaped door into [method dig_segment].
##
## KEPT SO THE CELL-SPEAKING CALLERS SURVIVE THE CHANGE OF UNIT. Bots choose a neighbouring cell
## to dig (see [BotDigger]), and every audit scenario in the project builds its network by naming
## cells; rewriting all of them in the same commit as the geometry would mean a failure could be
## in either, with nothing trustworthy left to bisect against. They move to angles in stage 2.
##
## THE ANGLE IS INFERRED FROM WHAT IS ALREADY THERE, which is what makes a run of these come out
## as a straight corridor rather than a string of discs: a stroke laid from the dug neighbour
## through the new cell overlaps the one before it exactly as a chained stroke would.
func dig(plane: int, cell: Vector2i, team: int = -1) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT:
		return false
	var heading := Vector2(1.0, 0.0)
	for side: Vector2i in SIDES:
		if _cells[plane].has(cell + side):
			heading = Vector2(float(-side.x), float(-side.y))
			break
	var centre := Vector2(float(cell.x) * CELL, float(cell.y) * CELL)
	return dig_segment(plane, centre - heading * (SEG_LENGTH * 0.5), direction_angle(heading), team)


## Bring a cell down: the floor closes, the walls seal around it, and it is earth again.
##
## THE ONLY THING THAT SHRINKS THE NETWORK, which is why it gets its own signal and its own set
## of refusals. Everything else here only ever adds, and a good deal of the code below quietly
## assumes that -- the mask, the graph, the lamps and the wall mesh are all caches over `_cells`,
## and all four are rebuilt from it here rather than patched.
##
## `[REVISED]` A SHAFT CELL IS NO LONGER REFUSED -- IT TAKES THE SHAFT WITH IT. A shaft is a hole
## in one plane's floor and in the ceiling of the one below, recorded once, and the old answer here
## was simply "no": collapsing one end would leave the other starting or finishing in solid earth,
## which the audit's SHAFT_ENDS invariant catches and which in play is a mouse pressing E and
## arriving inside the ground. That reasoning was about the GEOMETRY and it is still right; what was
## wrong was concluding from it that the shaft has to survive. The other way out is to take both
## ends at once, and that is what [method collapse_shaft] does.
##
## THE DESIGN THIS BUYS is the reason it moved. Un-digging is the Brute's whole (see [CaveIn]), and
## a denial ability that cannot touch the one piece of the network the enemy crew actually depends
## on is denial with the teeth filed off -- a Brute could seal ten metres of corridor and the route
## would simply go round it. An entrance is the thing worth destroying. The old header's objection
## ("it would let one Engineer erase an entrance the whole crew relies on") was answered by the
## ability changing hands: erasing an entrance is exactly what the Brute is for, and it costs a walk
## to the spot and a ten-second cooldown to do it.
##
## SO THIS TAKES ONE CELL OR TWO, and the caller does not get to choose which. Ask
## [method collapse_footprint] first if you need to know -- the Brute does, because everything
## standing in what comes down gets buried.
##
## STRANDING IS ALLOWED, and is the point. Sealing a corridor can cut off everything past it, and
## the REACHABLE invariant deliberately is not asserted against live play -- a pocket of tunnel
## nobody can get to is exactly what a cave-in is for. Anyone caught in the cell is scruffed
## (GDD section 3); anyone caught BEYOND it can dig their way out, slowly, or take the six
## seconds. Both are consequences worth having.
func collapse(plane: int, cell: Vector2i) -> bool:
	if _puppet:
		return false
	if plane <= 0 or plane >= PLANE_COUNT or not _cells[plane].has(cell):
		return false
	# THE TIMBERS FIRST, AND ABOVE THE SHAFT REDIRECT. A shored cell answers false -- nothing came
	# down -- and the shoring is spent doing it, which is the whole of the Engineer's answer to the
	# Brute: the corridor survives, and the next cooldown takes it. Above the redirect because a
	# shored shaft cell should hold as a shaft cell does not, and asking on the far side of it would
	# let a shored mouth be filled in while the timbers stood there untouched.
	if _shored[plane].has(cell):
		break_shoring(plane, cell)
		return false
	# Either end of a shaft is the same object asked from two sides, and both answers are the same
	# operation on the plane the shaft is RECORDED at -- the upper of the two it joins.
	if _shafts[plane].has(cell):
		return collapse_shaft(plane, cell)
	if has_shaft_up(plane, cell):
		return collapse_shaft(plane - 1, cell)

	_take_cell(plane, cell)
	_rebuild_walls(plane)
	_relight(plane)
	tunnel_revealed.emit(plane, TEAM_BITS)
	return true


## Fill a shaft in: the mouth, the landing, and the hole between them.
##
## `plane` IS THE UPPER OF THE TWO IT JOINS, which is where a shaft is recorded (see `_shafts`).
## Callers holding the lower end should ask with `plane - 1`; `collapse` does that for them.
##
## BOTH ENDS GO, ALWAYS. Half a shaft is not a state this network has a way to draw or a mouse has
## a way to survive, so there is no flag here for taking only one -- the two `_take_cell` calls are
## a single act. At plane 0 the upper end is the lawn, which has no cell to erase: the mouth is a
## mark on ground that was never dug, so closing it is one grid tile going back to nothing.
##
## THE LANDING IS TAKEN EVEN THOUGH IT IS ORDINARY CORRIDOR, and that is the part worth being sure
## about rather than the mouth. Leaving it would put a sealed ceiling over a room somebody is
## standing in -- fine geometrically, and wrong for the ability, which is called a cave-in because
## the roof arrives. It is also what makes the Brute's stomp read correctly from the lawn: you put a
## foot through an entrance and the earth under it comes down with it.
func collapse_shaft(plane: int, cell: Vector2i) -> bool:
	if _puppet:
		return false
	if plane < 0 or plane + 1 >= PLANE_COUNT or not _shafts[plane].has(cell):
		return false

	# EITHER END HOLDS THE WHOLE LADDER, and both sets of timbers are spent doing it. A shaft comes
	# down as one act (see the header), so it cannot half-survive: shoring the landing has to save
	# the mouth as well, or an Engineer would be paying three seconds for a cell that gets taken
	# anyway by an aim one tile off. What that costs is both ends' worth of work for one cooldown,
	# which is the honest price of a rule that says a shaft is a single object.
	var held := break_shoring(plane, cell)
	held = break_shoring(plane + 1, cell) or held
	if held:
		return false

	_shafts[plane].erase(cell)
	_shaft_known[plane].erase(cell)

	if plane == 0:
		# No cell to erase up here -- the lawn is not dug, it is walked on. What goes is the
		# ENTRANCE mark and the point the routing graph hangs on it, which is the only reason a
		# bot believes it can cross between navmesh and network at this spot.
		_refresh_cell(0, cell)
		cell_collapsed.emit(0, cell)
	elif _cells[plane].has(cell):
		_take_cell(plane, cell)
		_rebuild_walls(plane)
	if _cells[plane + 1].has(cell):
		_take_cell(plane + 1, cell)
		_rebuild_walls(plane + 1)

	# Both, and unconditionally: the shaft was the light source for the pair of them, so the plane
	# that kept its floor still has a lamp to lose.
	_relight(plane)
	_relight(plane + 1)
	shaft_closed.emit(plane, cell)
	tunnel_revealed.emit(plane, TEAM_BITS)
	tunnel_revealed.emit(plane + 1, TEAM_BITS)
	return true


## Every cell a collapse aimed at `cell` would actually take, upper end first.
##
## PURE, AND ASKED BEFORE IT IS ACTED ON, for the same reason `stomp_cells` is: the Brute has to
## bury everyone standing in what comes down, and after the fact there is nothing left to ask.
## Empty means the collapse would be refused.
##
## TWO ENTRIES WHEN THE TARGET IS EITHER END OF A SHAFT, and one of that pair may be plane 0 -- a
## mouth on the lawn rather than a corridor cell. It is returned because it IS part of what came
## down and a caller counting ground taken should count it. **A caller crushing mice must not.**
## Mice on the surface are plane 0, and the Brute filling in the entrance it is standing on is the
## first one in the queue; see [method CaveIn._bury], which is where that is handled.
func collapse_footprint(plane: int, cell: Vector2i) -> Array:
	if not can_collapse(plane, cell):
		return []
	if _shafts[plane].has(cell):
		if is_shored(plane, cell) or is_shored(plane + 1, cell):
			return []
		return [[plane, cell], [plane + 1, cell]]
	if has_shaft_up(plane, cell):
		if is_shored(plane, cell) or is_shored(plane - 1, cell):
			return []
		return [[plane - 1, cell], [plane, cell]]
	# EMPTY BECAUSE NOTHING COMES DOWN, and this is the line that keeps a shored cell from burying
	# the mouse standing in it. `collapse` refuses a shored cell and spends the timbers instead, so
	# a footprint that still named this cell would have the Brute crushing somebody in a corridor
	# that is visibly still there -- the worst kind of disagreement, because the geometry is right
	# and only the casualty is wrong. Asked and answered in the same place as the refusal.
	if is_shored(plane, cell):
		return []
	return [[plane, cell]]


## The cell erased and everything cached over it told. Shared by the plain collapse and by the
## shaft one, which does this twice -- deliberately WITHOUT the wall rebuild and the relight, since
## those are per-plane and doing them per-cell would rebuild the same mesh twice for one shaft.
## `[REVISED]` A CELL IS TAKEN BY TAKING THE STROKES THROUGH IT, which is the one place the change
## of unit is visible from outside this file. A cell is no longer a thing that can be removed on
## its own -- it is the shadow of the segments crossing it -- so bringing one down means bringing
## those down, and a stroke a metre long generally shades two or three cells. A cave-in therefore
## takes a slightly wider bite than it used to.
##
## THAT IS THE HONEST BEHAVIOUR RATHER THAN A COMPROMISE, and it is worth being clear which. The
## alternative -- clipping segments so exactly one cell's worth disappears -- would leave strokes
## of a length nothing else in the system believes in, and the first thing to break would be the
## wire, where a segment's identity IS its origin and angle. Stage 2 gives collapse a segment to
## aim at, at which point the Brute is aiming at the thing that actually comes down.
func _take_cell(plane: int, cell: Vector2i) -> void:
	# THE STROKES THAT FLOOR THIS CELL, not every stroke the spatial index lists near it. Those are
	# two different sets -- `_cell_segments` is deliberately generous so that chunks and the cursor
	# find everything nearby -- and taking the generous one meant a cave-in aimed at one cell
	# brought down its neighbours either side as well.
	for id: int in _segments_standing_in(plane, cell):
		_drop_segment(plane, id)
	# And whatever was only part-cut here, for the same reason: a cave-in that left the trench
	# somebody had started would close the cell on the books and leave a slot of open ground and
	# open floor standing in it.
	_drop_carves_in(plane, cell)
	# Belt and braces: `collapse` refuses a shored cell before it ever reaches here, so this only
	# fires for a cell taken as the far end of something else -- a shaft's landing, say. Timbers
	# recorded against earth that no longer exists would be timbers an Engineer could never spend
	# and a Brute could never break, and the cell might be dug again later.
	_shored[plane].erase(cell)
	# Unconditionally, even if some other stroke still shades this cell. The caller asked for this
	# cell to stop being anybody's, and `_vacate` has already told everything cached over it about
	# whichever cells actually emptied.
	if _cells[plane].has(cell):
		return
	_tunnel_known[plane].erase(cell)
	cell_collapsed.emit(plane, cell)


## One stroke out of the world, and everything derived from it told.
func _drop_segment(plane: int, id: int) -> void:
	if not _segments[plane].has(id):
		return
	_segments[plane].erase(id)
	for emptied: Vector2i in _vacate(plane, id):
		_tunnel_known[plane].erase(emptied)
		_shored[plane].erase(emptied)
		cell_collapsed.emit(plane, emptied)
	segment_closed.emit(plane, id)


# ------------------------------------------------------------------- what the wire is allowed to say


## Stop deciding. Called on a client, where every cell of earth is cut somewhere else.
##
## THE PLAYABLE CONSEQUENCE, said plainly: a client's network contains only the cells its own crew
## has cut or can currently see. That is not a reduced copy of the host's world, it *is* M5's
## pillar expressed as geometry -- and it works visually for a reason that is not luck.
## `tunnel_sight.gd` defines line of sight as "every cell between here and there is open", so the
## set of cells a crew can see is very nearly the set it could have drawn anyway. What is missing
## was behind a bend or behind earth.
func set_puppet(on: bool) -> void:
	_puppet = on


## A stroke that exists somewhere else, with the knowledge bits it was sent with.
##
## `[REVISED]` A SEGMENT RATHER THAN A CELL, and this is the entry that forced the wire to change
## shape. A client told only which cells are dug cannot draw the tunnel: the same set of cells is
## produced by strokes at a dozen different angles, so the two machines would agree on where the
## corridor is and disagree about what it looks like -- and the client's collision mesh, built
## from its own geometry, would disagree with the server about where you can walk.
##
## The bits are taken rather than derived. `_learn_tunnel_cell` has junction rules -- breaking into
## an enemy corridor makes the new cell shared -- and re-running them here against a partial copy
## of the world would reach a different answer from the server's for the same cell. There is one
## place that decides who knows what, and it is not this end.
func adopt_segment(plane: int, origin: Vector2, angle: int, bits: int) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT:
		return false
	var id := segment_id(origin, angle)
	var fresh := not _segments[plane].has(id)
	if fresh:
		_segments[plane][id] = true
		# The prediction this client cut for itself has arrived as the real thing. Same reasoning as
		# [method dig_segment]: the stroke covers everything its carve did, so the record goes and
		# the picture does not change.
		_drop_carve(plane, id)
		_occupy(plane, id)
		_rebuild_walls(plane)
		_relight(plane)
	for cell: Vector2i in _segment_cells(id):
		if not _cells[plane].has(cell):
			continue
		if int(_tunnel_known[plane].get(cell, 0)) != bits:
			_tunnel_known[plane][cell] = bits
			tunnel_revealed.emit(plane, bits)
		if fresh:
			cell_opened.emit(plane, cell)
	if fresh:
		segment_opened.emit(plane, id)
	return fresh


func adopt_shaft(plane: int, cell: Vector2i, bits: int) -> bool:
	if plane < 0 or plane + 1 >= PLANE_COUNT:
		return false
	var fresh := not _shafts[plane].has(cell)
	_shafts[plane][cell] = true
	_shaft_known[plane][cell] = bits
	if fresh:
		_refresh_cell(plane, cell)
		_refresh_cell(plane + 1, cell)
		_relight(plane)
		_relight(plane + 1)
		shaft_opened.emit(plane, cell)
	return fresh


## Which crews have found a seam. The rock ITSELF is not sent and never needs to be: it is laid
## from `rock_seed` at startup, so both ends generate the identical stone without a byte crossing
## the wire. Only who has run into it is knowledge, and only knowledge is per-crew.
func adopt_rock(plane: int, cell: Vector2i, bits: int) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT or not _rock[plane].has(cell):
		return false
	if int(_known[plane].get(cell, 0)) == bits:
		return false
	_known[plane][cell] = bits
	_announce_rock(plane, bits)
	return true


## Timbers the server says are there. The client end of [method shore].
##
## THE WIRE, NOT A CALLER, which is why there is no `_puppet` guard and no check that the ability
## was legal: it already happened on the machine that was allowed to decide it. What this DOES
## still insist on is that the cell exists locally, because a client is only told about earth its
## crew has earned -- shoring on a corridor this client has never heard of is a fact about a place
## it does not have, and recording it would leave an entry no `forget_shoring` ever names.
func adopt_shoring(plane: int, cell: Vector2i) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT or not _cells[plane].has(cell):
		return false
	if _shored[plane].has(cell):
		return false
	_shored[plane][cell] = true
	cell_shored.emit(plane, cell)
	return true


## Timbers the server says are gone -- broken by a collapse, or aged out of this crew's fog with
## the cell they were in. The same signal either way, for the same reason [method forget_cell]
## reuses `cell_collapsed`: a client's map is its world, and the prop has to come down regardless
## of which of the two happened.
func forget_shoring(plane: int, cell: Vector2i) -> bool:
	if plane < 0 or plane >= PLANE_COUNT or not _shored[plane].has(cell):
		return false
	_shored[plane].erase(cell)
	shoring_broke.emit(plane, cell)
	return true


## A cell this crew is no longer allowed to know: a glimpse that has aged out of the fog.
##
## THE SAME MACHINERY AS A COLLAPSE AND DELIBERATELY THE SAME SIGNAL, because on a client "gone
## from my map" and "gone from the world" are the same event -- a client's map *is* its world, and
## every cache over `_cells` has to hear about it either way.
##
## It is a rule on a host and a fact on a client, which is why it is here rather than in
## `collapse`: collapsing refuses on a shaft cell, and forgetting a shaft you glimpsed has to
## work.
func forget_segment(plane: int, origin: Vector2, angle: int) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT:
		return false
	var id := segment_id(origin, angle)
	if not _segments[plane].has(id):
		return false
	# Whatever cells this leaves empty take their shoring and their shaft record with them. Done
	# through the same `_drop_segment` a collapse uses, so there is one description of what it
	# means for a stroke to stop existing rather than a host's and a client's.
	for cell: Vector2i in _segment_cells(id):
		if _shafts[plane].has(cell):
			_shafts[plane].erase(cell)
			_shaft_known[plane].erase(cell)
		forget_shoring(plane, cell)
	_drop_segment(plane, id)
	_rebuild_walls(plane)
	_relight(plane)
	return true


## A shaft this crew is no longer allowed to know about, or that no longer exists.
##
## THE CLIENT HALF OF [method collapse_shaft], and separate from `forget_cell` for the same reason
## that one is separate from `collapse`: a shaft is recorded at the UPPER of the two planes it
## joins, so forgetting the landing cell -- which is what the host's FORGET entries name -- never
## reaches the record. Both ends arrive as their own entries and each does its own half.
##
## Nothing here decides anything. A shaft leaves a client's world when the server says so, and the
## two reasons it might (somebody filled it in, or this crew stopped being allowed to see it) are
## the same fact from here.
func forget_shaft(plane: int, cell: Vector2i) -> bool:
	if plane < 0 or plane + 1 >= PLANE_COUNT or not _shafts[plane].has(cell):
		return false
	_shafts[plane].erase(cell)
	_shaft_known[plane].erase(cell)
	if plane == 0:
		_refresh_cell(0, cell)
		cell_collapsed.emit(0, cell)
	else:
		_refresh_cell(plane, cell)
	_refresh_cell(plane + 1, cell)
	_relight(plane)
	_relight(plane + 1)
	shaft_closed.emit(plane, cell)
	return true


## Whether this cell could be brought down, without doing it. For a UI that has to say so before
## the player commits, and for the ability's own reach test.
##
## `[REVISED]` A SHAFT CELL PASSES NOW. This used to carry the shaft exclusion as a second clause
## and it was the reason the Brute's stomp quietly skipped every ladder inside its patch -- the
## patch was filtered through here. Whether the collapse takes one cell or two is
## [method collapse_footprint]'s question, not this one's.
func can_collapse(plane: int, cell: Vector2i) -> bool:
	return plane > 0 and plane < PLANE_COUNT and _cells[plane].has(cell)


## ASKING BEFORE ACTING, for anything that would rather try somewhere else than be told no.
##
## `dig` and the two shaft calls all announce their refusal on `dig_refused`, which is right: that
## signal is how a player finds out the controls are not broken, and swallowing it once cost a
## whole session to the entrance key looking dead. It is exactly wrong for a BOT. An AI reconsiders
## its route three times a second, and every rock face it probes would shout "solid rock -- go
## round it" across the human's HUD, in the middle of a match the human is playing. So the tests
## are available without the voice, and the rule stays in one place rather than being reimplemented
## by the caller doing the swallowing -- which is how the two would drift apart.
func can_dig(plane: int, cell: Vector2i) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT or _cells[plane].has(cell):
		return false
	return in_bounds(cell) and not _rock[plane].has(cell)


func can_shaft_down(plane: int, cell: Vector2i) -> bool:
	return _shaft_refusal(plane, cell) == ""


## Mirrors `dig_shaft_up`'s own guards, in its order. A shaft up is a shaft down cut from below, so
## the bulk of the answer is the same question asked one plane higher -- with the one difference
## that `dig_shaft_up` OPENS its landing on the way through, so a ceiling that is still solid earth
## is not a refusal there and must not be one here.
func can_shaft_up(plane: int, cell: Vector2i) -> bool:
	if plane <= 0 or is_rock(plane - 1, cell):
		return false
	if plane == 1 and is_sealed(cell):
		return false
	return _shaft_refusal(plane - 1, cell, true) == ""


## Sink a shaft from `plane` down to `plane + 1`, at the cell the player is standing on.
func dig_shaft_down(plane: int, cell: Vector2i, team: int = -1) -> bool:
	if _puppet:
		return false
	var refusal := _shaft_refusal(plane, cell)
	if refusal != "":
		dig_refused.emit(refusal)
		return false

	# Open the landing before recording the shaft, so the cell below exists to arrive in. A
	# shaft you drop through onto solid earth is worse than no shaft.
	dig(plane + 1, cell, team)
	# The landing may already be an enemy corridor. Taking a shaft into it reveals the landing
	# cell, not the connected route beyond it.
	_learn_tunnel_cell(plane + 1, cell, team)
	if plane > 0:
		_learn_tunnel_cell(plane, cell, team)
	_shafts[plane][cell] = true
	var bits := _team_bits(team)
	_shaft_known[plane][cell] = int(_shaft_known[plane].get(cell, 0)) | bits
	_refresh_cell(plane, cell)
	_refresh_cell(plane + 1, cell)
	# Both ends of the new shaft change what their plane's lights should look like, and neither
	# gets rebuilt on its own: _rebuild_walls only relights when a FLOOR cell changes, and
	# breaking upward changes no floor on the plane you are standing on. So the beam -- the only
	# thing that says a shaft goes up from here -- did not appear until something else forced a
	# rebuild, which in practice meant climbing up and back down to trip set_focus_plane.
	_relight(plane)
	_relight(plane + 1)
	shaft_opened.emit(plane, cell)
	tunnel_revealed.emit(plane, bits)
	return true


## Sink a shaft from `plane - 1` down to `plane`, authored from below -- the same object as
## dig_shaft_down, just dug by someone standing underneath it.
func dig_shaft_up(plane: int, cell: Vector2i, team: int = -1) -> bool:
	if _puppet:
		return false
	if plane <= 0:
		dig_refused.emit("nothing above to break into")
		return false
	# Rock overhead gets its own refusal. Left to the `dig` below it would come back as "no floor
	# to sink a shaft from", which is true and useless -- the player would go looking for somewhere
	# to stand rather than somewhere the ceiling is soft.
	if is_rock(plane - 1, cell):
		dig_refused.emit("rock overhead -- nothing to break into")
		return false
	# Paving overhead (GDD section 3) gets its own voice for the same reason rock does, and for a
	# sharper one: this refusal is the mechanic. Coming up under a patio has to say "not HERE,
	# keep going" -- a player who reads it as "the key is broken" learns nothing about the map,
	# and the whole value of a no-surface zone is that you know where the enemy has to appear.
	if plane == 1 and is_sealed(cell):
		dig_refused.emit("paving overhead -- keep going until you're clear of it")
		return false
	# The cell above has to be floor to arrive on, unless it is the surface, which is
	# everywhere. Opened first so the shaft below has somewhere to land.
	dig(plane - 1, cell, team)
	return dig_shaft_down(plane - 1, cell, team)


## Why a shaft can't be sunk here, or "" if it can.
##
## `floor_may_be_cut` is for the view from below. `dig_shaft_up` opens its own landing before it
## records anything, so asked on ITS behalf a ceiling of plain earth is not an obstacle -- only a
## ceiling that could never be opened is. Everything else about the two directions is identical,
## which is why they share this rather than each keeping a list.
func _shaft_refusal(plane: int, cell: Vector2i, floor_may_be_cut: bool = false) -> String:
	if plane < 0 or plane + 1 >= PLANE_COUNT:
		return "nothing below to break into"
	if not in_bounds(cell):
		return "outside the arena"
	# NO-SURFACE ZONES (GDD section 3), and plane 0 is the only place the rule can bite: a shaft
	# recorded at plane 0 is a mouth on the lawn, whichever end it was cut from. Everything deeper
	# passes straight through here, because tunnelling under a patio -- along it, and further down
	# beneath it -- is exactly what the rule leaves you.
	if plane == 0 and is_sealed(cell):
		return "paved over -- there's no digging through the patio"
	# Plane 0 is the surface: standing anywhere on it is standing on solid ground, so an
	# entrance needs no floor cut first. Below that you have to be in a tunnel.
	if plane > 0 and not _cells[plane].has(cell):
		if not floor_may_be_cut or not can_dig(plane, cell):
			return "no floor to sink a shaft from"
	if _shafts[plane].has(cell):
		return "a shaft is already here"
	# A shaft is only worth sinking if there is somewhere to arrive. Checked HERE rather than being
	# left to the `dig` below, because that call opens the landing before the shaft is recorded --
	# so rock underneath would give you a shaft into solid ground and trip the audit's SHAFT_ENDS
	# rather than a refusal you can act on.
	if _rock[plane + 1].has(cell):
		return "rock below -- nothing to sink into"

	# THE NO-STACKING RULE. A cell with a shaft above it and a shaft below it would give E
	# two destinations and no way to choose between them without a second key. Forbidding it
	# also stops a well being drilled straight from the lawn to the deepest plane, which is
	# what keeps depth a horizontal investment rather than something you buy on the spot --
	# the spirit of GDD section 3's "you can't dig straight down", by a different mechanism.
	if has_shaft_up(plane, cell):
		return "a shaft already comes up here"
	if plane + 1 < PLANE_COUNT and _shafts[plane + 1].has(cell):
		return "a shaft already goes down from below"
	if _crowded(plane, cell):
		return "too close to another shaft"
	return ""


## Is there already a shaft within the exclusion radius of `cell`? See shaft_exclusion_cells.
##
## THREE LAYERS, because a shaft is a hole in two planes at once: recorded at `plane`, it is a
## hole in that plane's floor and a hole in the ceiling of the one below. So the new shaft is
## next to something if any of layers plane-1, plane or plane+1 has one nearby -- checking only
## `plane` would happily put a floor hole beside a ceiling hole, which is two mouths a stride
## apart in the same corridor and exactly what the rule exists to stop.
##
## The centre cell is skipped: it is refused already, by messages that say which of the three
## ways it collides rather than the vague one this returns.
func _crowded(plane: int, cell: Vector2i) -> bool:
	var reach := shaft_exclusion_cells
	if reach <= 0:
		return false
	for x in range(cell.x - reach, cell.x + reach + 1):
		for y in range(cell.y - reach, cell.y + reach + 1):
			var other := Vector2i(x, y)
			if other == cell:
				continue
			for layer in range(maxi(plane - 1, 0), mini(plane + 2, PLANE_COUNT)):
				if _shafts[layer].has(other):
					return true
	return false


# ------------------------------------------------------------------------- rendering


## Focus a plane: it is lit and open, the one above it is a dim hint, everything else is gone.
##
## Nothing here touches alpha. Layers are separated by whether they are DRAWN AT ALL and by
## how brightly, which is why the transparent-pass problems that dogged M2 -- flickering rims,
## the ground slab painting over the rock scatter -- simply cannot happen now.
func set_focus_plane(plane: int) -> void:
	_focus = clampi(plane, 0, PLANE_COUNT - 1)
	for index in range(PLANE_COUNT):
		# ONE LAYER, and nothing else. The layer above used to be drawn as a dim inlay of its
		# floors, on the theory that seeing where you'd come from helped orient you. In a
		# corridor it did the opposite: its tunnels are laid over the lid you are trying to
		# look through, so they read as marks on your own floor and obscure the layer you are
		# actually in. What you want to see is your tunnel. Where the layer above joins yours
		# is announced by the light falling down the shaft, which needs no floor plan.
		var focused := index == _focus
		_floors[index].visible = focused
		_marks[index].visible = focused
		_walls[index].visible = focused
		_rock_faces[index].visible = focused
		_rock_caps[index].visible = focused
		_lamp_roots[index].visible = focused
		# Only the lid you are looking down through. The others would each hide the one below.
		if _lids[index] != null:
			_lids[index].visible = focused
	_rebuild_lamps(_focus)


func get_focus_plane() -> int:
	return _focus


## The mark a cell should be showing, or none.
##
## `[REVISED]` ONLY SHAFTS LEAVE A MARK NOW. There used to be a third case here -- plain dug floor
## -- because the floor was a tile and a cell had to be told to show one. The floor is contoured
## out of the dug field now and needs nobody's permission to exist, so this is down to the one
## question it was always really asking: is there a way out of this cell?
func _refresh_cell(plane: int, cell: Vector2i) -> void:
	if plane < 0 or plane >= PLANE_COUNT:
		return
	var wanted := has_shaft_down(plane, cell)
	var existing: Variant = _mark_nodes[plane].get(cell)
	if wanted == (existing != null):
		return
	if not wanted:
		(existing as Node3D).queue_free()
		_mark_nodes[plane].erase(cell)
		return
	var mark := MeshInstance3D.new()
	# The lawn is already the floor up here, so a surface entrance is a scuff laid straight on the
	# turf and needs the larger lift to win the depth fight with it.
	mark.mesh = _entrance_mesh if plane == 0 else _shaft_mesh
	mark.position = Vector3(float(cell.x) * CELL, 0.0, float(cell.y) * CELL)
	mark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_marks[plane].add_child(mark)
	_mark_nodes[plane][cell] = mark


## The earth you look down through to see `plane`, sitting one spacing above its floor.
##
## Planes 2 and 3 get a generated slab. Plane 1's lid is the map's own ground -- grass, props,
## rocks and all -- so the scene owns it and depth_focus.gd hands it the same shader. Plane 0
## has no lid because it IS the top.
func _build_lid(plane: int) -> void:
	if plane < 2:
		_lids.append(null)
		return

	var material := ShaderMaterial.new()
	material.shader = load("res://art/shaders/earth_cutaway.gdshader") as Shader
	material.set_shader_parameter("dug_here", _mask_textures[plane])
	material.set_shader_parameter("dug_above", _mask_textures[plane - 1])
	# The lid stays SOLID over the layer above's tunnels. It only opened there to make room
	# for that layer's floor tiles, and those aren't drawn any more -- cutting anyway would
	# punch holes in your ceiling showing nothing behind them.
	material.set_shader_parameter("cut_above", false)
	material.set_shader_parameter("field_half_metres", float(MASK_HALF_CELLS))
	material.set_shader_parameter(
		"field_texels_per_metre", float(TunnelContour.TEXELS_PER_METRE)
	)
	material.set_shader_parameter("albedo_color", lid_color)
	material.set_shader_parameter("dirt", DirtTexture.shared())
	material.set_shader_parameter("dirt_tile", DirtTexture.WORLD_TILE)

	var quad := PlaneMesh.new()
	quad.size = Vector2.ONE * float(MASK_HALF_CELLS * 2) * CELL

	var lid := MeshInstance3D.new()
	lid.name = "Lid%d" % plane
	lid.mesh = quad
	lid.material_override = material
	# A hair BELOW the floor of the plane above, which sits at exactly this height. The
	# cutaway already discards the lid wherever that floor exists, but coplanar surfaces still
	# fight along the seam a cell boundary leaves, and the result is a stripe crawling down
	# every corridor as the camera moves.
	lid.position = Vector3(0.0, plane_y(plane - 1) - 0.01, 0.0)
	lid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(lid)
	_lids.append(lid)


## The dug mask for a plane, for anything that needs to cut a hole in the earth above it.
func dug_mask(plane: int) -> Texture2D:
	return _mask_textures[clampi(plane, 0, PLANE_COUNT - 1)]


func mask_half_cells() -> int:
	return MASK_HALF_CELLS


## THE CUTAWAY IS A PIECE OF CREW KNOWLEDGE, not a picture of the ground (M5).
##
## This mask is what the lid shader discards against, so a texel set here is a hole in the earth
## you can see a corridor through. Set from `_cells` -- every dug cell, whoever cut it -- it
## handed the entire layer away: standing anywhere in your own plane-1 tunnel, the whole of the
## enemy network was cut out of the earth around you in plain sight, complete, before you had gone
## anywhere near it. The minimap was carefully filtered and the WORLD was not, which is the more
## convincing of the two and quietly cancelled the milestone.
##
## So the mask is the same set the minimap draws: the cells this crew cut, plus the cells it can
## currently make out (tunnel_sight.gd). Enemy earth reads as earth until somebody looks at it, and
## goes back to earth when the sighting is forgotten -- the fog is literally the ground closing
## over again.
##
## `_view_team < 0` means nobody is looking -- a headless audit, an editor preview -- and gets the
## whole layer, which is what those want and cannot leak anything to.
func _mask_wants(plane: int, cell: Vector2i) -> bool:
	if _view_team < 0:
		return _cells[plane].has(cell)
	return is_tunnel_known(plane, cell, _view_team) or _glimpsed[plane].has(cell)


## The same question about a STROKE, which is what the field is actually built out of.
##
## ASKED AT THE STROKE'S MIDPOINT rather than of every cell it touches, and the granularity that
## buys is exactly the granularity the rule already had: a segment is a metre long and a cell is a
## metre across, so this cannot reveal more than a cell's worth of corridor beyond what
## `_mask_wants` would have. Asking of every cell and taking the union would leak instead -- one
## glimpsed cell at the end of a stroke would uncover the whole metre leading up to it.
func _segment_wants(plane: int, id: int) -> bool:
	if _view_team < 0:
		return true
	var middle := segment_origin(id).lerp(segment_end(id), 0.5)
	return _mask_wants(plane, world_to_cell(Vector3(middle.x, 0.0, middle.y)))


## Is the earth over this cell actually open, as the shader will read it?
##
## Asked of the FIELD rather than recomputed from the same inputs, deliberately. The whole failure
## this exists to catch is the drawn world disagreeing with the rule -- a check that recomputed
## `_mask_wants` would agree with itself no matter what the texture said, and the texture is what
## the player sees.
##
## SAMPLED WHERE THE TUNNEL IS IN THIS CELL, not at the middle of the square -- the same
## correction [method standing_point] exists for, and needed here for the same reason. The
## question every caller is really asking is "can this crew see into this cell", and a corridor
## crossing a cell at an angle can leave the exact centre under solid earth while the tunnel
## beside it is plainly open. Asked at the centre, nine cells of a curved corridor reported
## themselves dug and not cut away, which is the shape of a real fog bug and was not one.
##
## A cell with no tunnel in it falls back to its centre, which is the right place to ask about
## ground nobody has dug.
func is_cut_away(plane: int, cell: Vector2i) -> bool:
	if plane < 0 or plane >= _mask_images.size():
		return false
	var at := standing_point(plane, cell)
	var x := roundi(at.x * TunnelContour.TEXELS_PER_METRE) + FIELD_HALF_TEXELS
	var y := roundi(at.z * TunnelContour.TEXELS_PER_METRE) + FIELD_HALF_TEXELS
	if x < 0 or y < 0 or x >= FIELD_TEXELS or y >= FIELD_TEXELS:
		return false
	return _mask_images[plane].get_pixel(x, y).r > TunnelContour.SURFACE


## Redraw a whole plane's cutaway from scratch, for when who is looking -- or what they can see --
## changes rather than what has been dug.
##
## `[REVISED]` DONE BY DIRTYING EVERY OCCUPIED CHUNK rather than by walking cells, because the
## cutaway is no longer a set of texels that can be flipped one at a time -- it is a distance
## field, and the value at a texel depends on every stroke near it. Marking the chunks and letting
## the ordinary rebuild run is the same code path a dig takes, which is the point: there is one
## description of how the field is computed, so a fog change and a dig cannot disagree about it.
func _rebuild_mask(plane: int) -> void:
	if plane < 0 or plane >= _mask_images.size():
		return
	_mask_images[plane].fill(Color(0.0, 0.0, 0.0, 1.0))
	for key: int in _chunk_cache[plane]:
		_dirty_chunks[plane][key] = true
	_rebuild_walls(plane)


## What the viewing crew can currently make out of somebody else's network on this plane. Pushed
## in by tunnel_sight.gd rather than pulled, for the reason `show_crew_knowledge` gives: the
## network must not go hunting through the match for whose eyes it is drawing.
##
## Ignored outright for any crew that is not the one looking, so the caller does not have to know
## which that is -- and at M7, when the answer is per-client, it still will not have to.
func show_glimpsed(team: int, plane: int, cells: Array) -> void:
	if team != _view_team or plane <= 0 or plane >= PLANE_COUNT:
		return
	if cells.size() == _glimpsed[plane].size():
		var same := true
		for cell: Vector2i in cells:
			if not _glimpsed[plane].has(cell):
				same = false
				break
		if same:
			return
	_glimpsed[plane].clear()
	for cell: Vector2i in cells:
		_glimpsed[plane][cell] = true
	# The earth opens up; the LAMPS do not follow. A cell you can see is still a cell nobody on
	# your crew hung a light in, and lighting what you glimpse would give the corridor back the
	# inhabited look the darkness was introduced to take away.
	_rebuild_mask(plane)


## Warm pools along the corridors of the focused layer.
##
## Spaced by DISTANCE FROM THE LAST LAMP, not by a lattice of cells whose coordinates divide
## evenly. A lattice looks reasonable and then lights nothing: a one-cell-wide corridor
## running along z = -5 contains no cell whose z is a multiple of four, so the whole corridor
## came out pitch black while the cells around the origin were fine.
##
## A LAMP IS A THING YOUR CREW HUNG THERE (M5, GDD section 3). Lighting every cell of the layer
## made an enemy corridor a warm, legible, inhabited room -- the exact opposite of what the
## milestone is trying to produce, and it undid the map rule beside it: the minimap could keep the
## floor plan secret all it liked while the world drew the whole route out in lamplight the moment
## you dropped into it.
##
## SO THE DARKNESS IS THE FEATURE, and it is a systems answer rather than a shader one. Nothing is
## hidden, occluded or faded -- the earth is exactly where it was, and there is simply no light in
## it. Your own network reads far ahead because you lit it; theirs is a hole you brought no lamp
## into, which is what GDD section 3 means by crawling blind, and it costs one condition rather
## than a fog volume.
##
## SHAFT DAYLIGHT IS DELIBERATELY LEFT ALONE. A beam falling down a hole is the sun, not a lamp,
## and it does not care who cut it -- so an enemy mouth still announces itself from the dark, which
## is the one piece of information an intruder should get for free. It is also the counterplay: the
## way out of a corridor you cannot read is to head for the light.
func _rebuild_lamps(plane: int) -> void:
	var root := _lamp_roots[plane]
	for child in root.get_children():
		child.free()
	if plane <= 0:
		return

	var spacing := maxi(1, lamp_spacing_cells)
	var lit: Array[Vector2i] = []
	# Nobody looking means nobody to keep a secret from -- a headless audit and an editor preview
	# both get the whole layer lit, which is what they want and cannot leak anything to.
	var cells: Array = (
		_cells[plane].keys() if _view_team < 0
		else known_tunnel_cells(plane, _view_team)
	)
	cells.sort()  # Deterministic, so the same network always lights the same way.

	for cell: Vector2i in cells:
		if lit.size() >= lamp_budget:
			break
		# Never in a shaft. You wouldn't hang a lamp down the hole, and a light sitting on the
		# marker blows the one thing the player needs to read out to flat white.
		if has_shaft_down(plane, cell) or has_shaft_up(plane, cell):
			continue
		var clear := true
		for other: Vector2i in lit:
			if maxi(absi(other.x - cell.x), absi(other.y - cell.y)) < spacing:
				clear = false
				break
		if not clear:
			continue
		lit.append(cell)

		var lamp := OmniLight3D.new()
		lamp.light_color = lamp_color
		lamp.light_energy = lamp_energy
		lamp.omni_range = lamp_range
		# Shadows off, deliberately. Dozens of shadow-casting omnis in a trench is a lot of
		# cost for an effect the walls already give you by blocking the light's reach.
		lamp.shadow_enabled = false
		# Hung near the top of the trench, so light spills down the walls rather than starting
		# at the floor and leaving the earth faces flat.
		lamp.position = Vector3(cell.x * CELL, wall_height * 0.75, cell.y * CELL)
		root.add_child(lamp)

	_build_rays(plane, root)


## A shaft of light spilling out of every hole in the ceiling.
##
## This is the ONLY thing telling you a shaft goes up from here, now that the painted square
## is gone -- and it does the job better, because a beam is unmistakably a way out rather than
## a symbol you have to have been taught.
##
## The beam is additive and unshaded, which is a deliberate exception to this file's rule that
## nothing goes in the transparent pass. That rule exists because opaque surfaces wrongly
## marked transparent sort against each other and flicker; an additive beam writes no depth,
## occludes nothing, and has nothing to sort against. The spotlight beside it is what actually
## lights the floor -- the cone is only the dust in the air.
func _build_rays(plane: int, root: Node3D) -> void:
	if plane <= 0:
		return
	for cell: Vector2i in _shafts[plane - 1]:
		if not _cells[plane].has(cell):
			continue

		var beam := MeshInstance3D.new()
		beam.mesh = _ray_mesh()
		beam.material_override = _ray_material()
		beam.position = Vector3(cell.x * CELL, 0.0, cell.y * CELL)
		beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(beam)

		var light := SpotLight3D.new()
		light.light_color = ray_color
		light.light_energy = ray_light_energy
		light.spot_range = SPACING * 2.0
		light.spot_angle = 32.0
		light.shadow_enabled = false
		# Hung at the mouth of the shaft, pointing straight down the hole.
		light.position = Vector3(cell.x * CELL, SPACING * 0.95, cell.y * CELL)
		light.rotation_degrees.x = -90.0
		root.add_child(light)


## A cone widening downward from the ceiling, fading out as it falls. Vertex alpha does the
## fade, so the beam has no hard end -- it simply stops being light somewhere near the floor.
func _ray_mesh() -> ArrayMesh:
	var t := SurfaceTool.new()
	t.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segments := 14
	var top := SPACING
	var mouth := Vector3(0.0, top, 0.0)
	for i in range(segments):
		var a := TAU * float(i) / float(segments)
		var b := TAU * float(i + 1) / float(segments)
		var top_a := Vector3(cos(a) * ray_top_radius, top, sin(a) * ray_top_radius)
		var top_b := Vector3(cos(b) * ray_top_radius, top, sin(b) * ray_top_radius)
		var low_a := Vector3(cos(a) * ray_floor_radius, 0.02, sin(a) * ray_floor_radius)
		var low_b := Vector3(cos(b) * ray_floor_radius, 0.02, sin(b) * ray_floor_radius)
		for pair: Array in [[top_a, 1.0], [top_b, 1.0], [low_b, 0.0], [top_a, 1.0], [low_b, 0.0], [low_a, 0.0]]:
			t.set_color(Color(1.0, 1.0, 1.0, pair[1] as float))
			t.add_vertex(pair[0] as Vector3)

		# CAP THE MOUTH. Without it the cone is an open tube, and the cutaway has already
		# removed the ceiling over this cell -- so looking down the beam you saw straight past
		# the world to the clear colour, a black disc sitting in the middle of the light.
		# Filling it reads as what it should: the lit hole you would climb out of.
		for vertex: Vector3 in [mouth, top_b, top_a]:
			t.set_color(Color(1.0, 1.0, 1.0, 1.0))
			t.add_vertex(vertex)
	return t.commit()


func _ray_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.vertex_color_use_as_albedo = true
	material.albedo_color = Color(ray_color.r, ray_color.g, ray_color.b, ray_strength)
	# No depth write: the beam is light in the air, and anything it covers should still be
	# visible through it.
	material.no_depth_test = false
	material.disable_receive_shadows = true
	return material


## Always opaque. Focus is carried by visibility and brightness, so nothing here ever needs
## the transparent pass -- see set_focus_plane for why that matters.
##
## GRAIN BY DEFAULT. Flat colour at this camera distance reads as card, not as earth: nothing
## says how big a cell is and the mouse looks like it is standing on a colour. The dirt speckle
## is world-mapped and shared with the lawn and the lids, so a trench floor is visibly the same
## material as the ground it is cut into. The one thing that opts out is the shaft marker, which
## is a hole rather than a surface -- texturing it would say there is floor down there.
func _make_material(colour: Color, grain: bool = true) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = colour
	material.roughness = 0.95
	material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if grain:
		DirtTexture.apply_to(material)
	return material


## The face of a rock seam. Cool, pale, and FAINTLY SELF-LIT.
##
## The self-lighting is the load-bearing part and it took a screenshot to find out. Everything
## down here is lit by warm lamps, so a plain grey albedo comes back off the wall as brown -- the
## seam ended up the same colour as the earth beside it and the one thing it has to say ("this is
## not going to open") was said in the one channel the lighting had already claimed. A little
## emission holds the hue against the lamp, which is also how actual stone reads next to soil: it
## doesn't take the colour of the light the way loose earth does.
func _make_rock_material() -> StandardMaterial3D:
	var material := _make_material(rock_color)
	material.emission_enabled = true
	material.emission = rock_color
	material.emission_energy_multiplier = 0.22
	return material


## The top of a seam your crew has found. Unshaded pale stone with this plane's tunnels cut out of
## it; see rock_cap.gdshader for why each of those three words is doing work.
##
## `[REVISED]` A SHADER RATHER THAN A PLAIN MATERIAL, because the sheet is built out of whole cells
## and the tunnel under it is not built out of anything of the kind. A stroke's rounded end may
## reach into a rock cell without making any of it walkable -- perfectly legal, and what you do
## every time you run a corridor alongside a seam -- and the cell's whole square then hangs over
## open trench. Square overhangs on a smooth curved corridor, which is the sort of thing that reads
## as the renderer being broken. Discarded against the dug field, the sheet ends where the wall does.
func _make_rock_top_material(plane: int) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load("res://art/shaders/rock_cap.gdshader") as Shader
	material.set_shader_parameter("dug_here", _mask_textures[plane])
	material.set_shader_parameter("field_half_metres", float(MASK_HALF_CELLS))
	material.set_shader_parameter(
		"field_texels_per_metre", float(TunnelContour.TEXELS_PER_METRE)
	)
	material.set_shader_parameter("albedo_color", rock_top_color)
	material.set_shader_parameter("dirt", DirtTexture.shared())
	material.set_shader_parameter("dirt_tile", DirtTexture.WORLD_TILE)
	return material


## Draw the world as `team` knows it: the veins they have found, and the corridors they lit.
##
## THE VIEWER IS TOLD TO THE NETWORK RATHER THAN LOOKED UP BY IT, because a network that went
## hunting for "the player" would be a rendering object reaching into the match to find out whose
## side it is on -- and at M7 there is no single answer to that question on a server. One caller,
## one line, and the day this is per-client it is the caller that changes.
##
## ONE CHANNEL FOR EVERY PER-CREW THING THE WORLD DRAWS, which is why this is no longer called
## `show_known_rock`. Rock caps came first and got a name that described that week's feature; lamps
## are the second thing to need the same answer and fog will be the third. A second setter would
## have meant two ways to be told who is looking, and the interesting bug -- one of them being told
## and the other not -- would show up as the earth knowing something the light did not.
func show_crew_knowledge(team: int) -> void:
	if team == _view_team:
		return
	_view_team = team
	for plane in range(PLANE_COUNT):
		_rebuild_rock_caps(plane)
		# Everything anyone had been glimpsing belonged to the crew that was looking a moment ago.
		_glimpsed[plane].clear()
		_rebuild_mask(plane)
	_rebuild_lamps(_focus)


## One flat sheet per plane, over the cells this crew knows about.
##
## Quads rather than a GridMap or one mesh per cell: a vein is a few dozen cells, the sheet is
## rebuilt a handful of times a match, and a single mesh means the whole thing is one draw call and
## one material to hide when you leave the plane.
func _rebuild_rock_caps(plane: int) -> void:
	if plane < 0 or plane >= _rock_caps.size():
		return
	var cap := _rock_caps[plane]
	if _view_team < 0 or plane <= 0:
		cap.mesh = null
		return

	var known := known_rock_cells(plane, _view_team)
	if known.is_empty():
		cap.mesh = null
		return

	# JUST ABOVE THE LID, not just below it, and the first version got this exactly backwards. Under
	# the lid is where a seam's top surface really is -- and it is invisible there, permanently: the
	# lid is opaque earth, and the one thing that ever cuts a hole in it is a cell being DUG. A rock
	# cell is never dug. So the sheet was drawn correctly, hidden under solid ground, on every plane.
	#
	# Above it, the sheet is what it always claimed to be in the comments: a piece of knowledge laid
	# over the world rather than a surface in it. You are looking at the ground your crew has learned
	# there is rock beneath, which is the only reading of "the top of the seam" a camera up here can
	# actually deliver.
	#
	# Measured off SPACING rather than `wall_height`, because the lid sits one plane spacing above
	# the floor whatever the walls have been tuned to -- and a sheet that tracked the wall dial would
	# sink back under the ground the first time somebody shortened it.
	var top := SPACING + 0.02
	var half := CELL * 0.5
	var t := SurfaceTool.new()
	t.begin(Mesh.PRIMITIVE_TRIANGLES)
	for cell: Vector2i in known:
		var centre := Vector3(cell.x * CELL, top, cell.y * CELL)
		_quad(t,
			centre + Vector3(-half, 0.0, half), centre + Vector3(half, 0.0, half),
			centre + Vector3(half, 0.0, -half), centre + Vector3(-half, 0.0, -half))
	t.generate_normals()
	var mesh := t.commit()
	mesh.surface_set_material(0, _make_rock_top_material(plane))
	cap.mesh = mesh
	cap.visible = plane == _focus


## Rebuild everything derived from a plane's cell set: the wall mesh and the collision trimesh.
##
## Walls run the FULL plane spacing, from the floor up to the underside of the lid, so the
## result is a trench cut through solid earth rather than a kerb standing on open ground. The
## lid caps them, which is why there is no separate top face: the cap is real geometry one
## layer up, and a lip drawn at the same height would only z-fight with it.
##
## Wonderfully dull now that every cell is flat. A neighbour is either dug or it isn't; there
## is no half-height edge to work out, no orientation to read back, and no cross-plane opening
## to remember. All of that existed to serve ramps.
## Bring a plane's drawn and collided geometry back in step with its segments.
##
## `[REVISED]` TWO STEPS NOW, AND ONLY THE FIRST IS EXPENSIVE. Re-contouring is done per 4m chunk
## and only for chunks a dig actually touched; assembling the plane's meshes is a concatenation of
## cached triangle arrays, which is native and costs nothing worth measuring. The old version
## walked every dug cell on every dig, which was affordable at a metre per cell and would not be
## at 12.5cm -- a plane's field is a million texels, and marching all of them to learn that one
## stroke moved is the version of this that drops a frame every time you dig.
##
## `[REVISED]` AND THE SECOND STEP IS NOW ACTUALLY NATIVE, which the paragraph above claimed before
## it was true. The concatenation always was; handing the result to a SurfaceTool a vertex at a time
## was not, and that loop ran over the WHOLE PLANE on every dig -- tens of thousands of GDScript
## iterations to redraw a mesh that changed in one corner, growing with the map, and by a good
## margin the most expensive thing a dig did. Normals are worked out per chunk while a chunk is
## being contoured anyway (there are a few hundred triangles in one, against a plane's tens of
## thousands) and cached with the triangles, which leaves nothing per-vertex to do out here at all.
##
## It did not matter much while a dig happened twice a second. Carving moved the same work to
## sixteen times a second, which is how it came to light.
##
## THE WHOLE PLANE IS STILL ONE MESH, deliberately. The chunk is a unit of WORK, not a unit of
## scene: one mesh instance per plane keeps the focus rules, the per-plane materials, the dimming
## and the single collision body exactly as the rest of the file already expects them -- and keeps
## a big network three draw calls rather than three hundred.
## `collide` is whether to hand the result to the physics engine as well as to the renderer. A
## concave shape has to build its whole tree from scratch every time it is faced -- there is no way
## to edit one -- so it costs the same whether a metre of corridor arrived or a centimetre did, and
## it is the second most expensive thing here after re-contouring.
##
## `[REVISED]` SO A CARVE PAYS IT EVERY QUARTER METRE RATHER THAN NEVER. The old rule was that a
## growing carve declined collision entirely and the earth you were cutting stayed solid to walk
## into until the stroke landed -- justified on the grounds that the only mouse in a position to
## walk into it was the one standing still cutting it. That stopped being true when carving became
## digging rather than a preview of it: you are meant to press dig and walk forward, and a trench
## you can see through and cannot enter is the same complaint as ground that will not open. See
## [constant CARVE_COLLIDE_STEP]. Every commit still rebuilds in full.
func _rebuild_walls(plane: int, collide: bool = true) -> void:
	for key: int in _dirty_chunks[plane]:
		_rebuild_chunk(plane, key)
	_dirty_chunks[plane].clear()

	var floors := PackedVector3Array()
	var walls := PackedVector3Array()
	var stone := PackedVector3Array()
	var collision := PackedVector3Array()
	var floor_normals := PackedVector3Array()
	var wall_normals := PackedVector3Array()
	var stone_normals := PackedVector3Array()
	for key: int in _chunk_cache[plane]:
		var chunk: Dictionary = _chunk_cache[plane][key]
		floors.append_array(chunk["floors"])
		walls.append_array(chunk["walls"])
		stone.append_array(chunk["stone"])
		collision.append_array(chunk["collision"])
		floor_normals.append_array(chunk["floor_normals"])
		wall_normals.append_array(chunk["wall_normals"])
		stone_normals.append_array(chunk["stone_normals"])

	_floors[plane].mesh = _commit(floors, floor_normals, _floor_materials[plane])
	_walls[plane].mesh = _commit(walls, wall_normals, _wall_materials[plane])
	_rock_faces[plane].mesh = _commit(stone, stone_normals, _rock_materials[plane])

	if collide:
		# THE SAME SHAPE RESOURCE, RE-FACED, rather than a fresh one hung on the node. Assigning to
		# `shape` takes the old shape off the physics body and puts a new one on, and a mouse
		# standing on the floor during that swap is a mouse standing on nothing for a frame -- which
		# with no floor below a plane means falling out of the world. Setting the faces on the shape
		# that is already attached is the same rebuild without the gap.
		var body_shape := _shapes[plane].shape as ConcavePolygonShape3D
		if body_shape == null:
			body_shape = ConcavePolygonShape3D.new()
			# Double-sided, so a triangle emitted with the wrong winding still collides. Winding
			# is easy to get backwards and produces a floor you silently fall through, which
			# is a miserable thing to debug for zero benefit on static level geometry.
			body_shape.backface_collision = true
			_shapes[plane].shape = body_shape
		body_shape.set_faces(collision)

	_relight(plane)


## Triangles and their normals into a mesh with a material, or null if there are none. Null rather
## than an empty mesh because an empty ArrayMesh still costs a draw call and still asks the renderer
## questions.
##
## ONE CALL RATHER THAN ONE PER VERTEX. `add_surface_from_arrays` hands the whole plane over as two
## packed arrays; the SurfaceTool this replaced took the same data a vertex at a time through
## GDScript, which is the same picture for a loop that grows with the map and runs on every dig.
func _commit(
	triangles: PackedVector3Array, normals: PackedVector3Array, material: Material
) -> ArrayMesh:
	if triangles.is_empty():
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = triangles
	arrays[Mesh.ARRAY_NORMAL] = normals
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	return mesh


## `count` normals all pointing straight up. Native fill, no loop.
static func _flat_up(count: int) -> PackedVector3Array:
	var normals := PackedVector3Array()
	normals.resize(count)
	normals.fill(Vector3.UP)
	return normals


## A flat normal per triangle, repeated for each of its three vertices.
##
## FLAT RATHER THAN SMOOTHED, which is what the SurfaceTool was producing too: `generate_normals`
## on an unindexed surface gives one normal per face. Earth is faceted on purpose -- a smoothed
## corridor wall reads as plastic -- so this is a like-for-like replacement rather than a look
## change.
static func _face_normals(triangles: PackedVector3Array) -> PackedVector3Array:
	var normals := PackedVector3Array()
	normals.resize(triangles.size())
	for t in range(0, triangles.size(), 3):
		var normal := (triangles[t + 1] - triangles[t]).cross(
			triangles[t + 2] - triangles[t]
		).normalized()
		normals[t] = normal
		normals[t + 1] = normal
		normals[t + 2] = normal
	return normals


## Re-contour one 4m square: its geometry, and its share of the crew's cutaway.
##
## THE FIELD IS REBUILT FROM THE SEGMENTS RATHER THAN EDITED IN PLACE, which makes digging and
## un-digging the same operation. A distance field unions by `min`, so adding a stroke is cheap to
## patch in -- but REMOVING one cannot be undone the same way, and a version that patched on the
## way in and rebuilt on the way out would have two descriptions of the same shape and a class of
## bug that only appears after a cave-in.
##
## TWO FIELDS OUT OF ONE PASS. `shape` is every stroke and is what the world is built from;
## `seen` is only the strokes the viewing crew may know about and is what the lid discards
## against. They differ on a host -- where the network holds both crews' tunnels and the player
## may see one crew's -- and are identical on a client, which is only ever sent its own. Building
## them together costs one extra array and keeps the fog impossible to forget.
##
## `[REVISED]` AND THE SCRAPS ARE SWALLOWED BEFORE ANYTHING IS DRAWN. See [method _cull_islands]:
## the union of the strokes is not quite the shape the world wants, because it leaves crumbs of
## earth the size of a few texels that a player can neither use nor get rid of. Filtering the field
## between composing it and contouring it is the one place that can be done once and be true of the
## walls, the collision and the cutaway together.
func _rebuild_chunk(plane: int, key: int) -> void:
	var cx := key % FIELD_CHUNKS
	var cy := key / FIELD_CHUNKS
	var n := TunnelContour.CHUNK_TEXELS
	var span := n + 1
	var base_x := cx * n - FIELD_HALF_TEXELS
	var base_y := cy * n - FIELD_HALF_TEXELS

	# SAMPLED WIDER THAN THE CHUNK IS CONTOURED, by exactly the island cull's reach. See
	# [method _cull_islands]: deciding whether a scrap of earth is small enough to swallow means
	# measuring the whole scrap, and a scrap sitting on a chunk border is only whole if the samples
	# reach past that border. Contoured and blitted from the middle of the window as before.
	var pad := _cull_pad()
	var wide := span + pad * 2
	var wide_x := base_x - pad
	var wide_y := base_y - pad
	var origin := Vector2(
		float(wide_x) / float(TunnelContour.TEXELS_PER_METRE),
		float(wide_y) / float(TunnelContour.TEXELS_PER_METRE)
	)
	var extent := float(wide - 1) * TunnelContour.TEXEL

	var shape := PackedFloat32Array()
	shape.resize(wide * wide)
	var seen := PackedFloat32Array()
	seen.resize(wide * wide)

	var found := {}
	# The window's cells plus a ring, because a stroke whose centre is in the next chunk can still
	# reach across the border. `_segment_cells` is conservative in the same direction, so anything
	# whose capsule touches this square is registered in one of these cells.
	var low := Vector2i(floori(origin.x) - 1, floori(origin.y) - 1)
	var high := Vector2i(ceili(origin.x + extent) + 1, ceili(origin.y + extent) + 1)
	for y in range(low.y, high.y + 1):
		for x in range(low.x, high.x + 1):
			for id: int in segments_in_cell(plane, Vector2i(x, y)):
				found[id] = true

	# Ends the strokes have been cut to, so a carve unions in exactly like a finished stroke and the
	# corridor has no idea which of the two it grew from. Full length unless somebody is part-way
	# through cutting it (see [method carve]).
	var strokes: Array[Vector2] = []
	var reaches: Array[Vector2] = []
	var shown := PackedByteArray()
	for id: int in found:
		strokes.append(segment_origin(id))
		reaches.append(segment_end(id))
		shown.append(1 if _segment_wants(plane, id) else 0)
	# CARVES ARE NOT IN THE CELL INDEX and are walked whole instead, rejected on their bounding box
	# rather than gathered by square. Registering them would mean maintaining an index entry for a
	# thing that grows every twelfth of a second, and un-registering it on the commit that turns it
	# into a real stroke -- against which a box test on a list that only grows when somebody walks
	# away from a half-dug alcove is nothing.
	#
	# AND THEY ARE SHOWN BY CREW RATHER THAN BY CELL, which is the one place a carve is not simply a
	# short stroke. See [method carve].
	# Grown by the furthest either sampling pass below reaches from a stroke's spine, so a carve
	# rejected here could not have written a texel of this window even at the widest of them.
	var window := Rect2(origin, Vector2(extent, extent))
	var carve_reach := SEG_HALF_WIDTH + maxf(TunnelContour.SDF_RANGE, _thin_reach())
	for id: int in _carving[plane]:
		var carve: Dictionary = _carving[plane][id]
		var from := segment_origin(id)
		var to := _carve_end(id, carve["along"] as float)
		if not window.intersects(Rect2(from, Vector2.ZERO).expand(to).grow(carve_reach)):
			continue
		strokes.append(from)
		reaches.append(to)
		shown.append(1 if _view_team < 0 or (carve["team"] as int) == _view_team else 0)

	## Whether any stroke in this window is one the viewing crew must not be shown. Almost always
	## false -- a client is only ever sent its own tunnels -- and when it is false `seen` came out
	## of the loop below identical to `shape`, so the cull can be run once and shared.
	var hidden := false

	for index in range(strokes.size()):
		var a := strokes[index]
		var b := reaches[index]
		var visible := shown[index] != 0
		if not visible:
			hidden = true
		# TWICE, OVER TWO DIFFERENT SQUARES, and the difference is what the values are FOR.
		#
		# Pass 0 is the field proper: the full metre of graded distance the contour interpolates its
		# crossings from and the cutaway shades with, laid only over the samples that survive
		# `_inner` -- there is no point grading a texel that is about to be thrown away.
		#
		# Pass 1 covers the whole padded window but reaches barely past the stroke itself, because
		# all the rules want out there is thick earth, thin earth or tunnel, and all three of those
		# are settled within a disc's radius of the capsule. Graded to the full range instead, the
		# ring would cost as much as the chunk does: a stroke paints a 3m square at 12.5cm, so the
		# strokes the wider gather picks up -- ones that never come near this chunk at all -- would
		# each be five hundred samples of distance nobody reads. Same formula either way, so the two
		# passes cannot disagree about a texel they both touch.
		for pass_index in range(2):
			var reach := SEG_HALF_WIDTH + (
				TunnelContour.SDF_RANGE if pass_index == 0 else _thin_reach()
			)
			var low_i := pad if pass_index == 0 else 0
			var high_i := wide - 1 - pad if pass_index == 0 else wide - 1
			var i0 := maxi(
				low_i, floori((minf(a.x, b.x) - reach) * TunnelContour.TEXELS_PER_METRE) - wide_x
			)
			var i1 := mini(
				high_i, ceili((maxf(a.x, b.x) + reach) * TunnelContour.TEXELS_PER_METRE) - wide_x
			)
			var j0 := maxi(
				low_i, floori((minf(a.y, b.y) - reach) * TunnelContour.TEXELS_PER_METRE) - wide_y
			)
			var j1 := mini(
				high_i, ceili((maxf(a.y, b.y) + reach) * TunnelContour.TEXELS_PER_METRE) - wide_y
			)
			for j in range(j0, j1 + 1):
				var row := j * wide
				for i in range(i0, i1 + 1):
					var at := origin + Vector2(float(i), float(j)) * TunnelContour.TEXEL
					var value := TunnelContour.encode(
						TunnelContour.segment_distance(at, a, b, SEG_HALF_WIDTH)
					)
					if value > shape[row + i]:
						shape[row + i] = value
					if visible and value > seen[row + i]:
						seen[row + i] = value

	# THINNED BEFORE THE ISLANDS ARE WALKED, and the order is not arbitrary. Shaving the teeth off a
	# lump changes how big it measures, and shaving a neck through can part one lump into two -- so
	# the island rule has to be looking at the earth that will actually be drawn, not at the earth
	# before this ran.
	_thin_earth(plane, shape, wide, origin)
	var islands := _cull_islands(plane, shape, wide, origin, pad, n)
	# The cutaway gets its own pass rather than the shape's answer: the crew's field is built out of
	# fewer strokes, so its earth is a different shape, thin in different places and pinched off in
	# different places. Sharing the verdict would cut a hole in the lid over ground that, as far as
	# this crew has been told, nobody has dug.
	if hidden:
		_thin_earth(plane, seen, wide, origin)
		_cull_islands(plane, seen, wide, origin, pad, n)
	else:
		seen = shape

	var contour := TunnelContour.new()
	var chunk_origin := Vector2(
		float(base_x) / float(TunnelContour.TEXELS_PER_METRE),
		float(base_y) / float(TunnelContour.TEXELS_PER_METRE)
	)
	contour.build(
		_inner(shape, wide, pad, span), n, chunk_origin, _wall_top(plane), _barrier_top(plane)
	)

	var walls := PackedVector3Array()
	var stone := PackedVector3Array()
	_split_stone(plane, contour.walls, walls, stone)

	_chunk_cache[plane][key] = {
		"floors": contour.floors,
		"walls": walls,
		"stone": stone,
		"collision": contour.collision,
		"islands": islands,
		# WORKED OUT HERE, WHERE THERE ARE A FEW HUNDRED TRIANGLES, rather than out in the plane
		# assembly where there are tens of thousands and none of them have moved.
		#
		# A floor triangle is horizontal and wound to face up by construction (see
		# TunnelContour._add_floor_triangle), so its normal is not worth a cross product -- and the
		# floor is much the bigger half of a dug chunk.
		"floor_normals": _flat_up(contour.floors.size()),
		"wall_normals": _face_normals(walls),
		"stone_normals": _face_normals(stone),
	}
	_blit(plane, _inner(seen, wide, pad, span), span, base_x, base_y, n)


## How far past its own square a chunk has to sample, in texels, for the two field rules to reach
## the same verdicts from either side of a border.
##
## A TEXEL WIDER THAN THE BIGGEST ISLAND, and that one spare texel is the whole argument. An island
## is culled only if it fits inside `island_max_span`; a scrap clipped by the window's edge has by
## definition run at least that far out from the chunk, so it measures wider than the limit and is
## kept. That makes "does it fit" a property of the earth rather than of which chunk is asking,
## which is what stops two neighbouring chunks disagreeing and leaving half an island standing.
##
## PLUS THE THINNING'S OWN REACH, ON TOP, because the two rules run in that order and the island
## walk must never see earth the thinning has not finished with. [method _thin_earth] can only work
## where it can see a disc's width all round, so it leaves a rim of the window untouched -- and
## stacking the reaches is what puts every island the cull could swallow inside the part that HAS
## been thinned. Overlap them instead and a scrap gets measured with its teeth still on in one
## chunk and shaved in the next.
func _cull_pad() -> int:
	var thin := _thin_search()
	if island_max_span <= 0.0:
		return thin
	# The spare texel and the thinning's reach are the same spare, not two: what the island walk
	# needs is that a scrap reaching the window's edge measures wider than the limit, and what the
	# thinning needs is its search radius of clearance inside that edge. Anything at least that far
	# from the rim is already more than a texel out.
	return _cull_texels() + maxi(1, thin)


## The cull limit in texels: how many samples across an island may measure and still be swallowed.
func _cull_texels() -> int:
	return maxi(1, ceili(island_max_span * float(TunnelContour.TEXELS_PER_METRE)))


## Half [member earth_min_thickness] in texels -- the radius of the disc that has to fit inside a
## piece of earth for it to be left standing.
func _thickness_texels() -> int:
	if earth_min_thickness <= 0.0:
		return 0
	return maxi(
		1, ceili(earth_min_thickness * 0.5 * float(TunnelContour.TEXELS_PER_METRE))
	)


## How far [method _thin_earth] looks for solid earth, in texels.
##
## A TEXEL PAST THE DISC ITSELF, because the search answers two questions with one loop. Inside the
## disc's radius it decides whether the earth stands at all; the ring beyond only ever produces a
## negative answer, but it produces a GRADED one, and that grading is what puts the new edge
## somewhere sensible instead of hard against the last sample that survived.
func _thin_search() -> int:
	var reach := _thickness_texels()
	return 0 if reach <= 0 else reach + 1


## How far past a stroke the coarse sampling pass has to reach for [method _thin_earth] to be able
## to tell thick earth from thin: far enough that anything it leaves unpainted is genuinely further
## off than the search could look rather than merely unvisited.
func _thin_reach() -> float:
	return float(_thin_search()) * TunnelContour.TEXEL + TunnelContour.TEXEL


## The middle of a sampled window, at the size the contour and the cutaway expect.
func _inner(values: PackedFloat32Array, wide: int, pad: int, span: int) -> PackedFloat32Array:
	if pad == 0:
		return values
	var out := PackedFloat32Array()
	out.resize(span * span)
	for j in range(span):
		var source := (j + pad) * wide + pad
		var target := j * span
		for i in range(span):
			out[target + i] = values[source + i]
	return out


## Open out every piece of earth in the window too thin to be left standing, wherever it is and
## whatever it is attached to.
##
## THE RULE IS "DOES A DISC FIT", which is the whole of it. Earth is kept where some disc of radius
## `r` lies entirely in earth and covers the sample; everything else goes. That is a morphological
## opening, and it is the right shape of question for this because it says nothing about how big a
## piece is or whether it is joined to anything -- a cusp between two strokes and a wall between two
## corridors fail it for the same reason and by the same amount.
##
## ASKED BACKWARDS, WHICH IS WHY IT IS AFFORDABLE. Written out, an opening is an erosion followed by
## a dilation: two filtered passes over every sample in the window, which at 12.5cm in this language
## is several milliseconds a chunk and quite out of the question. But the erosion's result is
## already in the field -- a sample is SOLID exactly when its own depth reads `r` or more, one
## comparison -- so all that is left is the dilation, and only samples SHALLOWER than `r` can be in
## any doubt. Those are a two-texel rim along the walls rather than a window, and each is settled by
## looking outward for the nearest solid sample, which for earth with anything behind it is the very
## first look.
##
## THE WHOLE RIM IS REWRITTEN, NOT JUST THE PART THAT GOES, and the first attempt at this got that
## wrong in a way worth recording. Removing a sample and leaving its neighbours alone leaves two
## different fields meeting along the new edge: on one side the earth's own distance, up to `r`; on
## the other, something just past the surface. The contour interpolates its crossing between the
## two, and where two numbers on such different scales meet, the crossing snaps about from texel to
## texel -- so a rule that should have shaved a smooth line off a wall instead left it looking
## chewed. Both sides now carry the same quantity, the distance to solid earth measured from the
## sample, and the edge comes out where the arithmetic says rather than where the grid does.
##
## WHICH COSTS NOTHING WHERE THE RULE DOES NOT BITE. `r` minus the distance to solid earth IS the
## depth again, exactly, anywhere the field has a sensible gradient: step outward from a sample at
## depth `d` and earth becomes solid after exactly `r - d`. So a straight wall, a curve, the inside
## of a bend -- all rewritten to the values they already had, and only where no solid earth is
## within reach does the answer change.
##
## THE SOLID SET NEVER MOVES WHILE THE SWEEP RUNS, which is what lets it write as it goes: only
## shallow samples are written, and the write can never make one solid, so the set being searched
## cannot gain or lose a member partway through. A pass in scan order gives the same field as a pass
## in any other.
##
## ROCK IS NEVER THINNED, for the same reason it is never swallowed: to these samples the last
## wafer of a seam is indistinguishable from a wafer of earth, and one of the two is meant to be
## permanent.
func _thin_earth(plane: int, values: PackedFloat32Array, wide: int, origin: Vector2) -> void:
	var search := _thin_search()
	if search <= 0:
		return
	var radius := earth_min_thickness * 0.5
	# The value a sample reads at exactly the disc's radius. Deeper earth encodes LOWER, so "solid
	# enough to stand on its own" is a single `<=`.
	var solid := TunnelContour.encode(radius)
	var disc := _thin_disc(wide, search)
	var spans := _thin_spans

	# Stopping the search's own reach short of the window's edge, because a sample nearer the edge
	# than that cannot be asked the question -- the earth that would answer it was never sampled.
	# The rim is left alone, and `_cull_pad` is what keeps it out of everything that reads this
	# afterwards.
	for j in range(search, wide - search):
		var row := j * wide
		for i in range(search, wide - search):
			var at := row + i
			var value := values[at]
			if value > TunnelContour.SURFACE or value <= solid:
				continue
			var world := origin + Vector2(float(i), float(j)) * TunnelContour.TEXEL
			if _rock[plane].has(world_to_cell(Vector3(world.x, 0.0, world.y))):
				continue

			var depth := TunnelContour.decode(value)
			# Far enough that nothing found sets the sample well inside the tunnel, which is the
			# right answer for the middle of a wafer with no solid earth anywhere near it.
			var away := float(search) * TunnelContour.TEXEL + TunnelContour.TEXEL
			for k in range(disc.size()):
				var q := at + disc[k]
				if values[q] > solid:
					continue
				# Between here and there the earth goes from `depth` to solid; the crossing is where
				# it passes `radius`. Interpolated rather than taken as the whole step, because the
				# step is 12.5cm and rounding every wall out to the nearest one of those is the
				# staircase this whole field exists to avoid.
				var there := TunnelContour.decode(values[q])
				away = spans[k] * clampf(
					(radius - depth) / maxf(there - depth, 0.000001), 0.0, 1.0
				)
				break
			values[at] = TunnelContour.encode(radius - away)


## Offsets into a window of the given width covering a disc of `reach` texels, nearest first and
## without the centre, with [member _thin_spans] filled with each one's length in metres.
##
## NEAREST FIRST BECAUSE THE SEARCH STOPS AT THE FIRST HIT, and for the overwhelming majority of
## samples -- a rim texel with the bulk of the map right behind it -- the first hit is the step
## inward. Ordered any other way the same loop reads the whole disc to reach the same answer, and
## reaches a WORSE one: the first solid sample found has to be the nearest, or the distance it
## reports is not a distance.
##
## Cached, because it depends only on the window and the setting and is otherwise rebuilt a few
## thousand times a dig.
func _thin_disc(wide: int, reach: int) -> PackedInt32Array:
	var key := Vector2i(wide, reach)
	if _thin_offsets_for == key:
		return _thin_offsets
	var found: Array[Vector3i] = []
	for dj in range(-reach, reach + 1):
		for di in range(-reach, reach + 1):
			var span := di * di + dj * dj
			if span == 0 or span > reach * reach:
				continue
			found.append(Vector3i(span, di, dj))
	found.sort_custom(func(a: Vector3i, b: Vector3i) -> bool: return a.x < b.x)
	_thin_offsets = PackedInt32Array()
	_thin_spans = PackedFloat32Array()
	for entry: Vector3i in found:
		_thin_offsets.append(entry.z * wide + entry.y)
		_thin_spans.append(sqrt(float(entry.x)) * TunnelContour.TEXEL)
	_thin_offsets_for = key
	return _thin_offsets


## Swallow every lump of earth in the window too small to be worth leaving standing, and report the
## ones that overlap the chunk itself so the dig rule can be told they are gone.
##
## TWO TESTS, AND A LUMP HAS TO FAIL BOTH TO GO. [member island_max_span] is how far across it may
## measure and is the one the sampling window is built around; [member island_max_area] is how much
## earth it may actually contain, and only ever narrows what the span already allowed. See both for
## why that order is the load-bearing one.
##
## DONE ON THE FIELD, NOT ON THE SEGMENTS, and that is the only place it can honestly go. An island
## is not a thing anybody dug -- it is what is LEFT between things people dug, and it appears and
## disappears as the strokes around it change. Recording it as state, or as some extra stroke laid
## down to erase it, would give the world a second description of itself that a cave-in could put
## out of step with the first. Recomputed here from the same samples the walls are contoured from,
## it cannot disagree with them: undig the strokes and the island simply comes back.
##
## FOUR-CONNECTED EARTH. A scrap joined to the mainland only at a corner is joined by nothing a
## mouse could stand on, so it counts as its own island and goes -- which is the common case at a
## shallow join, and the case that looks worst.
##
## ROCK IS NEVER SWALLOWED. The field knows nothing about seams -- rock is enforced by refusing to
## dig, so stone reads to these samples as earth nobody has got to yet. A nub standing in a rock
## cell is the last of a seam and is meant to be permanent, so any island whose box touches one is
## left exactly where it is.
func _cull_islands(
	plane: int, values: PackedFloat32Array, wide: int, origin: Vector2, pad: int, n: int
) -> PackedFloat32Array:
	var culled := PackedFloat32Array()
	if island_max_span <= 0.0:
		return culled
	var limit := _cull_texels()

	# Per texel: 0 not looked at, 1 walked as part of the lump in hand, 2 known to belong to
	# something too big to swallow.
	var state := PackedByteArray()
	state.resize(wide * wide)
	# The lump being walked, used as its own queue: a breadth-first fill reading from `head` and
	# writing to the end needs no second array and no per-texel allocation.
	var body := PackedInt32Array()
	# The chunk's own square, for deciding which islands are worth reporting back.
	var chunk := Rect2(
		origin + Vector2(float(pad), float(pad)) * TunnelContour.TEXEL,
		Vector2(float(n), float(n)) * TunnelContour.TEXEL
	)

	# STARTED FROM THE TUNNEL AND STEPPED OUTWARD, NEVER FROM INSIDE THE EARTH. Anything small
	# enough to swallow is by definition within `limit` texels of open tunnel, so every island has a
	# face on one -- and the alternative is starting somewhere in the middle of the map's undug bulk
	# and walking it to prove what its size already said.
	#
	# ASKED OF THE TUNNEL TEXELS RATHER THAN OF THE EARTH ONES, which is the same set of starts for
	# a fifth of the reads. Most of a window near the digging frontier is solid ground, and testing
	# each of those four ways round to hear "no" is two thousand texels' worth of neighbours nobody
	# needed; open tunnel is the scarce thing, so let the scarce thing do the asking.
	var seeds := PackedInt32Array()
	for j in range(wide):
		var row := j * wide
		for i in range(wide):
			var here := row + i
			if values[here] <= TunnelContour.SURFACE:
				continue
			if i > 0 and values[here - 1] <= TunnelContour.SURFACE:
				seeds.append(here - 1)
			if i < wide - 1 and values[here + 1] <= TunnelContour.SURFACE:
				seeds.append(here + 1)
			if j > 0 and values[here - wide] <= TunnelContour.SURFACE:
				seeds.append(here - wide)
			if j < wide - 1 and values[here + wide] <= TunnelContour.SURFACE:
				seeds.append(here + wide)

	# The same lump is reached from every texel of tunnel along its face, so most of these have been
	# walked by the time they come up. `state` is what says so.
	for start: int in seeds:
		if state[start] != 0:
			continue

		body.clear()
		body.append(start)
		state[start] = 1
		var head := 0
		var min_x := wide
		var max_x := -1
		var min_y := wide
		var max_y := -1
		# GIVEN UP ON THE MOMENT IT MEASURES TOO BIG, which is what keeps this affordable: the walk
		# is over a few dozen texels of scrap rather than over half a chunk of solid ground, and the
		# bulk of the earth is dismissed in the first handful of steps every time. The texels walked
		# so far are then marked as belonging to something big -- so the next start that runs into
		# them gives up immediately instead of re-walking the same ground from another corner, and,
		# more to the point, a HALF of a big lump can never be mistaken for a small whole one.
		var rejected := false
		while head < body.size() and not rejected:
			var at := body[head]
			head += 1
			@warning_ignore("integer_division")
			var y := at / wide
			var x := at - y * wide
			min_x = mini(min_x, x)
			max_x = maxi(max_x, x)
			min_y = mini(min_y, y)
			max_y = maxi(max_y, y)
			if max_x - min_x + 1 > limit or max_y - min_y + 1 > limit:
				rejected = true
				break
			# Four neighbours, written out four times. A loop over an array of them is the same
			# thing to read and allocates that array once per texel, in the one routine here that
			# runs a few thousand times per dig.
			if x > 0 and values[at - 1] <= TunnelContour.SURFACE:
				if state[at - 1] == 2:
					rejected = true
				elif state[at - 1] == 0:
					state[at - 1] = 1
					body.append(at - 1)
			if x < wide - 1 and values[at + 1] <= TunnelContour.SURFACE:
				if state[at + 1] == 2:
					rejected = true
				elif state[at + 1] == 0:
					state[at + 1] = 1
					body.append(at + 1)
			if y > 0 and values[at - wide] <= TunnelContour.SURFACE:
				if state[at - wide] == 2:
					rejected = true
				elif state[at - wide] == 0:
					state[at - wide] = 1
					body.append(at - wide)
			if y < wide - 1 and values[at + wide] <= TunnelContour.SURFACE:
				if state[at + wide] == 2:
					rejected = true
				elif state[at + wide] == 0:
					state[at + wide] = 1
					body.append(at + wide)

		if rejected:
			for at: int in body:
				state[at] = 2
			continue

		# Asked second because it is a read of a number the walk already has, where the span test
		# above is what let the walk stop early. Nothing is marked either way: a lump kept for its
		# footprint has been walked from end to end, so every texel of it is already spoken for and
		# no later start can reach it.
		if island_max_area > 0.0:
			var area := float(body.size()) * TunnelContour.TEXEL * TunnelContour.TEXEL
			if area > island_max_area:
				continue

		# In metres, grown by half a texel each way: the samples are the CORNERS of the marching
		# squares cells, so the earth reaches half a cell past the outermost one that measured solid.
		var half := TunnelContour.TEXEL * 0.5
		var box := Rect2(
			origin + Vector2(float(min_x), float(min_y)) * TunnelContour.TEXEL
				- Vector2(half, half),
			Vector2(float(max_x - min_x), float(max_y - min_y)) * TunnelContour.TEXEL
				+ Vector2(half, half) * 2.0
		)
		if _box_hits_rock(plane, box):
			continue

		for at: int in body:
			# Mirrored rather than flattened: the texel keeps the depth it had, on the other side of
			# the surface. Flat fill would put a step in the field where the island was, which the
			# cutaway shader reads as an edge; this leaves it smooth. The extra texel is what makes
			# every sample in the island land strictly INSIDE, so no crossing is left behind for the
			# contour to raise a hairline wall on.
			values[at] = TunnelContour.encode(
				-TunnelContour.decode(values[at]) - TunnelContour.TEXEL
			)

		# Only the ones the chunk itself covers. An island straddling a border is measured the same
		# from both sides and recorded by both, which is what makes one lookup enough in `_is_earth`.
		if not chunk.intersects(box):
			continue
		culled.append(box.position.x)
		culled.append(box.position.y)
		culled.append(box.end.x)
		culled.append(box.end.y)

	return culled


## Does any cell this box touches hold rock?
func _box_hits_rock(plane: int, box: Rect2) -> bool:
	var low := world_to_cell(Vector3(box.position.x, 0.0, box.position.y))
	var high := world_to_cell(Vector3(box.end.x, 0.0, box.end.y))
	for y in range(low.y, high.y + 1):
		for x in range(low.x, high.x + 1):
			if _rock[plane].has(Vector2i(x, y)):
				return true
	return false


## Is this spot inside a lump of earth the contour has already swallowed?
##
## ASKED OF ONE CHUNK, because [method _cull_islands] records an island in every chunk it overlaps.
func _in_culled_island(plane: int, point: Vector2) -> bool:
	var chunk := _chunk_at(point)
	if chunk.x < 0 or chunk.y < 0 or chunk.x >= FIELD_CHUNKS or chunk.y >= FIELD_CHUNKS:
		return false
	var cached: Variant = _chunk_cache[plane].get(chunk.y * FIELD_CHUNKS + chunk.x)
	if cached == null:
		return false
	var boxes: PackedFloat32Array = (cached as Dictionary)["islands"]
	for b in range(0, boxes.size(), 4):
		if (
			point.x >= boxes[b] and point.x <= boxes[b + 2]
			and point.y >= boxes[b + 1] and point.y <= boxes[b + 3]
		):
			return true
	return false


## Sort wall triangles into earth and stone by what is standing behind them.
##
## THE ENTIRE USER INTERFACE FOR ROCK: you dig into a seam, the corridor ends in grey, and nothing
## has to explain itself. Same geometry, same collision, split only so the two can carry different
## materials -- exactly as the cell version did, asked per wall face instead of per cell side.
func _split_stone(
	plane: int, source: PackedVector3Array, earth: PackedVector3Array, stone: PackedVector3Array
) -> void:
	for t in range(0, source.size(), 6):
		var a := source[t]
		var b := source[t + 1]
		# A step from the middle of the face AWAY from the corridor, far enough to land in the
		# neighbouring cell rather than back in this one.
		var outward := -(b - a).cross(Vector3.UP).normalized()
		var behind := (a + b) * 0.5 + outward * (CELL * 0.6)
		var into := stone if _rock[plane].has(world_to_cell(behind)) else earth
		for k in range(6):
			into.append(source[t + k])


## Write a chunk's visible field into the image the lid samples.
func _blit(
	plane: int, values: PackedFloat32Array, span: int, base_x: int, base_y: int, n: int
) -> void:
	var image := _mask_images[plane]
	for j in range(n):
		var y := base_y + j + FIELD_HALF_TEXELS
		if y < 0 or y >= FIELD_TEXELS:
			continue
		for i in range(n):
			var x := base_x + i + FIELD_HALF_TEXELS
			if x < 0 or x >= FIELD_TEXELS:
				continue
			var v := values[j * span + i]
			image.set_pixel(x, y, Color(v, 0.0, 0.0, 1.0))
	_mask_textures[plane].update(image)


## Rebuild a plane's lamps and beams, if it is the one being looked at. Off-focus planes are
## left alone on purpose: their lamp root is hidden, and set_focus_plane rebuilds whichever
## plane you arrive on, so building lights nobody can see is pure cost during a dig.
func _relight(plane: int) -> void:
	if plane == _focus and plane > 0 and plane < PLANE_COUNT:
		_rebuild_lamps(plane)


func _wall_top(plane: int) -> float:
	return 0.0 if plane == 0 else wall_height


func _barrier_top(plane: int) -> float:
	return 0.0 if plane == 0 else maxf(wall_height, barrier_height)


func _quad(t: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	for vertex: Vector3 in [a, b, c, a, c, d]:
		t.add_vertex(vertex)
