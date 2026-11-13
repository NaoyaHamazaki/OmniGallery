"""Blender の .blend を展示用の glb (オリジナル版 + 軽量版) に変換する。

Blender の中で実行する (UGC 投稿の自動変換にも流用する想定):
    blender.exe -b data/xxx.blend --python tools/convert_blend.py -- <出力先フォルダ> <名前> [軽量版の目標三角形数] [除外するオブジェクト名,...]

出力:
    <name>.glb        オリジナル版 (モディファイアを適用しただけ。高品質表示用)
    <name>_lite.glb   軽量版 (三角形数を目標まで削減 + テクスチャを長辺 1024px の JPEG に)
    <name>_report.json  検査結果 (オブジェクト数・三角形数・テクスチャ・ファイルサイズ)
"""

import json
import sys
from pathlib import Path

import bpy

LITE_TEXTURE_MAX = 1024


def args():
    a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    out = Path(a[0]) if a else Path.cwd()
    name = a[1] if len(a) > 1 else Path(bpy.data.filepath).stem
    target = int(a[2]) if len(a) > 2 else 60000
    exclude = set(a[3].split(",")) if len(a) > 3 and a[3] else set()
    return out, name, target, exclude


EXCLUDE: set = set()
STATIC = False  # True: 骨組みを書き出さず、今のポーズを適用した動かない形で書き出す


def is_static_pose() -> bool:
    """アクションがすべて 1 フレーム以下 (T ポーズなどの静止ポーズだけ) なら、動きのない作品とみなす。"""
    acts = list(bpy.data.actions)
    return all(a.frame_range[1] - a.frame_range[0] < 1.0 for a in acts)


def mesh_objects():
    return [o for o in bpy.context.scene.objects if o.type == "MESH" and o.visible_get() and o.name not in EXCLUDE]


def count_triangles(objs) -> int:
    dg = bpy.context.evaluated_depsgraph_get()
    total = 0
    for o in objs:
        m = o.evaluated_get(dg).to_mesh()
        total += sum(max(0, len(p.vertices) - 2) for p in m.polygons)
        o.evaluated_get(dg).to_mesh_clear()
    return total


def images_info():
    return [{"name": i.name, "size": list(i.size), "packed": i.packed_file is not None}
            for i in bpy.data.images if i.size[0] > 0]


def select_exportables() -> None:
    """書き出すのは表示中のメッシュと骨組みだけ (文字・カーブ・空オブジェクト・カメラ等は除外)。"""
    kinds = {"MESH"} if STATIC else {"MESH", "ARMATURE"}
    for o in bpy.context.scene.objects:
        o.select_set(o.visible_get() and o.type in kinds and o.name not in EXCLUDE)


IMAGE_KEYS = {  # 画像名に含まれる語 → 材質の入力
    "base": ("Base Color", "sRGB"), "albedo": ("Base Color", "sRGB"), "diffuse": ("Base Color", "sRGB"),
    "color": ("Base Color", "sRGB"),
    "rough": ("Roughness", "Non-Color"), "metal": ("Metallic", "Non-Color"),
    "normal": ("Normal", "Non-Color"), "emiss": ("Emission Color", "sRGB"),
}


def has_principled(mat) -> bool:
    return bool(mat and mat.use_nodes and any(n.type == "BSDF_PRINCIPLED" for n in mat.node_tree.nodes))


def upstream_image(socket):
    """ソケットの上流をたどって最初の画像ノードを探す (色調補正などのノードを飛ばす)。"""
    seen = set()
    stack = [l.from_node for l in socket.links]
    while stack:
        n = stack.pop()
        if n in seen:
            continue
        seen.add(n)
        if n.type == "TEX_IMAGE" and n.image:
            return n
        for inp in n.inputs:
            stack.extend(l.from_node for l in inp.links)
    return None


def flatten_udim() -> list[str]:
    """UDIM (タイル分割) の画像は glTF に書き出せないので、最初のタイル (1001) を通常の 1 枚画像に置き換える。"""
    import numpy as np
    done = []
    for mat in bpy.data.materials:
        if not mat.users or not mat.use_nodes:
            continue
        for n in mat.node_tree.nodes:
            img = getattr(n, "image", None)
            if n.type != "TEX_IMAGE" or img is None or img.source != "TILED":
                continue
            w, h = img.size
            flat = bpy.data.images.new(img.name.replace(".1001", "") + "_flat", w, h, alpha=True,
                                       float_buffer=img.is_float)
            buf = np.empty(w * h * 4, dtype=np.float32)
            img.pixels.foreach_get(buf)
            flat.pixels.foreach_set(buf)
            flat.colorspace_settings.name = img.colorspace_settings.name
            flat.pack()
            n.image = flat
            done.append(img.name)
    return done


def simplify_principled() -> list[str]:
    """glTF の書き出しは Principled に「画像ノードが直結」している場合しかテクスチャを拾えない。
    間に色調補正 (Hue/Saturation 等) が挟まっていたら、画像を直接つなぎ直す。"""
    fixed = []
    for mat in bpy.data.materials:
        if not mat.users or not has_principled(mat):
            continue
        nt = mat.node_tree
        for bsdf in [n for n in nt.nodes if n.type == "BSDF_PRINCIPLED"]:
            for name in ("Base Color", "Emission Color", "Metallic", "Roughness", "Alpha"):
                sock = bsdf.inputs.get(name)
                if sock is None or not sock.links or sock.links[0].from_node.type == "TEX_IMAGE":
                    continue
                img = upstream_image(sock)
                if img:
                    nt.links.new(img.outputs["Color"], sock)
                    fixed.append(f"{mat.name}.{name} <- {img.image.name}")
    return fixed


def rebuild_materials() -> list[str]:
    """Octane など外部レンダラー専用の材質は glTF に書き出せないので、Principled BSDF に組み直す。
    材質内の画像ノード → なければファイル内の画像を名前 (BaseColor / Normal / Roughness ...) で探して接続する。"""
    rebuilt = []
    images = [i for i in bpy.data.images if i.size[0] > 0]
    for o in bpy.context.scene.objects:
        if o.type != "MESH" or not o.visible_get():
            continue
        for slot in o.material_slots:
            mat = slot.material
            if mat is None or has_principled(mat):
                continue
            nm = bpy.data.materials.new(f"{mat.name}_export")
            nm.use_nodes = True
            nt = nm.node_tree
            bsdf = next(n for n in nt.nodes if n.type == "BSDF_PRINCIPLED")
            local = [n.image for n in (mat.node_tree.nodes if mat.use_nodes else []) if getattr(n, "image", None)]
            used = set()
            for img in (local or images):
                key = next((k for k in IMAGE_KEYS if k in img.name.lower()), None)
                if key is None or IMAGE_KEYS[key][0] in used:
                    continue
                socket, space = IMAGE_KEYS[key]
                used.add(socket)
                tex = nt.nodes.new("ShaderNodeTexImage")
                tex.image = img
                img.colorspace_settings.name = space
                if socket == "Normal":
                    nmap = nt.nodes.new("ShaderNodeNormalMap")
                    nt.links.new(tex.outputs["Color"], nmap.inputs["Color"])
                    nt.links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])
                else:
                    nt.links.new(tex.outputs["Color"], bsdf.inputs[socket])
                    if socket == "Emission Color":
                        bsdf.inputs["Emission Strength"].default_value = 1.0
            slot.material = nm
            rebuilt.append(f"{mat.name} -> {sorted(used)}")
    return rebuilt


def export(path: Path, lite: bool) -> None:
    select_exportables()
    kw = dict(filepath=str(path), export_format="GLB", use_selection=True, export_apply=True,
              export_cameras=False, export_lights=False)
    if STATIC:  # 骨組みによる変形を適用した形で書き出す (表示位置・大きさが見た目どおりになる)
        kw.update(export_skins=False, export_animations=False, export_morph=False)
    if lite:
        kw["export_image_format"] = "JPEG"
    try:
        bpy.ops.export_scene.gltf(**kw)
    except TypeError:  # 古い/新しい Blender で引数名が違う場合
        kw.pop("export_image_format", None)
        bpy.ops.export_scene.gltf(**kw)


def main():
    global EXCLUDE, STATIC
    out, name, target, EXCLUDE = args()
    STATIC = is_static_pose()
    out.mkdir(parents=True, exist_ok=True)
    objs = mesh_objects()
    report = {
        "source": Path(bpy.data.filepath).name,
        "blender": bpy.app.version_string,
        "objects": [{"name": o.name, "type": o.type} for o in bpy.context.scene.objects if o.visible_get()],
        "mesh_count": len(objs),
        "excluded": sorted(EXCLUDE),
        "static_pose": STATIC,
        "triangles_original": count_triangles(objs),
        "images": images_info(),
    }

    report["udim_flattened"] = flatten_udim()
    report["materials_rebuilt"] = rebuild_materials()
    report["materials_simplified"] = simplify_principled()

    # 1) オリジナル版
    orig = out / f"{name}.glb"
    export(orig, lite=False)
    report["original_mb"] = round(orig.stat().st_size / 1048576, 2)

    # 2) 軽量版: 三角形数を目標まで減らし、テクスチャを縮小
    ratio = min(1.0, target / max(1, report["triangles_original"]))
    report["decimate_ratio"] = round(ratio, 4)
    if ratio < 1.0:
        for o in objs:
            mod = o.modifiers.new("LiteDecimate", "DECIMATE")
            mod.ratio = ratio
            mod.use_collapse_triangulate = True
    for img in bpy.data.images:
        w, h = img.size
        if w > LITE_TEXTURE_MAX or h > LITE_TEXTURE_MAX:
            s = LITE_TEXTURE_MAX / max(w, h)
            img.scale(max(1, int(w * s)), max(1, int(h * s)))
    report["triangles_lite"] = count_triangles(objs)
    lite = out / f"{name}_lite.glb"
    export(lite, lite=True)
    report["lite_mb"] = round(lite.stat().st_size / 1048576, 2)

    (out / f"{name}_report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print("REPORT", json.dumps(report, ensure_ascii=False))


main()
