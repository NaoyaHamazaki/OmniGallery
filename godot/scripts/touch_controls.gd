class_name TouchControls
extends Control
## スマホ用タッチ操作。
##   画面左半分: バーチャルスティック (触れた位置がスティックの中心になる)
##   画面右半分: ドラッグで視点移動
## Web 版では最初のタップで 全画面化 + 横画面ロック を要求し、縦持ちのときは「横にしてください」を表示する。

signal look(relative: Vector2)
## 指をほぼ動かさずに素早く離した (= タップ)。作品などのクリック操作として使う
signal tap(position: Vector2)

@export var stick_radius: float = 90.0
@export var knob_radius: float = 38.0
@export var stick_margin: float = 70.0
@export var look_sensitivity: float = 0.006
@export var tap_max_move: float = 14.0
@export var tap_max_time: float = 0.35

## -1..1 の移動入力 (y がマイナス = 前進。Input.get_vector と同じ向き)
var move_vector: Vector2 = Vector2.ZERO
## モーダル表示中などは false (入力を無視)
var enabled: bool = true

var _stick_index := -1
var _look_index := -1
var _stick_center := Vector2.ZERO
var _knob_pos := Vector2.ZERO
var _touch_starts := {}  # index -> {pos, time}
## 視点ドラッグの指の前回位置。移動量は event.relative を使わず自前で計算する
## (Web 版ではタッチの番号が付け替わった直後に、別の指の古い位置との差が relative として届き、視点が急に飛ぶため)
var _look_last := Vector2.ZERO
const LOOK_JUMP_LIMIT := 120.0  # 1 回の移動量がこれを超えたら誤検知として無視 (画面座標)


func set_enabled(value: bool) -> void:
	enabled = value
	_stick_index = -1
	_look_index = -1
	_touch_starts.clear()
	_reset_stick()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_reset_stick)
	_set_active(DisplayServer.is_touchscreen_available())
	if OS.has_feature("web"):
		_install_web_mobile_helpers()


func _set_active(active: bool) -> void:
	visible = active
	_reset_stick()
	var help := get_node_or_null("%Help") as Label
	if help and active:
		help.text = "Left: move stick  /  Right: drag to look  /  Tap: view artwork"


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if not visible:
			_set_active(true)  # タッチ対応判定が漏れた端末でも、触った時点で有効化
		if not enabled:
			return
		if event.pressed:
			_touch_starts[event.index] = {"pos": event.position, "time": Time.get_ticks_msec()}
		elif _touch_starts.has(event.index):
			var s: Dictionary = _touch_starts[event.index]
			_touch_starts.erase(event.index)
			var quick: bool = (Time.get_ticks_msec() - s["time"]) / 1000.0 <= tap_max_time
			if quick and event.position.distance_to(s["pos"]) <= tap_max_move:
				tap.emit(event.position)
		if event.pressed:
			if event.position.x < size.x * 0.5:
				if _stick_index == -1:
					_stick_index = event.index
					_stick_center = event.position
					_knob_pos = event.position
			elif _look_index == -1:
				_look_index = event.index
				_look_last = event.position
		else:
			if event.index == _stick_index:
				_stick_index = -1
				_reset_stick()
			elif event.index == _look_index:
				_look_index = -1
		queue_redraw()

	elif event is InputEventScreenDrag:
		if not enabled:
			return
		if event.index == _stick_index:
			var offset: Vector2 = (event.position - _stick_center).limit_length(stick_radius)
			_knob_pos = _stick_center + offset
			move_vector = offset / stick_radius
			queue_redraw()
		elif event.index == _look_index:
			var delta: Vector2 = event.position - _look_last
			_look_last = event.position
			if delta.length() <= LOOK_JUMP_LIMIT:
				look.emit(delta * look_sensitivity)


func _reset_stick() -> void:
	if _stick_index != -1:
		return
	move_vector = Vector2.ZERO
	_stick_center = Vector2(stick_margin + stick_radius, size.y - stick_margin - stick_radius)
	_knob_pos = _stick_center
	queue_redraw()


func _draw() -> void:
	draw_circle(_stick_center, stick_radius, Color(1, 1, 1, 0.12))
	draw_arc(_stick_center, stick_radius, 0.0, TAU, 48, Color(1, 1, 1, 0.45), 3.0)
	draw_circle(_knob_pos, knob_radius, Color(1, 1, 1, 0.5))


## ブラウザ側の処理を JS で差し込む。
## 全画面化・画面向きロックは「ユーザー操作のイベントハンドラ内」でしか許可されないため、
## Godot 経由ではなくネイティブの touchend リスナーで実行する。
func _install_web_mobile_helpers() -> void:
	JavaScriptBridge.eval("""
	(function () {
		if (window.__omniMobileInstalled) return;
		window.__omniMobileInstalled = true;
		var isTouch = ('ontouchstart' in window) || navigator.maxTouchPoints > 0;
		if (!isTouch) return;

		// 縦持ち時のオーバーレイ (iPhone Safari は向きロック・全画面 API 非対応のため、案内で対応)
		var style = document.createElement('style');
		style.textContent =
			'#omni-rotate{display:none;position:fixed;inset:0;z-index:9999;background:#111;color:#fff;' +
			'font:600 20px/1.6 sans-serif;align-items:center;justify-content:center;text-align:center;padding:24px}' +
			'@media (orientation: portrait){#omni-rotate{display:flex}}';
		document.head.appendChild(style);
		var overlay = document.createElement('div');
		overlay.id = 'omni-rotate';
		overlay.innerHTML = '&#x1F4F1;&#x21BB;<br>画面を横向きにしてください';
		document.body.appendChild(overlay);
		// 全画面化・横画面固定は web_shell.html が最初のタップで行う (ここで毎回要求すると、
		// FULLSCREEN ボタンで全画面を解除しても次のタップで戻ってしまうため)
	})();
	""", true)
