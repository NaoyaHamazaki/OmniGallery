extends CharacterBody3D
## FPS プレイヤー: WASD / 矢印キーで移動、マウスで視点移動、Shift でダッシュ、ホイールで注視 (ズーム)。
## クリックでマウスをキャプチャ。キャプチャ中のクリック (スマホはタップ) で、近く (2m 以内) の作品などを調べる。
## 階段・エスカレーターは乗り口に入ると自動移動 (視点だけ動かせる)。

signal floor_changed(floor_index: int)
signal transit_started(dest_floor: int)

const HEAD_Y := 1.55
const FOV_DEFAULT := 75.0  # 横画面: 縦方向の視野角
const FOV_PORTRAIT := 64.0  # 縦画面: 横方向の視野角 (縦長の画面でも左右が狭くなりすぎないよう幅基準にする)
const FOV_MIN := 22.0
const STEP_DISTANCE := 1.15  # 歩幅 (ゲーム内の歩く速さ 3.5m/s で 1 秒に約 3 歩)
const JUMP_VELOCITY := 4.2  # 約 0.9m の高さまで跳べる

@export var walk_speed: float = 3.5
@export var sprint_multiplier: float = 1.8
@export var mouse_sensitivity: float = 0.0025
@export var acceleration: float = 12.0
@export var interact_distance: float = 2.0  # これより近いものだけクリックできる

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var touch_controls: TouchControls = get_node_or_null("%TouchControls") as TouchControls
@onready var ui: GalleryUI = get_node_or_null("%UI") as GalleryUI
@onready var audio: GalleryAudio = get_node_or_null("%Audio") as GalleryAudio

var current_floor := -1
var in_transit := false
## 運転中の車 (タクシーのイースターエッグ)。null なら歩行中
var driving: Taxi = null
## 移動先フロアの準備が終わるまで待つ処理 (gallery_manager が設定)。func(floor) を await する
var floor_gate: Callable

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _fov_target := FOV_DEFAULT
var _fov_base := FOV_DEFAULT  # ズームしていないときの視野角 (画面の向きで変わる)
var _portrait := false
var _step_accum := 0.0
var _bob_t := 0.0


func _ready() -> void:
	_register_input_actions()
	# 斜路を登れるように & エレベーターに乗ったまま運ばれるように
	floor_max_angle = deg_to_rad(46.0)
	floor_snap_length = 0.5
	platform_on_leave = CharacterBody3D.PLATFORM_ON_LEAVE_DO_NOTHING
	position = Outdoor.SPAWN  # 駐車場からスタート
	rotation.y = 0.0  # 北 = 美術館の正面を向く
	if touch_controls:
		touch_controls.look.connect(_rotate_view)
		touch_controls.tap.connect(_on_tap)


func _modal_open() -> bool:
	return ui != null and (ui.is_modal_open() or ui.just_closed())


func can_start_transit() -> bool:
	return not _modal_open() and driving == null


func start_driving(car: Taxi) -> void:
	driving = car
	velocity = Vector3.ZERO
	$CollisionShape3D.disabled = true
	if ui:
		ui.set_driving(true)


func stop_driving(car: Taxi) -> void:
	driving = null
	# 運転席側 (左) に降りる
	global_position = car.global_position - car.global_transform.basis.x * 1.6 + Vector3.UP * 0.1
	rotation.y = car.rotation.y
	$CollisionShape3D.disabled = false
	camera.current = true
	if ui:
		ui.set_driving(false)


func _unhandled_input(event: InputEvent) -> void:
	if _modal_open():
		return
	if driving:
		if event is InputEventKey and event.pressed and event.physical_keycode == KEY_E:
			driving.leave()
		elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED \
				and event.device != InputEvent.DEVICE_ID_EMULATION:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		return
	if event is InputEventMouseButton and event.pressed:
		# ホイールで注視 (視野角を狭める)
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_fov_target = maxf(FOV_MIN, _fov_target - 6.0)
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_fov_target = minf(_fov_base, _fov_target + 6.0)
			return
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			_fov_target = _fov_base
			return
		if event.button_index != MOUSE_BUTTON_LEFT:
			return
		# タッチから生成された疑似マウスイベント (device = -1) やスマホ操作中は対象外
		var from_touch: bool = event.device == InputEvent.DEVICE_ID_EMULATION
		var touch_mode := touch_controls != null and touch_controls.visible
		if from_touch or touch_mode:
			return
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			# ブラウザはユーザー操作(クリック)なしでポインタロックできないので、クリック時にキャプチャする
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		else:
			_interact_at(_screen_center())
	elif event is InputEventKey and event.pressed and event.physical_keycode == KEY_M and audio:
		ui.set_muted(audio.toggle_mute())
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_rotate_view(event.relative * mouse_sensitivity)


func _rotate_view(amount: Vector2) -> void:
	if _modal_open() or driving:
		return
	amount *= camera.fov / _fov_base  # ズーム中は感度を下げる
	rotate_y(-amount.x)
	head.rotate_x(-amount.y)
	head.rotation.x = clamp(head.rotation.x, deg_to_rad(-85.0), deg_to_rad(85.0))


func _on_tap(pos: Vector2) -> void:
	if not _modal_open() and driving == null:
		_interact_at(pos)


func _process(delta: float) -> void:
	_update_orientation()
	camera.fov = lerpf(camera.fov, _fov_target, clampf(delta * 10.0, 0.0, 1.0))


## 縦画面では視野角を幅基準 (KEEP_WIDTH) にする。横画面は従来どおり高さ基準
func _update_orientation() -> void:
	var vp := get_viewport().get_visible_rect().size
	var portrait := vp.y > vp.x
	if portrait == _portrait:
		return
	_portrait = portrait
	var zoom := _fov_target / _fov_base
	_fov_base = FOV_PORTRAIT if portrait else FOV_DEFAULT
	_fov_target = _fov_base * zoom
	camera.fov = _fov_target
	camera.keep_aspect = Camera3D.KEEP_WIDTH if portrait else Camera3D.KEEP_HEIGHT


func _physics_process(delta: float) -> void:
	if driving:
		global_position = driving.global_position  # 運転中は車と一緒に移動 (場所の判定・BGM 用)
		if ui:
			ui.set_hover("")
		return
	if not in_transit:
		_walk(delta)
	if global_position.y < -20.0:  # 万一すき間から落ちたら入口前に戻す
		global_position = Outdoor.SPAWN + Vector3(0, 0, -20)
		velocity = Vector3.ZERO
	var f := Building.floor_of(global_position.y)
	if f != current_floor:
		current_floor = f
		floor_changed.emit(f)
	_update_hover()


func _walk(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * delta
	var input_dir := Vector2.ZERO
	if not _modal_open() and is_on_floor() and Input.is_action_just_pressed("jump"):
		velocity.y = JUMP_VELOCITY
	if not _modal_open():
		input_dir = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
		if touch_controls and touch_controls.move_vector != Vector2.ZERO:
			input_dir = touch_controls.move_vector
	var direction := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized() * input_dir.length()
	var speed := walk_speed * (sprint_multiplier if Input.is_action_pressed("sprint") else 1.0)
	var target := direction * speed
	velocity.x = lerp(velocity.x, target.x, clamp(acceleration * delta, 0.0, 1.0))
	velocity.z = lerp(velocity.z, target.z, clamp(acceleration * delta, 0.0, 1.0))
	var before := global_position
	move_and_slide()
	if is_on_floor():
		_footsteps(Vector2(global_position.x - before.x, global_position.z - before.z).length())


func _footsteps(moved: float) -> void:
	_step_accum += moved
	if _step_accum >= STEP_DISTANCE:
		_step_accum = 0.0
		if audio:
			audio.step(Outdoor.is_outdoor(global_position))


## 階段・エスカレーターの自動移動 (TransitZone から呼ばれる)
func start_transit(zone: TransitZone) -> void:
	in_transit = true
	velocity = Vector3.ZERO
	transit_started.emit(zone.dest_floor)  # ここで移動先フロアの準備を開始
	var stairs := zone.kind == "Stairs"
	if ui:
		ui.set_status("%s to %dF" % [zone.kind, zone.dest_floor + 1], 3.0)
	await _move_to(zone.points[0], zone.speed, stairs)  # 今いる位置から降り口まで
	# 降り口で、移動先フロアの準備が終わるまで待つ
	if floor_gate.is_valid():
		await floor_gate.call(zone.dest_floor)
	await _move_to(zone.points[1], 1.6, stairs)
	head.position.y = HEAD_Y
	in_transit = false


func _move_to(target: Vector3, speed: float, bob: bool) -> void:
	while true:
		await get_tree().physics_frame
		var dt := get_physics_process_delta_time()
		var to := target - global_position
		var step := speed * dt
		if bob:
			_bob_t += dt
			head.position.y = HEAD_Y + sin(_bob_t * 9.0) * 0.025
			_footsteps(step)
		if to.length() <= step:
			global_position = target
			return
		global_position += to.normalized() * step


func _screen_center() -> Vector2:
	return get_viewport().get_visible_rect().size / 2.0


func _raycast(screen_pos: Vector2) -> Dictionary:
	var from := camera.project_ray_origin(screen_pos)
	# 視線方向の距離ではなく「目からの距離」で判定 (ズームしても遠くの物は調べられない)
	var to := from + camera.project_ray_normal(screen_pos) * interact_distance
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(query)


func _update_hover() -> void:
	if ui == null:
		return
	var aiming := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or (touch_controls and touch_controls.visible)
	if _modal_open() or not aiming:
		ui.set_hover("")
		return
	var hit := _raycast(_screen_center())
	ui.set_hover(Interact.text_of(hit.get("collider")) if hit else "")


func _interact_at(screen_pos: Vector2) -> void:
	var hit := _raycast(screen_pos)
	if hit:
		Interact.run(hit.get("collider"))


## project.godot の Input Map を手で書かなくて済むよう、コードで登録する。
func _register_input_actions() -> void:
	var bindings := {
		"move_forward": [KEY_W, KEY_UP],
		"move_back": [KEY_S, KEY_DOWN],
		"move_left": [KEY_A, KEY_LEFT],
		"move_right": [KEY_D, KEY_RIGHT],
		"sprint": [KEY_SHIFT],
		"jump": [KEY_SPACE],
	}
	for action in bindings:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for keycode in bindings[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = keycode
			InputMap.action_add_event(action, ev)
