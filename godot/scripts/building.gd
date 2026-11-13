class_name Building
extends Node3D
## 展示棟をコードで生成する。
##   - 2フロア: 階高 5.5m / 天井高 5.0m (美術館らしい開放感のため 4〜6m を確保)
##   - 西側 (x < 9) がギャラリー、東側が吹き抜け (階段・上り/下りエスカレーター・エレベーター)
##   - 床はヘリンボーンの寄木、壁はわずかに暖色のオフホワイト + 完全マット
## レイアウト定数は gallery_manager.gd / floor_map.gd からも参照する。
##
## 平面図 (上が北 = -Z)
##   x: -15 ............................ 9 | 9 ............. 17
##      [        ギャラリー             ]  |  EV   (北側ロビー)
##      [  作品・台座・ベンチ            ] 開口  階段 ESC↑ ESC↓ (z -1.5 → 8 で 1F→2F が下がる)
##      [  入口 (1F 南壁 x=-3)          ]  |  (南側通路)

const FLOORS := 2
const FLOOR_HEIGHT := 5.5
const CEILING_HEIGHT := 5.0
const SLAB := 0.5
const WALL_T := 0.3
const X_MIN := -15.0
const X_MAX := 17.0
const Z_MIN := -10.0
const Z_MAX := 10.0
const PARTITION_X := 9.0
const SPAWN := Vector3(-3.0, 0.2, 8.3)
const SPAWN_YAW := 0.0  # 北 (正面の壁のメイン作品) を向く

const RAMP_Z_BOTTOM := 8.0
const RAMP_Z_TOP := -1.5
const STAIRS_X := Vector2(10.5, 12.3)
const ESC_UP_X := Vector2(12.7, 13.9)
const ESC_DOWN_X := Vector2(14.3, 15.5)
const ESCALATOR_SPEED := 0.9
const STEP_LENGTH := 0.4
const VOID_RECT := Rect2(10.5, -1.5, 5.0, 5.0)  # 2F 床の吹き抜け (x, z, 幅x, 奥行z)
const SHAFT_RECT := Rect2(10.5, -10.0, 3.0, 3.0)  # エレベーターシャフト外形
const SHAFT_DOOR_Z := -7.1
const OPENING_HEIGHT := 3.4
## 階ごとの間仕切り壁 (x=9) の開口 [z_from, z_to]
const PARTITION_OPENINGS := [
	[Vector2(-6.0, -2.0), Vector2(6.0, 9.5)],
	[Vector2(-6.0, -2.0)],
]
const MAX_SEGMENT := 4.0  # 壁・床を分割する最大長 (1メッシュあたりのライト数上限対策)

var floor_titles: Array = ["1F", "2F"]
## フロアマップ用の図形 {floor, rect (xz), kind, label}
var map_items: Array = []
var map_viewport: SubViewport
var elevator: Elevator

var mat_parquet: StandardMaterial3D
var mat_stone: StandardMaterial3D
var mat_wall: StandardMaterial3D
var mat_ceiling: StandardMaterial3D
var mat_shaft: StandardMaterial3D
var mat_metal: StandardMaterial3D
var mat_dark: StandardMaterial3D
var mat_glass: StandardMaterial3D
var mat_wood: StandardMaterial3D
var mat_plinth: StandardMaterial3D
var mat_rubber: StandardMaterial3D

var _escalator_mats: Array = []  # [{mat, dir}]
var _floor_signs: Array = []  # Label3D (フロア名)

@onready var _api: ApiClient = get_node_or_null("%Api")
@onready var _ui: GalleryUI = get_node_or_null("%UI")


const SLICE_USEC := 4000  # 1 フレームあたりの生成作業の上限 (これを超えたら次フレームへ)
const LAYER_INDOOR := 1

var built := false
var _slice_start := 0


func _ready() -> void:
	# ここではマテリアルだけ作る。建物本体は build_async() で数フレームに分けて生成する
	_create_materials()
	if _api:
		_load_textures()


## 館内を時間分割で生成する (1 フレームに SLICE_USEC 以上かけない → 屋外を歩いている間も固まらない)。
## progress: func(ratio: float) 進捗通知
func build_async(progress: Callable = Callable()) -> void:
	_slice_start = Time.get_ticks_usec()
	var steps: Array[Callable] = [
		_build_floor_walls.bind(0), _build_floor_walls.bind(1), _build_slabs, _build_ramps,
		_build_void_railings, _build_lights, _build_entrance, _build_benches, _build_signs,
		_build_elevator, _build_transit_zones, _build_map_kiosks,
	]
	for i in steps.size():
		await steps[i].call()
		await _tick()
		if progress.is_valid():
			progress.call(float(i + 1) / steps.size())
	built = true


## 作業時間が上限を超えていたら 1 フレーム待つ
func _tick() -> void:
	if Time.get_ticks_usec() - _slice_start > SLICE_USEC:
		await get_tree().process_frame
		_slice_start = Time.get_ticks_usec()


func _build_elevator() -> void:
	elevator = Elevator.new()
	elevator.name = "Elevator"
	add_child(elevator)
	elevator.build(self)


func _build_map_kiosks() -> void:
	_create_map_viewport()
	_map_board(Vector3(0.0, 0.0, 5.0), Vector3(SPAWN.x, 0, SPAWN.z))
	_map_board(Vector3(16.2, FLOOR_HEIGHT, -4.0), Vector3(13.0, FLOOR_HEIGHT, -1.5))


## 階段・エスカレーターの乗り口。前を向いて進むと自動移動 (その間に移動先フロアを準備)
func _build_transit_zones() -> void:
	var stairs := (STAIRS_X.x + STAIRS_X.y) / 2.0
	var up := (ESC_UP_X.x + ESC_UP_X.y) / 2.0
	var down := (ESC_DOWN_X.x + ESC_DOWN_X.y) / 2.0
	_transit(stairs, true, 1.8, "Stairs")
	_transit(stairs, false, 1.8, "Stairs")
	_transit(up, true, 1.3, "Escalator")
	_transit(down, false, 1.3, "Escalator")


func _transit(x: float, going_up: bool, speed: float, kind: String) -> void:
	var z := TransitZone.new()
	z.kind = kind
	z.speed = speed
	z.going_up = going_up
	z.dest_floor = 1 if going_up else 0
	var half := 0.6 if kind == "Escalator" else 0.9
	z.lane = Vector2(x - half, x + half)
	var top := FLOOR_HEIGHT
	if going_up:
		z.points = PackedVector3Array([Vector3(x, top, RAMP_Z_TOP), Vector3(x, top, RAMP_Z_TOP - 1.7)])
	else:
		z.points = PackedVector3Array([Vector3(x, 0, RAMP_Z_BOTTOM), Vector3(x, 0, RAMP_Z_BOTTOM + 1.8)])
	add_child(z)


func _process(delta: float) -> void:
	for e in _escalator_mats:
		var m: StandardMaterial3D = e["mat"]
		m.uv1_offset.y = fmod(m.uv1_offset.y + e["dir"] * ESCALATOR_SPEED / STEP_LENGTH * delta, 1.0)


# ---------------------------------------------------------------------------
# 公開 API (gallery_manager / floor_map 用)
# ---------------------------------------------------------------------------
static func floor_y(f: int) -> float:
	return f * FLOOR_HEIGHT


static func floor_of(y: float) -> int:
	return clampi(int(floor((y + 1.0) / FLOOR_HEIGHT)), 0, FLOORS - 1)


## 絵画の展示位置。先頭がそのフロアのアイストップ (入ってきた正面の突き当たり)。
## pos は壁面上の点 (高さは床面)、normal は部屋側を向く法線。
func get_painting_slots(f: int) -> Array:
	var y := floor_y(f)
	var px := PARTITION_X - WALL_T / 2.0
	var s: Array = []
	if f == 0:
		s.append(_slot(Vector3(-3.0, y, Z_MIN), Vector3.BACK, true))  # 入口から正面
		for x in [-10.5, 4.5]:
			s.append(_slot(Vector3(x, y, Z_MIN), Vector3.BACK))
		for z in [-5.0, 0.0, 5.0]:
			s.append(_slot(Vector3(X_MIN, y, z), Vector3.RIGHT))
		for z in [2.0, -8.0]:
			s.append(_slot(Vector3(px, y, z), Vector3.LEFT))
		for x in [-10.5, 4.5]:
			s.append(_slot(Vector3(x, y, Z_MAX), Vector3.FORWARD))
	else:
		s.append(_slot(Vector3(X_MIN, y, -4.0), Vector3.RIGHT, true))  # 吹き抜けから入った正面
		for x in [-10.5, -3.0, 4.5]:
			s.append(_slot(Vector3(x, y, Z_MIN), Vector3.BACK))
		for z in [3.0, 7.5]:
			s.append(_slot(Vector3(X_MIN, y, z), Vector3.RIGHT))
		for z in [2.0, 6.5, -8.0]:
			s.append(_slot(Vector3(px, y, z), Vector3.LEFT))
		for x in [-10.5, -3.0, 4.5]:
			s.append(_slot(Vector3(x, y, Z_MAX), Vector3.FORWARD))
	return s


func _slot(wall_point: Vector3, normal: Vector3, featured: bool = false) -> Dictionary:
	return {
		"pos": wall_point, "normal": normal, "floor_y": wall_point.y, "featured": featured,
		"hang": 2.0 if featured else 1.65,  # 絵の中心の高さ
		"max_size": Vector2(3.4, 2.6) if featured else Vector2(2.4, 1.8),
	}


## 3D 作品の台座位置。facing はキャプションを置く向き (主動線側)。
func get_pedestal_slots(f: int) -> Array:
	var y := floor_y(f)
	if f == 0:
		return [
			{"pos": Vector3(-9.5, y, 1.0), "facing": Vector3.BACK},
			{"pos": Vector3(3.5, y, 1.0), "facing": Vector3.BACK},
		]
	return [
		{"pos": Vector3(-9.0, y, 3.5), "facing": Vector3.FORWARD},
		{"pos": Vector3(3.0, y, 3.5), "facing": Vector3.FORWARD},
	]


## デバッグ端末を置く場所 (1F 入口脇)
func get_debug_terminal_spot() -> Dictionary:
	return {"pos": Vector3(-6.0, 0.0, 5.0), "toward": Vector3(SPAWN.x, 0.0, SPAWN.z)}


func set_floor_titles(floors: Array) -> void:
	for i in mini(floors.size(), FLOORS):
		var fl: Dictionary = floors[i]
		floor_titles[i] = "%s  %s" % [fl.get("name", "%dF" % (i + 1)), fl.get("title", "")]
	for i in _floor_signs.size():
		_floor_signs[i].text = floor_titles[i].to_upper()


func add_map_item(f: int, rect: Rect2, kind: String, label: String = "") -> void:
	map_items.append({"floor": f, "rect": rect, "kind": kind, "label": label})


# ---------------------------------------------------------------------------
# マテリアル
# ---------------------------------------------------------------------------
func _create_materials() -> void:
	mat_parquet = _mat(Color(0.42, 0.29, 0.18), 0.6)
	_triplanar(mat_parquet, 0.45)
	mat_stone = _mat(Color(0.62, 0.58, 0.5), 0.7)
	_triplanar(mat_stone, 0.3)
	# 壁: 純白を避けたわずかに暖かいオフホワイト。Roughness 1 / Metallic 0 の完全マット
	mat_wall = _mat(Color(0.91, 0.89, 0.85), 1.0)
	_triplanar(mat_wall, 0.5)
	mat_ceiling = _mat(Color(0.82, 0.81, 0.79), 1.0)
	mat_shaft = _mat(Color(0.33, 0.32, 0.31), 0.8)
	mat_metal = _mat(Color(0.62, 0.62, 0.64), 0.35, 0.8)
	mat_dark = _mat(Color(0.08, 0.08, 0.09), 0.6)
	mat_wood = _mat(Color(0.4, 0.27, 0.16), 0.55)
	mat_plinth = _mat(Color(0.93, 0.92, 0.89), 0.95)
	mat_rubber = _mat(Color(0.05, 0.05, 0.05), 0.7)
	mat_glass = _mat(Color(0.75, 0.85, 0.9, 0.18), 0.05, 0.1)
	mat_glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat_glass.cull_mode = BaseMaterial3D.CULL_DISABLED


func _mat(color: Color, roughness: float, metallic: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m


func _triplanar(m: StandardMaterial3D, scale: float) -> void:
	# CSG/BoxMesh の UV は面ごとに 0..1 なので、ワールド座標基準の三平面投影でタイル状に貼る
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_scale = Vector3.ONE * scale
	m.uv1_triplanar_sharpness = 4.0


## テクスチャはバックエンドから実行時に取得する (Godot のインポート不要 / 将来フロアごとに差し替え可能)。
## 取得前・失敗時は単色のまま。
func _load_textures() -> void:
	_apply_texture(mat_parquet, "floor_parquet", true, true, 1.0)
	_apply_texture(mat_stone, "floor_stone", true, true, 1.0)
	_apply_texture(mat_wall, "wall_plaster", false, false, 0.6)


func _apply_texture(m: StandardMaterial3D, key: String, diffuse: bool, rough: bool, normal_scale: float) -> void:
	var base := "/static/textures/%s_" % key
	if diffuse:
		var d := await _api.get_texture(base + "diff.jpg")
		if d:
			m.albedo_texture = d
			m.albedo_color = Color.WHITE
	var n := await _api.get_texture(base + "nor.jpg")
	if n:
		m.normal_enabled = true
		m.normal_texture = n
		m.normal_scale = normal_scale
	if rough:
		var r := await _api.get_texture(base + "rough.jpg")
		if r:
			m.roughness_texture = r
			m.roughness = 1.0


# ---------------------------------------------------------------------------
# ジオメトリのヘルパー
# ---------------------------------------------------------------------------
func _box(center: Vector3, size: Vector3, mat: Material, collide: bool = true, parent: Node = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = center
	# 影を落とすのは 3D 作品とその台座だけに限定 (建物の大きな面を影の計算から外して軽量化)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	(parent if parent else self).add_child(mi)
	if collide:
		var body := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		cs.shape = shape
		body.add_child(cs)
		mi.add_child(body)
	return mi


## 傾斜に沿った板 (手すり・ガラス腰壁・エスカレーターの踏面など)。x0..x1 の幅、斜面から height の高さ。
func _slanted_box(x0: float, x1: float, height: float, offset_above: float, mat: Material, collide: bool) -> MeshInstance3D:
	var run := RAMP_Z_BOTTOM - RAMP_Z_TOP
	var length := sqrt(run * run + FLOOR_HEIGHT * FLOOR_HEIGHT)
	var ang := atan2(FLOOR_HEIGHT, run)
	var normal := Vector3(0, cos(ang), sin(ang))
	var mid := Vector3((x0 + x1) / 2.0, FLOOR_HEIGHT / 2.0, (RAMP_Z_BOTTOM + RAMP_Z_TOP) / 2.0)
	var mi := _box(mid + normal * (offset_above + height / 2.0), Vector3(x1 - x0, height, length), mat, collide)
	mi.rotation.x = ang
	return mi


## 1F 床から 2F 床まで上がる楔形 (北に向かって上り)。
func _wedge(x0: float, x1: float, mat: Material, collide: bool) -> CSGPolygon3D:
	var run := RAMP_Z_BOTTOM - RAMP_Z_TOP
	var csg := CSGPolygon3D.new()
	csg.polygon = PackedVector2Array([Vector2(0, 0), Vector2(run, 0), Vector2(run, FLOOR_HEIGHT)])
	csg.depth = x1 - x0
	csg.rotation.y = PI / 2.0  # ローカル +X → ワールド -Z、押し出し(-Z) → ワールド -X
	csg.position = Vector3(x1, 0.0, RAMP_Z_BOTTOM)
	csg.material = mat
	csg.use_collision = collide
	add_child(csg)
	return csg


func _label(text: String, pos: Vector3, normal: Vector3, font_size: int = 64, pixel: float = 0.006,
		color: Color = Color(0.2, 0.19, 0.18)) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font = GalleryFonts.title()
	l.font_size = font_size
	l.pixel_size = pixel * 0.9  # Cinzel は字幅が広いので少し小さめに
	l.modulate = color
	l.outline_size = 0
	l.double_sided = false
	l.position = pos
	l.rotation.y = atan2(normal.x, normal.z)
	add_child(l)
	return l


## 区間を最大長ごとに等分する
func _split(a: float, b: float, max_len: float) -> Array:
	var n := maxi(1, ceili((b - a) / max_len - 0.001))
	var out: Array = []
	for i in n:
		out.append(Vector2(a + (b - a) * i / n, a + (b - a) * (i + 1) / n))
	return out


## 開口付きの壁。along_x=true なら x 方向に伸びる壁 (z=fixed)。openings は [Vector2(from, to)]。
func _wall(along_x: bool, fixed: float, a0: float, a1: float, y0: float, y1: float, openings: Array,
		open_h: float, t: float, mat: Material, f: int) -> void:
	var solids: Array = []
	var cursor := a0
	var ops := openings.duplicate()
	ops.sort_custom(func(p, q): return p.x < q.x)
	for o in ops:
		if o.x > cursor:
			solids.append(Vector2(cursor, o.x))
		# 開口の上の垂れ壁
		_wall_piece(along_x, fixed, o.x, o.y, y0 + open_h, y1, t, mat)
		cursor = o.y
	if cursor < a1:
		solids.append(Vector2(cursor, a1))
	for s in solids:
		for seg in _split(s.x, s.y, MAX_SEGMENT):
			_wall_piece(along_x, fixed, seg.x, seg.y, y0, y1, t, mat)
			await _tick()
		var r := Rect2(s.x, fixed - t / 2.0, s.y - s.x, t) if along_x else Rect2(fixed - t / 2.0, s.x, t, s.y - s.x)
		add_map_item(f, r, "wall")


func _wall_piece(along_x: bool, fixed: float, a: float, b: float, y0: float, y1: float, t: float, mat: Material) -> void:
	var mid := (a + b) / 2.0
	var center := Vector3(mid, (y0 + y1) / 2.0, fixed) if along_x else Vector3(fixed, (y0 + y1) / 2.0, mid)
	var size := Vector3(b - a, y1 - y0, t) if along_x else Vector3(t, y1 - y0, b - a)
	_box(center, size, mat)


# ---------------------------------------------------------------------------
# 建物
# ---------------------------------------------------------------------------
func _build_floor_walls(f: int) -> void:
	var y0 := floor_y(f)
	var y1 := y0 + FLOOR_HEIGHT
	var t := WALL_T
	await _wall(false, X_MIN - t / 2.0, Z_MIN - t, Z_MAX + t, y0, y1, [], 0.0, t, mat_wall, f)  # 西
	await _wall(false, X_MAX + t / 2.0, Z_MIN - t, Z_MAX + t, y0, y1, [], 0.0, t, mat_wall, f)  # 東
	await _wall(true, Z_MIN - t / 2.0, X_MIN, X_MAX, y0, y1, [], 0.0, t, mat_wall, f)  # 北
	# 南 (1F は正面入口の開口。扉は outdoor.gd)
	var entrance: Array = [Vector2(Outdoor.DOOR_X - Outdoor.DOOR_W / 2.0, Outdoor.DOOR_X + Outdoor.DOOR_W / 2.0)] if f == 0 else []
	await _wall(true, Z_MAX + t / 2.0, X_MIN, X_MAX, y0, y1, entrance, Outdoor.DOOR_H, t, mat_wall, f)
	await _wall(false, PARTITION_X, Z_MIN, Z_MAX, y0, y1, PARTITION_OPENINGS[f], OPENING_HEIGHT, t, mat_wall, f)
	# エレベーターシャフト (南面に乗場の開口)
	var sx0 := SHAFT_RECT.position.x
	var sx1 := SHAFT_RECT.end.x
	await _wall(false, sx0 + 0.1, Z_MIN, SHAFT_DOOR_Z + 0.1, y0, y1, [], 0.0, 0.2, mat_shaft, f)
	await _wall(false, sx1 - 0.1, Z_MIN, SHAFT_DOOR_Z + 0.1, y0, y1, [], 0.0, 0.2, mat_shaft, f)
	await _wall(true, SHAFT_DOOR_Z, sx0, sx1, y0, y1, [Vector2(11.3, 12.7)], 2.4, 0.2, mat_shaft, f)


func _build_slabs() -> void:
	var holes := [VOID_RECT, SHAFT_RECT]
	await _slab(0.0, SLAB, [SHAFT_RECT], true, true)  # 1F 床 (エレベーターの下はピット)
	_box(Vector3(SHAFT_RECT.get_center().x, -0.55, SHAFT_RECT.get_center().y),
		Vector3(SHAFT_RECT.size.x, 0.1, SHAFT_RECT.size.y), mat_shaft)  # ピットの底
	await _slab(FLOOR_HEIGHT, 0.05, holes, true, true)  # 2F 床仕上げ
	await _slab(FLOOR_HEIGHT - 0.05, SLAB - 0.05, holes, false, false)  # 2F 床スラブ (= 1F 天井)
	await _slab(FLOOR_HEIGHT * FLOORS, SLAB, [], false, false)  # 屋根 (= 2F 天井)


func _slab(top: float, thickness: float, holes: Array, finish: bool, collide: bool) -> void:
	var extra_x: Array = [PARTITION_X]
	var extra_z: Array = []
	for h in holes:
		extra_x.append_array([h.position.x, h.end.x])
		extra_z.append_array([h.position.y, h.end.y])
	var xs := _cuts(X_MIN - WALL_T, X_MAX + WALL_T, extra_x)
	var zs := _cuts(Z_MIN - WALL_T, Z_MAX + WALL_T, extra_z)
	for i in xs.size() - 1:
		for j in zs.size() - 1:
			var c := Vector2((xs[i] + xs[i + 1]) / 2.0, (zs[j] + zs[j + 1]) / 2.0)
			var skip := false
			for h in holes:
				if h.has_point(c):
					skip = true
			if skip:
				continue
			var mat: Material = mat_ceiling
			if finish:
				mat = mat_parquet if c.x < PARTITION_X else mat_stone
			_box(Vector3(c.x, top - thickness / 2.0, c.y),
				Vector3(xs[i + 1] - xs[i], thickness, zs[j + 1] - zs[j]), mat, collide)
			await _tick()


func _cuts(a: float, b: float, extra: Array) -> Array:
	var raw: Array = [a, b]
	for e in extra:
		if e > a and e < b and not raw.has(e):
			raw.append(e)
	raw.sort()
	var out: Array = []
	for i in raw.size() - 1:
		for seg in _split(raw[i], raw[i + 1], 6.0):
			out.append(seg.x)
	out.append(b)
	return out


func _build_ramps() -> void:
	var run := RAMP_Z_BOTTOM - RAMP_Z_TOP
	# --- 階段: 当たり判定は斜面 (CharacterBody3D が段差で引っかからない)、見た目は段板 ---
	_wedge(STAIRS_X.x, STAIRS_X.y, mat_shaft, true)
	var steps := 30
	var rise := FLOOR_HEIGHT / steps
	var tread := run / steps
	for i in steps:
		_box(Vector3((STAIRS_X.x + STAIRS_X.y) / 2.0, (i + 0.5) * rise, RAMP_Z_BOTTOM - (i + 0.5) * tread),
			Vector3(STAIRS_X.y - STAIRS_X.x, rise, tread), mat_stone, false)
		await _tick()
	_balustrade(STAIRS_X.x, mat_metal)
	_balustrade(STAIRS_X.y, mat_metal)

	# --- エスカレーター: 楔形の当たり判定に constant_linear_velocity を持たせると、乗った人が運ばれる ---
	_escalator(ESC_UP_X, 1.0)
	_escalator(ESC_DOWN_X, -1.0)
	# 隙間を埋める化粧板
	_wedge(STAIRS_X.y, ESC_UP_X.x, mat_metal, false)
	_wedge(ESC_UP_X.y, ESC_DOWN_X.x, mat_metal, false)

	add_map_item(0, Rect2(STAIRS_X.x, RAMP_Z_TOP, STAIRS_X.y - STAIRS_X.x, run), "stairs", "STAIRS")
	add_map_item(0, Rect2(ESC_UP_X.x, RAMP_Z_TOP, ESC_UP_X.y - ESC_UP_X.x, run), "esc_up", "UP")
	add_map_item(0, Rect2(ESC_DOWN_X.x, RAMP_Z_TOP, ESC_DOWN_X.y - ESC_DOWN_X.x, run), "esc_down", "DOWN")
	add_map_item(1, VOID_RECT, "void", "")
	add_map_item(1, Rect2(STAIRS_X.x, RAMP_Z_TOP, STAIRS_X.y - STAIRS_X.x, 1.2), "stairs", "STAIRS")
	add_map_item(1, Rect2(ESC_UP_X.x, RAMP_Z_TOP, ESC_UP_X.y - ESC_UP_X.x, 1.2), "esc_up", "")
	add_map_item(1, Rect2(ESC_DOWN_X.x, RAMP_Z_TOP, ESC_DOWN_X.y - ESC_DOWN_X.x, 1.2), "esc_down", "")


func _escalator(xr: Vector2, dir: float) -> void:
	var run := RAMP_Z_BOTTOM - RAMP_Z_TOP
	var ang := atan2(FLOOR_HEIGHT, run)
	_wedge(xr.x, xr.y, mat_metal, false)

	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := ConvexPolygonShape3D.new()
	shape.points = PackedVector3Array([
		Vector3(xr.x, 0, RAMP_Z_BOTTOM), Vector3(xr.y, 0, RAMP_Z_BOTTOM),
		Vector3(xr.x, 0, RAMP_Z_TOP), Vector3(xr.y, 0, RAMP_Z_TOP),
		Vector3(xr.x, FLOOR_HEIGHT, RAMP_Z_TOP), Vector3(xr.y, FLOOR_HEIGHT, RAMP_Z_TOP),
	])
	cs.shape = shape
	body.add_child(cs)
	# dir=+1 は上り (北へ・上へ)。この速度は物体自体を動かさず、乗っている CharacterBody3D だけを運ぶ
	body.constant_linear_velocity = Vector3(0, sin(ang), -cos(ang)) * ESCALATOR_SPEED * dir
	add_child(body)

	# 踏面 (縞模様テクスチャを UV スクロールして動いて見せる)
	var m := StandardMaterial3D.new()
	m.albedo_texture = _make_step_texture()
	m.metallic = 0.6
	m.roughness = 0.4
	var length := sqrt(run * run + FLOOR_HEIGHT * FLOOR_HEIGHT)
	m.uv1_scale = Vector3(1, length / STEP_LENGTH, 1)
	var plane := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(xr.y - xr.x - 0.12, length)
	plane.mesh = pm
	plane.material_override = m
	plane.rotation.x = ang
	plane.position = Vector3((xr.x + xr.y) / 2.0, FLOOR_HEIGHT / 2.0, (RAMP_Z_BOTTOM + RAMP_Z_TOP) / 2.0) \
		+ Vector3(0, cos(ang), sin(ang)) * 0.015
	add_child(plane)
	_escalator_mats.append({"mat": m, "dir": dir})

	_balustrade(xr.x, mat_rubber)
	_balustrade(xr.y, mat_rubber)
	# 乗り口・降り口のくし板
	_box(Vector3((xr.x + xr.y) / 2.0, 0.01, RAMP_Z_BOTTOM + 0.5), Vector3(xr.y - xr.x, 0.02, 1.0), mat_metal, false)
	_box(Vector3((xr.x + xr.y) / 2.0, FLOOR_HEIGHT + 0.01, RAMP_Z_TOP - 0.5),
		Vector3(xr.y - xr.x, 0.02, 1.0), mat_metal, false)


## 斜路の側面のガラス腰壁 + 手すり (横からの出入りを防ぐ当たり判定付き)
func _balustrade(x: float, rail_mat: Material) -> void:
	_slanted_box(x - 0.025, x + 0.025, 1.0, 0.0, mat_glass, true)
	_slanted_box(x - 0.05, x + 0.05, 0.06, 1.0, rail_mat, false)


func _make_step_texture() -> ImageTexture:
	var img := Image.create_empty(32, 64, false, Image.FORMAT_RGB8)
	for y in 64:
		for x in 32:
			var c := 0.34
			if y >= 58:
				c = 0.1  # 段の境目
			elif x % 4 == 0:
				c = 0.22  # 溝
			img.set_pixel(x, y, Color(c, c, c * 1.04))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _build_void_railings() -> void:
	var y := FLOOR_HEIGHT
	var v := VOID_RECT
	var h := 1.1
	_railing(Vector3(v.get_center().x, y, v.end.y), Vector3(v.size.x, h, 0.05))  # 南
	_railing(Vector3(v.position.x, y, v.get_center().y), Vector3(0.05, h, v.size.y))  # 西
	_railing(Vector3(v.end.x, y, v.get_center().y), Vector3(0.05, h, v.size.y))  # 東
	# 上り口の間の小さな隙間
	for gap in [Vector2(STAIRS_X.y, ESC_UP_X.x), Vector2(ESC_UP_X.y, ESC_DOWN_X.x)]:
		_railing(Vector3((gap.x + gap.y) / 2.0, y, v.position.y), Vector3(gap.y - gap.x, h, 0.05))


func _railing(base: Vector3, size: Vector3) -> void:
	_box(base + Vector3(0, size.y / 2.0, 0), size, mat_glass, true)
	var top := Vector3(maxf(size.x, 0.07), 0.05, maxf(size.z, 0.07))
	_box(base + Vector3(0, size.y + 0.025, 0), top, mat_metal, false)


func _build_lights() -> void:
	for f in FLOORS:
		var y := floor_y(f) + CEILING_HEIGHT - 0.4
		# ギャラリーの環境光は暗めに抑え、作品はスポットライトで浮かび上がらせる
		for x in [-9.0, 2.0]:
			var l := OmniLight3D.new()
			l.position = Vector3(x, y, 0.0)
			l.omni_range = 13.0
			l.light_energy = 0.35
			l.light_color = Color(1.0, 0.92, 0.82)
			l.light_cull_mask = LAYER_INDOOR  # 館内だけを照らす
			add_child(l)
		var a := OmniLight3D.new()  # 吹き抜け・ロビー
		a.position = Vector3(13.0, y, -4.0 if f == 1 else 2.0)
		a.omni_range = 12.0
		a.light_energy = 0.8
		a.light_color = Color(1.0, 0.97, 0.92)
		a.light_cull_mask = LAYER_INDOOR
		add_child(a)


func _build_entrance() -> void:
	# 正面入口 (扉本体は outdoor.gd)。内側に出入口の表示と足元の金属見切り
	_box(Vector3(Outdoor.DOOR_X, 0.005, Z_MAX + WALL_T / 2.0), Vector3(Outdoor.DOOR_W, 0.01, WALL_T), mat_metal, false)
	_label("ENTRANCE", Vector3(Outdoor.DOOR_X, Outdoor.DOOR_H + 0.35, Z_MAX - 0.02), Vector3.FORWARD, 48, 0.006)
	add_map_item(0, Rect2(-4.4, Z_MAX - 0.4, 2.8, 0.4), "entrance", "ENTRANCE")


func _daylight_glass() -> StandardMaterial3D:
	var m := _mat(Color(0.75, 0.85, 0.95), 0.1)
	m.emission_enabled = true
	m.emission = Color(0.85, 0.92, 1.0)
	m.emission_energy_multiplier = 0.9
	return m


func _build_benches() -> void:
	_bench(Vector3(-3.0, 0.0, 1.0), 0)
	_bench(Vector3(-3.0, FLOOR_HEIGHT, 3.5), 1)
	_bench(Vector3(9.75, FLOOR_HEIGHT, 6.5), 1, true)  # 2F 吹き抜けを見下ろすバルコニー


## 背もたれのない鑑賞用ベンチ (空間のスケール感の基準になる)
func _bench(pos: Vector3, f: int, along_z: bool = false) -> void:
	var size := Vector3(2.2, 0.08, 0.55) if not along_z else Vector3(0.55, 0.08, 2.2)
	_box(pos + Vector3(0, 0.42, 0), size, mat_wood, false)
	for s in [-0.85, 0.85]:
		var off := Vector3(s, 0.19, 0) if not along_z else Vector3(0, 0.19, s)
		var leg := Vector3(0.06, 0.38, 0.45) if not along_z else Vector3(0.45, 0.38, 0.06)
		_box(pos + off, leg, mat_dark, false)
	# 当たり判定はまとめて1つ
	var col := _box(pos + Vector3(0, 0.23, 0), Vector3(size.x, 0.46, size.z), mat_wood, true)
	col.visible = false
	add_map_item(f, Rect2(pos.x - size.x / 2.0, pos.z - size.z / 2.0, size.x, size.z), "bench")


func _build_signs() -> void:
	var dark := Color(0.22, 0.2, 0.18)
	var gx := PARTITION_X - WALL_T / 2.0 - 0.02
	var ax := PARTITION_X + WALL_T / 2.0 + 0.02
	# 開口部の上の誘導サイン (文字幅が開口幅 = 3.5〜4m に収まる大きさ)
	_label("STAIRS / ESCALATORS / ELEVATOR", Vector3(gx, 3.75, -4.0), Vector3.LEFT, 40, 0.0042, dark)
	_label("STAIRS / ESCALATORS", Vector3(gx, 3.75, 7.75), Vector3.LEFT, 40, 0.0042, dark)
	_label("ESCALATORS / ELEVATOR - 1F", Vector3(gx, FLOOR_HEIGHT + 3.75, -4.0), Vector3.LEFT, 40, 0.0042, dark)
	for f in FLOORS:
		# 吹き抜け側から見えるフロア名
		var title_label := _label(floor_titles[f], Vector3(ax, floor_y(f) + 4.2, 2.0), Vector3.RIGHT, 72, 0.008, dark)
		_floor_signs.append(title_label)
	# 乗り口の案内は天井から吊り下げたプレート
	_hanging_sign("STAIRS", Vector3((STAIRS_X.x + STAIRS_X.y) / 2.0, 0.0, RAMP_Z_BOTTOM + 1.6), 0.0)
	_hanging_sign("UP  2F", Vector3((ESC_UP_X.x + ESC_UP_X.y) / 2.0, 0.0, RAMP_Z_BOTTOM + 1.6), 0.0)
	_hanging_sign("DOWN  1F", Vector3((ESC_DOWN_X.x + ESC_DOWN_X.y) / 2.0, FLOOR_HEIGHT, RAMP_Z_TOP - 1.6), 0.0)


## 天井から 2 本の吊り棒で下がる案内プレート (両面に文字)。pos は床面上の位置
func _hanging_sign(text: String, pos: Vector3, yaw: float) -> void:
	var root := Node3D.new()
	root.position = pos
	root.rotation.y = yaw
	add_child(root)
	var plate_y := 3.1
	var size := Vector3(1.5, 0.42, 0.05)
	_box(Vector3(0, plate_y, 0), size, mat_dark, false, root)
	for x in [-0.6, 0.6]:
		var top := CEILING_HEIGHT
		_box(Vector3(x, (plate_y + top) / 2.0, 0), Vector3(0.025, top - plate_y, 0.025), mat_metal, false, root)
	for face in [1.0, -1.0]:
		var l := Label3D.new()
		l.text = text
		l.font = GalleryFonts.title()
		l.font_size = 40
		l.pixel_size = 0.0055
		l.modulate = Color(0.95, 0.9, 0.8)
		l.outline_size = 0
		l.double_sided = false
		l.position = Vector3(0, plate_y, face * (size.z / 2.0 + 0.003))
		l.rotation.y = 0.0 if face > 0 else PI
		root.add_child(l)


# ---------------------------------------------------------------------------
# フロアマップ
# ---------------------------------------------------------------------------
func _create_map_viewport() -> void:
	map_viewport = SubViewport.new()
	map_viewport.size = Vector2i(1200, 600)
	map_viewport.disable_3d = true
	map_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(map_viewport)
	var fm := FloorMap.new()
	fm.building = self
	fm.player = get_node_or_null("%Player")
	fm.size = Vector2(map_viewport.size)
	map_viewport.add_child(fm)


## フロアマップの案内端末。近づくとマップのホログラムが立ち上がり、クリックで拡大表示。
func _map_board(pos: Vector3, toward: Vector3) -> void:
	var kiosk := HoloKiosk.new()
	kiosk.name = "MapKiosk"
	kiosk.position = pos
	var d := toward - pos
	kiosk.rotation.y = atan2(d.x, d.z)
	add_child(kiosk)
	kiosk.setup(self, get_node_or_null("%Player"), "FLOOR MAP", "View floor map", _open_map,
		map_viewport.get_texture(), Vector2(1.2, 0.6))
	var f := floor_of(pos.y)
	add_map_item(f, Rect2(pos.x - 0.4, pos.z - 0.4, 0.8, 0.8), "map", "MAP")


func _open_map() -> void:
	if _ui:
		_ui.show_modal("Floor Map", "", map_viewport.get_texture(), true)
