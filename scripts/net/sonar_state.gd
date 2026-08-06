class_name SonarState
extends RefCounted
## Every piece of thieves' cant this particular player is allowed to read.
##
## This is an ADDRESSED complete picture. Cant deliberately reveals one location outside ordinary
## tunnel sight, so `TunnelSight.knows` is the wrong filter: an owning crew can always read its
## marks, and an enemy can read them only while that player's authoritative class is Sneak on the
## mark's plane. A full picture lets spawn, erasure, class/depth changes, packet loss and late
## joining all reconcile through the same operation.
##
## The temporary echo uses the same file but not the same state model. It is a reliable, private
## response sent only to the player who sounded; it expires rather than becoming world knowledge.

const MAX_MARKS: int = 512
const MAX_ECHO_CELLS: int = 255
## kind, revision, count.
const HEADER_SIZE: int = 1 + 4 + 2
## owner team, source plane, signed cell x/y, whose tunnel.
##
## THE LAST BYTE IS NEW, and it is the one field here that is not geometry. Whose corridor a mark
## names is part of the mark (see [SonarMark]), so it travels with it or a client draws the wrong
## glyph in the wrong colour -- and unlike the rest of this packet it cannot be recomputed at the
## far end, because the far end's network holds only what its own crew knows.
const MARK_SIZE: int = 1 + 1 + 2 + 2 + 1
## kind, source plane, count.
const ECHO_HEADER_SIZE: int = 1 + 1 + 1
## signed cell x/y, whose tunnel.
const ECHO_CELL_SIZE: int = 2 + 2 + 1


class Mark:
	var owner_team: int = Team.BLUE
	var plane: int = 0
	var cell: Vector2i = Vector2i.ZERO
	## BLUE, RED or [constant SonarMark.SHARED].
	var tunnel_team: int = SonarMark.SHARED

	func _init(
		by: int = Team.BLUE, source_plane: int = 0, at: Vector2i = Vector2i.ZERO,
		whose: int = SonarMark.SHARED
	) -> void:
		owner_team = by
		plane = source_plane
		cell = at
		tunnel_team = whose


var revision: int = 0
var marks: Array[Mark] = []


func add(
	owner_team: int, plane: int, cell: Vector2i, tunnel_team: int = SonarMark.SHARED
) -> void:
	if (
		marks.size() >= MAX_MARKS
		or owner_team < Team.BLUE or owner_team > Team.RED
		or plane < 0 or plane + 1 >= TunnelNetwork.PLANE_COUNT
		or not _cell_fits(cell)
		or tunnel_team < Team.BLUE or tunnel_team > SonarMark.SHARED
	):
		return
	marks.append(Mark.new(owner_team, plane, cell, tunnel_team))


func to_bytes() -> PackedByteArray:
	var out := NetMessage.head(NetMessage.Kind.SONAR_MARKS)
	out.put_u32(revision)
	out.put_u16(marks.size())
	for mark: Mark in marks:
		out.put_u8(mark.owner_team)
		out.put_u8(mark.plane)
		out.put_u16(mark.cell.x & 0xffff)
		out.put_u16(mark.cell.y & 0xffff)
		out.put_u8(mark.tunnel_team)
	return out.data_array


## Null on a partial, padded, impossible or duplicate picture. Marks of opposite crews may share
## a cell, so owner team is part of the identity rather than merely presentation data.
static func from_bytes(bytes: PackedByteArray) -> SonarState:
	if bytes.size() < HEADER_SIZE:
		return null
	var into := NetMessage.body(bytes, HEADER_SIZE)
	if into == null:
		return null

	var state := SonarState.new()
	state.revision = into.get_u32()
	var count := into.get_u16()
	if count > MAX_MARKS or bytes.size() != HEADER_SIZE + count * MARK_SIZE:
		return null

	var identities: Dictionary = {}
	for i: int in range(count):
		var owner_team := into.get_u8()
		var plane := into.get_u8()
		var cell := Vector2i(_signed_16(into.get_u16()), _signed_16(into.get_u16()))
		var tunnel_team := into.get_u8()
		# IDENTITY IS UNCHANGED BY THE NEW FIELD, deliberately. Whose corridor a mark names is a
		# property OF the mark, not part of which mark it is -- two marks cannot differ only in it,
		# and treating it as identity would make a junction forming under an existing mark look
		# like a second mark rather than like the same one saying something new.
		var identity := "%d:%d:%d:%d" % [owner_team, plane, cell.x, cell.y]
		if (
			owner_team < Team.BLUE or owner_team > Team.RED
			or plane + 1 >= TunnelNetwork.PLANE_COUNT
			or tunnel_team < Team.BLUE or tunnel_team > SonarMark.SHARED
			or identities.has(identity)
		):
			return null
		identities[identity] = true
		state.marks.append(Mark.new(owner_team, plane, cell, tunnel_team))
	return state


## The one player's short-lived scan result. Unlike cant this is not repeated: it is presentation
## for an action that just happened, and reliable delivery is its recovery path.
## THE OWNERS TRAVEL WITH THE CELLS AND CANNOT BE LEFT OUT. A client's tunnel network holds what
## its own crew knows, so a cell sonar has just found is usually a cell it has never heard of --
## asking it locally whose corridor that is returns "nobody knows about it", which renders as a
## junction. Every enemy tunnel would draw as contested, which is the one wrong answer that looks
## like a right one.
static func echo_to_bytes(
	source_plane: int, cells: Array[Vector2i], owners: Array[int]
) -> PackedByteArray:
	if source_plane < 0 or source_plane + 1 >= TunnelNetwork.PLANE_COUNT:
		return PackedByteArray()
	var accepted: Array[Vector2i] = []
	var accepted_owners: Array[int] = []
	for index in range(cells.size()):
		if accepted.size() >= MAX_ECHO_CELLS:
			break
		if not _cell_fits(cells[index]):
			continue
		accepted.append(cells[index])
		var whose: int = owners[index] if index < owners.size() else SonarMark.SHARED
		accepted_owners.append(clampi(whose, Team.BLUE, SonarMark.SHARED))
	var out := NetMessage.head(NetMessage.Kind.SONAR_ECHO)
	out.put_u8(source_plane)
	out.put_u8(accepted.size())
	for index in range(accepted.size()):
		out.put_u16(accepted[index].x & 0xffff)
		out.put_u16(accepted[index].y & 0xffff)
		out.put_u8(accepted_owners[index])
	return out.data_array


## `{}` means malformed; a valid reading contains `plane`, a typed `cells` array, and a parallel
## typed `owners` array.
static func echo_from_bytes(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < ECHO_HEADER_SIZE:
		return {}
	var into := NetMessage.body(bytes, ECHO_HEADER_SIZE)
	if into == null:
		return {}
	var plane := into.get_u8()
	var count := into.get_u8()
	if (
		plane + 1 >= TunnelNetwork.PLANE_COUNT
		or bytes.size() != ECHO_HEADER_SIZE + count * ECHO_CELL_SIZE
	):
		return {}
	var cells: Array[Vector2i] = []
	var owners: Array[int] = []
	for i: int in range(count):
		cells.append(Vector2i(_signed_16(into.get_u16()), _signed_16(into.get_u16())))
		var whose := into.get_u8()
		if whose < Team.BLUE or whose > SonarMark.SHARED:
			return {}
		owners.append(whose)
	return {"plane": plane, "cells": cells, "owners": owners}


static func _cell_fits(cell: Vector2i) -> bool:
	return (
		cell.x >= -32768 and cell.x <= 32767
		and cell.y >= -32768 and cell.y <= 32767
	)


static func _signed_16(value: int) -> int:
	return value - 65536 if value >= 32768 else value
