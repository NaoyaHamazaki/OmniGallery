extends Node3D
## 読み込みの流れを管理し、館内に作品を展示する。
##
## 読み込みの流れ (屋外の駐車場から歩いている間に進める。画面は固まらない):
##   1. 設定取得 → 2. 建物を時間分割で生成 → 3. 1F の作品をダウンロード・配置
##   → 4. 1F の描画の下準備 (シェーダーのコンパイルを先に済ませる) → 5. 入口の自動ドアが開く
##   → 6. 2F は裏で読み込み、エレベーター/階段/エスカレーターで移動する間に下準備
##
## 展示:
##   絵画: 壁に額装 + 天井から斜め下 (約55度) のスポットライト
##   3D作品 (glb): 台座 + 進入防止の柵 + キャプション台 + 影付きスポットライト。実行時に GLTFDocument で読み込む
## 照明の色温度は作品ごとの light_kelvin (古典 3000K 電球色 / 現代・プロダクト 5000K 昼白色)。

signal floor_prepared(floor_index: int)

const FRAME_BORDER := 0.09
const FRAME_DEPTH := 0.06
const WALL_GAP := 0.012
const CAPTION_HEIGHT := 1.45
const BARRIER_HALF := 1.25  # 3D作品の柵 (中心から)
const PLINTH := Vector3(0.9, 1.0, 0.9)
const MODEL_SPIN := 0.18  # rad/s

@onready var api: ApiClient = %Api
@onready var building: Building = %Building
@onready var ui: GalleryUI = %UI
@onready var player: Node3D = %Player
@onready var outdoor: Outdoor = %Outdoor
@onready var audio: GalleryAudio = %Audio

var config: Dictionary = {}
var artworks: Array = []
var loaded_count := 0
var failed_count := 0
var floor_loaded: Array[bool] = [false, false]
var floor_warm: Array[bool] = [false, false]

var _floor_total: Array[int] = [0, 0]
var _floor_done: Array[int] = [0, 0]
var _preparing: Array[bool] = [false, false]
var _spinners: Array[Node3D] = []
var _frame_mat: StandardMaterial3D
var _warm_vp: SubViewport
var _warm_cam: Camera3D
var _zone := ""
var _models := {}  # id -> {art, spinner, floor, hq_loaded}


func _ready() -> void:
	_frame_mat = StandardMaterial3D.new()
	_frame_mat.albedo_color = Color(0.2, 0.13, 0.08)
	_frame_mat.roughness = 0.45
	_frame_mat.metallic = 0.1
	player.floor_changed.connect(func(_f): _update_zone(true))
	player.transit_started.connect(func(f): prepare_floor(f))  # 移動を始めた瞬間から準備開始
	player.floor_gate = prepare_floor
	ui.action_requested.connect(_on_ui_action)
	_load()


func _process(delta: float) -> void:
	for s in _spinners:
		s.rotate_y(MODEL_SPIN * delta)
	_update_zone(false)
	_cull_far_side()


## 読み込み完了後は、入口から離れているとき反対側 (屋外にいれば館内、館内にいれば屋外) を描画しない。
## Compatibility レンダラー (Web) では遮蔽カリングが使えないため、壁の向こうも全部描かれてしまう対策。
func _cull_far_side() -> void:
	if not floor_warm[0]:
		return  # 読み込み・下準備中は館内を描画しておく必要がある
	var p := player.global_position
	var near_door := Vector2(p.x - Outdoor.DOOR_X, p.z - Outdoor.DOOR_Z).length() < 16.0 and p.y < 3.0
	var outside := Outdoor.is_outdoor(p)
	var show_inside := not outside or near_door
	var show_outside := outside or near_door
	if building.visible != show_inside:
		building.visible = show_inside
		visible = show_inside
	if outdoor.visible != show_outside:
		outdoor.visible = show_outside


## 画面右上の場所表示と BGM の音量 (屋外 / 館内)
func _update_zone(force: bool) -> void:
	var outside := Outdoor.is_outdoor(player.global_position)
	var text := "ENTRANCE PLAZA" if outside else str(building.floor_titles[Building.floor_of(player.global_position.y)])
	var ta: TimeAttack = get_node_or_null("%TimeAttack")
	if ta and ta.active:
		text = "TIME ATTACK"
	if text != _zone or force:
		_zone = text
		ui.set_floor(text)
		audio.set_indoor(not outside)


func _progress(ratio: float, text: String) -> void:
	ui.set_loading(ratio, text)
	outdoor.set_progress(ratio, text.to_upper())


func _load() -> void:
	_progress(0.02, "Unlocking the gates")
	var cfg = await api.get_json("/api/config")
	if cfg is Dictionary:
		config = cfg
	await building.build_async(func(r): _progress(0.04 + r * 0.36, "Constructing the galleries"))
	building.set_floor_titles(config.get("floors", []))
	building.elevator.floor_gate = prepare_floor
	building.elevator.audio = audio
	_update_zone(true)
	if config.get("debug", false):
		var term := DebugTerminal.new()
		term.name = "DebugTerminal"
		add_child(term)
		term.setup(self, building.get_debug_terminal_spot())

	var data = await api.get_json("/api/artworks")
	if not (data is Dictionary and data.has("artworks")):
		ui.set_loading(0.0, "Server unavailable: %s" % api.last_error)
		outdoor.set_progress(0.0, "CLOSED  -  SERVER UNAVAILABLE")
		return
	artworks = data["artworks"]

	await _load_floor(0, 0.4, 0.88)
	await _warmup(0, func(r): _progress(0.88 + r * 0.12, "Adjusting the spotlights"))
	floor_warm[0] = true
	floor_prepared.emit(0)
	_progress(1.0, "Welcome")
	outdoor.set_ready()
	ui.finish_loading()

	await _load_floor(1, -1.0, -1.0)  # 2F は裏で読み込み (下準備はフロア移動時)
	if failed_count > 0:
		ui.set_status("%d artworks on display (%d failed to load)" % [loaded_count, failed_count], 8.0)
	_start_dev_tools()


## 指定フロアの作品を配置し、ダウンロードが終わるまで待つ。p0/p1 は進捗バーの範囲 (負なら表示しない)
func _load_floor(f: int, p0: float, p1: float) -> void:
	var paintings: Array = artworks.filter(func(a): return a.get("kind") == "painting" and int(a.get("floor", 1)) == f + 1)
	var models: Array = artworks.filter(func(a): return a.get("kind") == "model" and int(a.get("floor", 1)) == f + 1)
	var slots := building.get_painting_slots(f)
	var featured_slot: Dictionary = slots[0]
	var others: Array = slots.slice(1)
	var featured_used := false
	var pedestals := building.get_pedestal_slots(f)
	_floor_total[f] = 0
	for art in paintings:
		var slot: Dictionary
		if art.get("featured", false) and not featured_used:
			slot = featured_slot
			featured_used = true
		elif not others.is_empty():
			slot = others.pop_front()
		elif not featured_used:
			slot = featured_slot
			featured_used = true
		else:
			push_warning("No wall slot left on %dF for %s" % [f + 1, art.get("id")])
			continue
		_floor_total[f] += 1
		_create_painting(art, slot, f)
		await get_tree().process_frame  # 1 作品ずつ (生成を 1 フレームに詰め込まない)
	for i in models.size():
		if i >= pedestals.size():
			push_warning("No pedestal left on %dF for %s" % [f + 1, models[i].get("id")])
			break
		_floor_total[f] += 1
		_create_model(models[i], pedestals[i], f)
		await get_tree().process_frame
	while _floor_done[f] < _floor_total[f]:
		if p0 >= 0.0:
			var r := float(_floor_done[f]) / maxf(1.0, _floor_total[f])
			_progress(p0 + (p1 - p0) * r, "Hanging the masterpieces  %d / %d" % [_floor_done[f], _floor_total[f]])
		await get_tree().process_frame
	floor_loaded[f] = true


func _finish_item(f: int, ok: bool) -> void:
	if ok:
		loaded_count += 1
	else:
		failed_count += 1
	_floor_done[f] += 1


## フロアの準備 (読み込み完了 + 描画の下準備)。エレベーター・階段・エスカレーターから await される。
func prepare_floor(f: int) -> void:
	if floor_warm[f]:
		return
	if _preparing[f]:
		while not floor_warm[f]:
			await floor_prepared
		return
	_preparing[f] = true
	ui.set_status("Preparing %dF ..." % (f + 1))
	while not floor_loaded[f]:
		await get_tree().process_frame
	await _warmup(f, Callable())
	floor_warm[f] = true
	_preparing[f] = false
	ui.set_status(str(building.floor_titles[f]), 2.5)
	floor_prepared.emit(f)


## 描画の下準備: 画面外の小さなカメラでフロア内をひと通り見回し、マテリアルとライトの組み合わせごとの
## シェーダーを先にコンパイルさせる (初めて天井などを見た瞬間のカクつき対策)。
func _warmup(f: int, progress: Callable) -> void:
	if _warm_vp == null:
		_warm_vp = SubViewport.new()
		_warm_vp.size = Vector2i(320, 180)
		add_child(_warm_vp)
		_warm_cam = Camera3D.new()
		_warm_cam.fov = 80.0
		_warm_vp.add_child(_warm_cam)
		_warm_cam.current = true
	_warm_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var y := Building.floor_y(f) + 1.6
	var views: Array = []
	for s in [Vector2(-10, -4), Vector2(-10, 5), Vector2(-3, 0), Vector2(4, -4), Vector2(4, 5), Vector2(10, -4), Vector2(16, 6)]:
		var pos := Vector3(s.x, y, s.y)
		for yaw in [0.0, PI / 2.0, PI, -PI / 2.0]:
			views.append([pos, Vector3(0, yaw, 0)])
		views.append([pos, Vector3(deg_to_rad(70.0), 0, 0)])  # 天井
		views.append([pos, Vector3(deg_to_rad(-60.0), 0, 0)])  # 床
	for i in views.size():
		_warm_cam.global_position = views[i][0]
		_warm_cam.rotation = views[i][1]
		await get_tree().process_frame
		await get_tree().process_frame
		if progress.is_valid():
			progress.call(float(i + 1) / views.size())
	_warm_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED


func _start_dev_tools() -> void:
	var shots := DevShots.new()  # 起動引数 --shots= / --selftest があるときだけ動く開発用機能
	add_child(shots)
	if shots.selftest:
		shots.run_selftest(self)
	elif shots.out_dir != "":
		shots.run(self)


func _create_painting(art: Dictionary, slot: Dictionary, f: int) -> void:
	var normal: Vector3 = slot["normal"]
	var root := Node3D.new()
	root.name = "Painting_%s" % art.get("id", "x")
	add_child(root)
	root.position = slot["pos"] + Vector3(0, slot["hang"], 0) + normal * (WALL_GAP + FRAME_DEPTH / 2.0)
	root.rotation.y = atan2(normal.x, normal.z)

	var frame := MeshInstance3D.new()
	var frame_mesh := BoxMesh.new()
	frame.mesh = frame_mesh
	frame.material_override = _frame_mat
	root.add_child(frame)

	var canvas := MeshInstance3D.new()
	var quad := QuadMesh.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.45, 0.45)  # 画像が届くまでのプレースホルダー
	mat.roughness = 0.9
	canvas.mesh = quad
	canvas.material_override = mat
	canvas.position.z = FRAME_DEPTH / 2.0 + 0.002
	root.add_child(canvas)

	# 作品の右横に小さなキャプションプレート (実際の美術館の作品ラベル風)
	var plate := Node3D.new()
	root.add_child(plate)
	var plate_mesh := MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(0.34, 0.2, 0.01)
	plate_mesh.mesh = pm
	plate_mesh.material_override = building.mat_plinth
	plate.add_child(plate_mesh)
	var label := _caption_label(art, 300)
	label.position = Vector3(0, 0, 0.006)
	plate.add_child(label)

	var body := Interact.add_box(root, Vector3.ONE, Vector3.ZERO, "%s" % art.get("title", "Untitled"),
		Callable())
	var spot := _spot(f)
	var p := {
		"art": art, "slot": slot, "root": root, "frame_mesh": frame_mesh, "quad": quad, "material": mat,
		"plate": plate, "body": body, "spot": spot, "texture": null, "floor": f,
	}
	Interact.attach(body, str(art.get("title", "Untitled")), _open_artwork.bind(p))
	_apply_painting_size(p, 4.0 / 3.0)
	building.add_map_item(f, _wall_rect(slot, 1.2 if slot["featured"] else 0.8), "featured" if slot["featured"] else "painting")
	_load_painting_texture(p)


func _wall_rect(slot: Dictionary, half: float) -> Rect2:
	var pos: Vector3 = slot["pos"]
	var n: Vector3 = slot["normal"]
	if absf(n.x) > 0.5:
		return Rect2(pos.x - 0.15, pos.z - half, 0.3, half * 2.0)
	return Rect2(pos.x - half, pos.z - 0.15, half * 2.0, 0.3)


func _apply_painting_size(p: Dictionary, aspect: float) -> void:
	var slot: Dictionary = p["slot"]
	var max_size: Vector2 = slot["max_size"]
	var size := Vector2(max_size.x, max_size.x / aspect)
	if size.y > max_size.y:
		size = Vector2(max_size.y * aspect, max_size.y)
	p["quad"].size = size
	var outer := Vector3(size.x + FRAME_BORDER * 2.0, size.y + FRAME_BORDER * 2.0, FRAME_DEPTH)
	p["frame_mesh"].size = outer
	var shape: BoxShape3D = p["body"].get_child(0).shape
	shape.size = outer + Vector3(0, 0, 0.04)
	var hang: float = slot["hang"]
	p["plate"].position = Vector3(outer.x / 2.0 + 0.4, CAPTION_HEIGHT - hang, -FRAME_DEPTH / 2.0 + 0.005)
	# スポットライト: 天井付近から斜め下に、額全体を少し余裕を持って照らす
	var target: Vector3 = p["root"].global_position
	var normal: Vector3 = slot["normal"]
	var light_pos := target + normal * 1.9
	light_pos.y = slot["floor_y"] + Building.CEILING_HEIGHT - 0.35
	_aim_spot(p["spot"], light_pos, target, maxf(outer.x, outer.y) * 0.62 + 0.25, int(p["art"].get("light_kelvin", 3000)))


func _load_painting_texture(p: Dictionary) -> void:
	var art: Dictionary = p["art"]
	var tex := await api.get_texture(art.get("url", ""))
	if tex:
		p["texture"] = tex
		p["material"].albedo_texture = tex
		p["material"].albedo_color = Color.WHITE
		_apply_painting_size(p, float(tex.get_width()) / float(tex.get_height()))
		if art.get("featured", false):
			outdoor.set_banner(p["floor"], tex)  # 正面玄関のバナーにメイン作品を掲示
	_finish_item(p["floor"], tex != null)


func _create_model(art: Dictionary, slot: Dictionary, f: int) -> void:
	var facing: Vector3 = slot["facing"]
	var root := Node3D.new()
	root.name = "Model_%s" % art.get("id", "x")
	add_child(root)
	root.position = slot["pos"]
	root.rotation.y = atan2(facing.x, facing.z)

	# 台座
	var plinth := building._box(Vector3(0, PLINTH.y / 2.0, 0), PLINTH, building.mat_plinth, false, root)
	plinth.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# 進入防止の柵 (ポール + ロープ) と、その範囲の見えない当たり判定
	var post_mat := building.mat_metal
	var rope_mat := building._mat(Color(0.45, 0.06, 0.08), 0.8)
	var corners := [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]
	for i in corners.size():
		var c: Vector2 = corners[i] * BARRIER_HALF
		var post := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.035
		cyl.bottom_radius = 0.035
		cyl.height = 0.95
		post.mesh = cyl
		post.material_override = post_mat
		post.position = Vector3(c.x, 0.475, c.y)
		root.add_child(post)
		building._box(Vector3(c.x, 0.012, c.y), Vector3(0.28, 0.024, 0.28), post_mat, false, root)
		var n: Vector2 = corners[(i + 1) % corners.size()] * BARRIER_HALF
		var mid := (c + n) / 2.0
		var length := c.distance_to(n)
		var rope := building._box(Vector3(mid.x, 0.86, mid.y),
			Vector3(length if absf(c.y - n.y) < 0.01 else 0.03, 0.03, length if absf(c.x - n.x) < 0.01 else 0.03),
			rope_mat, false, root)
		rope.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var blocker := Interact.add_box(root, Vector3(BARRIER_HALF * 2.0 + 0.1, 2.4, BARRIER_HALF * 2.0 + 0.1),
		Vector3(0, 1.2, 0), str(art.get("title", "Untitled")), Callable())

	# キャプション台 (柵の外・手前)
	var stand := Node3D.new()
	stand.position = Vector3(0, 0, BARRIER_HALF + 0.45)
	root.add_child(stand)
	building._box(Vector3(0, 0.5, 0), Vector3(0.06, 1.0, 0.06), building.mat_dark, false, stand)
	var plate := Node3D.new()
	plate.position = Vector3(0, 1.05, 0)
	plate.rotation.x = deg_to_rad(-35.0)
	stand.add_child(plate)
	building._box(Vector3.ZERO, Vector3(0.42, 0.28, 0.02), building.mat_dark, false, plate)
	var label := _caption_label(art, 380, Color(0.92, 0.9, 0.86))
	label.position = Vector3(0, 0, 0.012)
	plate.add_child(label)
	var stand_body := Interact.add_box(stand, Vector3(0.5, 1.2, 0.4), Vector3(0, 0.6, 0),
		str(art.get("title", "Untitled")), Callable())

	# 回転する展示物の支点
	var spinner := Node3D.new()
	spinner.position = Vector3(0, PLINTH.y, 0)
	root.add_child(spinner)
	_spinners.append(spinner)

	var size := float(art.get("display_size", 1.0))
	var spot := _spot(f, true)
	var target := root.global_position + Vector3(0, PLINTH.y + size * 0.45, 0)
	var light_pos := root.global_position + facing * 2.2
	light_pos.y = slot["pos"].y + Building.CEILING_HEIGHT - 0.35
	_aim_spot(spot, light_pos, target, size * 0.9 + 0.6, int(art.get("light_kelvin", 5000)))

	var p := {"art": art, "texture": null}
	_models[str(art.get("id", ""))] = {"art": art, "spinner": spinner, "floor": f, "hq_loaded": false}
	Interact.attach(blocker, str(art.get("title", "Untitled")), _open_artwork.bind(p))
	Interact.attach(stand_body, str(art.get("title", "Untitled")), _open_artwork.bind(p))
	var pos: Vector3 = slot["pos"]
	building.add_map_item(f, Rect2(pos.x - 0.5, pos.z - 0.5, 1.0, 1.0), "pedestal")
	_load_model(art, spinner, f)


func _load_model(art: Dictionary, spinner: Node3D, f: int, hq: bool = false) -> void:
	var body := await api.get_bytes(art.get("hq_url" if hq else "url", ""), 300.0)
	if body.is_empty():
		if not hq:
			_finish_item(f, false)
		return
	await api.decode_turn()  # glTF の解析は重いので他の重い処理と同じフレームに重ねない
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	# 実行時読み込みなのでテクスチャは非圧縮でメモリ上に展開する
	state.handle_binary_image = GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED
	var err := doc.append_from_buffer(body, "", state)
	if err != OK:
		push_warning("glTF parse failed for %s: %s" % [art.get("id"), error_string(err)])
		if not hq:
			_finish_item(f, false)
		return
	await api.decode_turn()
	var scene := doc.generate_scene(state)
	if hq:  # 高品質版に差し替え
		for c in spinner.get_children():
			c.queue_free()
	var holder := Node3D.new()
	spinner.add_child(holder)
	holder.add_child(scene)

	# 館内は空の映り込みを切っているため、金属の面は黒くつぶれる。金属感を抑えて照明で色が見えるようにする
	for n in scene.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		for i in mi.get_surface_override_material_count():
			var m := mi.get_active_material(i) as BaseMaterial3D
			if m and m.metallic > 0.35:
				m.metallic = 0.35
	# モデルの大きさを測り、display_size (m) に収まるよう拡縮して台座の上に乗せる
	var aabb := _measure(scene, holder)
	var longest := maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
	if longest > 0.0001:
		var s := float(art.get("display_size", 1.0)) / longest
		holder.scale = Vector3.ONE * s
		holder.position = Vector3(-aabb.get_center().x * s, -aabb.position.y * s, -aabb.get_center().z * s)

	for ap in scene.find_children("*", "AnimationPlayer", true, false):
		var player_node := ap as AnimationPlayer
		var names := player_node.get_animation_list()
		if names.is_empty():
			continue
		var pick: String = "Survey" if names.has("Survey") else names[0]
		player_node.get_animation(pick).loop_mode = Animation.LOOP_LINEAR
		player_node.play(pick)
	if not hq:
		_finish_item(f, true)


func _measure(scene: Node, holder: Node3D) -> AABB:
	var result := AABB()
	var first := true
	var inv := holder.global_transform.affine_inverse()
	for n in scene.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		var box: AABB = (inv * mi.global_transform) * mi.get_aabb()
		result = box if first else result.merge(box)
		first = false
	return result


# ---------------------------------------------------------------------------
# 照明
# ---------------------------------------------------------------------------
func _spot(_f: int, shadows: bool = false) -> SpotLight3D:
	var spot := SpotLight3D.new()
	add_child(spot)
	spot.light_cull_mask = Building.LAYER_INDOOR  # 館内だけを照らす
	spot.light_energy = 2.6
	spot.spot_attenuation = 0.6
	spot.spot_angle_attenuation = 0.7  # 縁をなだらかに
	# 影はぼかしたソフトシャドウ (3D作品のみ。絵画は壁に密着しているため省略して軽量化)
	spot.shadow_enabled = shadows
	spot.shadow_blur = 2.5
	spot.shadow_bias = 0.04
	# 器具 (天井から吊ったスポットライトの筐体)
	var housing := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.05
	cyl.bottom_radius = 0.075
	cyl.height = 0.2
	housing.mesh = cyl
	housing.material_override = building.mat_dark
	housing.rotation.x = -PI / 2.0  # 円柱の軸 (+Y) をライトの向き (-Z) に合わせる
	housing.position.z = 0.08
	housing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	spot.add_child(housing)
	return spot


func _aim_spot(spot: SpotLight3D, from: Vector3, target: Vector3, radius: float, kelvin: int) -> void:
	spot.look_at_from_position(from, target, Vector3.UP)
	var dist := from.distance_to(target)
	spot.spot_range = dist + 3.0
	spot.spot_angle = clampf(rad_to_deg(atan(radius / dist)) + 6.0, 12.0, 60.0)
	spot.light_color = kelvin_to_color(kelvin)
	# 天井へのロッド
	if not spot.has_meta("rod"):
		var rod := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.025, 0.36, 0.025)
		rod.mesh = bm
		rod.material_override = building.mat_dark
		rod.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(rod)
		spot.set_meta("rod", rod)
	var r: MeshInstance3D = spot.get_meta("rod")
	r.position = from + Vector3(0, 0.18, 0)


## 色温度 (K) → RGB (Tanner Helland の近似式)
static func kelvin_to_color(kelvin: int) -> Color:
	var t := kelvin / 100.0
	var r := 255.0
	var g := 0.0
	var b := 255.0
	if t <= 66.0:
		g = 99.4708025861 * log(t) - 161.1195681661
		b = 0.0 if t <= 19.0 else 138.5177312231 * log(t - 10.0) - 305.0447927307
	else:
		r = 329.698727446 * pow(t - 60.0, -0.1332047592)
		g = 288.1221695283 * pow(t - 60.0, -0.0755148492)
	return Color(clampf(r, 0, 255) / 255.0, clampf(g, 0, 255) / 255.0, clampf(b, 0, 255) / 255.0)


# ---------------------------------------------------------------------------
# キャプション / モーダル
# ---------------------------------------------------------------------------
func _caption_label(art: Dictionary, width_px: int, color: Color = Color(0.12, 0.12, 0.12)) -> Label3D:
	var l := Label3D.new()
	l.text = "%s\n%s, %s" % [art.get("title", "Untitled"), art.get("artist", "Unknown"), _year(art)]
	l.font = GalleryFonts.body()
	l.font_size = 24
	l.pixel_size = 0.001
	l.width = width_px
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.modulate = color
	l.outline_size = 0
	l.double_sided = false
	return l


## JSON の数値は float で届くので "1889.0" にならないよう整数化
static func _year(art: Dictionary) -> String:
	var y = art.get("year")
	if y is float or y is int:
		return str(int(y))
	return "" if y == null else str(y)


func _open_artwork(p: Dictionary) -> void:
	var art: Dictionary = p["art"]
	var kind := "Painting" if art.get("kind") == "painting" else "3D work"
	var bb := "[font_size=24][b]%s[/b][/font_size]\n[color=#c9a45c]%s  /  %s[/color]\n\n%s\n\n" % [
		GalleryUI.bb_escape(str(art.get("artist", "Unknown"))), _year(art), kind,
		GalleryUI.bb_escape(str(art.get("description", ""))),
	]
	bb += "[color=#9a96a0][font_size=16]Credit: %s[/font_size][/color]\n" % GalleryUI.bb_escape(str(art.get("credit", "")))
	var src := str(art.get("source_url", ""))
	if src != "":
		bb += "[font_size=16][url=%s]View source[/url][/font_size]" % src
	var info: Dictionary = _models.get(str(art.get("id", "")), {})
	if art.has("hq_url") and not info.get("hq_loaded", false):
		bb += "

[font_size=18][url=omni:hq:%s]> Load the high-quality version (%s MB)[/url][/font_size]" % [
			art.get("id"), str(art.get("hq_mb", "?"))]
	elif info.get("hq_loaded", false):
		bb += "

[color=#9a96a0][font_size=16]Showing the high-quality version.[/font_size][/color]"
	ui.show_modal(str(art.get("title", "Untitled")), bb, p.get("texture"))


## モーダルのリンクからの操作 (現在は 3D 作品の高品質版の読み込みのみ)
func _on_ui_action(action: String) -> void:
	if not action.begins_with("hq:"):
		return
	var info: Dictionary = _models.get(action.trim_prefix("hq:"), {})
	if info.is_empty() or info.get("hq_loaded", false):
		return
	info["hq_loaded"] = true
	ui.close_modal()
	var art: Dictionary = info["art"]
	ui.set_status("Loading the high-quality version (%s MB) ..." % str(art.get("hq_mb", "?")))
	await _load_model(art, info["spinner"], info["floor"], true)
	ui.set_status("High-quality version loaded", 3.0)
