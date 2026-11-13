class_name GalleryAudio
extends Node
## BGM と効果音 (控えめな音量)。
##   BGM: 館内では少し大きく、屋外では小さく。M キー / 画面右上のボタンでミュート
##   効果音: 足音・モーダル開閉・エレベーター到着・自動ドア
## ブラウザは最初のクリック/タップまで音を出せないが、Godot が自動で再開するのでそのまま再生してよい。

const BGM_INDOOR_DB := -19.0
const BGM_OUTDOOR_DB := -80.0  # 屋外では BGM は聞こえない (館内に入るとフェードイン)

var muted := false
var _bgm: AudioStreamPlayer
var _bgm_target := BGM_OUTDOOR_DB
var _pool: Array[AudioStreamPlayer] = []
var _streams := {}


func _ready() -> void:
	for n in ["step", "ui_open", "ui_close", "ding", "door"]:
		_streams[n] = load("res://audio/%s.wav" % n)
	var bgm: AudioStreamWAV = load("res://audio/bgm_gallery.wav")
	if bgm:
		bgm.loop_mode = AudioStreamWAV.LOOP_FORWARD
		bgm.loop_begin = 0
		bgm.loop_end = int(bgm.get_length() * bgm.mix_rate)
	_bgm = AudioStreamPlayer.new()
	_bgm.stream = bgm
	_bgm.volume_db = -80.0
	add_child(_bgm)
	_bgm.play()
	for i in 6:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_pool.append(p)


func _process(delta: float) -> void:
	# 入館時は約 2 秒でフェードイン、退館時は約 1.5 秒でフェードアウト (-40dB 以下は実質無音なので一気に下げる)
	var rate := 30.0 if _bgm_target > _bgm.volume_db else 45.0
	var from := maxf(_bgm.volume_db, -40.0) if _bgm_target > _bgm.volume_db else _bgm.volume_db
	_bgm.volume_db = move_toward(from, _bgm_target, rate * delta)


func set_indoor(indoor: bool) -> void:
	_bgm_target = BGM_INDOOR_DB if indoor else BGM_OUTDOOR_DB


func toggle_mute() -> bool:
	muted = not muted
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Master"), muted)
	return muted


func play(sound: String, volume_db: float = -8.0, pitch: float = 1.0) -> void:
	if not _streams.has(sound):
		return
	for p in _pool:
		if not p.playing:
			p.stream = _streams[sound]
			p.volume_db = volume_db
			p.pitch_scale = pitch
			p.play()
			return


## 位置付きの効果音 (エレベーター到着音・自動ドアなど)
func play_at(sound: String, pos: Vector3, volume_db: float = -4.0) -> void:
	if not _streams.has(sound):
		return
	var p := AudioStreamPlayer3D.new()
	p.stream = _streams[sound]
	p.volume_db = volume_db
	p.unit_size = 4.0
	p.max_distance = 30.0
	add_child(p)
	p.global_position = pos
	p.finished.connect(p.queue_free)
	p.play()


func step(outdoor: bool) -> void:
	play("step", -20.0 if not outdoor else -17.0, randf_range(0.85, 1.12) * (0.8 if outdoor else 1.0))
