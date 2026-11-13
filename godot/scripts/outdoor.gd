class_name Outdoor
extends Node3D
## 美術館の前庭 (駐車場 → 広場 → 大階段 → 列柱の玄関)。
## ゲームは駐車場から始まり、建物まで歩く間に館内の生成・作品の読み込みを進める (準備が整うまで自動ドアは閉じたまま)。
## 屋外は単純な箱・円柱だけで構成して軽くしている。
## 描画レイヤー: 屋外 = 2 / 館内 = 1。太陽は屋外だけ、館内の照明は館内だけを照らす (壁越しの光漏れ防止)。

const LAYER := 2
const GROUND_Y := -1.2
const FACADE_Z := Building.Z_MAX + Building.WALL_T  # 南面の外側 (10.3)
const TERRACE_Z := 14.0
const STEPS_Z := 17.6
const PLAZA_Z := 30.0
const LOT_Z := 52.0
const X0 := -30.0
const X1 := 32.0
const BX0 := Building.X_MIN - Building.WALL_T  # 建物の外形
const BX1 := Building.X_MAX + Building.WALL_T
const SPAWN := Vector3(-3.0, -1.2, 40.0)
const DOOR_X := -3.0
const DOOR_W := 2.8
const DOOR_H := 3.2
const DOOR_Z := Building.Z_MAX + Building.WALL_T / 2.0

var open_allowed := false
var _door_amount := 0.0
var _door_opening := false
var _leaves: Array[AnimatableBody3D] = []
var _progress_label: Label3D
var _progress_fill: MeshInstance3D
var _banners: Array[StandardMaterial3D] = []

var _b: Building
var _player: Node3D
var _audio: GalleryAudio

var mat_facade: StandardMaterial3D
var mat_trim: StandardMaterial3D
var mat_asphalt: StandardMaterial3D
var mat_line: StandardMaterial3D
var mat_green: StandardMaterial3D
var mat_bark: StandardMaterial3D


static func is_outdoor(pos: Vector3) -> bool:
	return pos.z > FACADE_Z - 0.05


func _ready() -> void:
	_b = get_node("%Building")
	_player = get_node_or_null("%Player")
	_audio = get_node_or_null("%Audio")
	mat_facade = _b._mat(Color(0.78, 0.74, 0.67), 0.9)
	mat_trim = _b._mat(Color(0.84, 0.81, 0.75), 0.85)
	mat_asphalt = _b._mat(Color(0.17, 0.17, 0.18), 0.95)
	mat_line = _b._mat(Color(0.9, 0.9, 0.86), 0.8)
	mat_green = _b._mat(Color(0.23, 0.36, 0.2), 0.9)
	mat_bark = _b._mat(Color(0.3, 0.22, 0.15), 0.9)
	_build_sun()
	_build_ground()
	_build_parking()
	_build_plaza()
	_build_terrace_and_steps()
	_build_facade()
	_build_portico()
	_build_entrance()
	_build_boundaries()


func _physics_process(delta: float) -> void:
	var near := false
	if _player:
		var d := _player.global_position - Vector3(DOOR_X, 0, DOOR_Z)
		near = Vector2(d.x, d.z).length() < 6.0
	var want := open_allowed and near
	if want != _door_opening:
		_door_opening = want
		if _audio:
			_audio.play_at("door", Vector3(DOOR_X, 1.5, DOOR_Z), -10.0)
	_door_amount = move_toward(_door_amount, 1.0 if want else 0.0, delta * 1.2)
	var off := DOOR_W / 4.0 + ease(_door_amount, -1.8) * (DOOR_W / 2.0 - 0.05)
	_leaves[0].position.x = DOOR_X - off
	_leaves[1].position.x = DOOR_X + off


## 入口上の表示 (準備中は進捗、完了で WELCOME)
func set_progress(ratio: float, text: String) -> void:
	_progress_label.text = text
	var w := 2.4 * clampf(ratio, 0.0, 1.0)
	_progress_fill.scale.x = maxf(w, 0.001)
	_progress_fill.position.x = DOOR_X - 1.2 + w / 2.0


func set_ready() -> void:
	open_allowed = true
	_progress_label.text = "WELCOME"
	_progress_fill.get_parent().visible = false


func set_banner(i: int, tex: Texture2D) -> void:
	if i < _banners.size() and tex:
		_banners[i].albedo_texture = tex
		_banners[i].albedo_color = Color.WHITE


# ---------------------------------------------------------------------------
func _box(center: Vector3, size: Vector3, mat: Material, collide: bool = true, parent: Node = null) -> MeshInstance3D:
	var mi := _b._box(center, size, mat, collide, parent if parent else self)
	mi.layers = LAYER
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	return mi


func _cyl(pos: Vector3, r_top: float, r_bottom: float, h: float, mat: Material, collide: bool = false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = r_top
	c.bottom_radius = r_bottom
	c.height = h
	c.radial_segments = 20
	mi.mesh = c
	mi.material_override = mat
	mi.position = pos
	mi.layers = LAYER
	add_child(mi)
	if collide:
		var body := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var shape := CylinderShape3D.new()
		shape.radius = maxf(r_top, r_bottom)
		shape.height = h
		cs.shape = shape
		body.add_child(cs)
		mi.add_child(body)
	return mi


func _wall(center: Vector3, size: Vector3) -> void:  # 見えない境界
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	body.add_child(cs)
	body.position = center
	add_child(body)


func _label(text: String, pos: Vector3, size: int, pixel: float, color: Color) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font = GalleryFonts.title()
	l.font_size = size
	l.pixel_size = pixel
	l.modulate = color
	l.outline_size = 0
	l.double_sided = false
	l.position = pos
	l.layers = LAYER
	add_child(l)
	return l


func _build_sun() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-26.0, -28.0, 0.0)  # 南南西の低い夕日 → 南向きの正面を照らす
	sun.light_color = Color(1.0, 0.84, 0.66)
	sun.light_energy = 0.95
	sun.light_cull_mask = LAYER
	sun.shadow_enabled = true
	sun.shadow_blur = 1.5
	sun.directional_shadow_max_distance = 70.0
	sun.set("shadow_caster_mask", LAYER)  # 館内の物体は太陽の影計算から外す
	add_child(sun)


func _build_ground() -> void:
	_box(Vector3((X0 + X1) / 2.0, GROUND_Y - 0.25, (FACADE_Z + PLAZA_Z) / 2.0),
		Vector3(X1 - X0, 0.5, PLAZA_Z - FACADE_Z), _b.mat_stone)
	_box(Vector3((X0 + X1) / 2.0, GROUND_Y - 0.25, (PLAZA_Z + LOT_Z) / 2.0),
		Vector3(X1 - X0, 0.5, LOT_Z - PLAZA_Z), mat_asphalt)
	# 駐車場を縦断する歩道
	_box(Vector3(DOOR_X, GROUND_Y + 0.01, (PLAZA_Z + LOT_Z) / 2.0), Vector3(4.0, 0.02, LOT_Z - PLAZA_Z), _b.mat_stone, false)


func _build_parking() -> void:
	# 白線のみ (車は置かない。1 台だけタクシーがいる)
	for row_z in [34.0, 46.0]:
		var x := -27.0
		while x <= 28.0:
			if absf(x - DOOR_X) > 2.6:
				_box(Vector3(x - 1.35, GROUND_Y + 0.005, row_z), Vector3(0.1, 0.01, 5.0), mat_line, false)
			x += 2.7
	# イースターエッグ: 運転できるタクシー
	var taxi := Taxi.new()
	taxi.name = "Taxi"
	taxi.position = Vector3(4.65, GROUND_Y + 0.05, 34.0)
	add_child(taxi)
	taxi.build(_b, _player, get_node_or_null("%UI"), _audio)
	# 車だけが当たる柵 (大階段・テラスに車で上がれないように)
	var barrier := StaticBody3D.new()
	barrier.collision_layer = Taxi.BARRIER_LAYER
	barrier.collision_mask = 0
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(X1 - X0, 4.0, 0.4)
	cs.shape = shape
	barrier.add_child(cs)
	barrier.position = Vector3((X0 + X1) / 2.0, GROUND_Y + 2.0, STEPS_Z + 0.3)
	add_child(barrier)


# ---- 樹木・街灯: メッシュとマテリアルを全インスタンスで共有して軽量化 (ポリゴン数も控えめ) ----
var _mesh_cache := {}


func _cached_mesh(key: String, maker: Callable) -> Mesh:
	if not _mesh_cache.has(key):
		_mesh_cache[key] = maker.call()
	return _mesh_cache[key]


func _cylinder_mesh(top: float, bottom: float, h: float, seg: int) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	return c


func _sphere_mesh(seg: int, rings: int) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = 1.0
	s.height = 2.0
	s.radial_segments = seg
	s.rings = rings
	return s


func _inst(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3, scale: Vector3 = Vector3.ONE,
		rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.scale = scale
	mi.rotation = rot
	mi.layers = LAYER
	parent.add_child(mi)
	return mi


func _build_plaza() -> void:
	var leaf_mats: Array[StandardMaterial3D] = [
		_b._mat(Color(0.2, 0.34, 0.17), 0.9), _b._mat(Color(0.26, 0.4, 0.2), 0.9), _b._mat(Color(0.17, 0.29, 0.15), 0.9)]
	var rnd := RandomNumberGenerator.new()
	rnd.seed = 5
	for p in [Vector2(-22, 21), Vector2(-15, 25), Vector2(9, 25), Vector2(16, 21), Vector2(-25, 28), Vector2(19, 28),
			Vector2(-12, 20), Vector2(6, 20)]:
		_tree(Vector3(p.x, GROUND_Y, p.y), rnd, leaf_mats)
	for z in [20.0, 26.0, 33.0, 39.0, 45.0]:
		for x in [DOOR_X - 2.6, DOOR_X + 2.6]:
			_lamp(Vector3(x, GROUND_Y, z))


## 植え込み付きの樹木: 石の縁石 + 土 + 幹 + 枝 + 大きさ・色の違う葉の塊を重ねる
func _tree(pos: Vector3, rnd: RandomNumberGenerator, leaf_mats: Array[StandardMaterial3D]) -> void:
	var root := Node3D.new()
	root.position = pos
	root.rotation.y = rnd.randf() * TAU
	var s := rnd.randf_range(0.85, 1.15)
	root.scale = Vector3.ONE * s
	add_child(root)
	_inst(root, _cached_mesh("planter", func(): return _cylinder_mesh(1.05, 1.1, 0.35, 16)), mat_trim, Vector3(0, 0.175, 0))
	_inst(root, _cached_mesh("soil", func(): return _cylinder_mesh(0.92, 0.92, 0.04, 16)), _b.mat_dark, Vector3(0, 0.36, 0))
	_inst(root, _cached_mesh("trunk", func(): return _cylinder_mesh(0.09, 0.17, 2.6, 8)), mat_bark, Vector3(0, 1.6, 0))
	var branch := _cached_mesh("branch", func(): return _cylinder_mesh(0.03, 0.06, 1.2, 6))
	for a in [0.0, 2.1, 4.2]:
		_inst(root, branch, mat_bark, Vector3(sin(a) * 0.3, 2.6, cos(a) * 0.3), Vector3.ONE, Vector3(0.6 * cos(a), 0, -0.6 * sin(a)))
	var leaf := _cached_mesh("leaf", func(): return _sphere_mesh(10, 6))
	var clusters := [Vector3(0, 3.4, 0), Vector3(0.75, 3.0, 0.2), Vector3(-0.7, 3.1, -0.3), Vector3(0.1, 3.0, 0.8),
		Vector3(-0.2, 2.95, -0.85), Vector3(0.25, 4.0, -0.1)]
	for i in clusters.size():
		var r := rnd.randf_range(0.65, 1.0) if i > 0 else 1.15
		_inst(root, leaf, leaf_mats[(i + rnd.randi()) % leaf_mats.size()], clusters[i], Vector3(r, r * 0.85, r))
	# 当たり判定は幹と植え込みだけ
	var body := StaticBody3D.new()
	for c in [[0.25, 3.0, 1.5], [1.1, 0.35, 0.175]]:
		var cs := CollisionShape3D.new()
		var shape := CylinderShape3D.new()
		shape.radius = c[0]
		shape.height = c[1]
		cs.shape = shape
		cs.position.y = c[2]
		body.add_child(cs)
	root.add_child(body)


## クラシックな街灯: 台座 + 柱 + 飾りリング + ガラスの灯籠 + 四角錐の笠 (発光体のみ。実ライトは置かず軽量化)
func _lamp(pos: Vector3) -> void:
	var root := Node3D.new()
	root.position = pos
	add_child(root)
	var iron := _b.mat_dark
	if not _mesh_cache.has("lamp_glow_mat"):
		var m := _b._mat(Color(1.0, 0.92, 0.75), 0.3)
		m.emission_enabled = true
		m.emission = Color(1.0, 0.82, 0.55)
		m.emission_energy_multiplier = 2.2
		_mesh_cache["lamp_glow_mat"] = m
	var glow: Material = _mesh_cache["lamp_glow_mat"]
	_inst(root, _cached_mesh("lamp_base", func(): return _cylinder_mesh(0.14, 0.2, 0.5, 8)), iron, Vector3(0, 0.25, 0))
	_inst(root, _cached_mesh("lamp_pole", func(): return _cylinder_mesh(0.045, 0.065, 3.0, 8)), iron, Vector3(0, 2.0, 0))
	var ring := _cached_mesh("lamp_ring", func(): return _cylinder_mesh(0.09, 0.09, 0.05, 8))
	for y in [0.55, 1.3, 3.45]:
		_inst(root, ring, iron, Vector3(0, y, 0))
	_inst(root, _cached_mesh("lamp_glass", func(): return _cylinder_mesh(0.17, 0.12, 0.42, 4)), glow,
		Vector3(0, 3.7, 0), Vector3.ONE, Vector3(0, PI / 4.0, 0))
	_inst(root, _cached_mesh("lamp_cap", func(): return _cylinder_mesh(0.0, 0.26, 0.22, 4)), iron,
		Vector3(0, 4.02, 0), Vector3.ONE, Vector3(0, PI / 4.0, 0))
	_inst(root, _cached_mesh("lamp_finial", func(): return _sphere_mesh(6, 4)), iron, Vector3(0, 4.17, 0), Vector3.ONE * 0.045)
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.2
	shape.height = 4.0
	cs.shape = shape
	cs.position.y = 2.0
	body.add_child(cs)
	root.add_child(body)

func _build_terrace_and_steps() -> void:
	var cx := (BX0 + BX1) / 2.0
	_box(Vector3(cx, (GROUND_Y + 0.0) / 2.0, (FACADE_Z + TERRACE_Z) / 2.0),
		Vector3(BX1 - BX0, -GROUND_Y, TERRACE_Z - FACADE_Z), _b.mat_stone)
	# 大階段 (当たり判定は斜面、見た目は段)
	var sx0 := -12.0
	var sx1 := 6.0
	var steps := 8
	var run := STEPS_Z - TERRACE_Z
	var rise := -GROUND_Y / steps
	for i in steps:
		var z0 := TERRACE_Z + i * run / steps
		var top := -i * rise
		_box(Vector3((sx0 + sx1) / 2.0, (top + GROUND_Y) / 2.0, z0 + run / steps / 2.0),
			Vector3(sx1 - sx0, top - GROUND_Y, run / steps), mat_trim, false)
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := ConvexPolygonShape3D.new()
	shape.points = PackedVector3Array([
		Vector3(sx0, 0, TERRACE_Z), Vector3(sx1, 0, TERRACE_Z),
		Vector3(sx0, GROUND_Y, TERRACE_Z), Vector3(sx1, GROUND_Y, TERRACE_Z),
		Vector3(sx0, GROUND_Y, STEPS_Z), Vector3(sx1, GROUND_Y, STEPS_Z),
	])
	cs.shape = shape
	body.add_child(cs)
	add_child(body)
	# テラス前面の手すり壁 (階段以外の段差に落ちないように)
	_box(Vector3((BX0 + sx0) / 2.0, 0.3, TERRACE_Z - 0.15), Vector3(sx0 - BX0, 0.6, 0.3), mat_trim)
	_box(Vector3((sx1 + BX1) / 2.0, 0.3, TERRACE_Z - 0.15), Vector3(BX1 - sx1, 0.6, 0.3), mat_trim)


func _build_facade() -> void:
	var y0 := GROUND_Y
	var y1 := 11.2
	var z := FACADE_Z + 0.04
	var t := 0.08
	var dl := DOOR_X - DOOR_W / 2.0
	var dr := DOOR_X + DOOR_W / 2.0
	_box(Vector3((BX0 + dl) / 2.0, (y0 + y1) / 2.0, z), Vector3(dl - BX0, y1 - y0, t), mat_facade, false)
	_box(Vector3((dr + BX1) / 2.0, (y0 + y1) / 2.0, z), Vector3(BX1 - dr, y1 - y0, t), mat_facade, false)
	_box(Vector3(DOOR_X, (DOOR_H + y1) / 2.0, z), Vector3(DOOR_W, y1 - DOOR_H, t), mat_facade, false)
	for x in [BX0 - 0.04, BX1 + 0.04]:  # 側面
		_box(Vector3(x, (y0 + y1) / 2.0, 0.0), Vector3(t, y1 - y0, (FACADE_Z) * 2.0), mat_facade, false)
	# 階の境の帯とコーニス
	_box(Vector3((BX0 + BX1) / 2.0, Building.FLOOR_HEIGHT, FACADE_Z + 0.12), Vector3(BX1 - BX0 + 0.3, 0.3, 0.2), mat_trim, false)
	_box(Vector3((BX0 + BX1) / 2.0, 11.4, FACADE_Z + 0.25), Vector3(BX1 - BX0 + 0.8, 0.5, 0.6), mat_trim, false)
	for x in [BX0 - 0.25, BX1 + 0.25]:
		_box(Vector3(x, 11.4, 0.0), Vector3(0.6, 0.5, FACADE_Z * 2.0 + 0.5), mat_trim, false)
	# 作品のバナー (読み込み後にメイン作品の画像を貼る)
	for i in 2:
		var bx := DOOR_X + (-6.1 if i == 0 else 6.1)
		var m := _b._mat(Color(0.45, 0.08, 0.1), 0.8)
		var q := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(1.9, 2.6)
		q.mesh = quad
		q.material_override = m
		q.position = Vector3(bx, 5.4, FACADE_Z + 0.12)
		q.layers = LAYER
		add_child(q)
		_banners.append(m)
		_box(Vector3(bx, 3.75, FACADE_Z + 0.12), Vector3(1.9, 0.7, 0.02), _b._mat(Color(0.45, 0.08, 0.1), 0.8), false)
		var l := _label("NOW ON VIEW", Vector3(bx, 3.75, FACADE_Z + 0.135), 40, 0.0045, Color(0.95, 0.85, 0.6))
		l.modulate = Color(0.95, 0.85, 0.6)
		_box(Vector3(bx, 6.75, FACADE_Z + 0.12), Vector3(2.1, 0.06, 0.06), _b.mat_dark, false)


func _build_portico() -> void:
	var z := 13.2
	for off in [1.9, 4.7, 7.5, 10.3]:
		for s in [-1.0, 1.0]:
			var x: float = DOOR_X + off * s
			_box(Vector3(x, 0.15, z), Vector3(1.1, 0.3, 1.1), mat_trim, false)
			_cyl(Vector3(x, 0.3 + 3.8, z), 0.38, 0.44, 7.6, mat_trim, true)
			_box(Vector3(x, 8.05, z), Vector3(1.1, 0.3, 1.1), mat_trim, false)
	var ex0 := DOOR_X - 11.5
	var ex1 := DOOR_X + 11.5
	_box(Vector3(DOOR_X, 8.8, (FACADE_Z + 13.9) / 2.0), Vector3(ex1 - ex0, 1.2, 13.9 - FACADE_Z), mat_trim, false)
	var ped := CSGPolygon3D.new()
	ped.polygon = PackedVector2Array([Vector2(-11.5, 0), Vector2(11.5, 0), Vector2(0, 2.8)])
	ped.depth = 13.9 - FACADE_Z
	ped.position = Vector3(DOOR_X, 9.4, 13.9)
	ped.material = mat_trim
	ped.layers = LAYER
	add_child(ped)
	_label("OMNIGALLERY", Vector3(DOOR_X, 8.8, 13.92), 180, 0.005, Color(0.45, 0.36, 0.2))
	_label("MUSEUM  OF  ART", Vector3(DOOR_X, 10.3, 13.92), 60, 0.006, Color(0.45, 0.36, 0.2))


func _build_entrance() -> void:
	var glass := _b._mat(Color(0.6, 0.72, 0.78, 0.35), 0.05, 0.3)
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	for i in 2:
		var leaf := AnimatableBody3D.new()
		leaf.sync_to_physics = false
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(DOOR_W / 2.0, DOOR_H, 0.08)
		cs.shape = shape
		leaf.add_child(cs)
		var g := _b._box(Vector3.ZERO, Vector3(DOOR_W / 2.0 - 0.06, DOOR_H - 0.06, 0.03), glass, false, leaf)
		g.layers = 3
		var fr := _b._box(Vector3(0, 0, 0), Vector3(DOOR_W / 2.0, 0.06, 0.06), _b.mat_metal, false, leaf)
		fr.position.y = DOOR_H / 2.0 - 0.03
		fr.layers = 3
		var fr2 := _b._box(Vector3(0, -DOOR_H / 2.0 + 0.05, 0), Vector3(DOOR_W / 2.0, 0.1, 0.06), _b.mat_metal, false, leaf)
		fr2.layers = 3
		leaf.position = Vector3(DOOR_X, DOOR_H / 2.0, DOOR_Z)
		add_child(leaf)
		_leaves.append(leaf)
	# 進捗表示 (扉の上)
	_progress_label = _label("PREPARING THE EXHIBITION", Vector3(DOOR_X, 3.75, FACADE_Z + 0.1), 44, 0.0042,
		Color(0.32, 0.25, 0.14))
	var bar := Node3D.new()
	add_child(bar)
	_box(Vector3(DOOR_X, 3.48, FACADE_Z + 0.1), Vector3(2.44, 0.07, 0.02), _b.mat_dark, false, bar)
	var fill_mat := _b._mat(Color(1.0, 0.8, 0.4), 0.4)
	fill_mat.emission_enabled = true
	fill_mat.emission = Color(1.0, 0.75, 0.35)
	fill_mat.emission_energy_multiplier = 1.5
	_progress_fill = _box(Vector3(DOOR_X - 1.2, 3.48, FACADE_Z + 0.115), Vector3(1.0, 0.045, 0.02), fill_mat, false, bar)
	set_progress(0.0, "PREPARING THE EXHIBITION")


func _build_boundaries() -> void:
	var h := 4.0
	_wall(Vector3(X0, 0, (FACADE_Z + LOT_Z) / 2.0), Vector3(0.5, h * 2, LOT_Z - FACADE_Z))
	_wall(Vector3(X1, 0, (FACADE_Z + LOT_Z) / 2.0), Vector3(0.5, h * 2, LOT_Z - FACADE_Z))
	_wall(Vector3((X0 + X1) / 2.0, 0, LOT_Z), Vector3(X1 - X0, h * 2, 0.5))
	# 建物の脇は生け垣で塞ぐ
	for seg in [Vector2(X0, BX0), Vector2(BX1, X1)]:
		_box(Vector3((seg.x + seg.y) / 2.0, GROUND_Y + 0.6, FACADE_Z + 0.6), Vector3(seg.y - seg.x, 1.2, 1.2), mat_green)
		_wall(Vector3((seg.x + seg.y) / 2.0, 0, FACADE_Z + 0.6), Vector3(seg.y - seg.x, h * 2, 1.2))
	# 外周の生け垣 (見た目)
	_box(Vector3(X0 + 0.6, GROUND_Y + 0.6, (FACADE_Z + LOT_Z) / 2.0), Vector3(1.2, 1.2, LOT_Z - FACADE_Z), mat_green, false)
	_box(Vector3(X1 - 0.6, GROUND_Y + 0.6, (FACADE_Z + LOT_Z) / 2.0), Vector3(1.2, 1.2, LOT_Z - FACADE_Z), mat_green, false)
	_box(Vector3((X0 + X1) / 2.0, GROUND_Y + 0.6, LOT_Z - 0.6), Vector3(X1 - X0, 1.2, 1.2), mat_green, false)
