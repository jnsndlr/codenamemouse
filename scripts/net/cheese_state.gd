class_name CheeseState
extends RefCounted
## Every pile of cheese currently lying in the yard, as one replaceable world-state picture.
##
## A CACHE IS NOT AN EVENT. A dropped wedge can be created before a client enters its arena, a
## packet can be lost, and an authored pile can be emptied while nobody is listening. Sending
## "spawn", "changed" and "removed" separately would need acknowledgements and a recovery path;
## sending the small complete set repeatedly makes all three cases the same operation: reconcile
## this picture. The revision drops an older unreliable picture that arrives after a newer one.
##
## This packet is public by design. `CheeseCache.minimap_shapes` already promises that every pile
## is visible to both crews; only how many wedges remain is newly carried here, and that count is
## already visible in the pile's world mesh.

const MAX_CACHES: int = 1024
## kind, revision, count.
const HEADER_SIZE: int = 1 + 4 + 2
## Surface x/z, wedges, and visual spread.
const CACHE_SIZE: int = 4 + 4 + 2 + 4


class Cache:
	var position: Vector2 = Vector2.ZERO
	var wedges: int = 0
	var spread: float = 0.0

	func _init(at: Vector2 = Vector2.ZERO, amount: int = 0, width: float = 0.0) -> void:
		position = at
		wedges = amount
		spread = width


var revision: int = 0
var caches: Array[Cache] = []


func add(at: Vector3, wedges: int, spread: float) -> void:
	if wedges <= 0 or caches.size() >= MAX_CACHES:
		return
	caches.append(Cache.new(Vector2(at.x, at.z), mini(wedges, 65535), maxf(spread, 0.0)))


func to_bytes() -> PackedByteArray:
	var out := NetMessage.head(NetMessage.Kind.CHEESE)
	out.put_u32(revision)
	out.put_u16(caches.size())
	for cache: Cache in caches:
		out.put_float(cache.position.x)
		out.put_float(cache.position.y)
		out.put_u16(cache.wedges)
		out.put_float(cache.spread)
	return out.data_array


## Null on a truncated, padded, or implausibly large picture. A partial cache set must never be
## applied: reconciliation treats anything absent as removed, so accepting half a packet would
## erase real piles until the next picture arrived.
static func from_bytes(bytes: PackedByteArray) -> CheeseState:
	if bytes.size() < HEADER_SIZE:
		return null
	var into := NetMessage.body(bytes, HEADER_SIZE)
	if into == null:
		return null

	var state := CheeseState.new()
	state.revision = into.get_u32()
	var count := into.get_u16()
	if count > MAX_CACHES or bytes.size() != HEADER_SIZE + count * CACHE_SIZE:
		return null

	for i in range(count):
		var position := Vector2(into.get_float(), into.get_float())
		var wedges := into.get_u16()
		var spread := into.get_float()
		if wedges <= 0 or not position.is_finite() or not is_finite(spread) or spread < 0.0:
			return null
		state.caches.append(Cache.new(position, wedges, spread))
	return state
