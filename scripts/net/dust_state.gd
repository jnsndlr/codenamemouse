class_name DustState
extends RefCounted
## A filtered complete picture of live clouds. Repeated pictures repair loss and late joins;
## age keeps them from restarting whenever a packet arrives.

const HEADER_SIZE: int = 6
const CLOUD_SIZE: int = 8 + 1 + 1 + 12 + 4 + 4 + 4
const MAX_CLOUDS: int = 64

class Cloud:
	var id: int
	var owner: int = 255
	var plane: int
	var at: Vector3
	var radius: float
	var age: float
	var seconds: float

var revision: int = 0
var clouds: Array[Cloud] = []


func to_bytes() -> PackedByteArray:
	var out := NetMessage.head(NetMessage.Kind.DUST)
	out.put_u32(revision)
	out.put_u8(clouds.size())
	for cloud: Cloud in clouds:
		out.put_u64(cloud.id)
		out.put_u8(cloud.owner)
		out.put_u8(cloud.plane)
		out.put_float(cloud.at.x)
		out.put_float(cloud.at.y)
		out.put_float(cloud.at.z)
		out.put_float(cloud.radius)
		out.put_float(cloud.age)
		out.put_float(cloud.seconds)
	return out.data_array


static func from_bytes(bytes: PackedByteArray) -> DustState:
	var into := NetMessage.body(bytes, HEADER_SIZE)
	if into == null:
		return null
	var state := DustState.new()
	state.revision = into.get_u32()
	var count := into.get_u8()
	if count > MAX_CLOUDS or bytes.size() != HEADER_SIZE + count * CLOUD_SIZE:
		return null
	var ids := {}
	for i in range(count):
		var cloud := Cloud.new()
		cloud.id = into.get_u64()
		cloud.owner = into.get_u8()
		cloud.plane = into.get_u8()
		cloud.at = Vector3(into.get_float(), into.get_float(), into.get_float())
		cloud.radius = into.get_float()
		cloud.age = into.get_float()
		cloud.seconds = into.get_float()
		if ids.has(cloud.id) or cloud.plane >= TunnelNetwork.PLANE_COUNT or not cloud.at.is_finite():
			return null
		if not is_finite(cloud.radius) or not is_finite(cloud.age) or not is_finite(cloud.seconds):
			return null
		if cloud.radius <= 0.0 or cloud.radius > 100.0 or cloud.seconds <= 0.0 or cloud.seconds > 60.0 or cloud.age < 0.0:
			return null
		ids[cloud.id] = true
		state.clouds.append(cloud)
	return state
