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
	var body_mat := b._mat(Color(0.14, 0.18, 0.38), 0.3, 0.35)  # 濃紺 (深藍色)
	var dark := b._mat(Color(0.05, 0.05, 0.06), 0.6)
	var glass := b._mat(Color(0.22, 0.28, 0.34), 0.08, 0.3)
	var chrome := b._mat(Color(0.8, 0.8, 0.82), 0.15, 1.0)
	var gold := b._mat(Color(0.8, 0.62, 0.3), 0.3, 0.8)
	var head := _emissive(b, Color(1.0, 0.97, 0.9), 2.5)
	var tail := _emissive(b, Color(0.9, 0.08, 0.06), 1.5)
	var sign_mat := _emissive(b, Color(1.0, 0.85, 0.45), 1.2)

	# 車体 (背の高いワゴン型)。前が -Z
	_part(b, Vector3(0, 0.6, 0), Vector3(1.74, 0.62, 4.35), body_mat)
	_part(b, Vector3(0, 0.95, -1.75), Vector3(1.7, 0.1, 0.85), body_mat)  # ボンネット
	_part(b, Vector3(0, 1.32, 0.35), Vector3(1.64, 0.72, 2.85), glass)  # 窓 (キャビン)
	_part(b, Vector3(0, 1.71, 0.35), Vector3(1.66, 0.07, 2.8), body_mat)  # 屋根
	for x in [-0.8, 0.8]:  # 窓枠の柱
		for z in [-1.03, 0.1, 1.72]:
			_part(b, Vector3(x, 1.32, z), Vector3(0.06, 0.72, 0.08), body_mat)
	_part(b, Vector3(0, 1.32, -1.06), Vector3(1.66, 0.06, 0.06), body_mat)
	for x in [-0.875, 0.875]:
		_part(b, Vector3(x, 0.82, 0.0), Vector3(0.01, 0.045, 4.1), gold)  # 金色のライン
		_part(b, Vector3(x, 0.65, -0.45), Vector3(0.012, 0.5, 0.015), dark)  # ドアの継ぎ目
		_part(b, Vector3(x, 0.65, 0.85), Vector3(0.012, 0.5, 0.015), dark)
		_part(b, Vector3(x * 1.06, 1.12, -1.0), Vector3(0.12, 0.1, 0.18), body_mat)  # ミラー
	_part(b, Vector3(0, 0.33, -2.2), Vector3(1.76, 0.2, 0.12), dark)  # バンパー
	_part(b, Vector3(0, 0.33, 2.2), Vector3(1.76, 0.2, 0.12), dark)
	_part(b, Vector3(0, 0.62, -2.18), Vector3(0.8, 0.22, 0.03), dark)  # グリル
	for x in [-0.62, 0.62]:
		_part(b, Vector3(x, 0.7, -2.18), Vector3(0.36, 0.13, 0.03), head)
		_part(b, Vector3(x, 0.72, 2.18), Vector3(0.3, 0.16, 0.03), tail)
	_part(b, Vector3(0, 0.55, 2.19), Vector3(0.5, 0.14, 0.02), b.mat_plinth)  # ナンバー
	# 屋根の行灯
	_part(b, Vector3(0, 1.84, 0.1), Vector3(0.5, 0.2, 0.2), sign_mat)
	for face in [Vector3.FORWARD, Vector3.BACK]:
		var l := Label3D.new()
		l.text = "TAXI"
		l.font = GalleryFonts.title()
		l.font_size = 40
		l.pixel_size = 0.004
		l.modulate = Color(0.12, 0.1, 0.08)
		l.outline_size = 0
		l.double_sided = false
		l.position = Vector3(0, 1.84, 0.1) + face * 0.105
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
	hub.top_radius = 0.19
	hub.bottom_radius = 0.19
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
	var hit := Interact.add_box(self, Vector3(2.0, 1.9, 4.6), Vector3(0, 0.95, 0), "Drive the taxi", _enter)
	hit.collision_layer = INTERACT_LAYER
	hit.collision_mask = 0

	_cam = Camera3D.new()
	_cam.top_level = true
	_cam.fov = 70.0
	_cam.far = 220.0
	add_child(_cam)


func _part(b: Building, center: Vector3, size: Vector3, mat: Material) -> void:
	var mi := b._box(center, size, mat, false, self)
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
	if _ui:
		_ui.set_status("Easter egg! Drive with W/S + A/D (stick on mobile).  E: get out", 6.0)


func leave() -> void:
	if not driving:
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
	if driving and not (_ui and _ui.is_modal_open()):
		var v := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		var touch: TouchControls = _ui.touch_controls if _ui else null
		if touch and touch.move_vector != Vector2.ZERO:
			v = touch.move_vector
		throttle = -v.y
		steer = -v.x
	if throttle > 0.05:
		speed = move_toward(speed, 0.0, BRAKE * delta) if speed < 0.0 else move_toward(speed, MAX_SPEED * throttle, ACCEL * delta)
	elif throttle < -0.05:
		speed = move_toward(speed, 0.0, BRAKE * delta) if speed > 0.0 else move_toward(speed, -REVERSE_SPEED, ACCEL * delta)
	else:
		speed = move_toward(speed, 0.0, DRAG * delta)
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
