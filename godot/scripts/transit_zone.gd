class_name TransitZone
extends Node3D
## 階段・エスカレーターの自動昇降。
## 乗り口に入っただけでは発動せず、自分で全体の約 2 割まで進んだ (= 利用する意図が明確) ところで自動移動に切り替える。
## エスカレーターは乗って運ばれている場合も「進んだ」とみなす。
## 自動移動中に移動先フロアの準備 (読み込み・描画の下準備) を行い、間に合わなければ降り口で待機させる。

const TRIGGER_PROGRESS := 0.2
const MAX_PROGRESS := 0.7  # これより先で止まっていた場合は発動しない (手動のまま)

var kind := "Stairs"  # Stairs / Escalator
var speed := 1.5  # 斜面を進む速さ (m/s)
var dest_floor := 1
var going_up := true
var lane := Vector2.ZERO  # 通路の x 範囲
var points := PackedVector3Array()  # [降り口, 降りた先]

var _player: CharacterBody3D
var _last := Vector3.ZERO


func _ready() -> void:
	_player = get_tree().current_scene.get_node_or_null("%Player")


func _physics_process(_delta: float) -> void:
	if _player == null:
		return
	var p := _player.global_position
	var moved := p - _last
	_last = p
	if _player.in_transit or not _player.can_start_transit():
		return
	if p.x < lane.x or p.x > lane.y:
		return
	var run := Building.RAMP_Z_BOTTOM - Building.RAMP_Z_TOP
	var from_bottom := (Building.RAMP_Z_BOTTOM - p.z) / run
	var progress := from_bottom if going_up else 1.0 - from_bottom
	if progress < TRIGGER_PROGRESS or progress > MAX_PROGRESS:
		return
	# 斜面の上にいるか (斜面の下をくぐっている等は除外)
	if absf(p.y - Building.FLOOR_HEIGHT * from_bottom) > 0.6:
		return
	# 進行方向に進んでいるか (歩いている or エスカレーターに運ばれている)
	var along := -moved.z if going_up else moved.z
	if along > 0.004:
		_player.start_transit(self)
