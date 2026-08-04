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
## WHAT IS NOT IN HERE, deliberately: health, cheese, score, the tunnel network, who is carrying
## what. Those are step 4's "on change" half and step 5's filtered half, and putting them in a
## thirty-times-a-second broadcast would be both wasteful and — for the tunnel network — the exact
## leak M5 spent a milestone preventing. **This packet goes to everyone unfiltered, so nothing
## secret may ever be added to it.** That sentence is the whole safety argument for the file.

## Position, facing, and the handful of bits that change how a mouse is drawn.
class Pose:
	var key: int = 0
	var position: Vector3 = Vector3.ZERO
	var facing: float = 0.0
	var flags: int = 0

	func _init(seat_key: int = 0, at: Vector3 = Vector3.ZERO, angle: float = 0.0, bits: int = 0) -> void:
		key = seat_key
		position = at
		facing = angle
		flags = bits


## The state a remote viewer needs to draw a mouse correctly and cannot infer from its position.
## Scruffed changes the pose, swinging changes the arc, carrying puts a banner over its head.
enum Flag {
	SCRUFFED = 1,
	SWINGING = 2,
	CARRYING = 4,
}

## Bytes per pose: key, three floats, facing, flags.
const POSE_SIZE: int = 1 + 4 * 4 + 1
const HEADER_SIZE: int = 1 + 4 + 1

var tick: int = 0
var poses: Array[Pose] = []


static func key_for(side: int, seat: int, crew_size: int) -> int:
	return side * crew_size + seat


func add(key: int, at: Vector3, facing: float, flags: int) -> void:
	poses.append(Pose.new(key, at, facing, flags))


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
		shot.add(key, at, facing, into.get_u8())
	return shot
