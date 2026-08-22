import bpy
import math
from mathutils import Vector


OUTPUT_BLEND = "assets/3d/basic_mouse/basic_mouse.blend"
OUTPUT_GLB = "assets/3d/basic_mouse/basic_mouse.glb"
OUTPUT_RENDER = "assets/3d/basic_mouse/basic_mouse_preview.png"


def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.materials, bpy.data.curves, bpy.data.meshes, bpy.data.cameras, bpy.data.lights):
        for block in list(datablocks):
            if block.users == 0:
                datablocks.remove(block)


def material(name, color, roughness=0.55, metallic=0.0):
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = (*color, 1.0)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    return mat


def smooth_mesh(obj):
    if obj.type == "MESH":
        for poly in obj.data.polygons:
            poly.use_smooth = True


def uv_sphere(name, location, scale, mat, segments=48, rings=32):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segments, ring_count=rings, location=location)
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    smooth_mesh(obj)
    obj.data.materials.append(mat)
    return obj


def curve_tube(name, points, radius, mat, bevel_resolution=5):
    curve = bpy.data.curves.new(name, "CURVE")
    curve.dimensions = "3D"
    curve.resolution_u = 16
    curve.bevel_depth = radius
    curve.bevel_resolution = bevel_resolution
    spline = curve.splines.new("BEZIER")
    spline.bezier_points.add(len(points) - 1)
    for bp, co in zip(spline.bezier_points, points):
        bp.co = co
        bp.handle_left_type = "AUTO"
        bp.handle_right_type = "AUTO"
    obj = bpy.data.objects.new(name, curve)
    bpy.context.collection.objects.link(obj)
    obj.data.materials.append(mat)
    return obj


def aim_at(obj, target):
    obj.rotation_euler = (Vector(target) - obj.location).to_track_quat("-Z", "Y").to_euler()


clear_scene()

fur = material("Warm Gray Fur", (0.34, 0.25, 0.23), 0.78)
fur_light = material("Muzzle Fur", (0.67, 0.51, 0.43), 0.82)
pink = material("Ear and Paw Pink", (0.83, 0.31, 0.35), 0.62)
inner_ear = material("Inner Ear", (1.0, 0.48, 0.51), 0.68)
black = material("Eyes", (0.012, 0.009, 0.012), 0.18)
white = material("Eye Highlights", (1.0, 1.0, 1.0), 0.12)
ground_mat = material("Ground", (0.12, 0.15, 0.17), 0.88)

# Body and head: deliberately simple, soft primitives that are easy to edit later.
body = uv_sphere("Body", (0.0, 0.0, 1.50), (1.03, 0.78, 1.18), fur)
head = uv_sphere("Head", (0.0, -0.18, 2.78), (1.12, 0.88, 0.98), fur)
muzzle = uv_sphere("Muzzle", (0.0, -0.94, 2.55), (0.65, 0.36, 0.43), fur_light)

# Ears use flattened spheres, giving a friendly graphic silhouette.
for side in (-1, 1):
    ear = uv_sphere(f"Ear_{side:+d}", (0.84 * side, -0.05, 3.43), (0.66, 0.25, 0.73), fur)
    ear.rotation_euler.y = math.radians(-10 * side)
    inner = uv_sphere(f"Inner_Ear_{side:+d}", (0.85 * side, -0.27, 3.43), (0.46, 0.12, 0.53), inner_ear)
    inner.rotation_euler.y = math.radians(-10 * side)

# Eyes, highlights, nose, and a tiny mouth line.
for side in (-1, 1):
    uv_sphere(f"Eye_{side:+d}", (0.41 * side, -0.91, 2.91), (0.18, 0.10, 0.25), black)
    uv_sphere(f"Eye_Highlight_{side:+d}", (0.36 * side, -1.01, 3.00), (0.055, 0.035, 0.072), white, 24, 16)
nose = uv_sphere("Nose", (0.0, -1.30, 2.65), (0.22, 0.16, 0.16), pink)
curve_tube("Mouth", [(0.0, -1.305, 2.54), (0.0, -1.31, 2.43), (0.12, -1.28, 2.38)], 0.018, black, 3)

# Arms, feet, and small pink paws.
for side in (-1, 1):
    arm = uv_sphere(f"Arm_{side:+d}", (0.78 * side, -0.34, 1.64), (0.31, 0.31, 0.72), fur)
    arm.rotation_euler.x = math.radians(-12)
    arm.rotation_euler.y = math.radians(15 * side)
    uv_sphere(f"Hand_{side:+d}", (0.88 * side, -0.52, 1.12), (0.28, 0.26, 0.27), pink)
    uv_sphere(f"Foot_{side:+d}", (0.58 * side, -0.36, 0.48), (0.47, 0.64, 0.25), pink)

# Tail curves out to camera-right and up.
curve_tube(
    "Tail",
    [(0.72, 0.20, 1.06), (1.55, 0.30, 0.92), (2.05, -0.05, 1.18), (2.18, -0.20, 1.82), (2.02, -0.28, 2.22)],
    0.105,
    pink,
    6,
)

# Whiskers are subtle and slightly asymmetric to avoid a sterile look.
for side in (-1, 1):
    for i, dz in enumerate((-0.14, 0.0, 0.14)):
        z = 2.54 + dz
        y_end = -1.20 + 0.035 * abs(i - 1)
        curve_tube(
            f"Whisker_{side:+d}_{i}",
            [(0.36 * side, -1.20, z), (0.76 * side, -1.30, z + dz * 0.25), (1.18 * side, y_end, z + dz * 0.52)],
            0.012,
            black,
            2,
        )

# Ground plane.
bpy.ops.mesh.primitive_plane_add(size=20, location=(0, 0, 0.17))
ground = bpy.context.object
ground.name = "Ground"
ground.data.materials.append(ground_mat)

# Camera and soft studio lighting.
bpy.ops.object.camera_add(location=(6.3, -9.5, 5.4))
camera = bpy.context.object
camera.name = "Camera"
camera.data.lens = 58
aim_at(camera, (0.25, -0.05, 2.05))
bpy.context.scene.camera = camera

def area_light(name, location, energy, size, color):
    bpy.ops.object.light_add(type="AREA", location=location)
    light = bpy.context.object
    light.name = name
    light.data.energy = energy
    light.data.shape = "DISK"
    light.data.size = size
    light.data.color = color
    aim_at(light, (0, 0, 2.0))
    return light

area_light("Key", (-4.5, -5.0, 7.5), 1050, 5.0, (1.0, 0.80, 0.68))
area_light("Fill", (4.5, -2.0, 4.8), 700, 4.0, (0.57, 0.72, 1.0))
area_light("Rim", (1.0, 4.2, 6.0), 900, 3.0, (1.0, 0.42, 0.30))

scene = bpy.context.scene
scene.render.engine = "BLENDER_EEVEE"
scene.render.resolution_x = 700
scene.render.resolution_y = 700
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "PNG"
scene.render.film_transparent = False
scene.render.filepath = OUTPUT_RENDER
scene.render.image_settings.color_mode = "RGBA"
scene.world.color = (0.025, 0.035, 0.05)
scene.view_settings.look = "AgX - Medium High Contrast"

# Organize model parts for convenient selection.
mouse_collection = bpy.data.collections.new("Mouse")
scene.collection.children.link(mouse_collection)
for obj in list(scene.collection.objects):
    if obj.name not in {"Ground", "Camera", "Key", "Fill", "Rim"}:
        for collection in list(obj.users_collection):
            collection.objects.unlink(obj)
        mouse_collection.objects.link(obj)

bpy.ops.wm.save_as_mainfile(filepath=OUTPUT_BLEND)
scene.render.filepath = OUTPUT_RENDER
bpy.ops.render.render(write_still=True)
# Export from a temporary asset-only scene state. The saved .blend still retains
# the studio setup because it was written above.
for staging_name in ("Ground", "Camera", "Key", "Fill", "Rim"):
    staging_obj = bpy.data.objects.get(staging_name)
    if staging_obj:
        bpy.data.objects.remove(staging_obj, do_unlink=True)
bpy.ops.export_scene.gltf(filepath=OUTPUT_GLB, export_format="GLB")
print(f"Created {OUTPUT_BLEND}, {OUTPUT_GLB}, and {OUTPUT_RENDER}")
