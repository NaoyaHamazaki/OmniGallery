class_name TimeAttack
extends Node3D
## タクシーのタイムアタック (美術館とは別マップ)。
##   入り方: タクシーに乗ると駐車場の南端のゲートが開く → その先へ進むと暗転してコースへ
##   コース: 教習所風 (直線・カーブ・S字・クランク)。走るルートは地面の黄色い線と矢印で表示。1 周 約 800m
##   計測: 3-2-1-GO でスタート → チェックポイントを順に通過してスタートラインに戻るとゴール
##   ランキング: 上位 10 位に入ったらアルファベット大文字 3 文字を登録 (サーバーの SQLite に保存)
## コースは美術館から 1km 離れた場所に作る。カメラの描画距離 (220m) の外なので美術館側は描画されない。

enum State { IDLE, COUNTDOWN, RUNNING, FINISHED }

const ORIGIN := Vector3(0, 0, 1000)
const ROAD_W := 7.0
const CP_RADIUS := 8.0
const OFFROAD_CAP := 4.5
const LAYER := 2
## コースの中心線 (x, z)。先頭がスタート/ゴール、時計回り。1 周 約 800m (タクシーで約 1 分半)
const ROUTE := [
	Vector2(0, 0), Vector2(182, 0), Vector2(210, 28), Vector2(210, 98),  # 直線 → 右カーブ
	Vector2(182, 126), Vector2(210, 154), Vector2(182, 182),  # S 字
	Vector2(84, 182), Vector2(63, 182), Vector2(63, 162.4), Vector2(39.2, 162.4),  # クランク
	Vector2(0, 162.4), Vector2(-28, 134.4), Vector2(-28, 28),  # バックストレート
]
const GOLD := Color(0.79, 0.64, 0.36)

var active := false
var state := State.IDLE
var best_ms := -1
var last_ms := 0
var last_rank := -1

var _built := false
var _start_ms := 0
var _next_cp := 1
var _taxi: Taxi
var _api: ApiClient
var _audio: GalleryAudio
var _ui: GalleryUI
var _hud: Control
var _time_label: Label
var _info_label: Label
var _center_label: Label
var _panel: PanelContainer
var _result_label: Label
var _entry_box: Control
var _slot_labels: Array[Label] = []
var _ranking_label: RichTextLabel
var _buttons: Control
var _fade: ColorRect
var _name: Array[int] = [0, 0, 0]
var _slot := 0
var _submitting := false


func _ready() -> void:
	_api = get_node("%Api")
	_audio = get_node("%Audio")
	_ui = get_node("%UI")
	_build_hud()


func _taxi_node() -> Taxi:
	if _taxi == null:
		_taxi = get_node("%Outdoor").get_node_or_null("Taxi")
	return _taxi


# ---------------------------------------------------------------------------
# 出入り
# ---------------------------------------------------------------------------
func enter() -> void:
	if active:
		return
	active = true
	_taxi_node().locked = true
	await _fade_to(1.0)
	if not _built:
		_build_course()
		_built = true
	_ui.set_exit_label("BACK TO MUSEUM (E)")
	_hud.visible = true
	_restart()
	await _fade_to(0.0)


func exit_course() -> void:
	if not active:
		return
	state = State.IDLE
	await _fade_to(1.0)
	var t := _taxi_node()
	t.teleport(Vector3(Outdoor.GATE_X, Outdoor.GROUND_Y + 0.05, Outdoor.LOT_Z - 4.0), 0.0)
	t.locked = false
	t.speed_cap = Taxi.MAX_SPEED
	_hud.visible = false
	_panel.visible = false
	_ui.set_exit_label("EXIT TAXI (E)")
	active = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if not _ui.touch_controls.visible else Input.MOUSE_MODE_VISIBLE
	await _fade_to(0.0)


func _restart() -> void:
	_panel.visible = false
	_next_cp = 1
	var t := _taxi_node()
	# スタートラインのすぐ先 (最初の直線の上) から、直線の向きでスタート
	var dir: Vector2 = (ROUTE[1] - ROUTE[0]).normalized()
	var start: Vector2 = ROUTE[0] + dir * 3.0
	t.teleport(ORIGIN + Vector3(start.x, 0.05, start.y), _yaw(dir))
	t.locked = true
	t.speed_cap = Taxi.MAX_SPEED
	_time_label.text = _fmt(0)
	_update_info()
	if not _ui.touch_controls.visible:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_countdown()


func _countdown() -> void:
	state = State.COUNTDOWN
	for n in ["3", "2", "1"]:
		_center(n)
		_audio.play("ui_close", -6.0, 1.2)
		await get_tree().create_timer(0.8).timeout
		if state != State.COUNTDOWN:
			return
	_center("GO!")
	_audio.play("ui_open", -4.0)
	_taxi_node().locked = false
	state = State.RUNNING
	_start_ms = Time.get_ticks_msec()
	await get_tree().create_timer(0.9).timeout
	if _center_label.text == "GO!":
		_center("")


# ---------------------------------------------------------------------------
# 計測
# ---------------------------------------------------------------------------
func _physics_process(_delta: float) -> void:
	if not active or state != State.RUNNING:
		return
	var t := _taxi_node()
	var p := Vector2(t.global_position.x - ORIGIN.x, t.global_position.z - ORIGIN.z)
	var off := _distance_to_route(p) > ROAD_W / 2.0 + 0.8
	t.speed_cap = OFFROAD_CAP if off else Taxi.MAX_SPEED
	if _next_cp < ROUTE.size():
		if p.distance_to(ROUTE[_next_cp]) < CP_RADIUS:
			_next_cp += 1
			_audio.play("step", -8.0, 1.6)
	elif p.distance_to(ROUTE[0]) < CP_RADIUS:
		_finish()
		return
	_time_label.text = _fmt(Time.get_ticks_msec() - _start_ms)
	_update_info(off)


func _update_info(off: bool = false) -> void:
	var s := "CHECKPOINT  %d / %d" % [mini(_next_cp - 1, ROUTE.size() - 1), ROUTE.size() - 1]
	if best_ms > 0:
		s += "      BEST  %s" % _fmt(best_ms)
	if off:
		s += "      OFF ROAD!"
	_info_label.text = s


func _finish() -> void:
	state = State.FINISHED
	last_ms = Time.get_ticks_msec() - _start_ms
	_taxi_node().locked = true
	if best_ms < 0 or last_ms < best_ms:
		best_ms = last_ms
	_time_label.text = _fmt(last_ms)
	_center("FINISH")
	_audio.play("ding", -4.0)
	await get_tree().create_timer(1.6).timeout
	_center("")
	_show_result()


func _show_result() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_panel.visible = true
	_result_label.text = "YOUR TIME   %s" % _fmt(last_ms)
	_entry_box.visible = false
	_buttons.visible = false
	_ranking_label.text = "[center]Loading ranking...[/center]"
	var data = await _api.get_json("/api/rankings")
	var top: Array = data.get("rankings", []) if data is Dictionary else []
	var qualify = data.get("qualify_ms") if data is Dictionary else null
	var in_top: bool = data is Dictionary and (qualify == null or last_ms < int(qualify))
	_ranking_label.text = _ranking_bbcode(top, -1)
	if in_top:
		_result_label.text += "\nNEW RECORD!  ENTER YOUR NAME"
		_name = [0, 0, 0]
		_slot = 0
		_refresh_slots()
		_entry_box.visible = true
	else:
		_buttons.visible = true


func _submit() -> void:
	if _submitting or not _entry_box.visible:
		return
	_submitting = true
	var entry_name := ""
	for c in _name:
		entry_name += char(65 + c)
	var res = await _api.post_json("/api/rankings", {"name": entry_name, "time_ms": last_ms})
	_submitting = false
	_entry_box.visible = false
	_buttons.visible = true
	if res is Dictionary:
		last_rank = int(res.get("rank", -1))
		_result_label.text = "YOUR TIME   %s\n%s  -  RANK %d" % [_fmt(last_ms), entry_name, last_rank]
		_ranking_label.text = _ranking_bbcode(res.get("rankings", []), last_rank)
		_audio.play("ui_open", -6.0)
	else:
		_result_label.text += "\n(failed to save: %s)" % _api.last_error


func _ranking_bbcode(top: Array, highlight: int) -> String:
	var s := "[center][font_size=20][color=#c9a45c]RANKING  TOP 10[/color][/font_size]\n"
	if top.is_empty():
		s += "No records yet[/center]"
		return s
	s += "[table=3]"
	for r in top:
		var rank := int(r.get("rank", 0))
		var col := "#ffe2a0" if rank == highlight else "#ece6da"
		s += "[cell][color=%s]%2d.   [/color][/cell][cell][color=%s]%s     [/color][/cell][cell][color=%s]%s[/color][/cell]" % [
			col, rank, col, str(r.get("name", "???")), col, _fmt(int(r.get("time_ms", 0)))]
	return s + "[/table][/center]"


# ---------------------------------------------------------------------------
# 名前入力 (PC はキーボード、スマホは +/- ボタン)
# ---------------------------------------------------------------------------
func _input(event: InputEvent) -> void:
	if not (active and _entry_box.visible) or not (event is InputEventKey and event.pressed):
		return
	var k: int = event.physical_keycode
	if k >= KEY_A and k <= KEY_Z:
		_name[_slot] = k - KEY_A
		_slot = mini(_slot + 1, 2)
	elif k == KEY_BACKSPACE or k == KEY_LEFT:
		_slot = maxi(_slot - 1, 0)
	elif k == KEY_RIGHT:
		_slot = mini(_slot + 1, 2)
	elif k == KEY_UP:
		_name[_slot] = (_name[_slot] + 1) % 26
	elif k == KEY_DOWN:
		_name[_slot] = (_name[_slot] + 25) % 26
	elif k == KEY_ENTER or k == KEY_KP_ENTER:
		_submit()
	_refresh_slots()
	get_viewport().set_input_as_handled()  # E や M など他の操作キーとして扱わせない


func _refresh_slots() -> void:
	for i in 3:
		_slot_labels[i].text = char(65 + _name[i])
		_slot_labels[i].add_theme_color_override("font_color", Color(1.0, 0.88, 0.6) if i == _slot else Color(0.9, 0.88, 0.84))


func _bump(i: int, d: int) -> void:
	_name[i] = (_name[i] + d + 26) % 26
	_slot = i
	_refresh_slots()


# ---------------------------------------------------------------------------
# 表示
# ---------------------------------------------------------------------------
func _fmt(ms: int) -> String:
	return "%02d:%02d.%02d" % [ms / 60000, (ms / 1000) % 60, (ms / 10) % 100]


func _center(text: String) -> void:
	_center_label.text = text


func _fade_to(a: float) -> void:
	var tw := create_tween()
	tw.tween_property(_fade, "color:a", a, 0.45)
	await tw.finished


func _label(size: int, font: Font = null) -> Label:
	var l := Label.new()
	l.add_theme_font_override("font", font if font else GalleryFonts.title())
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(0.97, 0.94, 0.88))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.add_theme_constant_override("outline_size", 6)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return l


func _button(text: String, cb: Callable, size: int = 20) -> Button:
	var b := Button.new()
	b.text = "  %s  " % text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_override("font", GalleryFonts.title())
	b.add_theme_font_size_override("font_size", size)
	b.pressed.connect(cb)
	return b


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	_hud = Control.new()
	_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.visible = false
	layer.add_child(_hud)

	_time_label = _label(46)
	_time_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_time_label.offset_left = -200
	_time_label.offset_right = 200
	_time_label.offset_top = 52
	_hud.add_child(_time_label)
	_info_label = _label(16)
	_info_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_info_label.offset_left = -400
	_info_label.offset_right = 400
	_info_label.offset_top = 112
	_hud.add_child(_info_label)
	_center_label = _label(110)
	_center_label.set_anchors_preset(Control.PRESET_CENTER)
	_center_label.offset_left = -400
	_center_label.offset_right = 400
	_center_label.offset_top = -90
	_center_label.offset_bottom = 60
	_hud.add_child(_center_label)

	_panel = PanelContainer.new()
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_bottom = 0.5
	_panel.offset_left = -300
	_panel.offset_right = 300
	_panel.offset_top = -280
	_panel.offset_bottom = 280
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.11, 0.12, 0.16, 0.95)
	style.border_color = GOLD
	style.set_border_width_all(2)
	style.set_corner_radius_all(14)
	style.set_content_margin_all(22)
	_panel.add_theme_stylebox_override("panel", style)
	_panel.visible = false
	_hud.add_child(_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	_panel.add_child(v)
	var title := _label(28)
	title.text = "TIME ATTACK"
	title.add_theme_color_override("font_color", GOLD)
	v.add_child(title)
	_result_label = _label(22)
	v.add_child(_result_label)

	var entry := VBoxContainer.new()
	entry.alignment = BoxContainer.ALIGNMENT_CENTER
	var slots := HBoxContainer.new()
	slots.alignment = BoxContainer.ALIGNMENT_CENTER
	slots.add_theme_constant_override("separation", 18)
	entry.add_child(slots)
	for i in 3:
		var col := VBoxContainer.new()
		col.add_child(_button("+", _bump.bind(i, 1), 18))
		var l := _label(44)
		l.custom_minimum_size = Vector2(56, 0)
		col.add_child(l)
		_slot_labels.append(l)
		col.add_child(_button("-", _bump.bind(i, -1), 18))
		slots.add_child(col)
	var hint := _label(13, GalleryFonts.body())
	hint.text = "Type A-Z or use + / -   then ENTER"
	entry.add_child(hint)
	var ok := _button("ENTER", _submit)
	ok.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	entry.add_child(ok)
	_entry_box = entry
	v.add_child(entry)

	_ranking_label = RichTextLabel.new()
	_ranking_label.bbcode_enabled = true
	_ranking_label.fit_content = true
	_ranking_label.scroll_active = false
	_ranking_label.add_theme_font_override("normal_font", GalleryFonts.title())
	_ranking_label.add_theme_font_size_override("normal_font_size", 18)
	v.add_child(_ranking_label)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)
	row.add_child(_button("RETRY", _restart))
	row.add_child(_button("BACK TO MUSEUM", exit_course))
	_buttons = row
	v.add_child(row)

	var fade_layer := CanvasLayer.new()
	fade_layer.layer = 20
	add_child(fade_layer)
	_fade = ColorRect.new()
	_fade.color = Color(0, 0, 0, 0)
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fade_layer.add_child(_fade)


# ---------------------------------------------------------------------------
# コース
# ---------------------------------------------------------------------------
static func _yaw(dir: Vector2) -> float:
	# 前方 (-Z) が dir (x, z) を向く回転
	return atan2(-dir.x, -dir.y)


func _distance_to_route(p: Vector2) -> float:
	var best := INF
	for i in ROUTE.size():
		var a: Vector2 = ROUTE[i]
		var b: Vector2 = ROUTE[(i + 1) % ROUTE.size()]
		var ab := b - a
		var t := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
		best = minf(best, p.distance_to(a + ab * t))
	return best


func _w(p: Vector2, y: float) -> Vector3:
	return ORIGIN + Vector3(p.x, y, p.y)


func _mat(c: Color, rough: float = 0.9) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m


func _mesh(mesh: Mesh, mat: Material, pos: Vector3, yaw: float = 0.0, shadow: bool = false) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation.y = yaw
	mi.layers = LAYER
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


func _box_mesh(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


func _solid(center: Vector3, size: Vector3, mat: Material) -> void:
	_mesh(_box_mesh(size), mat, center, 0.0, true)
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	body.add_child(cs)
	body.position = center
	add_child(body)


func _build_course() -> void:
	var grass := _mat(Color(0.32, 0.47, 0.24), 1.0)
	var asphalt := _mat(Color(0.2, 0.2, 0.21), 0.95)
	var white := _mat(Color(0.92, 0.92, 0.9), 0.8)
	var yellow := _mat(Color(0.98, 0.78, 0.15), 0.7)
	var black := _mat(Color(0.05, 0.05, 0.05), 0.8)
	var wall := _mat(Color(0.75, 0.74, 0.7), 0.9)
	var red := _mat(Color(0.75, 0.12, 0.1), 0.7)

	# 地面 (当たり判定はこれだけ。道路は見た目の薄い板)
	var c0 := Vector2(-75, -50)
	var c1 := Vector2(255, 235)
	_solid(_w((c0 + c1) / 2.0, -0.5), Vector3(c1.x - c0.x, 1.0, c1.y - c0.y), grass)
	# 外周の低い壁
	var h := 1.0
	_solid(_w(Vector2((c0.x + c1.x) / 2.0, c0.y), h / 2.0), Vector3(c1.x - c0.x, h, 0.6), wall)
	_solid(_w(Vector2((c0.x + c1.x) / 2.0, c1.y), h / 2.0), Vector3(c1.x - c0.x, h, 0.6), wall)
	_solid(_w(Vector2(c0.x, (c0.y + c1.y) / 2.0), h / 2.0), Vector3(0.6, h, c1.y - c0.y), wall)
	_solid(_w(Vector2(c1.x, (c0.y + c1.y) / 2.0), h / 2.0), Vector3(0.6, h, c1.y - c0.y), wall)

	var joint := CylinderMesh.new()
	joint.top_radius = ROAD_W / 2.0
	joint.bottom_radius = ROAD_W / 2.0
	joint.height = 0.02
	joint.radial_segments = 20
	var n := ROUTE.size()
	var dash := _box_mesh(Vector3(0.25, 0.01, 2.4))
	for i in n:
		var a: Vector2 = ROUTE[i]
		var b: Vector2 = ROUTE[(i + 1) % n]
		var d := b - a
		var seg_len := d.length()
		var dir := d / seg_len
		var yaw := _yaw(dir)
		var mid := (a + b) / 2.0
		# 舗装 + 角の丸め
		_mesh(_box_mesh(Vector3(ROAD_W, 0.02, seg_len)), asphalt, _w(mid, 0.01), yaw)
		_mesh(joint, asphalt, _w(a, 0.011))
		# 両端の白線 (教習所の外側線)
		var nrm := Vector2(-dir.y, dir.x)
		for s in [-1.0, 1.0]:
			_mesh(_box_mesh(Vector3(0.15, 0.01, seg_len)), white, _w(mid + nrm * s * (ROAD_W / 2.0 - 0.3), 0.025), yaw)
		# 走るルート: 中央の黄色い破線 + 進行方向の矢印 (シェブロン)
		var k := 2.0
		while k < seg_len - 2.0:
			_mesh(dash, yellow, _w(a + dir * k, 0.026), yaw)
			k += 5.0
		var m := 9.0
		while m < seg_len - 4.0:
			_chevron(a + dir * m, dir, yellow)
			m += 18.0
		# 曲がり角の外側にパイロン
		if i > 0:
			var prev: Vector2 = (a - ROUTE[i - 1]).normalized()
			var turn := prev.x * dir.y - prev.y * dir.x
			if absf(turn) > 0.3:
				var outward := (prev - dir).normalized()
				for j in 3:
					var side := Vector2(-outward.y, outward.x) * (j - 1) * 1.6
					_cone(a + outward * (ROAD_W / 2.0 + 1.0) + side)
	# スタート/ゴールライン (市松模様) とゲート
	var d0: Vector2 = (ROUTE[1] - ROUTE[0]).normalized()
	var n0 := Vector2(-d0.y, d0.x)
	var sq := ROAD_W / 8.0
	var sqm := _box_mesh(Vector3(sq, 0.012, sq))
	for r in 2:
		for c in 8:
			var p: Vector2 = ROUTE[0] + n0 * (-ROAD_W / 2.0 + sq * (c + 0.5)) + d0 * (sq * (r - 0.5))
			_mesh(sqm, white if (r + c) % 2 == 0 else black, _w(p, 0.03), _yaw(d0))
	for s in [-1.0, 1.0]:
		_solid(_w(ROUTE[0] + n0 * s * (ROAD_W / 2.0 + 1.2), 2.75), Vector3(0.35, 5.5, 0.35), red)
	_mesh(_box_mesh(Vector3(ROAD_W + 2.8, 1.0, 0.4)), red, _w(ROUTE[0], 5.6), _yaw(d0))  # 道路をまたぐ向き
	for face in [-1.0, 1.0]:
		var l := Label3D.new()
		l.text = "START  /  FINISH"
		l.font = GalleryFonts.title()
		l.font_size = 64
		l.pixel_size = 0.009
		l.outline_size = 0
		l.modulate = Color(1, 0.95, 0.85)
		l.double_sided = false
		l.layers = LAYER
		var face_dir: Vector2 = d0 * face * -1.0
		l.position = _w(ROUTE[0] + face_dir * 0.22, 5.6)
		l.rotation.y = atan2(face_dir.x, face_dir.y)
		add_child(l)
	# 区間名を地面に表示
	_ground_label("S-CURVE", Vector2(196, 140), yellow)
	_ground_label("CRANK", Vector2(50, 172), yellow)
	_ground_label("OMNIGALLERY DRIVING SCHOOL", Vector2(90, 85), white, 0.04)
	# 周囲の木 (円錐形の針葉樹。メッシュを共有して軽量化)
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.12
	trunk.bottom_radius = 0.18
	trunk.height = 1.6
	trunk.radial_segments = 6
	var crown := CylinderMesh.new()
	crown.top_radius = 0.0
	crown.bottom_radius = 1.6
	crown.height = 4.5
	crown.radial_segments = 8
	var bark := _mat(Color(0.32, 0.22, 0.14))
	var pine := _mat(Color(0.16, 0.3, 0.17))
	var rnd := RandomNumberGenerator.new()
	rnd.seed = 3
	for i in 40:
		var p := Vector2(rnd.randf_range(c0.x + 3, c1.x - 3), rnd.randf_range(c0.y + 3, c1.y - 3))
		if _distance_to_route(p) < ROAD_W + 4.0:
			continue
		_mesh(trunk, bark, _w(p, 0.8), 0.0, true)
		_mesh(crown, pine, _w(p, 3.6), 0.0, true)
		var body := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var shape := CylinderShape3D.new()
		shape.radius = 0.4
		shape.height = 3.0
		cs.shape = shape
		body.add_child(cs)
		body.position = _w(p, 1.5)
		add_child(body)


func _chevron(p: Vector2, dir: Vector2, mat: Material) -> void:
	var bar := _box_mesh(Vector3(0.3, 0.01, 1.7))
	var yaw := _yaw(dir)
	for s in [-1.0, 1.0]:
		var nrm: Vector2 = Vector2(-dir.y, dir.x) * s
		_mesh(bar, mat, _w(p + nrm * 0.55 - dir * 0.6, 0.027), yaw + s * deg_to_rad(35.0))


func _cone(p: Vector2) -> void:
	if not has_meta("cone_mesh"):
		var c := CylinderMesh.new()
		c.top_radius = 0.04
		c.bottom_radius = 0.22
		c.height = 0.7
		c.radial_segments = 10
		set_meta("cone_mesh", c)
		set_meta("cone_mat", _mat(Color(1.0, 0.42, 0.08), 0.6))
	_mesh(get_meta("cone_mesh"), get_meta("cone_mat"), _w(p, 0.35), 0.0, true)
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = 0.22
	shape.height = 0.7
	cs.shape = shape
	body.add_child(cs)
	body.position = _w(p, 0.35)
	add_child(body)


func _ground_label(text: String, p: Vector2, mat: StandardMaterial3D, pixel: float = 0.025) -> void:
	var l := Label3D.new()
	l.text = text
	l.font = GalleryFonts.title()
	l.font_size = 96
	l.pixel_size = pixel
	l.outline_size = 0
	l.modulate = mat.albedo_color
	l.layers = LAYER
	l.position = _w(p, 0.04)
	l.rotation.x = -PI / 2.0  # 地面に寝かせる
	add_child(l)
