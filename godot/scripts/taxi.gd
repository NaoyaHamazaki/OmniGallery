class_name Taxi
extends CharacterBody3D
## 駐車場に 1 台だけ停まっているタクシー (イースターエッグ)。近づいてクリック/タップで運転できる。
##   W/S (スマホは左スティック上下): アクセル / ブレーキ・後退   A/D: ハンドル   E または画面の EXIT TAXI: 降りる
## 走れるのは屋外 (駐車場・広場) だけ。大階段の手前に「車だけが当たる」見えない柵がある (物理レイヤー 3)。

const BARRIER_LAYER := 4  # 物理レイヤー 3 (ビット値 4): 車だけが衝突する柵
const INTERACT_LAYER := 8  # 物理レイヤー 4: クリック判定専用 (誰とも衝突しない)
const MAX_SPEED := 11.0
const REVERSE_SPEED := 4.0
const ACCEL := 5.5
const BRAKE := 11.0
const DRAG := 2.5
const STEER_MAX := 0.55
const WHEELBASE := 2.6
const WHEEL_R := 0.34

var driving := false
var speed := 0.0
## タイムアタックのカウントダウン中・ゴール後は操作できない
var locked := false
## コース外 (芝生) では速度を制限する
var speed_cap := MAX_SPEED
## 開発用の自動運転入力 (dev_shots.gd のテストで使用)
var ai_input := Vector2.ZERO
var _steer := 0.0
var _spins: Array[Node3D] = []
var _front: Array[Node3D] = []
var _cam: Camera3D
var _player: Node
var _ui: GalleryUI
var _audio: GalleryAudio
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")


func build(b: Building, player: Node, ui: GalleryUI, audio: GalleryAudio) -> void:
	_player = player
	_ui = ui
	_audio = audio
	collision_layer = 1
	collision_mask = 1 | BARRIER_LAYER
	# 現代的なワンボックス型タクシー (汎用デザイン。実在の車種・ロゴは再現しない)
	var body_mat := b._mat(Color(0.12, 0.16, 0.36), 0.2, 0.45)  # 深藍色の艶あり塗装
	var dark := b._mat(Color(0.03, 0.03, 0.035), 0.5)
	var glass := b._mat(Color(0.16, 0.2, 0.24), 0.04, 0.5)
	var chrome := b._mat(Color(0.82, 0.82, 0.84), 0.12, 1.0)
	var lime := b._mat(Color(0.72, 0.86, 0.18), 0.35)  # フェンダーミラーの黄緑
	var head := _emissive(b, Color(1.0, 0.97, 0.9), 2.5)
	var tail := _emissive(b, Color(0.9, 0.08, 0.06), 1.4)
	var lamp := _emissive(b, Color(0.96, 0.96, 0.92), 0.6)

	# 前が -Z。下半分の車体
	_part(b, Vector3(0, 0.62, 0), Vector3(1.72, 0.6, 4.3), body_mat)
	_part(b, Vector3(0, 0.38, 0), Vector3(1.74, 0.12, 3.6), dark)  # サイドの黒い下まわり
	# 短いボンネット (前に向かって少し下がる)
	_part(b, Vector3(0, 0.98, -1.74), Vector3(1.66, 0.14, 0.92), body_mat, Vector3(-0.1, 0, 0))
	# 傾斜したフロントガラスと黒いAピラー
	var ws_ang := atan2(0.75, 0.68)
	_part(b, Vector3(0, 1.4, -0.93), Vector3(1.54, 1.0, 0.04), glass, Vector3(ws_ang, 0, 0))
	for x in [-0.79, 0.79]:
		_part(b, Vector3(x, 1.4, -0.93), Vector3(0.07, 1.02, 0.07), dark, Vector3(ws_ang, 0, 0))
	# キャビン: 大きな窓 + 黒い柱 + 屋根
	_part(b, Vector3(0, 1.28, 0.79), Vector3(1.62, 0.68, 2.66), glass)
	for x in [-0.815, 0.815]:
		for z in [0.25, 1.3, 2.08]:
			_part(b, Vector3(x, 1.28, z), Vector3(0.05, 0.68, 0.1), dark)
	_part(b, Vector3(0, 1.7, 0.78), Vector3(1.66, 0.16, 2.78), body_mat)
	_part(b, Vector3(0, 1.36, 2.13), Vector3(1.4, 0.5, 0.03), glass)  # リアガラス
	# 側面: ドアの継ぎ目・取っ手・スライドドアのレール・TAXI の文字
	for x in [-0.865, 0.865]:
		for z in [-0.52, 0.27, 1.32]:
			_part(b, Vector3(x, 0.66, z), Vector3(0.012, 0.52, 0.015), dark)
		for z in [-0.12, 0.62]:
			_part(b, Vector3(x * 1.005, 0.86, z), Vector3(0.02, 0.035, 0.15), chrome)
		_part(b, Vector3(x, 1.0, 1.7), Vector3(0.012, 0.03, 0.75), chrome)  # スライドドアのレール
		var l := Label3D.new()
		l.text = "TAXI"
		l.font = GalleryFonts.title()
		l.font_size = 32
		l.pixel_size = 0.0035
		l.modulate = Color(0.9, 0.9, 0.92)
		l.outline_size = 0
		l.double_sided = false
		l.position = Vector3(x * 1.008, 0.72, -1.45)
		l.rotation.y = PI / 2.0 if x > 0 else -PI / 2.0
		l.layers = Outdoor.LAYER
		add_child(l)
		_part(b, Vector3(x * 1.07, 1.06, -0.6), Vector3(0.1, 0.12, 0.16), dark)  # ドアミラー
	# フェンダーミラー (ボンネットの先端。先端が黄緑)
	for x in [-0.72, 0.72]:
		_part(b, Vector3(x, 1.11, -2.0), Vector3(0.03, 0.17, 0.03), dark)
		_part(b, Vector3(x, 1.2, -2.0), Vector3(0.13, 0.1, 0.07), lime)
	# 前: 大きめのグリル + 細いヘッドライト + バンパー
	_part(b, Vector3(0, 0.62, -2.16), Vector3(1.0, 0.32, 0.04), dark)
	for i in 3:
		_part(b, Vector3(0, 0.52 + i * 0.1, -2.185), Vector3(0.9, 0.015, 0.01), chrome)
	for x in [-0.6, 0.6]:
		_part(b, Vector3(x, 0.86, -2.16), Vector3(0.4, 0.1, 0.04), head)
	_part(b, Vector3(0, 0.33, -2.17), Vector3(1.74, 0.22, 0.12), dark)
	# 後ろ: 縦長のテールランプ + バンパー + ナンバー
	for x in [-0.8, 0.8]:
		_part(b, Vector3(x, 1.02, 2.16), Vector3(0.12, 0.55, 0.04), tail)
	_part(b, Vector3(0, 0.33, 2.17), Vector3(1.74, 0.22, 0.12), dark)
	_part(b, Vector3(0, 0.6, 2.165), Vector3(0.5, 0.14, 0.02), b.mat_plinth)
	# 屋根の行灯 (白いドーム)
	_part(b, Vector3(0, 1.8, -0.25), Vector3(0.36, 0.04, 0.18), dark)
	var dome := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.2
	sph.height = 0.24
	sph.radial_segments = 16
	sph.rings = 8
	dome.mesh = sph
	dome.material_override = lamp
	dome.scale = Vector3(1.1, 1.0, 0.7)
	dome.position = Vector3(0, 1.9, -0.25)
	dome.layers = Outdoor.LAYER
	add_child(dome)
	for face in [Vector3.FORWARD, Vector3.BACK]:
		var l := Label3D.new()
		l.text = "TAXI"
		l.font = GalleryFonts.title()
		l.font_size = 30
		l.pixel_size = 0.0035
		l.modulate = Color(0.1, 0.2, 0.55)
		l.outline_size = 0
		l.double_sided = false
		l.position = Vector3(0, 1.9, -0.25) + face * 0.145
		l.rotation.y = atan2(face.x, face.z)
		l.layers = Outdoor.LAYER
		add_child(l)
	# タイヤ (前輪はハンドルで向きが変わる)
	var tire := CylinderMesh.new()
	tire.top_radius = WHEEL_R
	tire.bottom_radius = WHEEL_R
	tire.height = 0.24
	tire.radial_segments = 16
	var hub := CylinderMesh.new()
	hub.top_radius = 0.24
	hub.bottom_radius = 0.24
	hub.height = 0.25
	hub.radial_segments = 10
	for x in [-0.8, 0.8]:
		for z in [-1.35, 1.35]:
			var pivot := Node3D.new()
			pivot.position = Vector3(x, WHEEL_R, z)
			add_child(pivot)
			var spin := Node3D.new()
			pivot.add_child(spin)
			for m in [[tire, dark], [hub, chrome]]:
				var mi := MeshInstance3D.new()
				mi.mesh = m[0]
				mi.material_override = m[1]
				mi.rotation.z = PI / 2.0
				mi.layers = Outdoor.LAYER
				spin.add_child(mi)
			for k in 5:  # スポーク
				var sp := MeshInstance3D.new()
				var bm := BoxMesh.new()
				bm.size = Vector3(0.02, 0.4, 0.05)
				sp.mesh = bm
				sp.material_override = dark
				sp.position.x = 0.13 * signf(x)
				sp.rotation.x = k * TAU / 5.0
				sp.layers = Outdoor.LAYER
				spin.add_child(sp)
			_spins.append(spin)
			if z < 0.0:
				_front.append(pivot)

	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.76, 1.5, 4.4)
	cs.shape = shape
	cs.position.y = 0.75  # 箱の底 = タイヤの接地面
	add_child(cs)
	# クリック判定 (衝突はしない専用レイヤー)
	# 隠し要素なので照準を合わせても案内は出さない (クリック/タップすると乗れる)
	var hit := Interact.add_box(self, Vector3(2.0, 1.9, 4.6), Vector3(0, 0.95, 0), "", _enter)
	hit.collision_layer = INTERACT_LAYER
	hit.collision_mask = 0

	_cam = Camera3D.new()
	_cam.top_level = true
	_cam.fov = 70.0
	_cam.far = 220.0
	add_child(_cam)


func _part(b: Building, center: Vector3, size: Vector3, mat: Material, rot: Vector3 = Vector3.ZERO) -> void:
	var mi := b._box(center, size, mat, false, self)
	mi.rotation = rot
	mi.layers = Outdoor.LAYER
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON


func _emissive(b: Building, c: Color, energy: float) -> StandardMaterial3D:
	var m := b._mat(c, 0.3)
	m.emission_enabled = true
	m.emission = c
	m.emission_energy_multiplier = energy
	return m


func _enter() -> void:
	if driving:
		return
	driving = true
	_player.start_driving(self)
	_cam.global_position = global_position + global_transform.basis.z * 6.5 + Vector3.UP * 2.6
	_cam.current = true
	if _audio:
		_audio.play_at("door", global_position, -12.0)


## 指定位置へ瞬間移動 (タイムアタックのコースとの行き来)
func teleport(pos: Vector3, yaw: float) -> void:
	global_position = pos
	rotation = Vector3(0, yaw, 0)
	speed = 0.0
	_steer = 0.0
	velocity = Vector3.ZERO
	_cam.global_position = global_position + global_transform.basis.z * 6.5 + Vector3.UP * 2.6
	_cam.look_at(global_position + Vector3.UP, Vector3.UP)


func leave() -> void:
	if not driving:
		return
	# タイムアタック中は「降りる」= 美術館の駐車場に戻る
	var ta: TimeAttack = get_tree().current_scene.get_node_or_null("%TimeAttack")
	if ta and ta.active:
		ta.exit_course()
		return
	driving = false
	speed = 0.0
	_player.stop_driving(self)
	if _audio:
		_audio.play_at("door", global_position, -12.0)


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
	var throttle := 0.0
	var steer := 0.0
	if driving and not locked and not (_ui and _ui.is_modal_open()):
		var v := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		var touch: TouchControls = _ui.touch_controls if _ui else null
		if touch and touch.move_vector != Vector2.ZERO:
			v = touch.move_vector
		if ai_input != Vector2.ZERO:
			v = ai_input
		throttle = -v.y
		steer = -v.x
	if locked:
		throttle = 0.0
		speed = move_toward(speed, 0.0, BRAKE * delta)
	if throttle > 0.05:
		speed = move_toward(speed, 0.0, BRAKE * delta) if speed < 0.0 else move_toward(speed, MAX_SPEED * throttle, ACCEL * delta)
	elif throttle < -0.05:
		speed = move_toward(speed, 0.0, BRAKE * delta) if speed > 0.0 else move_toward(speed, -REVERSE_SPEED, ACCEL * delta)
	else:
		speed = move_toward(speed, 0.0, DRAG * delta)
	if speed > speed_cap:
		speed = move_toward(speed, speed_cap, BRAKE * delta)
	_steer = lerpf(_steer, steer * STEER_MAX, clampf(6.0 * delta, 0.0, 1.0))
	rotation.y += speed / WHEELBASE * tan(_steer) * delta
	var fwd := -global_transform.basis.z
	velocity.x = fwd.x * speed
	velocity.z = fwd.z * speed
	move_and_slide()
	if get_slide_collision_count() > 0:
		var real := get_real_velocity()
		if Vector2(real.x, real.z).length() < absf(speed) * 0.5:
			speed *= 0.3  # ぶつかったら減速
	for s in _spins:
		s.rotate_x(-speed / WHEEL_R * delta)
	for f in _front:
		f.rotation.y = _steer


func _process(delta: float) -> void:
	if not driving:
		return
	# 後方から追いかけるカメラ
	var target := global_position + global_transform.basis.z * 6.5 + Vector3.UP * 2.6
	_cam.global_position = _cam.global_position.lerp(target, 1.0 - exp(-4.0 * delta))
	_cam.look_at(global_position + Vector3.UP * 1.0, Vector3.UP)
