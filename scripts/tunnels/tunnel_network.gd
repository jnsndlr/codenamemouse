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
## The stone on a plane changed: a boulder broken up, a lobe taken off a rock, a lump cleared away.
##
## `[REVISED]` NO LONGER ABOUT KNOWLEDGE. This used to fire when a crew LEARNED where some rock was,
## and carried the crews affected, because rock was hidden information a dig bought you. It is not
## any more -- a rock either stands above the dirt where anyone can see it or it is buried, and both
## crews look at the same world -- so what is left is the layout itself changing, which the minimap
## and the drawn lumps both redraw a whole plane for.
signal rock_changed(plane: int)
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

## How much room a mouse needs to get PAST something, which is not the same question and does not
## get the same answer. See [method walkable_between].
##
## THE MARGIN IS THE WHOLE DIFFERENCE, and it belongs to standing rather than to walking.
## [constant STANDING_CLEARANCE] decides whether a square is somewhere a mouse LIVES -- a place to
## be shoved about in, to swing from, to be a waypoint -- and being fussy by two centimetres there
## costs a cell at the end of a corridor that nobody wanted anyway. A doorway is the opposite trade:
## the mouse is only passing through, the body either fits or it does not, and a graph two
## centimetres fussier than the collision mesh refuses junctions the player is visibly walking
## through. The tangent join in [method walkable_between]'s header is exactly that case -- it
## measures 16.8cm at its narrowest and the capsule goes through it without touching the sides.
##
## THE PHYSICS IS THE ARBITER, not this number: `tunnel_audit.gd` walks the player's actual capsule
## along every step of every route it plans, so a value that let a route through a gap the body
## cannot take would fail there rather than in play.
const WALK_CLEARANCE: float = 0.16

## Samples around the body when the field has to be asked the long way. See [method _stands_at].
## Eight leaves 12cm between neighbouring samples at this radius -- about a texel, which is as fine
## as the field can distinguish anyway.
const WALK_RING: int = 8

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

## How finely a walk between two places is sampled. See [method walkable_between].
##
## SIZED AGAINST THE BODY RATHER THAN AGAINST THE FIELD. Each sample proves a disc of
## [constant WALK_CLEARANCE] fits at that spot, and a signed distance is 1-Lipschitz, so a chain of
## them proves the walk fits inside a sausage of `sqrt(clearance^2 - (step/2)^2)` -- 15.2cm at this
## step. Halving it buys under a centimetre; doubling it starts letting a walk clip a corner between
## two samples, which is a bot walking into a wall.
const WALK_SAMPLE: float = 0.1

## Bit 1 is the world: ground, arena walls, props, rocks. Everything a mouse collides with
## regardless of depth.
const WORLD_BIT: int = 1

## Both crews, as the knowledge masks store it. For the things everybody can see.
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
## Per-plane rock obstructions (GDD section 3). Boulders buried in the earth that stop horizontal
## digging, with A DIFFERENT LAYOUT ON EVERY PLANE -- which is the whole idea. Rock in one place on
## every layer would be a flat maze repeated three times; rock that moves as you go down makes
## getting past an obstruction a question of which LAYER to go around it on, and turns map knowledge
## into four floors of map knowledge rather than one.
##
## `[REVISED]` BOULDERS RATHER THAN TILES, AND THAT IS A CORRECTION RATHER THAN A NEW FEATURE. Rock
## used to be a set of whole cells, laid as random walks. Digging stopped being made of cells two
## milestones ago -- a stroke is a capsule at a free angle contoured into a distance field -- and
## the two descriptions of the earth disagreed everywhere they met: a stroke was refused if a cell
## it CLAIMED held rock, but its body is wider than the cells it claims, so a corridor run alongside
## a seam took a bite out of the stone. The wall was drawn through the middle of a rock cell and the
## mouse walked into ground the rules called permanent. You could dig inside the rock.
##
## So a rock is a [RockBody] now: a union of discs with a real distance function, subtracted from
## the dug field one `min` per sample. The stone is the same object to the wall mesh, the collision
## trimesh, the cutaway and the routing graph as it is to the dig rule, because all five read the
## one field. See rock_body.gd, which is where the argument is written out in full.
##
## A rock is still not a new kind of thing to the rest of the file. It is earth that will not open,
## drawn by the same wall the surrounding earth is (in stone, so you can see what stopped you), and
## invisible until somebody digs up against it -- which is exactly right for a game about hidden
## information: you learn where the rock is by paying for the knowledge.
@export var rock_seed: int = 20260801
## Fraction of plane 1's ground covered by rock. Nothing on the surface: the lawn is not diggable in
## the first place, and a "rock" up there is just a prop.
##
## `[REVISED]` DOWN FROM 9% WITH THE SHRINK, AND THE DIAL MEANS SOMETHING DIFFERENT NOW. Coverage is
## a poor proxy for the thing that is actually felt, which is HOW FAR YOU GET BEFORE YOU MEET STONE
## -- and the two came apart when the pieces got small. A corridor is a metre wide and nearly every
## rock is wider than that, so a rock blocks a run whatever its area: cutting the radius by two
## thirds at constant coverage multiplied the number of blockers by ten. Measured, the median
## straight dig before hitting stone fell from 4.9 metres to 1.75 -- rock every other stroke, which
## is not an obstruction, it is a texture.
##
## 5% puts plane 1's median back to about 5.5 metres and its mean to 7.5, which is a rock every few
## strokes: often enough to plan around, rare enough to be an event. Plane 3 comes out at about 2
## metres, which is the "deeper is rockier" gradient actually being felt rather than merely stated.
##
## MOVE THIS AGAINST THE MEASUREMENT, NOT AGAINST THE PERCENTAGE. The percentage is an input the
## generator happens to take; the free run is the thing a player experiences, and the two stopped
## tracking each other the moment rock size became a range. See the free-run probe in the scratch
## tooling, and `_check_surfacing` for the visibility half of the same tuning.
@export_range(0.0, 0.5, 0.005) var rock_density: float = 0.05
## Added per plane below the first. Kept at the same RATIO to the base as before -- plane 3 comes out
## a bit under twice plane 1 -- because the argument for it never had anything to do with the
## absolute number. Deeper is rockier, which gives the shallow planes a reason to
## exist once the deep ones are faster to cross -- and it is the same direction section 3 sends
## dig TIMES, so the two dials push the same way instead of cancelling.
@export_range(0.0, 0.2, 0.005) var rock_density_deeper: float = 0.008
## `[REVISED]` SIZED FOR A THING YOU MEET, NOT A REGION YOU ROUTE AROUND, and the old numbers were
## a full order of magnitude out on that. A rock used to be 0.85 to 2.60 metres of RADIUS -- one and
## three quarters to over five metres across, against a corridor a metre wide and a mouse forty
## centimetres tall. One lump covered fifteen cells. Nothing that size can be a rock you run into
## while digging; it is a district, and the only honest way to draw it was the cell footprint that
## started this. At this range a rock is between two thirds of a corridor's width and a bit over
## two, so meeting one is an event in a stroke rather than a fact about the map.
##
## THE COVERAGE DIAL IS UNCHANGED AND MEANS THE SAME THING, which is the point of aiming
## `_generate_rock` at an area rather than a count: the same fraction of ground is stone, in many
## more, much smaller pieces. That is a different game -- you meet rock often and go round it
## quickly, instead of meeting it rarely and going round it for ten seconds -- and it is the one
## the design asks for.
## Nominal radius of one rock, in metres. The upper end is deliberately most of a corridor's turning
## room: these took over from a seam that could run eleven cells, and an obstruction you step round
## without noticing is not an obstruction. The outer reach of a finished lump comes out a little
## past this -- see [method RockBody.reach].
##
## `[REVISED]` THE TOP OF THE RANGE EXISTS TO KEEP THE REFUSAL ALIVE, and that is the whole reason it
## is not simply the bottom plus a bit. A stroke is refused only when it would open NOTHING, so a
## rock has to be able to swallow a whole one -- a metre long and a metre wide -- before the words
## *"solid rock: go round it, or go under it"* can ever be said. Shrunk to a top span of 1.10 the
## widest full-corridor band of stone anywhere on the map measured 0.88m, so no rock on any plane
## could refuse anything: every encounter became a corridor curving past a pebble, the refusal was
## dead code, and the one message that teaches a player they can go DOWN never appeared.
##
## So the range is wide and the draw is skewed (see `_generate_rock`). Most rocks are small things
## you curve around without stopping. A few are big enough to stop you dead -- and because height
## scales with span, those are also the ones standing out of the dirt where you could see them
## coming. The rock that blocks you is the rock you were shown.
@export var rock_span: Vector2 = Vector2(0.30, 1.95)
## How many of them a Brute can shift. The rest are bedrock: permanent, and drawn in their own
## colour so that "can this be broken" is a question you answer by looking rather than by swinging.
##
## Both kinds draw from the same size range on purpose. If the big ones were always the breakable
## ones the colour would be decoration -- you would read the size and never look at it -- and the
## interesting decision (is it worth fetching a Brute, or is going round cheaper?) would have been
## made for the player by the generator.
@export_range(0.0, 1.0, 0.01) var rock_breakable_fraction: float = 0.55
## Brute swings to take ONE LOBE off a breakable rock. A lump is four to seven lobes, so clearing a
## whole one is twenty to thirty swings and it comes apart a bite at a time -- which is what makes
## it collaboration rather than a countdown: the Engineer can start digging round the moment the
## first bite opens a way through, and does not have to wait for the rock to be gone.
@export var rock_hits_per_lobe: int = 4
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
## The face of a breakable rock where a tunnel runs into one. Cool and pale against the warm earth
## -- the message is "this is not the same stuff, and it is not going to open", and it has to land
## from across a corridor with no legend to read.
##
## UNCHANGED FROM WHEN THIS WAS A SEAM'S COLOUR, deliberately. The stone a Brute can break is the
## stone players have already learned to recognise; making the NEW thing (bedrock, below) the one
## that looks different is what keeps the existing reading intact.
@export var rock_color: Color = Color(0.60, 0.64, 0.70)
## The face of bedrock: the rock nothing shifts.
##
## DARKER AND FLATTER, not a different hue. The two have to read as the same material in different
## grades -- both are stone, and the question the colour answers is "is this one worth a Brute", not
## "what is this made of". A contrasting hue would say the second thing and would also stop reading
## as rock at all in lamplight, which is the only light down there.
@export var bedrock_color: Color = Color(0.34, 0.36, 0.41)

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
## plane -> {cell: true}: earth that will never open, at CELL granularity.
##
## `[REVISED]` A DERIVED INDEX NOW, NOT THE RECORD OF WHERE THE ROCK IS. The stone itself lives in
## `_rock_bodies` as shapes; this is the answer to the questions that are about squares anyway --
## may a shaft land here, may a bot plan to dig here, what does the minimap draw, which cells does
## a crew know about. A cell is in here when its CENTRE is inside a rock, plus the cells a boulder
## on the lawn shuts wholesale.
##
## WHICH IS WHY `_rock_owner` EXISTS. The two entries mean different things to the dig: a boulder
## shuts the whole square (there is a rock standing on top of it and no part of it can open), while
## a rock body only shuts the stone, and there may be perfectly good earth in the rest of the cell.
## Anything deciding whether ground can open has to tell them apart -- see [method _is_earth].
var _rock: Array[Dictionary] = []
## plane -> [RockBody]: the stone, as shapes. Grown once from `rock_seed`, and edited by exactly one
## thing after that -- a Brute taking a lobe off a breakable one.
##
## THE ARRAY POSITION IS THE ROCK'S NAME, on both ends of a wire and for the whole match: the seed
## grows them in the same order everywhere, so an index is enough to address one without any of the
## geometry crossing. Broken rocks leave a null in place rather than being removed, because
## compacting the array would rename every rock after them.
var _rock_bodies: Array[Array] = []
## plane -> {cell: index into `_rock_bodies`}, or -1 for a cell a boulder shut. The other half of
## `_rock`; see its note.
var _rock_owner: Array[Dictionary] = []
## plane -> {cell: [index, ...]}: which rocks come anywhere near a cell, for asking "is this point
## stone" without walking every rock on the plane. A rock registers in every cell its bounding box
## touches, so a lookup is one dictionary hit and then a handful of distance tests.
var _rock_near: Array[Dictionary] = []
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
## A reused per-window stone mask. See [method _stone_scratch].
var _stone_mask: PackedByteArray = PackedByteArray()
var _thin_offsets: PackedInt32Array = PackedInt32Array()
var _thin_spans: PackedFloat32Array = PackedFloat32Array()
var _thin_offsets_for: Vector2i = Vector2i(-1, -1)
## plane -> {chunk key: true}: chunks whose cache is stale. Flushed by [method _rebuild_walls].
var _dirty_chunks: Array[Dictionary] = []
## plane -> {cell: Vector3}: where in a cell a mouse actually stands, remembered.
##
## WHY THIS IS WORTH A CACHE AND `_field_at` IS NOT. [method standing_point] is a pure function of
## the strokes registered in one cell and the stone around them, and it is asked the SAME QUESTION
## about the SAME CELL by every bot several times a second: [method TunnelGraph.route] calls it once
## per step of every path it returns, and `RoutePlanner.plan` asks the graph for up to nine paths
## per plan. Measured in a live match at 78 strokes, one `plan` was **6.8ms**, of which about
## nineteen twentieths was this function, and nine bots planning three times a second spent
## **204ms of every second** in it -- a fifth of the wall clock, on a layer whose earth had not
## moved between one bot asking and the next.
##
## It is not cheap per call either: twenty-five samples of graded distance per stroke in the cell,
## each rejecting itself against the rock field.
##
## DROPPED PER CELL BY [method _occupy] AND [method _vacate], which are the only two places the set
## of strokes near a cell can change, and they already walk exactly the cells affected. Rock is
## coarser -- a whole plane at a time, at [method _register_rock] and [method _unregister_rock] --
## because a rock moving is a rare, large event and a cell-accurate drop there would be a second
## description of which cells a lump reaches.
var _standing_at: Array[Dictionary] = []
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
## The same, for the faces standing on bedrock. A third mesh rather than a second material on the
## same one, because a mesh carries exactly one material per surface and the split is already being
## made a triangle at a time in [method _split_stone] -- so this costs one more draw call per plane
## and no new machinery at all.
var _bedrock_faces: Array[MeshInstance3D] = []
## The stone standing above a plane's dirt, one batched surface per plane. Only the rocks tall
## enough to break the ground are in it, and only the part of them above the ground is drawn: the
## rest is already the wall face the contour wrapped round the stone. Built once, when the layout
## is, and edited only when a Brute takes a lobe off one.
var _rock_lumps: Array[MeshInstance3D] = []
## The same, for bedrock, and a second surface for the same reason the faces have one: a mesh
## carries one material per surface and the two grades have to be told apart on sight.
var _bedrock_lumps: Array[MeshInstance3D] = []
## Whose knowledge the world is being drawn for. -1 until somebody asks, because a network in a
## headless audit has no player and should draw nothing.
var _view_team: int = -1
var _bodies: Array[StaticBody3D] = []
## One collision shape per CHUNK, hung on that plane's one body: `_chunk_shapes[plane][key]`.
##
## `[REVISED]` IT USED TO BE ONE SHAPE PER PLANE, and that was the single most expensive thing a dig
## did. A `ConcavePolygonShape3D` cannot be edited -- faced, it throws its tree away and builds
## another from every triangle it was given -- so a plane-wide shape charged a dig for the whole map
## every time, and a carve pays that four times a metre. Measured against a network of two hundred
## strokes it was fifteen milliseconds per dig and climbing linearly: a guaranteed dropped frame,
## paid by every mouse on the map because it runs on the main thread, and it got worse the longer a
## match went on.
##
## The chunk was already the unit of re-contouring. Making it the unit of collision too turns that
## into a bounded cost -- a dig re-faces the two to five chunks it actually moved, whatever the map
## looks like around them.
##
## MANY SHAPES, ONE BODY, which keeps everything else in this file true: the layer, the mask and the
## node the audits look for are all still per plane, and a mouse still collides with exactly the one
## layer it is standing on.
var _chunk_shapes: Array[Dictionary] = []
## The union of every COMMITTED stroke over one chunk's window, kept so a carve does not have to
## re-derive it: `_committed_field[plane][key]` is `{shape, seen, hidden, wide, knowledge, ids}`.
##
## WHAT THIS IS FOR. Composing a chunk means walking every stroke that reaches into its window and
## painting a metre of graded distance from each -- and at the density a mid-match corridor network
## reaches, that is thirty-odd strokes and about two milliseconds a chunk. A dig moves a handful of
## chunks, so a commit pays it several times over; a CARVE pays it sixteen times a second while
## somebody holds the button, and every one of those rebuilds repainted thirty strokes that had not
## moved in order to advance one tip by a centimetre.
##
## So the committed half is composed once and kept. A carve step copies it and unions its own
## growing stroke on top, which is the one thing that actually changed.
##
## INVALIDATED BY DIRTYING, WHICH IS THE ONLY RULE. Every path that can change what a committed
## stroke contributes goes through [method _touch_span], [method _touch_box] or
## [method _rebuild_mask], and all three drop the entry -- the growing-carve step is the single
## exception, and it is the only caller that knows the committed strokes have not moved.
##
## `[REVISED]` **AND A STROKE ARRIVING IS NOT A REASON TO DROP IT.** Dirtying was doing two jobs at
## once, and only one of them was true. A commit reaches nine chunks (the cull's reach, see
## [method _touch_span]) and threw away all nine compositions, each of which then repaid a full
## walk of every stroke in its window -- measured at 10 strokes a window early in a match and 43 by
## two hundred, which is exactly the curve the complaint described. But the field is a `max` union
## of strokes: a stroke ARRIVING is one more `max`, and re-deriving the other forty to add it is
## the whole cost for none of the information. Only a stroke LEAVING -- a collapse, a vacate --
## needs the window composed again from nothing.
##
## SO THE ENTRY CARRIES THE IDS IT WAS BUILT FROM (`ids`), and a rebuild compares that set against
## the strokes the cell index reports now. Everything in the cache and still present is kept;
## whatever is new is painted on top; anything MISSING forces the full recompose. That is a rule
## about the ids themselves rather than a list of callers who must remember to invalidate -- the
## same reason [member _knowledge_age] is a stamp rather than a convention -- so a path that
## removes a stroke without telling anybody is still correct, just slow.
##
## AND BY A KNOWLEDGE STAMP ON TOP, because what a chunk paints also depends on which strokes THIS
## crew has been told about (see [method _segment_wants]) -- a thing that changes without any earth
## moving. [member _knowledge_age] is what makes that structurally impossible to get wrong rather
## than a list of callers somebody has to remember to extend.
var _committed_field: Array[Dictionary] = []
## Bumped whenever what a crew knows changes, so a cached committed field built under the old
## answer cannot be mistaken for one built under the new. Per plane, because knowledge is.
var _knowledge_age: Array[int] = []
## Chunks whose triangles have moved since the physics engine was last told about them.
##
## KEPT AS A SET RATHER THAN ACTED ON IMMEDIATELY, because a growing carve re-contours on every step
## and only hands the result to physics every quarter metre (see [constant CARVE_COLLIDE_STEP]). The
## chunks it moved in between still have to be caught up, and the dirty list they came from has been
## cleared by then -- so the debt is recorded here and settled by the next commit that collides.
var _stale_collision: Array[Dictionary] = []
var _floor_materials: Array[StandardMaterial3D] = []
var _wall_materials: Array[StandardMaterial3D] = []
var _rock_materials: Array[StandardMaterial3D] = []
var _bedrock_materials: Array[StandardMaterial3D] = []
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
		_standing_at.append({})
		_chunk_shapes.append({})
		_stale_collision.append({})
		_committed_field.append({})
		_knowledge_age.append(0)
		_mark_nodes.append({})
		_cells.append({})
		_shafts.append({})
		_rock.append({})
		_rock_bodies.append([])
		_rock_owner.append({})
		_rock_near.append({})
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
		_rock_materials.append(_make_rock_material(rock_color))
		_bedrock_materials.append(_make_rock_material(bedrock_color))

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
		# NO SHADOW FROM THE EARTH ITSELF. A plane's geometry is only ever drawn while you are
		# standing in it, and down there the sun does not reach and the lamps cast none by
		# deliberate choice (see [method _rebuild_lamps]) -- so every triangle of floor, wall,
		# stone and lump was being drawn into the directional light's shadow cascades to change
		# nothing whatever. Photographed with and without: the two frames are the same picture.
		#
		# AND IT IS FOUR FIFTHS OF THE UNDERGROUND FRAME. The cascades redraw this geometry four
		# more times, so a hundred thousand triangles of corridor came to half a million primitives
		# -- on a mesh that also grows for every metre anybody digs, all match.
		floor_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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
		wall.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(wall)
		_walls.append(wall)

		var stone := MeshInstance3D.new()
		stone.name = "Rock%d" % plane
		stone.position = Vector3(0.0, plane_y(plane), 0.0)
		stone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(stone)
		_rock_faces.append(stone)

		var hard := MeshInstance3D.new()
		hard.name = "Bedrock%d" % plane
		hard.position = Vector3(0.0, plane_y(plane), 0.0)
		hard.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(hard)
		_bedrock_faces.append(hard)

		# The stone that stands PROUD of this layer's dirt: the top of every rock tall enough to
		# break the ground above it, drawn as real lumps. Two surfaces because there are two grades
		# and the colour is what a player reads them by -- see [method _rebuild_rock_lumps].
		var lumps := MeshInstance3D.new()
		lumps.name = "RockLumps%d" % plane
		lumps.position = Vector3(0.0, plane_y(plane), 0.0)
		lumps.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(lumps)
		_rock_lumps.append(lumps)

		var hard_lumps := MeshInstance3D.new()
		hard_lumps.name = "BedrockLumps%d" % plane
		hard_lumps.position = Vector3(0.0, plane_y(plane), 0.0)
		hard_lumps.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(hard_lumps)
		_bedrock_lumps.append(hard_lumps)

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
		# No shape here: they are made one per chunk, on the first dig that puts a triangle in one.
		# See [member _chunk_shapes].
		_bodies.append(body)

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
## this decides whether there is anything to be gained by digging, and stone is the one thing you
## can point at all day and never move. A stroke whose only unopened part is rock is refused for
## being rock (see [method dig_segment]), and it must not be offered on the way there either.
##
## `[REVISED]` AND IT IS ASKED AT THE POINT NOW, WHICH IS THE FIX FOR DIGGING INSIDE A ROCK. The old
## test was "is this sample's CELL flagged as rock", which is a square answer to a question the
## earth stopped answering in squares: it refused perfectly good ground in the open part of a cell
## a seam merely clipped, and -- much worse -- said nothing at all about the part of a stroke's
## body that reached past the cell boundary into stone. A corridor run alongside a seam took a bite
## out of it, every time, and the only way to notice was to look at the wall.
##
## SWALLOWED ISLANDS COUNT AS NOT EARTH FOR THE SAME REASON. A scrap the contour has already opened
## (see [member island_max_span]) still measures as solid against the strokes, because no stroke
## went through it -- so asked of the segments alone this says there is ground there to take out,
## the dig is allowed, and the player spends a stroke on a chamber floor and watches nothing happen.
## Which is the very complaint the cull exists to answer, moved one step along.
## `except` is a stroke whose own carve is to be ignored; see [method opens_ground].
func _is_earth(plane: int, point: Vector2, except: int = -1) -> bool:
	var cell := world_to_cell(Vector3(point.x, 0.0, point.y))
	if _is_stone(plane, point):
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


## Is this exact spot permanent -- a rock body, or ground a boulder has shut?
##
## THE ONE PREDICATE FOR "THIS WILL NEVER OPEN", and having exactly one is the point. There are two
## kinds of permanent earth in this game and they are stored differently for good reasons -- a
## boulder shuts whole cells of plane 1 because it is a thing standing ON those cells, and a rock
## body is a shape in the earth -- but nothing asking the question cares which it met. Every place
## that used to read `_rock[plane].has(cell)` and mean "is there stone here" reads this instead.
func _is_stone(plane: int, point: Vector2) -> bool:
	var cell := world_to_cell(Vector3(point.x, 0.0, point.y))
	# A boulder: the whole square is shut, exactly as it always was. Told apart from a rock body's
	# derived cells by the owner book -- see `_rock`.
	if _rock[plane].has(cell) and int(_rock_owner[plane].get(cell, -1)) < 0:
		return true
	return rock_depth(plane, point) > 0.0


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
##
## `plane` IS FOR THE STONE, and -1 asks the question without it. A stroke run alongside a rock has
## a body that reaches into cells the rock is standing in, and claiming those would put a graph node
## -- a place a bot will plan to walk to -- inside solid stone. Callers that are asking about the
## STROKE rather than about the ground (what does this cut back onto, which shafts go with it when
## it is forgotten) pass -1 and get the old answer.
func _segment_cells(id: int, plane: int = -1) -> Array[Vector2i]:
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
			if _probe_cell(plane, cell, a, b)[1] <= -STANDING_CLEARANCE:
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
## TIES GO TO THE MIDDLE OF THE SQUARE, and that is not tidiness. Every sample along a straight
## corridor's centreline is exactly as deep as every other, so a plain `<` keeps whichever the loop
## reached first -- the corner of the sampling window, 0.4m off-centre, for every cell of every
## axis-aligned tunnel in the game. Nothing minded while this only had to find somewhere solid to
## drop a ray, and then [TunnelGraph] started handing these out as waypoints and pricing routes off
## the gaps between them: a straight corridor came out as a row of points all shoved to one side,
## and a route down it measured a length no corridor has. The centre is the honest tie-break, and
## it is also the one a player would name.
## `plane` of -1 skips the stone test; see [method _segment_cells].
func _probe_cell(plane: int, cell: Vector2i, a: Vector2, b: Vector2) -> Array:
	var origin := Vector2(float(cell.x) * CELL, float(cell.y) * CELL)
	var along := b - a
	var length_squared := along.length_squared()
	var best := 1000.0
	var closest := INF
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
			# STONE IS NOT SOMEWHERE TO STAND, and it is rejected sample by sample rather than cell
			# by cell. A rock is a shape now, so a cell can be part stone and part corridor -- and
			# both halves of that are real: the open half is a place a mouse walks and the graph
			# must know about, and the stone half is a place a waypoint must never land.
			if plane >= 0 and rock_depth(plane, point) > 0.0:
				continue
			var distance := TunnelContour.segment_distance(point, a, b, SEG_HALF_WIDTH)
			var gap := point.distance_squared_to(origin)
			# A centimetre of depth is the width of the tie: below that the two samples are the
			# same spot as far as anything downstream can tell, and the nearer one is better.
			if distance < best - 0.01 or (distance < best + 0.01 and gap < closest):
				best = minf(best, distance)
				closest = gap
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
	# REMEMBERED, because the routing asks this of the same cells over and over between one stroke
	# and the next. See [member _standing_at] for what it cost before and what drops it again.
	if plane >= 0 and plane < _standing_at.size():
		var known: Variant = _standing_at[plane].get(cell)
		if known != null:
			return known as Vector3
	var best := 1000.0
	var at := Vector2(float(cell.x) * CELL, float(cell.y) * CELL)
	for id: int in segments_in_cell(plane, cell):
		var probe := _probe_cell(plane, cell, segment_origin(id), segment_end(id))
		if (probe[1] as float) < best:
			best = probe[1]
			at = probe[0]
	var here := Vector3(at.x, plane_y(plane), at.y)
	if plane >= 0 and plane < _standing_at.size():
		_standing_at[plane][cell] = here
	return here


## Could a mouse walk from here to there in a straight line, without leaving the tunnel?
##
## WHAT ADJACENCY USED TO BE ASSUMED TO MEAN, and the assumption that off-grid digging broke. Two
## cells were connected if they shared a face, because a corridor was a run of whole squares and a
## shared face was a doorway. Neither half of that survives: a stroke at 30 degrees claims a chain
## of cells that touch only at their CORNERS -- perfectly walkable, no shared face anywhere -- and
## it also clips cells whose far side is still solid, so a shared face can now have a metre of earth
## standing in it. The old test was wrong in both directions at once, and the two failures look
## completely different in play: a bot that will not follow you down a diagonal corridor, and a bot
## that walks into a wall and grinds against it.
##
## SO CONNECTIVITY IS ASKED OF THE EARTH INSTEAD OF THE GRID. This is the whole of it -- the graph
## above (see [TunnelGraph]) is nothing but this question asked of every pair of neighbouring cells.
##
## AND IT IS THE BOT'S OWN MOVEMENT MODEL, stated once. Underground a bot heads straight at the next
## waypoint -- there is no navmesh down here and the graph is expected to have done the routing (see
## `bot.gd::_next_step`) -- so "there is an edge between these two cells" and "walking straight
## between these two points works" have to be the same claim, or the route is a promise the walk
## cannot keep. Asking exactly the question the mouse will ask is what makes them the same claim.
##
## ASKED OF THE FIELD, NOT OF THE STROKES, and that was the second answer rather than the first.
## Measuring against the strokes is the obvious thing and it is a SECOND MODEL of the earth: the
## field has two more rules applied to it (the island cull and the thin-earth pass -- see
## [member island_max_span], [member earth_min_thickness]) and the walls, the floor and the
## collision trimesh are all built from the field AFTER they have run. A tunnel measured from the
## strokes is therefore the tunnel as it was before the world finished deciding what it looked
## like, and the two disagree in exactly the places those rules bite.
##
## THE CASE THAT FORCED IT, because it is not a corner case. Dig a corridor square-on at another
## one and the last stroke you are allowed lands its rounded end exactly tangent to the far
## corridor's wall -- they touch at a single point, there is no earth left between them for another
## stroke to take, and measured off the strokes the doorway is zero wide. The thin-earth pass then
## shaves the wedge either side of that point away and leaves a half-metre opening a mouse walks
## straight through. Off the strokes the graph refuses a junction the player is using; off the field
## it agrees with the floor.
func walkable_between(plane: int, from: Vector2, to: Vector2) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT:
		return false
	var span := from.distance_to(to)
	var steps := maxi(1, ceili(span / WALK_SAMPLE))
	for i in range(steps + 1):
		if not _stands_at(plane, from.lerp(to, float(i) / float(steps))):
			return false
	return true


## Is there room for a mouse to stand at this exact spot?
##
## ASKED AS "IS THERE EARTH WITHIN A BODY'S REACH", NOT AS "HOW DEEP IS IT HERE", and the difference
## is the one property the field does not have. The field is the MAXIMUM of one signed distance per
## stroke, which puts its zero crossing exactly where the tunnel's edge is -- a point is inside the
## union precisely when some capsule contains it -- and makes the number at any other point an
## UNDER-estimate of how far the nearest wall really is. Two parallel strokes laid side by side meet
## along a seam their own distances both call zero, and the depth reading down that seam is nothing
## while the ground either side of it is wide open. A chamber dug as adjacent runs is nothing but
## seams, so a depth test refuses to walk across the middle of a room.
##
## Sampling a ring instead only ever asks the field the question it answers exactly: inside, or not.
##
## THE DEEP CASE STILL SHORT-CIRCUITS, because it is almost every case -- anywhere the reading is
## already a body's width there is no ring worth taking.
func _stands_at(plane: int, point: Vector2) -> bool:
	# A barricade is a collider dropped into an otherwise open cell (see [method block_cell]): it
	# moves no earth, so the field has no idea it is there. It has to be asked here rather than left
	# to the graph dropping the cell, because a diagonal step between two open cells passes through
	# the corner of two others and one of those can be the one holding the boulder.
	if is_blocked(plane, world_to_cell(Vector3(point.x, 0.0, point.y))):
		return false
	var here := TunnelContour.decode(_field_at(plane, point))
	if here > 0.0:
		return false
	if here <= -WALK_CLEARANCE:
		return true
	for i in range(WALK_RING):
		var around := TAU * float(i) / float(WALK_RING)
		var at := point + Vector2(cos(around), sin(around)) * WALK_CLEARANCE
		if TunnelContour.decode(_field_at(plane, at)) > 0.0:
			return false
	return true


## The dug field at a point, interpolated the way the contour interpolates it.
##
## Solid earth wherever nothing has been contoured, which is the honest answer for a chunk nobody
## has ever dug in and the safe one for a chunk waiting on a rebuild.
func _field_at(plane: int, point: Vector2) -> float:
	if plane < 0 or plane >= PLANE_COUNT:
		return 0.0
	var fx := point.x * float(TunnelContour.TEXELS_PER_METRE) + float(FIELD_HALF_TEXELS)
	var fy := point.y * float(TunnelContour.TEXELS_PER_METRE) + float(FIELD_HALF_TEXELS)
	var gx := floori(fx)
	var gy := floori(fy)
	if gx < 0 or gy < 0 or gx + 1 >= FIELD_TEXELS or gy + 1 >= FIELD_TEXELS:
		return 0.0
	var tx := fx - float(gx)
	var ty := fy - float(gy)
	return lerpf(
		lerpf(_texel(plane, gx, gy), _texel(plane, gx + 1, gy), tx),
		lerpf(_texel(plane, gx, gy + 1), _texel(plane, gx + 1, gy + 1), tx),
		ty
	)


## One stored sample, found through the chunk that holds it.
##
## Chunks overlap by a row and a column on purpose -- a chunk keeps `CHUNK_TEXELS + 1` samples each
## way, so the texel on a border belongs to both neighbours and reads the same from either. That is
## the same spare sample that stops a seam of missing wall appearing on every chunk edge, being
## useful for a second reason.
func _texel(plane: int, gx: int, gy: int) -> float:
	var n := TunnelContour.CHUNK_TEXELS
	var cx := mini(gx / n, FIELD_CHUNKS - 1)
	var cy := mini(gy / n, FIELD_CHUNKS - 1)
	var cached: Variant = _chunk_cache[plane].get(cy * FIELD_CHUNKS + cx)
	if cached == null:
		return 0.0
	var field: PackedFloat32Array = (cached as Dictionary)["field"]
	return field[(gy - cy * n) * (n + 1) + (gx - cx * n)]


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
		# The strokes near this cell have changed, so where a mouse stands in it may have too.
		_standing_at[plane].erase(cell)
	var fresh: Array[Vector2i] = []
	for cell: Vector2i in _segment_cells(id, plane):
		if not _cells[plane].has(cell):
			_cells[plane][cell] = true
			fresh.append(cell)
	_touch(plane, id)
	return fresh


## The reverse: take a segment out, and report the cells that stopped being dug entirely.
func _vacate(plane: int, id: int) -> Array[Vector2i]:
	# THE INDEX FIRST, so that the standing test below cannot see the stroke being removed.
	for cell: Vector2i in _near_cells(id):
		_standing_at[plane].erase(cell)
		var here: Variant = _cell_segments[plane].get(cell)
		if here == null:
			continue
		var users := here as Dictionary
		users.erase(id)
		if users.is_empty():
			_cell_segments[plane].erase(cell)

	var emptied: Array[Vector2i] = []
	for cell: Vector2i in _segment_cells(id, plane):
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
		var reach: float = _probe_cell(plane, cell, segment_origin(id), segment_end(id))[1]
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
##
## `[REVISED]` **IT NO LONGER DROPS THE CACHED COMPOSITION, and there is no `carving` flag saying
## when not to.** That flag was one caller declaring "the committed strokes have not moved", which
## made every OTHER caller declare the opposite -- so a commit, whose strokes had not moved either
## but for one arrival, threw away nine windows and repaid a full walk of every stroke in each.
## Whether a composition can be kept is now derived from the ids it was built from rather than
## announced by whoever dirtied it (see [member _committed_field]), which is both cheaper and the
## kind of rule that cannot be got wrong by a caller who has not read this comment.
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


## Clear ground between two rocks, in metres. A stride and a bit: wider than a corridor, so the gap
## between two lumps is somewhere a stroke can actually be threaded rather than a crevice the
## field's own thinning rule would close before anybody got through it.
## `[REVISED]` DOWN FROM 1.4 WITH THE ROCKS. The gap has to stay wide enough to thread a stroke
## through -- that is what it is for -- but a metre is a corridor's full width, and at the old
## figure a plane of the new small rocks could not be packed densely enough to meet any coverage
## worth having: every candidate landed inside somebody's ring and the generator ran out of tries.
const ROCK_SPACING: float = 1.0

## How far a drawn lump is sunk below the dirt it comes through, in metres.
##
## A rock's mesh is built standing on its own base, so without this the base sits exactly on the
## ground plane -- and at this camera angle a stone resting on a surface with no part of it below
## the surface reads as a prop dropped on top of the map rather than as something coming out of it.
## A finger's depth is enough to hide the join from every angle the camera can reach.
const LUMP_SKIRT: float = 0.06

## How much of a lobe's radius the lump above ground is drawn at.
##
## UNDER ONE, because what breaks the surface is the CAP of a stone and a cap is narrower than the
## body it is cut from. Drawn at the full radius, a rock poking two centimetres out of the ground
## comes out as a broad flat disc of stone the width of the whole lobe -- which reads as a paving
## slab, and is the failure the cap sheet had. Narrowed, the same rock is a knuckle of stone in the
## dirt, and a rock standing well proud of the ground still shows most of its width because the
## lump is widest around its own middle.
const LUMP_SPREAD: float = 0.72



## Lay the stone. Once, at startup, per plane, from a seed.
##
## SEEDED AND PER-PLANE, which are the two things that matter. Seeded, because a map you cannot
## replay is a map you cannot learn (GDD section 8 wants layouts to be a recipe plus a seed),
## because a bug that only happens on one layout is a bug you can only reproduce by luck, and
## because it is what lets the stone cross a network without a byte of geometry on the wire. Per
## plane, because rock in the same place on every layer is a flat maze drawn three times -- the
## point of section 3's obstructions is that going AROUND one may mean going down.
##
## AIMED AT AN AREA RATHER THAN AT A COUNT, which is what keeps `rock_density` meaning the same
## thing it always did while the objects underneath it changed from tiles to boulders. A plane is
## rocky by the fraction of its ground that is stone, not by how many lumps that took.
func _generate_rock() -> void:
	if rock_density <= 0.0:
		return

	for plane in range(1, PLANE_COUNT):
		var rng := RandomNumberGenerator.new()
		# A different stream per plane, derived from one dial. Sharing the generator across planes
		# would work too, but then changing plane 1's density would silently relayout planes 2 and
		# 3 as well, and every screenshot of the deep layers would stop being comparable.
		rng.seed = rock_seed + plane * 7919

		var span := float(half_extent_cells) * CELL
		var ground := (span * 2.0 + CELL) * (span * 2.0 + CELL)
		var wanted := ground * (rock_density + rock_density_deeper * float(plane - 1))
		var covered := 0.0
		var attempts := 0
		# Capped on attempts rather than run until satisfied: a dense plane with a big nest
		# clearance and a spacing rule can simply run out of room, and a generator that spins
		# looking for a spot that is not there is a startup that never finishes. `[REVISED]` Raised
		# with the shrink -- the same coverage in rocks a third the radius is most of an order of
		# magnitude more of them, and each one is a fresh draw that may land inside a neighbour's
		# ring. The first version stopped at four hundred and quietly under-delivered every density
		# by a third, which is the kind of miss that reads as the dial not working.
		while covered < wanted and attempts < 12000:
			attempts += 1
			# `[REVISED]` DEEPER IS ROCKIER, AND NO LONGER CHUNKIER -- the size ramp has been taken
			# out, and it is worth saying why it was ever there. It existed because a plane
			# SATURATES: at 16% coverage in metre-radius lumps, past a certain count every new one
			# lands inside somebody's spacing ring and the generator runs out of tries with the
			# target unmet, so the deep planes had to grow bigger rocks to hit their number at all.
			#
			# At the sizes and densities rock comes in now there is no saturation to work around --
			# and the ramp had quietly inverted the thing it was there to serve. Bigger rocks means
			# FEWER of them, and a corridor is stopped by a rock whatever its size, so plane 3 came
			# out with longer clear runs than plane 1 despite carrying nearly twice the stone.
			# Measured: 6.25 metres median against 5.25. "Deeper is harder" was true of the
			# percentage and false of the digging, which is the only place a player meets it.
			# SKEWED SMALL, WHICH IS WHAT MAKES A WIDE RANGE USABLE. Drawn uniformly, half of every
			# plane's rocks come out in the top half of the range and the map is back to being
			# districts. Squaring the draw puts most rocks near the bottom of the range and leaves
			# a handful at the top, which is both what a field of stones looks like and what the
			# rest of the design needs: see `rock_span` for why the big end has to exist at all.
			var roll := rng.randf()
			var size := lerpf(rock_span.x, rock_span.y, roll * roll)
			var at := Vector2(
				rng.randf_range(-span, span), rng.randf_range(-span, span)
			)
			var can_break := rng.randf() < rock_breakable_fraction
			var rock := RockBody.grow(plane, at, size, can_break, rng)
			if not _rock_fits(rock):
				continue
			rock.index = _rock_bodies[plane].size()
			_rock_bodies[plane].append(rock)
			_register_rock(rock)
			# MEASURED IN CELLS ACTUALLY CLAIMED, not as a disc of the outer reach. A lobed rock
			# fills well under the circle that contains it, so pricing it at its reach counted
			# about a third more ground than there is stone on -- which made `rock_density` a dial
			# whose number bore no relation to what a player walks past.
			covered += float(rock.cells(CELL, half_extent_cells).size()) * CELL * CELL

		_spawn_breakers(plane)
		_rebuild_rock_lumps(plane)


## May this rock stand where it has grown?
##
## THE NEST RULE IS THE LOAD-BEARING ONE, and it is measured to the stone's outer reach rather than
## to its centre -- a three-metre lump whose middle is just outside the clearance still puts rock
## inside it. A crew whose ground is stone to the horizon cannot get underground at home, and
## because the layout is seeded that would happen in exactly the same place every single match,
## which reads as the map being broken rather than as a hard start.
##
## AND THEY DO NOT TOUCH EACH OTHER. Two overlapping rocks read as one bigger rock with a seam in
## it, and if one is breakable and the other is not the player is looking at a single object that
## is half shiftable -- which is a rule nothing on screen can express. The gap between two rocks is
## also where the interesting digging is, exactly as it is between two boulders on the lawn.
func _rock_fits(rock: RockBody) -> bool:
	var reach := rock.reach()
	var limit := float(half_extent_cells) * CELL - reach
	if absf(rock.centre.x) > limit or absf(rock.centre.y) > limit:
		return false
	if is_inside_tree() and Nest.blocks(get_tree(), rock.centre, rock_nest_clearance + reach):
		return false
	for other: Variant in _rock_bodies[rock.plane]:
		if other == null:
			continue
		var near := other as RockBody
		if rock.centre.distance_to(near.centre) < reach + near.reach() + ROCK_SPACING:
			return false
	return true


## Put a rock into the coarse indexes: the cells it fills, and the cells it comes near.
##
## BOTH ARE DERIVED AND BOTH ARE REBUILT WHOLE when a lobe goes, rather than patched. A rock that
## has lost a bite covers different cells and reaches a different distance, and the difference
## between "recompute the two dictionaries for this one rock" and "work out the delta" is a few
## dozen cells against a class of bug where a broken rock keeps blocking a shaft.
func _register_rock(rock: RockBody) -> void:
	var plane := rock.plane
	# A sample inside stone is not somewhere to stand (see [method _probe_cell]), so a rock arriving
	# moves the answer for every cell it reaches. Dropped a plane at a time -- see [member
	# _standing_at] for why this one is not cell-accurate.
	_standing_at[plane].clear()
	for cell: Vector2i in rock.cells(CELL, half_extent_cells):
		_rock[plane][cell] = true
		_rock_owner[plane][cell] = rock.index
	var box := rock.bounds()
	var low := world_to_cell(Vector3(box.position.x, 0.0, box.position.y))
	var high := world_to_cell(Vector3(box.end.x, 0.0, box.end.y))
	for y in range(low.y - 1, high.y + 2):
		for x in range(low.x - 1, high.x + 2):
			var cell := Vector2i(x, y)
			var here: Variant = _rock_near[plane].get(cell)
			if here == null:
				here = []
				_rock_near[plane][cell] = here
			(here as Array).append(rock.index)


## And take it out again, before it is put back changed or dropped entirely.
func _unregister_rock(rock: RockBody) -> void:
	var plane := rock.plane
	# The other half of the pair in [method _register_rock]: stone leaving frees ground to stand on
	# just as surely as stone arriving takes it away.
	_standing_at[plane].clear()
	for cell: Vector2i in _rock_owner[plane].keys():
		if int(_rock_owner[plane][cell]) == rock.index:
			_rock_owner[plane].erase(cell)
			# A boulder on the lawn writes `_rock` without an owner, so only owned cells go -- and
			# the owner test above is exactly that guard.
			_rock[plane].erase(cell)
	for cell: Vector2i in _rock_near[plane].keys():
		var here: Array = _rock_near[plane][cell]
		here.erase(rock.index)
		if here.is_empty():
			_rock_near[plane].erase(cell)


## A hittable target for each breakable rock, so a Brute has something to swing at.
##
## A NODE WITH NO COLLIDER AND NO MESH, which is worth being explicit about because every other
## breakable thing in this game has both. The stone is already drawn -- it is the wall the contour
## wrapped round it -- and it is already solid, because that same wall is in the collision trimesh.
## What is missing is only the one thing a shape in a distance field cannot be: something in
## `Breakable.GROUP` for the swing to find. See underground_rock.gd.
##
## LOADED BY PATH RATHER THAN NAMED, AND THAT IS A CYCLE BREAK. `UndergroundRock` extends
## `Breakable`, which is written against `Mouse`, which is written against this file -- so naming
## the class here closes a ring of four and GDScript refuses to compile any of them, with an error
## that names one file and blames an identifier that is perfectly well declared. This file is the
## honest place to break the ring: it is the one that does not need the type, only the constructor.
## Same trick, and the same reason, as the shader loads elsewhere in this file.
func _spawn_breakers(plane: int) -> void:
	var breaker: GDScript = load("res://scripts/maps/underground_rock.gd") as GDScript
	if breaker == null:
		push_warning("rock: no breaker script -- breakable rock could not be broken")
		return
	for entry: Variant in _rock_bodies[plane]:
		var rock := entry as RockBody
		if rock == null or not rock.breakable:
			continue
		breaker.call("place", self, rock)



## How far into stone a point is, in metres. Zero or less is earth.
##
## THE EXACT QUESTION EVERYTHING ABOUT DIGGING NOW ASKS, and the reason it can be asked at all. The
## old cell test could only answer at the resolution of a square, which is eight times coarser than
## the field the earth is actually stored in -- so a stroke either lost a whole cell it had every
## right to or ate a bite of stone it had none.
##
## Bucketed by cell, so a plane with two dozen rocks on it costs one dictionary lookup and two or
## three distance tests rather than a walk over every rock. This is called once per texel of every
## chunk rebuild that touches stone, so the constant matters.
func rock_depth(plane: int, point: Vector2) -> float:
	if plane < 0 or plane >= PLANE_COUNT:
		return -1000.0
	var near: Variant = _rock_near[plane].get(world_to_cell(Vector3(point.x, 0.0, point.y)))
	if near == null:
		return -1000.0
	var deepest := -1000.0
	for i: int in (near as Array):
		var rock := _rock_bodies[plane][i] as RockBody
		if rock == null:
			continue
		deepest = maxf(deepest, rock.depth(point))
	return deepest


## Which rock holds this point, or null. What the wall material and the swing both ask.
func rock_holding(plane: int, point: Vector2) -> RockBody:
	if plane < 0 or plane >= PLANE_COUNT:
		return null
	var near: Variant = _rock_near[plane].get(world_to_cell(Vector3(point.x, 0.0, point.y)))
	if near == null:
		return null
	for i: int in (near as Array):
		var rock := _rock_bodies[plane][i] as RockBody
		if rock != null and rock.depth(point) > 0.0:
			return rock
	return null


## Every rock still standing on a plane. For the audits, the breakers and anything drawing a layout.
func rock_bodies(plane: int) -> Array:
	var out: Array = []
	if plane < 0 or plane >= PLANE_COUNT:
		return out
	for entry: Variant in _rock_bodies[plane]:
		if entry != null:
			out.append(entry)
	return out


func rock_body(plane: int, index: int) -> RockBody:
	if plane < 0 or plane >= PLANE_COUNT:
		return null
	if index < 0 or index >= _rock_bodies[plane].size():
		return null
	return _rock_bodies[plane][index] as RockBody


## Take one bite out of a breakable rock: the Brute's swing, landed.
##
## THE EARTH REOPENS IMMEDIATELY, before any debris has finished falling, exactly as a barricade
## reopens its corridor on the swing that breaks it. A Brute who has just earned a metre of ground
## must not be stopped by stone that is visibly in pieces.
##
## RETURNS WHETHER THE ROCK IS FINISHED, so the node standing in for it knows whether to go too.
func break_rock_lobe(plane: int, index: int, at: Vector2) -> bool:
	# THE SAME GUARD EVERY OTHER WORLD EDIT CARRIES, and it belongs here for the reason `_puppet`'s
	# own note gives: refusing at the state is what makes it structurally impossible for a client to
	# change the earth, rather than depending on every caller remembering to ask.
	if _puppet:
		return false
	var rock := rock_body(plane, index)
	if rock == null or not rock.breakable:
		return true
	var lobe := rock.nearest_lobe(at)
	if lobe < 0:
		return true
	var box := RockBody.lobe_bounds(rock.lobes[lobe], 0.0)

	_unregister_rock(rock)
	rock.drop_lobe(lobe)
	var gone := rock.is_gone()
	if gone:
		_rock_bodies[plane][index] = null
	else:
		_register_rock(rock)

	# The field around the bite is a different shape now, so every chunk it could have written has
	# to re-contour. Grown by the cull's reach for the same reason a stroke's touch is: opening
	# ground can pinch off -- or free -- a scrap of earth a chunk away.
	_touch_box(plane, box)
	_rebuild_walls(plane)
	# Cells the stone was standing in may be standable now. Nothing else re-derives them, because
	# nothing else changes the earth without a stroke being involved.
	_reclaim(plane, box)
	# THE LUMPS FOLLOW THE SHAPE. A rock that has lost a lobe is a different silhouette above the
	# ground as well as below it, and rebuilding the plane's batch is the only way to say so --
	# there is no per-lobe mesh to hide, deliberately, because one draw call for a plane's stone is
	# worth more than the ability to edit it in place.
	_rebuild_rock_lumps(plane)
	rock_changed.emit(plane)
	return gone


## Mark every chunk overlapping a square as needing re-contouring. The rock's equivalent of
## [method _touch_span], and grown by the same reach for the same reason.
func _touch_box(plane: int, box: Rect2) -> void:
	var reach := TunnelContour.TEXEL * 2.0 + float(_cull_pad()) * TunnelContour.TEXEL
	var low := _chunk_at(box.position - Vector2(reach, reach))
	var high := _chunk_at(box.end + Vector2(reach, reach))
	for cy in range(low.y, high.y + 1):
		for cx in range(low.x, high.x + 1):
			if cx < 0 or cy < 0 or cx >= FIELD_CHUNKS or cy >= FIELD_CHUNKS:
				continue
			var key := cy * FIELD_CHUNKS + cx
			_dirty_chunks[plane][key] = true
			# A rock has come or gone, so the earth these chunks were composed from has changed.
			_committed_field[plane].erase(key)


## Ground that stone was standing in, given back to whichever strokes already reach it.
##
## WHY THIS IS NOT AUTOMATIC. `_cells` is a claim about where a mouse can STAND, and it is written
## when a stroke is dug -- at which point the answer included the rock. Take the rock away and the
## strokes have not changed, so nothing would ever re-ask. The corridor would be visibly open, the
## collision would let a mouse walk down it, and the routing graph would refuse to plan through it:
## a bot standing at the mouth of a passage a Brute just opened, declining to use it.
func _reclaim(plane: int, box: Rect2) -> void:
	var low := world_to_cell(Vector3(box.position.x, 0.0, box.position.y)) - Vector2i.ONE
	var high := world_to_cell(Vector3(box.end.x, 0.0, box.end.y)) + Vector2i.ONE
	for y in range(low.y, high.y + 1):
		for x in range(low.x, high.x + 1):
			var cell := Vector2i(x, y)
			if _cells[plane].has(cell) or not in_bounds(cell):
				continue
			if _segments_standing_in(plane, cell).is_empty():
				continue
			_cells[plane][cell] = true
			# KNOWN TO WHOEVER ALREADY KNEW THE GROUND BESIDE IT, and not through
			# `_learn_tunnel_cell`, whose rules are about a LIVE dig -- it takes a crew and has a
			# junction rule for breaking into an enemy corridor, and neither is what happened here.
			# A rock coming apart brings no new crew to the cell; it widens ground somebody has
			# already cut, so the honest answer is the bits that ground already carries.
			var bits := 0
			for side: Vector2i in SIDES:
				bits |= int(_tunnel_known[plane].get(cell + side, 0))
			_tunnel_known[plane][cell] = bits if bits != 0 else TEAM_BITS
			tunnel_revealed.emit(plane, _tunnel_known[plane][cell])
			cell_opened.emit(plane, cell)


## Earth that will never open, however long you hold the button.
func is_rock(plane: int, cell: Vector2i) -> bool:
	return plane >= 0 and plane < PLANE_COUNT and _rock[plane].has(cell)


## Is this cell shut by a BOULDER -- an object standing on the lawn above it -- as opposed to by a
## rock body in the earth?
##
## The two refuse a dig differently and anything mirroring the dig rule has to tell them apart. See
## [method dig_segment], which is the rule this exists to let the cursor copy.
func boulder_shuts(plane: int, cell: Vector2i) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT:
		return false
	return _rock[plane].has(cell) and int(_rock_owner[plane].get(cell, -1)) < 0


## Is this exact spot open corridor -- somewhere a mouse is physically inside the tunnel?
##
## THE FIELD'S OWN ANSWER, unfiltered by the ring test [method _stands_at] adds. That one asks
## whether there is ROOM for a body here, which is the right question for routing and the wrong one
## for "did the earth open", because a point a centimetre inside a wall fails it either way. This
## is for anything checking the shape of the world against something else's model of it.
func is_open_at(plane: int, point: Vector2) -> bool:
	if plane < 0 or plane >= PLANE_COUNT:
		return false
	return TunnelContour.decode(_field_at(plane, point)) < 0.0


## Is this exact spot stone? The public face of [method _is_stone], for the cursor -- which walks a
## prospective stroke a point at a time and wants the same answer the dig will give.
func is_stone_at(plane: int, point: Vector2) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT:
		return false
	return _is_stone(plane, point)


## The rock that reaches into this cell's square, if any.
##
## LOOSER THAN OWNERSHIP, and that is what makes a reveal work at the edges. `_rock_owner` records
## the cells a rock's middle covers, which is the right index for "may a shaft land here"; running
## a shovel into stone happens in whichever square you were digging in, and a rounded rock clips
## plenty of squares whose centres are earth. Owner first, because it is a dictionary hit and it is
## the common case.
func rock_touching(plane: int, cell: Vector2i) -> RockBody:
	if plane <= 0 or plane >= PLANE_COUNT:
		return null
	var owned := rock_body(plane, int(_rock_owner[plane].get(cell, -1)))
	if owned != null:
		return owned
	var near: Variant = _rock_near[plane].get(cell)
	if near == null:
		return null
	var centre := Vector2(float(cell.x) * CELL, float(cell.y) * CELL)
	for i: int in (near as Array):
		var rock := _rock_bodies[plane][i] as RockBody
		if rock != null and rock.touches_cell(centre, CELL * 0.5):
			return rock
	return null


## Can a Brute shift the stone in this cell?
##
## FOR THE PANEL AS MUCH AS FOR THE RULES. Which rock is breakable is the one thing a player decides
## a route on -- go round, or fetch the class that opens it -- and that decision is made looking at
## the minimap at least as often as looking at the wall.
##
## A CELL A BOULDER SHUT COUNTS AS BREAKABLE, which is not a fudge: there is a rock standing on the
## lawn above it and five Brute swings take it off. The cell is shut by something destructible
## either way, which is exactly what this question means.
func rock_breakable_at(plane: int, cell: Vector2i) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT:
		return false
	var rock := rock_body(plane, int(_rock_owner[plane].get(cell, -1)))
	return true if rock == null else rock.breakable


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
## `[REVISED]` NO `known` FLAG ANY MORE. A boulder used to have to be marked as known-to-everybody
## to tell it apart from a hidden seam; there are no hidden seams now. A rock is either standing
## above the dirt where both crews can see it or it is buried, and that is a fact about the rock
## rather than a fact about who has been told.
func add_rock(plane: int, cell: Vector2i) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT or not in_bounds(cell):
		return false
	# Never over a tunnel somebody already dug. Rock arriving on top of an open corridor would make
	# a cell that is dug AND impassable, which is a state nothing else here handles: the floor is
	# drawn, the graph routes through it, and the dig refuses to reopen it.
	if _cells[plane].has(cell) or _rock[plane].has(cell):
		return false
	_rock[plane][cell] = true
	rock_changed.emit(plane)
	return true


## And rock that stops being rock: a boulder broken up, the earth under it ordinary again.
func remove_rock(plane: int, cell: Vector2i) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT or not _rock[plane].has(cell):
		return false
	# NOT SOMEBODY ELSE'S STONE. This is the boulder's way of giving its cell back, and a boulder
	# never gets one that a rock body already holds -- `boulder_field.gd` asks `is_rock` before
	# placing. The guard is for the day something else calls this: erasing a cell a rock body owns
	# would leave the index disagreeing with the shape, and the shape is what the earth is built
	# from, so the cell would come back the next time the rock was re-indexed and be gone again
	# after that. See [method break_rock_lobe], which is how a rock body's ground is really freed.
	if int(_rock_owner[plane].get(cell, -1)) >= 0:
		return false
	_rock[plane].erase(cell)
	# The face of the seam was drawn in stone by whichever corridors had run up against it, and it
	# is ordinary earth now. Cheap, and only ever on a Brute's last swing.
	_rebuild_walls(plane)
	rock_changed.emit(plane)
	return true


## Take whatever stone is in this cell out of the world entirely -- a whole rock body, or a cell a
## boulder had shut.
##
## SCAFFOLDING, NOT A GAME RULE, and it is worth saying which. Nothing a player does calls this: a
## Brute takes rock apart a lobe at a time through [method break_rock_lobe], and a boulder gives its
## own cell back through [method remove_rock]. This is for the places that need a NAMED COORDINATE
## to be diggable whatever the seed grew there -- the replication audit stands its hidden controls
## at fixed cells, and a generated rock landing on one would make the run fail on the layout rather
## than on the wire.
##
## THE WHOLE ROCK GOES, not the one cell. Erasing a single cell of a body would leave the index
## disagreeing with the shape it is derived from, and the shape is what the earth is built out of --
## so the cell would come back the next time the rock was re-indexed. See [method remove_rock],
## which refuses that for the same reason.
func clear_rock_at(plane: int, cell: Vector2i) -> bool:
	if plane <= 0 or plane >= PLANE_COUNT:
		return false
	var rock := rock_touching(plane, cell)
	if rock == null:
		return remove_rock(plane, cell)
	var box := rock.bounds()
	_unregister_rock(rock)
	_rock_bodies[plane][rock.index] = null
	# The group name written out rather than read off `UndergroundRock.ROCK_GROUP`, for the cycle
	# reason `_spawn_breakers` gives at length: naming that class here is what GDScript refuses to
	# compile. The breaker is freed from out here rather than told, because a rock removed by
	# scaffolding never "broke" -- there is nobody to credit and nothing to throw.
	for node in get_tree().get_nodes_in_group(&"underground_rock"):
		var breaker: Node = node
		if (
			int(breaker.get("plane_index")) == plane
			and int(breaker.get("rock_index")) == rock.index
		):
			breaker.queue_free()
	_touch_box(plane, box)
	_rebuild_walls(plane)
	_reclaim(plane, box)
	_rebuild_rock_lumps(plane)
	rock_changed.emit(plane)
	return true


# ------------------------------------------------------------------------- what a crew knows
#
# `[REVISED]` ROCK USED TO BE HERE, AND DELIBERATELY IS NOT ANY MORE. A seam was hidden information:
# running into one revealed the whole lump to your crew alone, which was recorded per rock, mirrored
# onto cells, drawn as a plate on the ground, sent over the wire and re-drawn on the minimap. All of
# that existed to answer "can this crew see this rock", and the answer is now a property of the rock
# instead of a property of the crew -- it is either tall enough to stand out of the dirt, where
# anybody can see it, or it is buried and nobody can. Five mechanisms replaced by one subtraction;
# see [method _rebuild_rock_lumps].
#
# What is left under this heading is tunnels and shafts, which are genuinely per-crew and stay so.

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
	# WHAT THIS CREW KNOWS HAS MOVED, so no composition of the earth cached under the old answer is
	# safe to reuse -- see [member _knowledge_age]. Measured against dropping it: no difference, and
	# a chunk only re-composes when something dirties it anyway.
	_knowledge_age[plane] += 1
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
## `[REVISED]` A STROKE IS NO LONGER REFUSED FOR TOUCHING ROCK. IT STOPS AT IT. The old rule threw
## the whole metre away if any cell it would have made walkable held stone -- an approximation
## forced by rock being a set of squares, and the note here used to say that stopping short at the
## stone was the better answer and somebody else's job. It is this one's now: the rock is a shape in
## the field (see [RockBody]), so a stroke that runs up against one simply comes out shorter and
## curved round it, which is what an Engineer digging past a boulder should get.
##
## SO THE ONLY THING LEFT TO REFUSE IS A STROKE THAT WOULD OPEN NOTHING AT ALL, and the whole of
## that test is `opens_ground`. What survives is the VOICE: pointing at a rock and holding the
## button has to say why nothing is happening, because ground that refuses to open in silence is
## indistinguishable from a dig control that has stopped working -- the exact lesson the entrance
## key taught this file once already. See [method _rock_in_the_way].
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

	# A BOULDER STILL SHUTS ITS WHOLE SQUARE, and that refusal survives the change of unit because
	# a boulder is not the same kind of obstruction as a rock body. A rock body is a shape IN the
	# earth, so a stroke that meets one stops at it and keeps whatever it opened on the way; a
	# boulder is an object standing ON a cell of the lawn, and what it blocks is the square under
	# it, whole. Letting a stroke take a bite out of that square would open ground beneath a rock
	# that is visibly still sitting there -- and, unlike a rock body, nothing would draw the stone
	# it stopped at, because the boulder's blocking is a fact about the index rather than a shape
	# in the field.
	#
	# ASKED WITHOUT THE PLANE, deliberately. `_segment_cells(id, plane)` drops the cells whose
	# standing room is stone -- which is exactly the set this wants to refuse, so passing the plane
	# would make the loop find nothing and the rule quietly stop existing.
	for cell: Vector2i in _segment_cells(id):
		if _rock[plane].has(cell) and int(_rock_owner[plane].get(cell, -1)) < 0:
			dig_refused.emit("solid rock -- go round it, or go under it")
			return false

	# A stroke that would take no earth out is a no-op, and saying so here rather than only in the
	# controller is what keeps `dig`'s old contract -- "false if it was already dug" -- true for
	# bots and for every audit scenario that builds a network by naming cells twice.
	#
	# AND WHEN THE REASON IS STONE, IT SAYS SO. `opens_ground` counts rock as nothing to be gained,
	# quite correctly, so a stroke aimed squarely at a rock lands here -- and used to return a
	# silent false, leaving a player holding the button on stone with nothing said. The order is
	# reversed from the version this replaces (which tested the stone first and then the ground);
	# it has to be, now that touching rock is legal and only being STOPPED by it is worth a word.
	if not opens_ground(plane, origin, angle):
		if _rock_in_the_way(plane, id):
			dig_refused.emit("solid rock -- go round it, or go under it")
		return false
	var cells := _segment_cells(id, plane)

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


## Is stone the reason this stroke would take nothing out?
##
## ASKED ONLY AFTER `opens_ground` HAS SAID NO, and only to choose what to say. There are three ways
## a stroke can be worth nothing -- it lies inside tunnel that is already open, it lies inside
## ground somebody else is part-way through cutting, or it is pointed at a rock -- and exactly one
## of those is the player's fault and needs telling. Getting it wrong in the safe direction (saying
## nothing when it was rock) leaves the old silent refusal; getting it wrong the other way announces
## rock at somebody digging down their own corridor, which is worse, so this asks for stone at the
## same samples `opens_ground` asked for earth.
func _rock_in_the_way(plane: int, id: int) -> bool:
	var origin := segment_origin(id)
	var direction := angle_direction(segment_angle(id))
	var across := Vector2(-direction.y, direction.x)
	var steps := maxi(2, ceili(SEG_LENGTH / TunnelContour.TEXEL))
	for i in range(steps + 1):
		var spine := origin + direction * (SEG_LENGTH * float(i) / float(steps))
		for offset: float in [0.0, -0.6, 0.6]:
			if _is_stone(plane, spine + across * (SEG_HALF_WIDTH * offset)):
				return true
	return false


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
		if _probe_cell(plane, cell, segment_origin(id), _carve_end(id, along))[1] > -STANDING_CLEARANCE:
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


## Is this a network somebody else decides? For the few things that have to ask rather than simply
## being refused -- see underground_rock.gd, which is a node in a group a client's own swing walks.
func is_puppet() -> bool:
	return _puppet


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
		_bedrock_faces[index].visible = focused
		_rock_lumps[index].visible = focused
		_bedrock_lumps[index].visible = focused
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
	material.set_shader_parameter("dug_grow", rim_grow(plane))
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


## How far past the dug outline the ground over a plane has to be taken back, in metres.
##
## The top of that plane's walls leans away from the outline by exactly this much (see
## [constant TunnelContour.WALL_BEVEL]); ground cut on the outline itself would stand over the
## lean and hide it. Asked of the network rather than read off the constant because it depends on
## how tall the walls of that particular plane are -- plane 0's are nothing.
func rim_grow(plane: int) -> float:
	return TunnelContour.wall_bevel(_wall_top(plane))


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


## Redraw a whole plane's cutaway from scratch, for when WHO IS LOOKING changes.
##
## Recompute each occupied chunk with the same field rules used by digging, then repaint
## its mask. Visibility changes leave the physical floor and collision geometry intact.
##
## `[REVISED]` **AND IT IS NO LONGER WHAT THE FOG CALLS.** A new crew to draw for genuinely changes
## every chunk on the layer, and that is what this is still for. A cell coming into or out of
## SIGHT does not: it changes the verdict on the strokes whose middles are in that one square. The
## fog was calling this from `_publish`, which runs on every physics frame and fires whenever the
## seen set moves by a single cell -- so one mouse walking down a corridor re-contoured all
## forty-odd chunks of plane 1, measured at just over **100ms**, several times a second. See
## [method _remask_cells], which is what the fog calls now.
func _rebuild_mask(plane: int) -> void:
	if plane < 0 or plane >= _mask_images.size():
		return
	_mask_images[plane].fill(Color(0.0, 0.0, 0.0, 1.0))
	# WHO IS LOOKING, OR WHAT THEY CAN SEE, HAS CHANGED -- which is exactly the thing a cached
	# composition cannot notice for itself, because no earth moved. See [member _knowledge_age].
	_knowledge_age[plane] += 1
	for key: int in _chunk_cache[plane]:
		_committed_field[plane].erase(key)
		_rebuild_chunk(plane, key, true)
	_relight(plane)


## The same repaint, for the cells whose visibility actually moved.
##
## REACHING A WHOLE STROKE PAST EACH CELL, because what a cell's sight changes is the verdict on
## every stroke whose MIDDLE lies in it (see [method _segment_wants]) -- and such a stroke reaches
## half its length either side of that middle, plus its own width, plus the distance the field
## rules read from. Short by any of those and a corridor keeps a sliver of lid over it that only
## goes when something else happens to dirty that chunk.
##
## NO `fill`, AND THAT IS THE HALF THAT WOULD BITE. [method _rebuild_mask] blanks the whole cutaway
## texture because it is about to repaint every chunk of it; blanking it here -- where only some
## chunks are rebuilt -- would erase the lid over every corridor that did not change and leave it
## erased until somebody dug there. The texels of a chunk nobody rebuilt are still correct, because
## nothing about that chunk moved.
##
## THE COMMITTED FIELDS ARE LEFT ALONE, unlike the wholesale path. Bumping [member _knowledge_age]
## is enough: a chunk whose strokes are all still shown the same way verifies its entry and keeps
## it, and one whose verdicts moved throws it away by itself. That is the difference between
## re-composing the handful of chunks a crew's sight actually reached and re-composing the layer.
func _remask_cells(plane: int, cells: Array) -> void:
	if plane < 0 or plane >= _mask_images.size() or cells.is_empty():
		return
	_knowledge_age[plane] += 1
	var affected := {}
	var reach := (
		SEG_LENGTH * 0.5 + SEG_HALF_WIDTH + TunnelContour.TEXEL * 2.0
		+ float(_cull_pad()) * TunnelContour.TEXEL
	)
	for cell: Vector2i in cells:
		var at := Vector2(float(cell.x) * CELL, float(cell.y) * CELL)
		var low := _chunk_at(at - Vector2(CELL * 0.5 + reach, CELL * 0.5 + reach))
		var high := _chunk_at(at + Vector2(CELL * 0.5 + reach, CELL * 0.5 + reach))
		for cy in range(low.y, high.y + 1):
			for cx in range(low.x, high.x + 1):
				if cx < 0 or cy < 0 or cx >= FIELD_CHUNKS or cy >= FIELD_CHUNKS:
					continue
				affected[cy * FIELD_CHUNKS + cx] = true
	for key: int in affected:
		_rebuild_chunk(plane, key, true)


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
	# WHICH CELLS MOVED, not merely that the set did. Both directions count: a cell newly seen
	# opens the earth over it, and one forgotten closes it again.
	var moved: Array[Vector2i] = []
	var arriving := {}
	for cell: Vector2i in cells:
		arriving[cell] = true
		if not _glimpsed[plane].has(cell):
			moved.append(cell)
	for cell: Vector2i in _glimpsed[plane]:
		if not arriving.has(cell):
			moved.append(cell)
	_glimpsed[plane].clear()
	for cell: Vector2i in cells:
		_glimpsed[plane][cell] = true
	# The earth opens up; the LAMPS do not follow. A cell you can see is still a cell nobody on
	# your crew hung a light in, and lighting what you glimpse would give the corridor back the
	# inhabited look the darkness was introduced to take away.
	_remask_cells(plane, moved)


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
## `colour` is the stone's own: pale for the rock a Brute can break, dark for bedrock. The faint
## emission is what keeps either readable at the bottom of an unlit corridor, where the only light
## is a lamp several metres back -- without it both grades go to the same near-black and the one
## decision the colours exist to support cannot be made.
func _make_rock_material(colour: Color) -> StandardMaterial3D:
	var material := _make_material(colour)
	material.emission_enabled = true
	material.emission = colour
	material.emission_energy_multiplier = 0.22
	return material


## Draw the world as `team` knows it: the veins they have found, and the corridors they lit.
##
## THE VIEWER IS TOLD TO THE NETWORK RATHER THAN LOOKED UP BY IT, because a network that went
## hunting for "the player" would be a rendering object reaching into the match to find out whose
## side it is on -- and at M7 there is no single answer to that question on a server. One caller,
## one line, and the day this is per-client it is the caller that changes.
##
## ONE CHANNEL FOR EVERY PER-CREW THING THE WORLD DRAWS, which is why this is no longer called
## `show_known_rock`. Rock caps came first and got a name that described that week's feature -- and
## are gone now, but the lesson outlived them: lamps needed the same answer and fog will be next. A second setter would
## have meant two ways to be told who is looking, and the interesting bug -- one of them being told
## and the other not -- would show up as the earth knowing something the light did not.
func show_crew_knowledge(team: int) -> void:
	if team == _view_team:
		return
	_view_team = team
	for plane in range(PLANE_COUNT):
		# Everything anyone had been glimpsing belonged to the crew that was looking a moment ago.
		_glimpsed[plane].clear()
		_rebuild_mask(plane)
	_rebuild_lamps(_focus)
## The stone standing above a plane's dirt: every rock tall enough to break the ground, drawn as
## real lumps of the same shape a barricade and a boulder are made of.
##
## `[REVISED]` THIS REPLACES THE CAP SHEET, AND IT IS A CORRECTION RATHER THAN A NEW FEATURE. What
## used to be here drew a flat plate over the CELLS a crew had learned held rock -- so the one thing
## a player ever saw of a rock from above was its footprint on the dig grid, quantised to whole
## metre squares, in a game where nothing else has been on the grid since digging went off it. A
## lobed three-metre lump came out as fifteen tiles in a staircase. It was also drawn in a colour
## nothing in the world is, hovering two centimetres over the dirt, which is the look of a debug
## overlay and not of a place.
##
## SO THE ROCK IS AN OBJECT NOW AND VISIBILITY IS PHYSICAL. A layer of earth is [constant SPACING]
## thick. A rock taller than that pokes out of the top of it and you can see it from across the
## yard; a rock shorter than that is buried, and the first you know of it is your shovel ringing
## off it. Nothing is painted on the ground and no crew is told anything -- the stone is either
## standing in daylight or it is not, and both crews are looking at the same world.
##
## ONLY THE PART ABOVE THE DIRT IS DRAWN, which is what makes this cheap and what keeps it honest.
## Everything below the surface is already drawn: it is the stone face the contour wrapped round the
## rock the moment somebody dug up to it, cut from the same field, in the same two colours. Modelling
## the buried half as well would put a second description of the rock in the scene that could
## disagree with the first -- and it would be invisible under an opaque lid anyway.
##
## ONE LOBE, ONE LUMP. The rock's shape is a union of discs, so its silhouette above the ground is a
## cluster of stones at those same centres and radii -- which is both a faithful reading of the
## shape and, by luck, exactly what a broken outcrop looks like. A lobe only just reaching the
## surface shows as a pebble; the core of a big rock shows as a boulder.
##
## TWO SURFACES, ONE PER GRADE, so the colour a player reads underground is the colour they read
## from up here. A dark lump means bedrock and means do not fetch the Brute, and that is worth
## knowing before you have spent a dig finding out.
func _rebuild_rock_lumps(plane: int) -> void:
	if plane <= 0 or plane >= _rock_lumps.size():
		return
	var pale := SurfaceTool.new()
	var dark := SurfaceTool.new()
	pale.begin(Mesh.PRIMITIVE_TRIANGLES)
	dark.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pale_count := 0
	var dark_count := 0

	for entry: Variant in _rock_bodies[plane]:
		var rock := entry as RockBody
		if rock == null:
			continue
		var rise := rock.rise_above(SPACING)
		if rise <= 0.0:
			continue
		var surface := pale if rock.breakable else dark

		for i in range(rock.lobes.size()):
			var lobe: Vector3 = rock.lobes[i]
			# SUNK BY ITS OWN SKIRT so there is no seam where the stone meets the dirt. The lump is
			# built standing on its base, so dropping the base below the lid buries the join
			# instead of leaving a ring of daylight under the rock the camera can see through.
			var base := SPACING - LUMP_SKIRT
			# Squatter than the lobe is wide, and deliberately: what is above the ground is the CAP
			# of a stone whose bulk is still in the earth, so a lump as tall as it is broad reads as
			# a rock sitting ON the dirt -- which is a boulder, and boulders mean something else.
			var tall := rise + LUMP_SKIRT
			# SEEDED BY THE LOBE'S PLACE, like every other rock in this game: the same stone always
			# grows the same shape, two lobes of one rock are visibly different, and a screenshot is
			# comparable to the last one.
			var grain := rock_seed + plane * 7919 + rock.index * 131 + i
			RockShell.append_lump(
				surface,
				Vector3(lobe.x, base, lobe.y),
				lobe.z * LUMP_SPREAD,
				tall,
				grain
			)
			if rock.breakable:
				pale_count += 1
			else:
				dark_count += 1

	_rock_lumps[plane].mesh = _commit_lumps(pale, pale_count, _rock_materials[plane])
	_bedrock_lumps[plane].mesh = _commit_lumps(dark, dark_count, _bedrock_materials[plane])
	_rock_lumps[plane].visible = plane == _focus
	_bedrock_lumps[plane].visible = plane == _focus


## A batched lump surface, or null if nothing went into it.
##
## The count is passed rather than asked of the tool, because a SurfaceTool that has had nothing
## added to it cannot be committed and has no way to say so.
func _commit_lumps(surface: SurfaceTool, count: int, material: Material) -> ArrayMesh:
	if count <= 0:
		return null
	surface.generate_normals()
	var mesh := surface.commit()
	if mesh != null and mesh.get_surface_count() > 0:
		mesh.surface_set_material(0, material)
	return mesh


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
## `collide` is whether to hand the result to the physics engine as well as to the renderer. See
## [method _recollide] -- collision is per chunk now, so this no longer costs the whole map.
##
## `[REVISED]` A CARVE PAYS IT EVERY QUARTER METRE RATHER THAN NEVER. The old rule was that a
## growing carve declined collision entirely and the earth you were cutting stayed solid to walk
## into until the stroke landed -- justified on the grounds that the only mouse in a position to
## walk into it was the one standing still cutting it. That stopped being true when carving became
## digging rather than a preview of it: you are meant to press dig and walk forward, and a trench
## you can see through and cannot enter is the same complaint as ground that will not open. See
## [constant CARVE_COLLIDE_STEP].
func _rebuild_walls(plane: int, collide: bool = true) -> void:
	for key: int in _dirty_chunks[plane]:
		_rebuild_chunk(plane, key)
		# Owed to the physics engine whether or not this call is the one that pays -- see
		# [member _stale_collision].
		_stale_collision[plane][key] = true
	_dirty_chunks[plane].clear()

	var floors := PackedVector3Array()
	var walls := PackedVector3Array()
	var stone := PackedVector3Array()
	var bedrock := PackedVector3Array()
	var floor_normals := PackedVector3Array()
	var wall_normals := PackedVector3Array()
	var stone_normals := PackedVector3Array()
	var bedrock_normals := PackedVector3Array()
	for key: int in _chunk_cache[plane]:
		var chunk: Dictionary = _chunk_cache[plane][key]
		floors.append_array(chunk["floors"])
		walls.append_array(chunk["walls"])
		stone.append_array(chunk["stone"])
		bedrock.append_array(chunk["bedrock"])
		floor_normals.append_array(chunk["floor_normals"])
		wall_normals.append_array(chunk["wall_normals"])
		stone_normals.append_array(chunk["stone_normals"])
		bedrock_normals.append_array(chunk["bedrock_normals"])

	_floors[plane].mesh = _commit(floors, floor_normals, _floor_materials[plane])
	_walls[plane].mesh = _commit(walls, wall_normals, _wall_materials[plane])
	_rock_faces[plane].mesh = _commit(stone, stone_normals, _rock_materials[plane])
	_bedrock_faces[plane].mesh = _commit(bedrock, bedrock_normals, _bedrock_materials[plane])

	if collide:
		_recollide(plane)

	_relight(plane)


## Bring the physics engine back in step with the chunks that have moved, and only those.
##
## THE WHOLE POINT IS WHAT IS NOT HERE. A `ConcavePolygonShape3D` cannot be edited: facing one
## throws its tree away and builds another out of every triangle it is handed. Faced per plane, that
## priced a dig at the size of the MAP rather than at the size of the hole -- fifteen milliseconds a
## dig by two hundred strokes, sixteen times a second while anybody carves, and worse every minute
## of the match. Per chunk it is the two to five squares the dig actually moved, and it stays that
## whatever else has been dug.
##
## THE SAME SHAPE RESOURCE, RE-FACED, rather than a fresh one hung on the node -- which is the one
## rule the plane-wide version had and this must keep. Assigning to `shape` takes the old shape off
## the body and puts a new one on, and a mouse standing on the floor during that swap is a mouse
## standing on nothing for a frame, which with no floor below a plane means falling out of the world.
func _recollide(plane: int) -> void:
	for key: int in _stale_collision[plane]:
		var cached: Variant = _chunk_cache[plane].get(key)
		var faces := PackedVector3Array()
		if cached != null:
			faces = (cached as Dictionary)["collision"]
		var shape: CollisionShape3D = _chunk_shapes[plane].get(key)
		if shape == null:
			# A chunk of solid earth has no faces and gets no shape. Most of the map is that, all
			# match, and a body carrying six hundred empty shapes is six hundred things the
			# broadphase has to be told to ignore.
			if faces.is_empty():
				continue
			shape = _new_chunk_shape(plane, key)
		(shape.shape as ConcavePolygonShape3D).set_faces(faces)
	_stale_collision[plane].clear()


## The collider for one chunk, made on the first dig that puts a triangle in it.
func _new_chunk_shape(plane: int, key: int) -> CollisionShape3D:
	var body_shape := ConcavePolygonShape3D.new()
	# Double-sided, so a triangle emitted with the wrong winding still collides. Winding is easy to
	# get backwards and produces a floor you silently fall through, which is a miserable thing to
	# debug for zero benefit on static level geometry.
	body_shape.backface_collision = true
	var shape := CollisionShape3D.new()
	shape.name = "Chunk%d" % key
	shape.shape = body_shape
	_bodies[plane].add_child(shape)
	_chunk_shapes[plane][key] = shape
	return shape


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
func _rebuild_chunk(plane: int, key: int, mask_only: bool = false) -> void:
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

	## Whether any stroke in this window is one the viewing crew must not be shown. Almost always
	## false -- a client is only ever sent its own tunnels -- and when it is false `seen` comes out
	## of the composition identical to `shape`, so the cull can be run once and shared.
	var hidden := false
	var shape := PackedFloat32Array()
	var seen := PackedFloat32Array()

	# THE COMMITTED HALF, COMPOSED ONCE AND KEPT. Everything already dug over this window is a
	# picture that only changes when a stroke does, and re-deriving it is much the most expensive
	# thing a chunk rebuild does -- thirty-odd strokes by a metre of graded distance each, at the
	# density a mid-match corridor network reaches. A carve re-contours its chunks sixteen times a
	# second and moves none of those strokes, so it copies the composition and unions its own
	# growing tip on top. See [member _committed_field] for what drops the entry again.
	var kept: Variant = _committed_field[plane].get(key)
	var book: Dictionary = {} if kept == null else kept as Dictionary
	# The window size, because `_cull_pad` is derived from exported dials that can move in the
	# inspector between one rebuild and the next -- and a field of the wrong width read back as if
	# it were the right one is garbage, silently, everywhere.
	var usable := kept != null and int(book["wide"]) == wide
	# What that entry was composed from: `{id: 1 if this crew is shown it else 0}`.
	var carried: Dictionary = {} if not usable else book["ids"] as Dictionary

	# WHAT IS IN THIS WINDOW NOW, gathered before the cache is judged rather than only once it has
	# missed -- it is a handful of dictionary lookups, and it is what turns "the entry is stale"
	# into "the entry is short by these two strokes". The window's cells plus a ring, because a
	# stroke whose centre is in the next chunk can still reach across the border. `_segment_cells`
	# is conservative in the same direction, so anything whose capsule touches this square is
	# registered in one of these cells.
	var found := {}
	var low := Vector2i(floori(origin.x) - 1, floori(origin.y) - 1)
	var high := Vector2i(ceili(origin.x + extent) + 1, ceili(origin.y + extent) + 1)
	for y in range(low.y, high.y + 1):
		for x in range(low.x, high.x + 1):
			for id: int in segments_in_cell(plane, Vector2i(x, y)):
				found[id] = true

	# A STROKE LEAVING IS THE ONLY THING THAT FORCES A RECOMPOSE. The field is a `max` union, so a
	# stroke arriving is one more `max` over what is already there; a stroke GONE would have to be
	# unpainted, and a max union cannot be undone. Read off the ids rather than announced by
	# whoever moved the earth, so a path that drops a stroke without invalidating anything is still
	# correct here. See [member _committed_field].
	if usable:
		for id: int in carried:
			if not found.has(id):
				usable = false
				break

	# AND THE KNOWLEDGE STAMP IS CHECKED BY ASKING, NOT BY COMPARING COUNTERS. [member
	# _knowledge_age] is one number per PLANE, bumped by every cell any crew learns -- so a single
	# dig invalidated the composition of every chunk on the layer, including the thirty that were
	# nowhere near it. It is kept as the fast path, because when it matches nothing can have
	# changed and there is nothing to ask; when it does NOT match, the entry is worth two dictionary
	# lookups per stroke before it is thrown away, against repainting forty strokes to learn that
	# all forty were unchanged. `_view_team < 0` shows every stroke, so this cannot fire at all on
	# a server.
	if usable and int(book["knowledge"]) != _knowledge_age[plane]:
		for id: int in carried:
			if _segment_wants(plane, id) != (int(carried[id]) != 0):
				usable = false
				break

	var arrived: Array[int] = []
	if usable:
		shape = (book["shape"] as PackedFloat32Array).duplicate()
		seen = (book["seen"] as PackedFloat32Array).duplicate()
		hidden = bool(book["hidden"])
		for id: int in found:
			if not carried.has(id):
				arrived.append(id)
			else:
				found[id] = carried[id]
	else:
		shape.resize(wide * wide)
		seen.resize(wide * wide)
		arrived.assign(found.keys())

	if not usable or not arrived.is_empty():
		var done: Array[Vector2] = []
		var done_to: Array[Vector2] = []
		var done_shown := PackedByteArray()
		for id: int in arrived:
			done.append(segment_origin(id))
			done_to.append(segment_end(id))
			var wanted := _segment_wants(plane, id)
			done_shown.append(1 if wanted else 0)
			found[id] = 1 if wanted else 0
			if not wanted:
				hidden = true
		var painted := _paint_strokes(
			shape, seen, done, done_to, done_shown, wide, wide_x, wide_y, origin, pad
		)
		shape = painted[0]
		seen = painted[1]
		# STORED AS COPIES, so the carve pass below cannot write through into what was kept. Packed
		# arrays are copy-on-write and would in fact fork on the first assignment, but a cache whose
		# safety rests on that is a cache that breaks the day somebody reads it differently.
		_committed_field[plane][key] = {
			"shape": shape.duplicate(),
			"seen": seen.duplicate() if hidden else shape.duplicate(),
			"hidden": hidden,
			"wide": wide,
			"knowledge": _knowledge_age[plane],
			# What the composition above actually contains, and what each stroke was shown as --
			# which is what lets the next rebuild add to it rather than start again.
			"ids": found,
		}
	elif int(book["knowledge"]) != _knowledge_age[plane]:
		# Verified above and unchanged, so re-stamp it -- otherwise every rebuild from here re-asks
		# the same question of the same strokes and gets the same answer.
		book["knowledge"] = _knowledge_age[plane]

	# Ends the strokes have been cut to, so a carve unions in exactly like a finished stroke and the
	# corridor has no idea which of the two it grew from.
	var strokes: Array[Vector2] = []
	var reaches: Array[Vector2] = []
	var shown := PackedByteArray()
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
	var box := Rect2(origin, Vector2(extent, extent))
	var carve_reach := SEG_HALF_WIDTH + maxf(TunnelContour.SDF_RANGE, _thin_reach())
	for id: int in _carving[plane]:
		var carve: Dictionary = _carving[plane][id]
		var from := segment_origin(id)
		var to := _carve_end(id, carve["along"] as float)
		if not box.intersects(Rect2(from, Vector2.ZERO).expand(to).grow(carve_reach)):
			continue
		strokes.append(from)
		reaches.append(to)
		var wanted := _view_team < 0 or (carve["team"] as int) == _view_team
		shown.append(1 if wanted else 0)
		if not wanted:
			hidden = true

	if not strokes.is_empty():
		var cut := _paint_strokes(
			shape, seen, strokes, reaches, shown, wide, wide_x, wide_y, origin, pad
		)
		shape = cut[0]
		seen = cut[1]
	# THE STONE IS TAKEN OUT OF THE FIELD LAST, AFTER EVERY STROKE AND BEFORE EVERY RULE, and both
	# halves of that placement are load-bearing.
	#
	# AFTER THE STROKES, because what the world is is "everywhere somebody dug, MINUS the rock". A
	# distance field intersects by `max` of the two signed distances -- the tunnel's, and the
	# complement of the stone's -- which encoded is a `min`, one per sample. That is the whole
	# mechanism, and it is why nothing downstream has to be taught that rock exists: the contour
	# wraps it because the field says the earth comes back there, the collision trimesh is those
	# same triangles, the cutaway discards against the same numbers, and `walkable_between` refuses
	# to route through it because it asks the field how much room there is.
	#
	# BEFORE THE RULES, because the thinning and the island cull are about what the earth looks like
	# and both would happily shave a spur off a rock or swallow a small one whole. They are told to
	# leave stone alone (see [method _thin_earth] and [method _cull_islands]), and they can only be
	# told that if the stone is already in the field when they run.
	#
	# ON BOTH FIELDS, and forgetting the crew's one would be a quiet, nasty bug: the lid discards
	# against `seen`, so rock missing from it is a hole cut in the ground above solid stone -- a
	# window into a rock, on the host only, for one crew.
	# ONE MASK, BUILT ONCE, SHARED BY BOTH FIELDS AND BOTH RULES. Where the stone is does not depend
	# on which crew is being drawn for -- a rock is in the same place in everybody's earth -- so the
	# crew's field re-subtracts the same shapes and re-uses the mask the world's pass filled in.
	# KEPT AND CLEARED RATHER THAN ALLOCATED, like `_thin_offsets` a few functions down and for the
	# same reason: every chunk of every carve step wants one of exactly the same size, and a fresh
	# PackedByteArray each time is an allocation per chunk for a buffer nothing outlives.
	var stone_mask := _stone_scratch(wide)
	_subtract_rock(plane, shape, wide, origin, stone_mask)
	if hidden:
		# THE SAME MASK, WRITTEN TWICE AND IDENTICALLY. Where the stone is does not depend on which
		# crew is looking, so the second pass re-marks exactly what the first did -- which is
		# cheaper than carrying a flag to suppress it and impossible to get out of step.
		_subtract_rock(plane, seen, wide, origin, stone_mask)

	# THINNED BEFORE THE ISLANDS ARE WALKED, and the order is not arbitrary. Shaving the teeth off a
	# lump changes how big it measures, and shaving a neck through can part one lump into two -- so
	# the island rule has to be looking at the earth that will actually be drawn, not at the earth
	# before this ran.
	_thin_earth(shape, stone_mask, wide)
	var islands := _cull_islands(plane, shape, stone_mask, wide, origin, pad, n)
	# The cutaway gets its own pass rather than the shape's answer: the crew's field is built out of
	# fewer strokes, so its earth is a different shape, thin in different places and pinched off in
	# different places. Sharing the verdict would cut a hole in the lid over ground that, as far as
	# this crew has been told, nobody has dug.
	if hidden:
		_thin_earth(seen, stone_mask, wide)
		_cull_islands(plane, seen, stone_mask, wide, origin, pad, n)
	else:
		seen = shape

	# Sight changes the lid, never the physical earth. Reuse the field rules but do not
	# regenerate triangles, upload meshes, or invalidate physics shapes for a fog update.
	if mask_only:
		_blit(plane, _inner(seen, wide, pad, span), span, base_x, base_y, n)
		return

	var contour := TunnelContour.new()
	var chunk_origin := Vector2(
		float(base_x) / float(TunnelContour.TEXELS_PER_METRE),
		float(base_y) / float(TunnelContour.TEXELS_PER_METRE)
	)
	var inner := _inner(shape, wide, pad, span)
	# ONE RING WIDER FOR THE WALL'S SAKE. The bevel and the gouging both move a vertex along "away
	# from the tunnel", which is a central difference of the field -- and at the outermost samples
	# of a chunk that difference has to be taken across the border, or the two chunks sharing that
	# seam lean their walls back in slightly different directions and the seam opens. See
	# [method TunnelContour.build]. Free: these samples are already in `shape`.
	contour.build(
		inner,
		n,
		chunk_origin,
		_wall_top(plane),
		_barrier_top(plane),
		_inner(shape, wide, pad - 1, span + 2) if pad >= 1 else PackedFloat32Array()
	)

	var walls := PackedVector3Array()
	var stone := PackedVector3Array()
	var bedrock := PackedVector3Array()
	_split_stone(plane, contour.walls, walls, stone, bedrock)

	_chunk_cache[plane][key] = {
		"floors": contour.floors,
		"walls": walls,
		"stone": stone,
		"bedrock": bedrock,
		"collision": contour.collision,
		"islands": islands,
		# THE NUMBERS THE TRIANGLES ABOVE CAME OUT OF, kept rather than thrown away, so that
		# anything asking "is there room for a mouse here" can ask the same thing the wall was
		# built from instead of a second model of it. See [method walkable_between], which is the
		# whole reason this is here -- routing used to re-derive the shape of the earth from the
		# strokes, which is the field before two of its rules have run, and got a different answer
		# from the collision mesh in exactly the places those rules bite.
		#
		# A CHUNK'S WORTH IS 33x33 FLOATS -- 4.4KB, against the tens of KB of triangles it sits
		# beside, and only for chunks somebody has dug in.
		"field": inner,
		# WORKED OUT HERE, WHERE THERE ARE A FEW HUNDRED TRIANGLES, rather than out in the plane
		# assembly where there are tens of thousands and none of them have moved.
		#
		# A floor triangle is horizontal and wound to face up by construction (see
		# TunnelContour._add_floor_triangle), so its normal is not worth a cross product -- and the
		# floor is much the bigger half of a dug chunk.
		"floor_normals": _flat_up(contour.floors.size()),
		"wall_normals": _face_normals(walls),
		"stone_normals": _face_normals(stone),
		"bedrock_normals": _face_normals(bedrock),
	}
	_blit(plane, _inner(seen, wide, pad, span), span, base_x, base_y, n)


## Union a set of strokes into the two fields, and hand them back.
##
## HANDED BACK RATHER THAN WRITTEN THROUGH, and that is a fact about the language rather than a
## style choice: a `PackedFloat32Array` parameter is copy-on-write, so the moment this assigns to
## one it is writing to a copy of its own and the caller's array is untouched. Returning them is the
## only way the composition can be split into more than one call at all -- and splitting it is the
## whole point, because the committed strokes are painted once and kept while the carve on top is
## repainted sixteen times a second. See [member _committed_field].
##
## `[EXTRACTED, NOT REWRITTEN]` The loop below is exactly what `_rebuild_chunk` used to run inline.
func _paint_strokes(
	shape: PackedFloat32Array,
	seen: PackedFloat32Array,
	strokes: Array[Vector2],
	reaches: Array[Vector2],
	shown: PackedByteArray,
	wide: int,
	wide_x: int,
	wide_y: int,
	origin: Vector2,
	pad: int
) -> Array:
	for index in range(strokes.size()):
		var a := strokes[index]
		var b := reaches[index]
		var visible := shown[index] != 0
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
	return [shape, seen]

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


## Mark the squares a boulder has shut into a window's stone mask.
##
## CELLS, BECAUSE A BOULDER IS CELLS. Everything else about the earth stopped being square when
## digging went off the grid, but a boulder is a lump lying on the lawn that shuts the ground
## directly under it -- the footprint is its own, authored in cells, and there is no shape in the
## field to sample. Whole squares is what it means.
func _mark_boulder_cells(
	plane: int, stone: PackedByteArray, wide: int, origin: Vector2
) -> void:
	if plane <= 0 or plane >= PLANE_COUNT or _rock[plane].is_empty():
		return
	var extent := float(wide - 1) * TunnelContour.TEXEL
	var low := world_to_cell(Vector3(origin.x, 0.0, origin.y))
	var high := world_to_cell(Vector3(origin.x + extent, 0.0, origin.y + extent))
	var half := CELL * 0.5
	for y in range(low.y, high.y + 1):
		for x in range(low.x, high.x + 1):
			var cell := Vector2i(x, y)
			# A rock body's derived cells are skipped: those are marked by the field pass at their
			# real outline, and painting their whole square here would put stone in the open earth
			# of every cell a rock merely clips.
			if not _rock[plane].has(cell) or int(_rock_owner[plane].get(cell, -1)) >= 0:
				continue
			var i0 := maxi(0, ceili(
				(float(x) * CELL - half - origin.x) * TunnelContour.TEXELS_PER_METRE
			))
			var i1 := mini(wide - 1, floori(
				(float(x) * CELL + half - origin.x) * TunnelContour.TEXELS_PER_METRE
			))
			var j0 := maxi(0, ceili(
				(float(y) * CELL - half - origin.y) * TunnelContour.TEXELS_PER_METRE
			))
			var j1 := mini(wide - 1, floori(
				(float(y) * CELL + half - origin.y) * TunnelContour.TEXELS_PER_METRE
			))
			for j in range(j0, j1 + 1):
				var row := j * wide
				for i in range(i0, i1 + 1):
					stone[row + i] = 1


## Which rocks could possibly reach into this box, as indices into the plane's array.
##
## THROUGH THE PROXIMITY BUCKETS RATHER THAN OVER EVERY ROCK, and that stopped being an optimisation
## and became a requirement when the rocks shrank. Coverage is aimed at an AREA, so a plane holds
## the same fraction of stone however big the pieces are -- and cutting the radius by two thirds
## multiplied the count by nearly ten. Five hundred `Rect2.intersects` calls per chunk, several
## chunks per carve step, sixteen carve steps a second, is most of a frame spent asking rocks on the
## far side of the map whether they are here.
##
## A chunk's window is a few dozen cells and each bucket holds a handful of indices, so this is
## thirty dictionary lookups against five hundred box tests. The caller still tests the box: a rock
## registered in a cell the window clips has not necessarily reached the window.
func _rocks_near_box(plane: int, box: Rect2) -> PackedInt32Array:
	var found := PackedInt32Array()
	if plane <= 0 or plane >= PLANE_COUNT or _rock_near[plane].is_empty():
		return found
	var seen := {}
	var low := world_to_cell(Vector3(box.position.x, 0.0, box.position.y))
	var high := world_to_cell(Vector3(box.end.x, 0.0, box.end.y))
	for y in range(low.y, high.y + 1):
		for x in range(low.x, high.x + 1):
			var near: Variant = _rock_near[plane].get(Vector2i(x, y))
			if near == null:
				continue
			for i: int in (near as Array):
				if seen.has(i):
					continue
				seen[i] = true
				found.append(i)
	return found


## Put the stone back into a window of the field, wherever a rock stands in it.
##
## `value = min(value, encode(depth))` AND THAT IS THE WHOLE OPERATION. The field stores the signed
## distance to the tunnel surface, negative inside; encoding negates and shifts it, so a `min` of
## encoded values is a `max` of distances, which is the intersection of two regions. The two here
## are "the tunnel" and "not this rock", so what comes out is the tunnel with the rock taken back
## out of it. Exact on both sides: a sample deep in a corridor a handspan from a rock reads its
## distance to the ROCK, because that is genuinely the nearest surface, which is what makes the
## wall lean and bevel correctly where it wraps stone.
##
## WRITTEN PER LOBE OVER THE LOBE'S OWN SQUARE, exactly as a stroke is written over its own. Beyond
## a metre from the surface the encoded depth saturates and the `min` cannot change anything, so
## there is no point sampling further -- and a plane with two dozen rocks on it would otherwise pay
## for all of them in every chunk.
func _subtract_rock(
	plane: int,
	values: PackedFloat32Array,
	wide: int,
	origin: Vector2,
	stone: PackedByteArray
) -> void:
	if plane <= 0 or plane >= PLANE_COUNT:
		return
	# BOULDER CELLS FIRST, and only into the mask. A boulder shuts whole squares of plane 1 without
	# being a shape in the field at all -- it is a thing standing on the lawn, not a lump in the
	# earth -- so it never had a distance to subtract. It still has to be stone to the rules that
	# read the mask, and marking it here is what stops [method _thin_earth] shaving the ground out
	# from under one.
	_mark_boulder_cells(plane, stone, wide, origin)
	if _rock_bodies[plane].is_empty():
		return
	var extent := float(wide - 1) * TunnelContour.TEXEL
	var window := Rect2(origin, Vector2(extent, extent))
	for index: int in _rocks_near_box(plane, window.grow(TunnelContour.SDF_RANGE)):
		var rock := _rock_bodies[plane][index] as RockBody
		if rock == null or not window.intersects(rock.bounds().grow(TunnelContour.SDF_RANGE)):
			continue
		for lobe: Vector3 in rock.lobes:
			var box := RockBody.lobe_bounds(lobe, TunnelContour.SDF_RANGE)
			if not window.intersects(box):
				continue
			var j0 := maxi(0, floori((box.position.y - origin.y) * TunnelContour.TEXELS_PER_METRE))
			var j1 := mini(
				wide - 1, ceili((box.end.y - origin.y) * TunnelContour.TEXELS_PER_METRE)
			)
			# THE DISC, NOT ITS BOX, AND WITHOUT A FUNCTION CALL PER TEXEL. Both are about the same
			# thing: this is the innermost loop in the whole rebuild, and the rocks getting small
			# put ten times as many lobes through it.
			#
			# `encode` clamps, so past `reach` from a lobe's centre the answer saturates and the
			# `min` provably cannot change a texel -- which makes the square box a fifth of a job
			# that is never worth doing. Solving each row's span against the circle instead skips it
			# outright, rather than sampling it and discarding the answer.
			#
			# And `encode` is inlined here, alone in this file. It is three arithmetic operations
			# behind a call, and at a few hundred thousand texels a second the call is most of the
			# cost -- so the formula is written out with the one comment that matters: it must stay
			# in step with [method TunnelContour.encode], which is the definition.
			var reach: float = lobe.z + TunnelContour.SDF_RANGE
			var reach_sq := reach * reach
			for j in range(j0, j1 + 1):
				var dy := origin.y + float(j) * TunnelContour.TEXEL - lobe.y
				var across_sq := reach_sq - dy * dy
				if across_sq <= 0.0:
					continue
				var across := sqrt(across_sq)
				var i0 := maxi(
					0,
					ceili((lobe.x - across - origin.x) * TunnelContour.TEXELS_PER_METRE)
				)
				var i1 := mini(
					wide - 1,
					floori((lobe.x + across - origin.x) * TunnelContour.TEXELS_PER_METRE)
				)
				var row := j * wide
				var dy_sq := dy * dy
				var radius_sq := lobe.z * lobe.z
				for i in range(i0, i1 + 1):
					var at := row + i
					var dx := origin.x + float(i) * TunnelContour.TEXEL - lobe.x
					var gap_sq := dx * dx + dy_sq
					if gap_sq <= radius_sq:
						stone[at] = 1
					# THE HALO IS SKIPPED WHERE IT PROVABLY CANNOT BITE, and that is most of it. A
					# lobe writes over its own radius PLUS the field's full metre of grading, so a
					# rock 30cm across paints a disc 2.3m wide -- thirty times its own area, nearly
					# all of it in earth nobody has touched. `encode` floors at zero, the array
					# starts at zero, and no stroke ever lowers a sample: a texel still reading zero
					# cannot be lowered by a `min` with anything. One comparison replaces a square
					# root and a clamp, on the innermost loop of the whole rebuild.
					#
					# EXACT, NOT AN APPROXIMATION. This is not a tolerance or a distance cutoff --
					# it is the identity `min(0, x) = 0` for a quantity that cannot go below zero.
					if values[at] <= 0.0:
						continue
					var depth := lobe.z - sqrt(gap_sq)
					# TunnelContour.encode, written out.
					var value := clampf(
						TunnelContour.SURFACE - depth / (TunnelContour.SDF_RANGE * 2.0), 0.0, 1.0
					)
					if value < values[at]:
						values[at] = value
					# THE SAME SAMPLE ANSWERS BOTH QUESTIONS, which is the whole point of writing
					# the mask here rather than asking again later. `_thin_earth` and the island
					# cull both have to know whether a texel is stone, and both used to find out by
					# calling back through the cell buckets and the lobe list -- per rim texel, per
					# island, on every carve step. The distance is already in hand; its sign is the
					# answer; and a byte array read costs nothing next to a dictionary walk.


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
## wafer of a rock is indistinguishable from a wafer of earth, and one of the two is meant to be
## permanent.
##
## `[REVISED]` ASKED OF THE POINT RATHER THAN OF ITS CELL, now that a rock is a shape. The cell test
## was both too generous and too mean at once: it protected the earth in the open part of a cell a
## rock merely clips -- which is ordinary earth and ought to be thinned -- and it protected nothing
## at all in the part of a rock hanging over the line into the next square.
##
## `[REVISED AGAIN]` AND READ OFF A MASK RATHER THAN RE-ASKED. The point test was right and cost too
## much: a dictionary lookup and a walk over a rock's lobes, per rim texel, on every carve step.
## [method _subtract_rock] has the distance in hand when it writes the field and now writes the sign
## of it alongside, so the question is a byte array read and the two can no longer disagree.
func _thin_earth(values: PackedFloat32Array, stone: PackedByteArray, wide: int) -> void:
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
			if stone[at] != 0:
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


## The scratch stone mask for a window this wide, cleared and ready.
##
## One buffer, reused. The window is the same size every time for a given setting, so this resizes
## once in a match and clears thereafter -- and a clear of a few thousand bytes is a memset, which
## is the one thing this language is reliably fast at.
func _stone_scratch(wide: int) -> PackedByteArray:
	var want := wide * wide
	if _stone_mask.size() != want:
		_stone_mask.resize(want)
	_stone_mask.fill(0)
	return _stone_mask


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
	plane: int,
	values: PackedFloat32Array,
	stone: PackedByteArray,
	wide: int,
	origin: Vector2,
	pad: int,
	n: int
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
		# `[REVISED]` ASKED OF THE LUMP, NOT OF ITS BOX. The old test walked the cells a bounding box
		# covered, and for each one every nearby rock's every lobe, per island, per carve step --
		# and it was conservative in the wrong direction as well as slow: a box is bigger than the
		# scrap inside it, so an island NEXT to a rock was spared along with the ones made of it.
		# The mask answers exactly, for exactly the texels the island is made of.
		var stony := false
		for at: int in body:
			if stone[at] != 0:
				stony = true
				break
		if stony:
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


## Is there any stone in this box?
##
## TWO ANSWERS FROM TWO SOURCES, because there are two kinds of permanent earth and they are not
## stored the same way. A boulder on the lawn shuts whole CELLS of plane 1, and any box overlapping
## one of those squares is over stone; a rock body is a shape, and the honest test is whether the
## box actually reaches it.
##
## Conservative in both directions on purpose. This decides whether the island cull may swallow a
## lump of earth, and swallowing a scrap of ROCK would quietly delete part of an obstruction the
## whole map is routed around -- so anything in doubt is left standing.
func _box_hits_rock(plane: int, box: Rect2) -> bool:
	var low := world_to_cell(Vector3(box.position.x, 0.0, box.position.y))
	var high := world_to_cell(Vector3(box.end.x, 0.0, box.end.y))
	for y in range(low.y, high.y + 1):
		for x in range(low.x, high.x + 1):
			var cell := Vector2i(x, y)
			if _rock[plane].has(cell) and int(_rock_owner[plane].get(cell, -1)) < 0:
				return true
			# Through the proximity buckets rather than over every rock on the plane. An island is
			# never bigger than `island_max_span`, so this is two or three squares' worth of
			# lookups against a walk over a couple of dozen lumps.
			var near: Variant = _rock_near[plane].get(cell)
			if near == null:
				continue
			for i: int in (near as Array):
				var rock := _rock_bodies[plane][i] as RockBody
				if rock == null:
					continue
				for lobe: Vector3 in rock.lobes:
					if box.intersects(RockBody.lobe_bounds(lobe, 0.0)):
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


## Sort wall triangles into earth, breakable stone and bedrock by what is standing behind them.
##
## THE ENTIRE USER INTERFACE FOR ROCK: you dig up to a rock, the corridor ends in grey, and nothing
## has to explain itself. Same geometry, same collision, split only so the three can carry different
## materials -- exactly as the cell version did, asked per wall face instead of per cell side.
##
## THREE WAYS NOW, BECAUSE THERE ARE TWO KINDS OF STONE. Pale is a rock a Brute can break; dark is
## bedrock, which nothing shifts. That distinction has to be readable from across a corridor with
## no legend, because the whole decision it exists to create -- fetch a Brute, or spend the time
## going round -- is made by looking at the wall you have just run into.
##
## THE STEP BEHIND THE FACE IS SHORT, AND IT IS SHORT BECAUSE THE ROCK IS REAL NOW. The cell version
## stepped 0.6m outward to be sure of landing in the NEXT SQUARE, because the question was about
## squares. The wall now stands on the rock's own outline -- the field put it there -- so a couple
## of texels past it is inside the stone, and a long step would sail out the far side of a small
## lobe and report earth.
func _split_stone(
	plane: int,
	source: PackedVector3Array,
	earth: PackedVector3Array,
	stone: PackedVector3Array,
	bedrock: PackedVector3Array
) -> void:
	# A WHOLE FACE AT A TIME, ASKED AT ITS FOOT. A face is a strip of rows now rather than one quad
	# (see TunnelContour._add_wall), and the rows above the first stand back from the outline by
	# the bevel -- so asking each row for itself would sometimes put a row of stone and a row of
	# earth on the same face, and the seam between them would be a grey stripe up a mud wall. The
	# bottom row is the one on the true outline, which is the question this was always asking.
	var stride := TunnelContour.face_verts()
	for t in range(0, source.size(), stride):
		var a := source[t]
		var b := source[t + 1]
		# A step from the middle of the face AWAY from the corridor, far enough to land in the
		# neighbouring cell rather than back in this one.
		var outward := -(b - a).cross(Vector3.UP).normalized()
		var flat := (a + b) * 0.5
		var into := earth
		# The boulder case first, and asked at the old distance: a boulder really does shut the
		# whole of the next square, and the face standing against one is on the cell boundary
		# rather than on any shape.
		var far := flat + outward * (CELL * 0.6)
		var far_cell := world_to_cell(far)
		if _rock[plane].has(far_cell) and int(_rock_owner[plane].get(far_cell, -1)) < 0:
			into = stone
		else:
			var near := flat + outward * (TunnelContour.TEXEL * 2.0)
			var rock := rock_holding(plane, Vector2(near.x, near.z))
			if rock != null:
				into = stone if rock.breakable else bedrock
		for k in range(stride):
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
