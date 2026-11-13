class_name Elevator
extends Node3D
## 2 フロアを往復するエレベーター。
##   - かご: AnimatableBody3D (sync_to_physics) を動かすと、乗っているプレイヤーも一緒に運ばれる
##   - 乗場ドア: フロアごとに左右 2 枚。かごが停止しているフロアだけ開く
##   - ボタン: 乗場の呼びボタン / かご内の行き先ボタン (クリック or タップ)

enum State { IDLE, CLOSING, PREPARING, MOVING }

## 移動先フロアの準備 (読み込み・描画の下準備) を待つ処理。gallery_manager が設定する
var floor_gate: Callable
var audio: GalleryAudio

const MAX_SPEED := 1.8
const DOOR_SPEED := 1.3  # 開閉量 (0..1) / 秒
const DOOR_LEAF := 0.7
const DOOR_TRAVEL := 0.68
const DOOR_HEIGHT := 2.4

var current_floor := 0
var target_floor := 0
var state := State.IDLE

var _b: Building
var _center := Vector3.ZERO  # かごの中心 (x, z)
var _cabin: AnimatableBody3D
var _doors: Array = []  # [{left, right, amount}]
var _indicators: Array = []  # Label3D


func build(building: Building) -> void:
	_b = building
	var shaft := Building.SHAFT_RECT
	# シャフト内寸: x 10.7..13.3 / z -10..-7.2
	_center = Vector3(shaft.get_center().x, 0.0, (Building.Z_MIN + Building.SHAFT_DOOR_Z - 0.1) / 2.0)
	_build_cabin()
	for f in Building.FLOORS:
		_build_landing(f)
		_b.add_map_item(f, shaft, "elevator", "EV")


func _build_cabin() -> void:
	_cabin = AnimatableBody3D.new()
	_cabin.name = "Cabin"
	_cabin.sync_to_physics = true
	_cabin.position = Vector3(_center.x, Building.floor_y(0), _center.z)
	add_child(_cabin)
	var w := 2.5
	var d := 2.6
	# 床 (当たり判定あり)
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(w, 0.12, d)
	cs.shape = shape
	cs.position.y = -0.06
	_cabin.add_child(cs)
	# かごの床: 磨いた黒御影石 + ステンレスの縁取り (館内の床と見分けがつくように)
	var granite := _b._mat(Color(0.07, 0.07, 0.075), 0.18, 0.1)
	_b._box(Vector3(0, -0.06, 0), Vector3(w, 0.12, d), granite, false, _cabin)
	var trim := 0.07
	_b._box(Vector3(0, 0.002, -d / 2.0 + trim / 2.0), Vector3(w, 0.004, trim), _b.mat_metal, false, _cabin)
	_b._box(Vector3(0, 0.002, d / 2.0 - trim / 2.0), Vector3(w, 0.004, trim), _b.mat_metal, false, _cabin)
	_b._box(Vector3(-w / 2.0 + trim / 2.0, 0.002, 0), Vector3(trim, 0.004, d), _b.mat_metal, false, _cabin)
	_b._box(Vector3(w / 2.0 - trim / 2.0, 0.002, 0), Vector3(trim, 0.004, d), _b.mat_metal, false, _cabin)
	_b._box(Vector3(0, 0.002, 0), Vector3(w - 0.6, 0.003, 0.03), _b.mat_metal, false, _cabin)
	_b._box(Vector3(0, 0.002, 0), Vector3(0.03, 0.003, d - 0.6), _b.mat_metal, false, _cabin)
	# 内装 (見た目のみ。実際の囲いはシャフトの壁)
	var panel := _b._mat(Color(0.55, 0.53, 0.5), 0.3, 0.7)
	_b._box(Vector3(0, 1.4, -d / 2.0 + 0.02), Vector3(w, 2.8, 0.04), panel, false, _cabin)
	_b._box(Vector3(-w / 2.0 + 0.02, 1.4, 0), Vector3(0.04, 2.8, d), panel, false, _cabin)
	_b._box(Vector3(w / 2.0 - 0.02, 1.4, 0), Vector3(0.04, 2.8, d), panel, false, _cabin)
	_b._box(Vector3(0, 2.82, 0), Vector3(w, 0.04, d), _b.mat_ceiling, false, _cabin)
	_b._box(Vector3(0, 0.95, -d / 2.0 + 0.08), Vector3(w - 0.3, 0.05, 0.05), _b.mat_metal, false, _cabin)
	var light := OmniLight3D.new()
	light.position = Vector3(0, 2.5, 0)
	light.omni_range = 3.5
	light.light_energy = 0.7
	light.light_cull_mask = Building.LAYER_INDOOR
	_cabin.add_child(light)
	# 行き先ボタン (東側の壁、扉の近く)
	var bx := w / 2.0 - 0.05
	_b._box(Vector3(bx, 1.3, d / 2.0 - 0.45), Vector3(0.03, 0.6, 0.26), _b.mat_dark, false, _cabin)
	for f in Building.FLOORS:
		var pos := Vector3(bx - 0.03, 1.15 + f * 0.25, d / 2.0 - 0.45)
		_button(_cabin, pos, Vector3.LEFT, "%dF" % (f + 1), "Go to %dF" % (f + 1), request_floor.bind(f))


func _build_landing(f: int) -> void:
	var y := Building.floor_y(f)
	var z := Building.SHAFT_DOOR_Z
	var door_mat := _b._mat(Color(0.6, 0.6, 0.62), 0.3, 0.85)
	var entry := {"amount": 1.0 if f == current_floor else 0.0}
	for side in ["left", "right"]:
		var leaf := AnimatableBody3D.new()
		leaf.sync_to_physics = false
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(DOOR_LEAF, DOOR_HEIGHT, 0.06)
		cs.shape = shape
		leaf.add_child(cs)
		_b._box(Vector3.ZERO, shape.size, door_mat, false, leaf)
		leaf.position = Vector3(_center.x, y + DOOR_HEIGHT / 2.0, z)
		add_child(leaf)
		entry[side] = leaf
	_doors.append(entry)
	_set_door(entry)
	# 乗場の敷居 (金属)
	_b._box(Vector3(_center.x, y + 0.004, z + 0.16), Vector3(1.5, 0.008, 0.14), _b.mat_metal, false)
	# 呼びボタンと階数表示 (乗場側 = 南を向く)
	_button(self, Vector3(_center.x + 1.05, y + 1.2, z + 0.11), Vector3.BACK, "", "Call elevator", request_floor.bind(f))
	var ind := Label3D.new()
	ind.font = GalleryFonts.title()
	ind.font_size = 44
	ind.pixel_size = 0.005
	ind.modulate = Color(1.0, 0.75, 0.35)
	ind.outline_size = 0
	ind.double_sided = false
	ind.position = Vector3(_center.x, y + DOOR_HEIGHT + 0.3, z + 0.11)
	add_child(ind)
	_indicators.append(ind)
	_b._box(Vector3(_center.x, y + DOOR_HEIGHT + 0.3, z + 0.105), Vector3(0.7, 0.24, 0.01), _b.mat_dark, false)


func _button(parent: Node3D, pos: Vector3, normal: Vector3, text: String, hint: String, callable: Callable) -> void:
	var root := Node3D.new()
	root.position = pos
	root.rotation.y = atan2(normal.x, normal.z)
	parent.add_child(root)
	var m := _b._mat(Color(0.85, 0.85, 0.82), 0.4, 0.5)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.8, 0.45)
	m.emission_energy_multiplier = 0.4
	_b._box(Vector3.ZERO, Vector3(0.09, 0.09, 0.03), m, false, root)
	if text != "":
		var l := Label3D.new()
		l.text = text
		l.font = GalleryFonts.title()
		l.font_size = 30
		l.pixel_size = 0.0018
		l.modulate = Color(0.1, 0.1, 0.1)
		l.outline_size = 0
		l.double_sided = false
		l.position = Vector3(0, 0, 0.017)
		root.add_child(l)
	Interact.add_box(root, Vector3(0.14, 0.14, 0.08), Vector3.ZERO, hint, callable)


func request_floor(f: int) -> void:
	if state != State.IDLE or f == current_floor:
		return
	target_floor = f
	state = State.CLOSING


func _physics_process(delta: float) -> void:
	match state:
		State.IDLE:
			_animate_doors(delta, current_floor)
		State.CLOSING:
			if _animate_doors(delta, -1):
				state = State.PREPARING
				_prepare_then_move()
		State.MOVING:
			var ty := Building.floor_y(target_floor)
			var p := _cabin.position
			var dist := absf(ty - p.y)
			var speed := minf(MAX_SPEED, 0.35 + dist * 1.2)  # 到着前に減速
			p.y = move_toward(p.y, ty, speed * delta)
			_cabin.position = p
			if is_equal_approx(p.y, ty):
				current_floor = target_floor
				state = State.IDLE
				if audio:
					audio.play_at("ding", _cabin.global_position + Vector3(0, 2.2, 1.0), -11.0)
	_update_indicators()


## ドアが閉まったら、移動先フロアの準備が終わるのを待ってから動き出す (最低 0.8 秒は待つ)
func _prepare_then_move() -> void:
	var started := Time.get_ticks_msec()
	if floor_gate.is_valid():
		await floor_gate.call(target_floor)
	var rest := 0.8 - (Time.get_ticks_msec() - started) / 1000.0
	if rest > 0.0:
		await get_tree().create_timer(rest).timeout
	state = State.MOVING


## open_floor のドアを開け、それ以外を閉める。すべて閉まっていれば true。
func _animate_doors(delta: float, open_floor: int) -> bool:
	var all_closed := true
	for i in _doors.size():
		var e: Dictionary = _doors[i]
		e["amount"] = move_toward(e["amount"], 1.0 if i == open_floor else 0.0, DOOR_SPEED * delta)
		_set_door(e)
		if e["amount"] > 0.0:
			all_closed = false
	return all_closed


func _set_door(e: Dictionary) -> void:
	var off: float = DOOR_LEAF / 2.0 + e["amount"] * DOOR_TRAVEL
	e["left"].position.x = _center.x - off
	e["right"].position.x = _center.x + off


func _update_indicators() -> void:
	var y := _cabin.position.y
	var shown := Building.floor_of(y) + 1
	var arrow := ""
	if state == State.MOVING:
		arrow = "UP " if Building.floor_y(target_floor) > y else "DN "
	for l in _indicators:
		l.text = "%s%dF" % [arrow, shown]
