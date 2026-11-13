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
## コース (教習所風)。敷地全体が舗装されていて、緑の中島が道路を区切る。
## 走るルートは外周 → クランク → 内周道路 → S 字 → 外周 の順。①〜⑧ の標識がチェックポイント
const AREA := Rect2(15, 15, 190, 130)  # 外周路の中心線で囲まれた範囲
const OFFROUTE_DIST := 9.0  # ルートからこれ以上離れると減速 (別の道を走っている)
## ルート以外の道路 (見た目と抜け道用。チェックポイントがあるので近道にはならない)
const EXTRA_ROADS := [
	[Vector2(205, 70), Vector2(205, 133)], [Vector2(205, 133), Vector2(193, 145)], [Vector2(193, 145), Vector2(108, 145)],
	[Vector2(15, 70), Vector2(132, 70)], [Vector2(60, 15), Vector2(60, 145)], [Vector2(120, 15), Vector2(120, 90)],
	[Vector2(15, 110), Vector2(60, 110)], [Vector2(162, 15), Vector2(162, 57)],
]
const CROSSWALKS := [  # [位置, 道路の向き]
	[Vector2(60, 58), Vector2(0, 1)], [Vector2(45, 70), Vector2(1, 0)], [Vector2(120, 58), Vector2(0, 1)],
	[Vector2(150, 145), Vector2(1, 0)], [Vector2(15, 95), Vector2(0, 1)],
]
static var CHECKPOINTS: Array[int] = []  # ROUTE のうち番号標識 (①〜⑧) の位置
static var ROUTE: Array[Vector2] = _make_route()


static func _make_route() -> Array[Vector2]:
	var r: Array[Vector2] = []
	var cps: Array[int] = []
	r.append_array([Vector2(50, 15), Vector2(193, 15)])  # 先頭がスタート/ゴールライン
	cps.append(r.size() - 1)  # ① 外周の北
	r.append_array([Vector2(205, 27), Vector2(205, 70)])
	cps.append(r.size() - 1)  # ② 外周の東
	r.append_array([Vector2(190, 70), Vector2(176, 70), Vector2(176, 57)])
	cps.append(r.size() - 1)  # ③ クランク
	r.append_array([Vector2(162, 57), Vector2(162, 70)])
	cps.append(r.size() - 1)  # ④ クランク出口
	r.append_array([Vector2(132, 70), Vector2(120, 82)])
	# S 字 (なめらかな正弦カーブ)
	var s0 := r.size()
	for i in 12:
		var t := float(i) / 11.0
		r.append(Vector2(120.0 + 9.0 * sin(t * TAU), 90.0 + 44.0 * t))
	cps.append(s0 + 3)  # ⑤ S 字の前半
	cps.append(r.size() - 1)  # ⑥ S 字の出口
	r.append_array([Vector2(108, 145), Vector2(27, 145)])
	cps.append(r.size() - 1)  # ⑦ 外周の南
	r.append_array([Vector2(15, 133), Vector2(15, 27)])
	cps.append(r.size() - 1)  # ⑧ 外周の西
	r.append(Vector2(27, 15))  # 角を曲がってスタートラインへ
	CHECKPOINTS = cps
	return r


const GOLD := Color(0.79, 0.64, 0.36)

var active := false
var state := State.IDLE
var best_ms := -1
var last_ms := 0
var last_rank := -1

var _built := false
var _start_ms := 0
var _next_cp := 0
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
	_next_cp = 0
	var t := _taxi_node()
	# スタートラインの手前 (ラインを越えていない位置) から、直線の向きでスタート
	var dir: Vector2 = (ROUTE[1] - ROUTE[0]).normalized()
	var start: Vector2 = ROUTE[0] - dir * 8.0
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
	var off := _distance_to_route(p) > OFFROUTE_DIST
	t.speed_cap = OFFROAD_CAP if off else Taxi.MAX_SPEED
	if _next_cp < CHECKPOINTS.size():
		if p.distance_to(ROUTE[CHECKPOINTS[_next_cp]]) < CP_RADIUS:
			_next_cp += 1
			_audio.play("ui_close", -10.0, 1.5)
	elif p.distance_to(ROUTE[0]) < CP_RADIUS:
		_finish()
		return
	_time_label.text = _fmt(Time.get_ticks_msec() - _start_ms)
	_update_info(off)


func _update_info(off: bool = false) -> void:
	var s := "CHECKPOINT  %d / %d" % [_next_cp, CHECKPOINTS.size()]
	if best_ms > 0:
		s += "      BEST  %s" % _fmt(best_ms)
	if off:
		s += "      OFF ROUTE!"
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


func _dist_to_segments(p: Vector2, segs: Array) -> float:
	var best := INF
	for sg in segs:
		var a: Vector2 = sg[0]
		var ab: Vector2 = sg[1] - a
		var t := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
		best = minf(best, p.distance_to(a + ab * t))
	return best


func _route_segments() -> Array:
	var segs: Array = []
	for i in ROUTE.size():
		segs.append([ROUTE[i], ROUTE[(i + 1) % ROUTE.size()]])
	return segs


## 同じメッシュを大量に置くときは MultiMesh にまとめて 1 回の描画で済ませる
func _multi(mesh: Mesh, mat: Material, xforms: Array, shadow: bool = false) -> void:
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.material_override = mat
	mi.layers = LAYER
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _xf(p: Vector2, y: float, yaw: float = 0.0, scale: Vector3 = Vector3.ONE) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw).scaled(scale), _w(p, y))


func _build_course() -> void:
	var grass := _mat(Color(0.33, 0.5, 0.24), 1.0)
	var island_mat := _mat(Color(0.45, 0.68, 0.22), 0.95)
	var asphalt := _mat(Color(0.47, 0.47, 0.48), 0.95)
	var white := _mat(Color(0.95, 0.95, 0.93), 0.8)
	var yellow := _mat(Color(0.98, 0.78, 0.15), 0.7)
	var black := _mat(Color(0.05, 0.05, 0.05), 0.8)
	var wall := _mat(Color(0.75, 0.74, 0.7), 0.9)
	var red := _mat(Color(0.75, 0.12, 0.1), 0.7)
	var navy := _mat(Color(0.12, 0.2, 0.42), 0.5)

	# 地面: 外側は芝生、敷地 (外周路の外側まで) は全面舗装
	var pad := ROAD_W / 2.0 + 1.0
	var paved := AREA.grow(pad)
	_solid(_w(paved.get_center(), -0.5), Vector3(paved.size.x + 120.0, 1.0, paved.size.y + 120.0), grass)
	_mesh(_box_mesh(Vector3(paved.size.x, 0.02, paved.size.y)), asphalt, _w(paved.get_center(), 0.01))
	# 敷地を囲む低い壁
	var outer := paved.grow(3.0)
	var h := 1.0
	for e in [[Vector2(outer.get_center().x, outer.position.y), Vector3(outer.size.x, h, 0.6)],
			[Vector2(outer.get_center().x, outer.end.y), Vector3(outer.size.x, h, 0.6)],
			[Vector2(outer.position.x, outer.get_center().y), Vector3(0.6, h, outer.size.y)],
			[Vector2(outer.end.x, outer.get_center().y), Vector3(0.6, h, outer.size.y)]]:
		_solid(_w(e[0], h / 2.0), e[1], wall)

	# 緑の中島: 敷地を 2.5m 角のマスに分け、どの道路からも離れたマスを中島にする (行ごとに連結して箱を減らす)
	var route_segs := _route_segments()
	var all_segs: Array = route_segs.duplicate()
	all_segs.append_array(EXTRA_ROADS)
	var cell := 2.5
	var clear := ROAD_W / 2.0 + 1.0
	var island_xf: Array = []
	var island_cells: Array[Vector2] = []
	var body := StaticBody3D.new()
	add_child(body)
	var zc := AREA.position.y + cell / 2.0
	while zc < AREA.end.y:
		var run_start := -1.0
		var xc := AREA.position.x + cell / 2.0
		while xc < AREA.end.x + cell:
			var inside := xc < AREA.end.x and _dist_to_segments(Vector2(xc, zc), all_segs) > clear
			if inside:
				island_cells.append(Vector2(xc, zc))
				if run_start < 0.0:
					run_start = xc
			elif run_start >= 0.0:
				var x0 := run_start - cell / 2.0
				var x1 := xc - cell / 2.0
				var c := Vector2((x0 + x1) / 2.0, zc)
				island_xf.append(_xf(c, 0.15, 0.0, Vector3(x1 - x0, 0.3, cell)))
				var cs := CollisionShape3D.new()
				var shape := BoxShape3D.new()
				shape.size = Vector3(x1 - x0, 0.6, cell)
				cs.shape = shape
				cs.position = _w(c, 0.3)
				body.add_child(cs)
				run_start = -1.0
			xc += cell
		zc += cell
	_multi(_box_mesh(Vector3.ONE), island_mat, island_xf)

	# 道路の標示: ルートは黄色の破線 + 矢印、他の道路は白い破線
	var dash := _box_mesh(Vector3(0.25, 0.01, 2.4))
	var yellow_xf: Array = []
	var chevron_xf: Array = []
	for sg in route_segs:
		var a: Vector2 = sg[0]
		var d: Vector2 = sg[1] - a
		var seg_len := d.length()
		var dir := d / seg_len
		var yaw := _yaw(dir)
		var k := 2.0
		while k < seg_len - 1.0:
			yellow_xf.append(_xf(a + dir * k, 0.03, yaw))
			k += 5.0
		if seg_len > 12.0:
			var m := 8.0
			while m < seg_len - 4.0:
				for s in [-1.0, 1.0]:
					var nrm: Vector2 = Vector2(-dir.y, dir.x) * s
					chevron_xf.append(_xf(a + dir * m + nrm * 0.55 - dir * 0.6, 0.032, yaw + s * deg_to_rad(35.0)))
				m += 16.0
	_multi(dash, yellow, yellow_xf)
	_multi(_box_mesh(Vector3(0.3, 0.01, 1.7)), yellow, chevron_xf)
	var white_xf: Array = []
	for sg in EXTRA_ROADS:
		var a: Vector2 = sg[0]
		var d: Vector2 = sg[1] - a
		var seg_len := d.length()
		var dir := d / seg_len
		var k := 3.0
		while k < seg_len - 3.0:
			var p: Vector2 = a + dir * k
			if _dist_to_segments(p, route_segs) > ROAD_W:  # ルートと重なる所は描かない
				white_xf.append(_xf(p, 0.028, _yaw(dir)))
			k += 6.0
	_multi(dash, white, white_xf)
	# 横断歩道
	var stripe_xf: Array = []
	for cw in CROSSWALKS:
		var p: Vector2 = cw[0]
		var dir: Vector2 = cw[1]
		var nrm := Vector2(-dir.y, dir.x)
		for i in 6:
			stripe_xf.append(_xf(p + nrm * (-ROAD_W / 2.0 + 0.7 + i * 1.12), 0.029, _yaw(dir)))
	_multi(_box_mesh(Vector3(0.55, 0.01, 3.0)), white, stripe_xf)

	# スタート/ゴールライン (市松模様) とゲート
	var d0: Vector2 = (ROUTE[1] - ROUTE[0]).normalized()
	var n0 := Vector2(-d0.y, d0.x)
	var sq := ROAD_W / 8.0
	var w_sq: Array = []
	var b_sq: Array = []
	for r in 2:
		for c in 8:
			var p: Vector2 = ROUTE[0] + n0 * (-ROAD_W / 2.0 + sq * (c + 0.5)) + d0 * (sq * (r - 0.5))
			if (r + c) % 2 == 0:
				w_sq.append(_xf(p, 0.034, _yaw(d0)))
			else:
				b_sq.append(_xf(p, 0.034, _yaw(d0)))
	var sqm := _box_mesh(Vector3(sq, 0.012, sq))
	_multi(sqm, white, w_sq)
	_multi(sqm, black, b_sq)
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

	# チェックポイントの番号標識 1〜8 (道路の右側に立つ紺色の丸看板)
	var disc := CylinderMesh.new()
	disc.top_radius = 0.6
	disc.bottom_radius = 0.6
	disc.height = 0.06
	disc.radial_segments = 20
	var pole := _box_mesh(Vector3(0.08, 2.2, 0.08))
	for i in CHECKPOINTS.size():
		var idx: int = CHECKPOINTS[i]
		var p: Vector2 = ROUTE[idx]
		var dir: Vector2 = (ROUTE[(idx + 1) % ROUTE.size()] - p).normalized()
		var right := Vector2(-dir.y, dir.x)
		var sp: Vector2 = p + right * (ROAD_W / 2.0 + 1.3)
		_mesh(pole, white, _w(sp, 1.1))
		var toward := -dir  # 近づいてくる車の方を向く
		var dm := MeshInstance3D.new()
		dm.mesh = disc
		dm.material_override = navy
		dm.layers = LAYER
		dm.rotation_order = EULER_ORDER_YXZ
		dm.rotation = Vector3(PI / 2.0, atan2(toward.x, toward.y), 0.0)
		dm.position = _w(sp, 2.5)
		add_child(dm)
		var l := Label3D.new()
		l.text = str(i + 1)
		l.font = GalleryFonts.title()
		l.font_size = 96
		l.pixel_size = 0.008
		l.outline_size = 0
		l.modulate = Color(1, 1, 1)
		l.layers = LAYER
		l.position = _w(sp, 2.5) + Vector3(toward.x, 0, toward.y) * 0.05
		l.rotation.y = atan2(toward.x, toward.y)
		add_child(l)

	# クランクの角にパイロン
	for i in range(CHECKPOINTS[1] + 1, CHECKPOINTS[3] + 1):
		var a: Vector2 = ROUTE[i]
		var prev: Vector2 = (a - ROUTE[i - 1]).normalized()
		var dir: Vector2 = (ROUTE[i + 1] - a).normalized()
		if absf(prev.x * dir.y - prev.y * dir.x) > 0.3:
			var outward := (prev - dir).normalized()
			_cone(a + outward * (ROAD_W / 2.0 + 0.6))
	_ground_label("CRANK", Vector2(197, 76), yellow)
	_ground_label("S-CURVE", Vector2(112, 86), yellow)
	# 案内板
	var board := Label3D.new()
	board.text = "OMNIGALLERY DRIVING SCHOOL"
	board.font = GalleryFonts.title()
	board.font_size = 96
	board.pixel_size = 0.02
	board.outline_size = 0
	board.modulate = GOLD
	board.layers = LAYER
	board.position = _w(Vector2(110, paved.position.y - 2.0), 3.0)
	board.rotation.y = PI
	add_child(board)

	# 中島の木 (針葉樹と丸い木を交互に。メッシュ共有 + MultiMesh で軽量化)
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.1
	trunk.bottom_radius = 0.16
	trunk.height = 1.6
	trunk.radial_segments = 6
	var crown := CylinderMesh.new()
	crown.top_radius = 0.0
	crown.bottom_radius = 1.4
	crown.height = 3.8
	crown.radial_segments = 8
	var ball := SphereMesh.new()
	ball.radius = 1.3
	ball.height = 2.4
	ball.radial_segments = 10
	ball.rings = 6
	var trunk_xf: Array = []
	var crown_xf: Array = []
	var ball_xf: Array = []
	var rnd := RandomNumberGenerator.new()
	rnd.seed = 7
	for i in 70:
		if island_cells.is_empty():
			break
		var p: Vector2 = island_cells[rnd.randi() % island_cells.size()]
		if _dist_to_segments(p, all_segs) < clear + 2.0:
			continue
		var sc := rnd.randf_range(0.8, 1.2)
		trunk_xf.append(_xf(p, 1.1, 0.0, Vector3.ONE * sc))
		if i % 2 == 0:
			crown_xf.append(_xf(p, 3.4 * sc, 0.0, Vector3.ONE * sc))
		else:
			ball_xf.append(_xf(p, 2.8 * sc, 0.0, Vector3.ONE * sc))
	_multi(trunk, _mat(Color(0.32, 0.22, 0.14)), trunk_xf, true)
	_multi(crown, _mat(Color(0.16, 0.3, 0.17)), crown_xf, true)
	_multi(ball, _mat(Color(0.24, 0.42, 0.2)), ball_xf, true)


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
