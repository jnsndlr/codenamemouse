class_name Snapshot
extends RefCounted
## Where every mouse is, thirty times a second.
##
## SEAT-INDEXED, AND THAT IS WHAT STEP 3 BOUGHT. There are no spawn messages in this protocol and
## there do not need to be: the roster already says which chairs exist and who is in them, so a
## client can build its ten mice before a single snapshot arrives and every entry afterwards is
## just "chair 7 is here now". Spawn/despawn replication is one of the fiddliest parts of a netcode
## and this design skips it entirely — the population of the world is fixed at ten and known to
## both ends from the seating message.
##
## **A key is `team * crew_size + seat`**, one byte, which is why the roster's size has to be
## agreed before any of this means anything.
##
## WHAT IS IN HERE IS WHAT CHANGES EVERY TICK: where a mouse is, which way it faces, whether it is
## down or mid-swing, and how hurt it is. Health earns its byte because it moves continuously and
## belongs to a mouse; the score, the stores and the clock do not and live in `MatchState`, which
## goes out four times a second instead of thirty.
##
## WHAT IS NOT IN HERE, deliberately: the tunnel network. That is step 5's filtered payload and
## putting it in a broadcast would be the exact leak M5 spent a milestone preventing. **This packet
## goes to everyone unfiltered, so nothing secret may ever be added to it.** That sentence is the
## whole safety argument for the file.

## Position, facing, health, and the handful of bits that change how a mouse is drawn.
class Pose:
	var key: int = 0
	var position: Vector3 = Vector3.ZERO
	var facing: float = 0.0
	var flags: int = 0
	## 0..255 across the mouse's own maximum, which is per-class. A RATIO rather than a number of
	## points, because the bar on the HUD is a ratio and the class table is not replicated -- a
	## client told "62 health" would have to know whether that is most of a Brute or nearly a dead
	## Sneak.
	var health: int = 255

	func _init(seat_key: int = 0, at: Vector3 = Vector3.ZERO, angle: float = 0.0,
			bits: int = 0, hp: int = 255) -> void:
		key = seat_key
		position = at
		facing = angle
		flags = bits
		health = hp


## The state a remote viewer needs to draw a mouse correctly and cannot infer from its position.
## Scruffed changes the pose it lies in; swinging plays the arc.
##
## THERE WAS A `CARRYING` BIT HERE AND IT WAS THE SAME FACT TWICE. `MatchState` says which banner
## is on whose head -- that is strictly more information, since it also says *which* banner -- and
## two encodings of one fact are two things that can disagree. The client sets up the real carry
## relationship from the banner payload, so `is_carrying()` is true on a puppet for the ordinary
## reason rather than because a bit said so, and everything that reads it (the grass camouflage,
## the roster) keeps working without knowing any of this happened.
enum Flag {
	SCRUFFED = 1,
	SWINGING = 2,
	## Put down by a collapse rather than by a paw. Only ever set alongside SCRUFFED -- it says
	## *how*, not *whether*, and a client reading it alone would be asking the wrong question.
	##
	## BIT 6, the first of the two the plane and class bits left spare in this byte. Worth the bit
	## rather than deriving it at the far end: there is nothing in a pose a client could infer it
	## from, and the alternative is a remote player's HUD confidently reporting the wrong word for
	## the six seconds it is on screen.
	BURIED = 64,
	## Behind the Sneak's veil (GDD section 4, [Fade]).
	##
	## **BIT 7, AND IT IS THE LAST ONE IN THIS BYTE.** Plane took two, class took two, and the three
	## state bits take the rest -- a ninth thing to say about a pose does not fit and grows
	## [constant POSE_SIZE] for all ten mice thirty times a second. Written down here because the
	## byte has looked half empty in every previous edit of this enum and does not any more.
	##
	## IT HAS TO BE REPLICATED AND CANNOT BE DERIVED, which is the argument for spending the last
	## bit on it. A client is told a remote player's *poses*, never their input -- so the machine
	## watching a third player's Sneak has no way whatsoever to know the ability fired, and the
	## failure mode is not cosmetic: it draws a solid mouse standing where the server says an
	## invisible one is. That is the one disagreement between two screens that decides a fight.
	##
	## SAFE TO PUT IN AN UNFILTERED BROADCAST, which this packet is and which the header above is
	## emphatic about. It reveals nothing: a viewer either can already see this mouse -- in which
	## case the veil is the thing they are looking at -- or cannot, in which case there is no mouse
	## on their screen for the bit to be attached to. `spotting.gd` decides who is on the map, and
	## this decides how a mouse already being drawn is drawn.
	FADED = 128,
}

## Which of the four layers a mouse is on, packed into the spare bits of the same byte.
##
## STATE, NOT A READING TAKEN OFF ITS HEIGHT, which `mouse.gd` has a scar about and which is doubly
## true here: a client could infer the plane from the y it was sent, and would be wrong for the
## whole of a fall and for every frame of a shaft. It is two bits and it decides which layer the
## camera cuts away, so a client whose own mouse has no plane stands underground looking at a lawn.
const PLANE_SHIFT: int = 2
const PLANE_MASK: int = 0b1100

## Which of the four classes a mouse currently is, in the next two bits of the same byte.
##
## HERE RATHER THAN IN `MatchState`, and rather than nowhere at all. Class was never replicated
## because it never changed: both ends build their ten mice from the same `SEATS` table, so they
## agreed by construction. M7's controls refactor is what breaks that -- the swap point is one of
## the five, so a remote human standing on their own nest and pressing C now genuinely re-types
## their mouse on the server, and every other machine went on drawing the old class, showing the
## old row on the roster, and expecting the old dig speed.
##
## IT HAS TO ARRIVE WITH THE HEALTH RATHER THAN NEAR IT. Health travels as a fraction of a
## per-class maximum (see [member Pose.health]), so a pose that carried a Sneak's ratio and a
## Brute's class read as a mouse that had just lost forty points. Two bits in a byte that was
## already being sent, applied in the right order, and the whole disagreement goes away.
const CLASS_SHIFT: int = 4
const CLASS_MASK: int = 0b110000

## Bytes per pose: key, three floats, facing, flags, health.
const POSE_SIZE: int = 1 + 4 * 4 + 1 + 1
const HEADER_SIZE: int = 1 + 4 + 1

var tick: int = 0
var poses: Array[Pose] = []


static func key_for(side: int, seat: int, crew_size: int) -> int:
	return side * crew_size + seat


func add(key: int, at: Vector3, facing: float, flags: int, health: int) -> void:
	poses.append(Pose.new(key, at, facing, flags, health))


func to_bytes() -> PackedByteArray:
	var out := NetMessage.head(NetMessage.Kind.SNAPSHOT)
	out.put_u32(tick)
	out.put_u8(poses.size())
	for pose: Pose in poses:
		out.put_u8(pose.key)
		out.put_float(pose.position.x)
		out.put_float(pose.position.y)
		out.put_float(pose.position.z)
		out.put_float(pose.facing)
		out.put_u8(pose.flags)
		out.put_u8(pose.health)
	return out.data_array


## Null on anything that is not exactly a well-formed snapshot.
##
## The length is checked against what the header CLAIMS rather than only against a minimum, so a
## truncated packet — the ordinary result of a fragmented unreliable send — is dropped whole
## instead of yielding a short list of mice that reads as half the match having vanished.
static func from_bytes(bytes: PackedByteArray) -> Snapshot:
	var into := NetMessage.body(bytes, HEADER_SIZE)
	if into == null:
		return null

	var shot := Snapshot.new()
	shot.tick = into.get_u32()
	var count := into.get_u8()
	if bytes.size() != HEADER_SIZE + count * POSE_SIZE:
		return null

	for i: int in range(count):
		var key := into.get_u8()
		var at := Vector3(into.get_float(), into.get_float(), into.get_float())
		var facing := into.get_float()
		var flags := into.get_u8()
		shot.add(key, at, facing, flags, into.get_u8())
	return shot
