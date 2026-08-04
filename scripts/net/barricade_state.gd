class_name BarricadeState
extends RefCounted
## Every barricade one crew is currently allowed to know about, as a replaceable picture.
##
## Unlike cheese this picture is ADDRESSED, not public. A barricade identifies a dug cell, so
## broadcasting every rock would hand both crews the other one's tunnel map. `NetMatch` filters
## one instance of this state through `TunnelSight.knows` for each peer.
##
## Plane and cell are the identity. Barricades never move; a later reading at the same place
## updates its owner and remaining swings, while absence removes it. Repeating the whole small set
## means a lost spawn, damage packet, removal, or a client entering its arena late all heal on the
## next picture without acknowledgements.

const NOBODY: int = 255
const MAX_BARRICADES: int = 256
const MAX_OWNERS: int = 32
## kind, revision, owner-count, and barricade-count. Owner supply bytes sit between the two counts.
const FIXED_SIZE: int = 1 + 4 + 1 + 2
## plane, signed cell x/y, owner seat key, remaining hits, total hits.
const ROCK_SIZE: int = 1 + 2 + 2 + 1 + 1 + 1


class Rock:
	var plane: int = 0
	var cell: Vector2i = Vector2i.ZERO
	var owner: int = NOBODY
	var hits_left: int = 0
	var hits_total: int = 0

	func _init(
		at_plane: int = 0,
		at_cell: Vector2i = Vector2i.ZERO,
		by: int = NOBODY,
		left: int = 0,
		total: int = 0
	) -> void:
		plane = at_plane
		cell = at_cell
		owner = by
		hits_left = left
		hits_total = total


var revision: int = 0
## Standing barricades by seat key. `NetMatch` fills only the receiving player's slot: their HUD
## must retain the cost of a rock after fog hides its coordinate, while everybody else's count
## would disclose hidden fortification activity for no gameplay benefit.
var standing: PackedByteArray = PackedByteArray()
var rocks: Array[Rock] = []


func add(
	plane: int, cell: Vector2i, owner: int, hits_left: int, hits_total: int
) -> void:
	if (
		rocks.size() >= MAX_BARRICADES
		or plane <= 0 or plane >= 255
		or cell.x < -32768 or cell.x > 32767
		or cell.y < -32768 or cell.y > 32767
		or owner < 0 or owner > NOBODY
		or hits_total <= 0 or hits_total > 255
		or hits_left <= 0 or hits_left > hits_total
	):
		return
	rocks.append(Rock.new(plane, cell, owner, hits_left, hits_total))


func set_standing(counts: PackedByteArray) -> void:
	standing = counts.slice(0, mini(counts.size(), MAX_OWNERS))


func to_bytes() -> PackedByteArray:
	var out := NetMessage.head(NetMessage.Kind.BARRICADES)
	out.put_u32(revision)
	out.put_u8(standing.size())
	out.put_data(standing)
	out.put_u16(rocks.size())
	for rock: Rock in rocks:
		out.put_u8(rock.plane)
		out.put_u16(rock.cell.x & 0xffff)
		out.put_u16(rock.cell.y & 0xffff)
		out.put_u8(rock.owner)
		out.put_u8(rock.hits_left)
		out.put_u8(rock.hits_total)
	return out.data_array


## Null on a truncated, padded, or impossible picture. Absence means removal during
## reconciliation, so a partial packet must never be accepted as a smaller authoritative world.
static func from_bytes(bytes: PackedByteArray) -> BarricadeState:
	if bytes.size() < FIXED_SIZE:
		return null
	var into := NetMessage.body(bytes, FIXED_SIZE)
	if into == null:
		return null

	var state := BarricadeState.new()
	state.revision = into.get_u32()
	var owners := into.get_u8()
	if owners > MAX_OWNERS or bytes.size() < FIXED_SIZE + owners:
		return null
	for i: int in range(owners):
		state.standing.append(into.get_u8())
	var count := into.get_u16()
	if (
		count > MAX_BARRICADES
		or bytes.size() != FIXED_SIZE + owners + count * ROCK_SIZE
	):
		return null

	var occupied: Dictionary = {}
	for i: int in range(count):
		var plane := into.get_u8()
		var cell := Vector2i(_signed_16(into.get_u16()), _signed_16(into.get_u16()))
		var owner := into.get_u8()
		var left := into.get_u8()
		var total := into.get_u8()
		var identity := "%d:%d:%d" % [plane, cell.x, cell.y]
		if (
			plane <= 0 or total <= 0 or left <= 0 or left > total
			or occupied.has(identity)
		):
			return null
		occupied[identity] = true
		state.rocks.append(Rock.new(plane, cell, owner, left, total))
	return state


static func _signed_16(value: int) -> int:
	return value - 65536 if value >= 32768 else value
