class_name GalleryUI
extends CanvasLayer
## 画面 UI: 読み込みバー・場所表示・照準・操作案内・ミュート・モーダル (作品説明 / フロアマップ / デバッグ情報)。
## モーダルはコードで組み立てる (シーンを手で編集しなくて済むように)。

signal modal_closed

const GOLD := Color(0.79, 0.64, 0.36)

var _modal: Control
var _panel: PanelContainer
var _title: Label
var _image: TextureRect
var _scroll: ScrollContainer
var _body: RichTextLabel
var _custom: Control  # 任意のコントロールを表示する枠 (デバッグの表など)
var _closed_frame := -100
var _status_timer: SceneTreeTimer
var _loading: Control
var _loading_bar: ProgressBar
var _loading_label: Label
var _loading_pct: Label
var _mute_button: Button

@onready var status_label: Label = %Status
@onready var hover_label: Label = %Hover
@onready var floor_label: Label = %FloorLabel
@onready var touch_controls: TouchControls = %TouchControls


func _ready() -> void:
	floor_label.label_settings = floor_label.label_settings.duplicate()
	floor_label.label_settings.font = GalleryFonts.title()
	_build_loading()
	_build_mute()
	_build_modal()
	hover_label.text = ""


func is_modal_open() -> bool:
	return _modal != null and _modal.visible


## モーダルを閉じた直後か (閉じるタップがそのまま次の操作として扱われるのを防ぐ)
func just_closed() -> bool:
	return Engine.get_process_frames() - _closed_frame < 5


func set_status(text: String, auto_hide: float = 0.0) -> void:
	print("[Gallery] ", text)
	status_label.text = text
	status_label.visible = true
	_status_timer = null
	if auto_hide > 0.0:
		_status_timer = get_tree().create_timer(auto_hide)
		var timer := _status_timer
		timer.timeout.connect(func():
			if _status_timer == timer:
				status_label.visible = false)


func set_hover(text: String) -> void:
	if text == "":
		hover_label.text = ""
	else:
		var verb := "Tap" if touch_controls.visible else "Click"
		hover_label.text = "%s  -  %s" % [verb, text]


func set_floor(text: String) -> void:
	floor_label.text = text


func set_muted(muted: bool) -> void:
	_mute_button.text = "SOUND OFF" if muted else "SOUND ON"


var _exit_button: Button
var _help_text := ""


## タクシー運転中の表示 (降りるボタン。スマホでも押せるように画面右下)
func set_driving(on: bool) -> void:
	var help: Label = get_node_or_null("%Help")
	if _exit_button == null:
		_exit_button = Button.new()
		_exit_button.text = "  EXIT TAXI (E)  "
		_exit_button.focus_mode = Control.FOCUS_NONE
		_exit_button.add_theme_font_override("font", GalleryFonts.title())
		_exit_button.add_theme_font_size_override("font_size", 18)
		_exit_button.anchor_left = 1.0
		_exit_button.anchor_right = 1.0
		_exit_button.anchor_top = 1.0
		_exit_button.anchor_bottom = 1.0
		_exit_button.offset_left = -230
		_exit_button.offset_right = -20
		_exit_button.offset_top = -80
		_exit_button.offset_bottom = -30
		_exit_button.pressed.connect(func():
			var p = get_node_or_null("%Player")
			if p and p.driving:
				p.driving.leave())
		add_child(_exit_button)
	_exit_button.visible = on
	hover_label.text = ""
	if help:
		if on:
			_help_text = help.text
			help.text = "W / S: accelerate / brake   A / D: steer   E: get out"
		elif _help_text != "":
			help.text = _help_text


# ---------------------------------------------------------------------------
# 読み込みバー (画面上部。小さく控えめに、でも少しワクワクする金色のバー)
# ---------------------------------------------------------------------------
func _build_loading() -> void:
	_loading = VBoxContainer.new()
	_loading.anchor_left = 0.5
	_loading.anchor_right = 0.5
	_loading.offset_left = -190
	_loading.offset_right = 190
	_loading.offset_top = 18
	_loading.add_theme_constant_override("separation", 6)
	add_child(_loading)
	var row := HBoxContainer.new()
	_loading.add_child(row)
	_loading_label = Label.new()
	_loading_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_loading_label.add_theme_font_override("font", GalleryFonts.title())
	_loading_label.add_theme_font_size_override("font_size", 15)
	_loading_label.add_theme_color_override("font_color", Color(0.95, 0.9, 0.8))
	_loading_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_loading_label.add_theme_constant_override("outline_size", 4)
	row.add_child(_loading_label)
	_loading_pct = _loading_label.duplicate()
	_loading_pct.size_flags_horizontal = Control.SIZE_SHRINK_END
	row.add_child(_loading_pct)
	_loading_bar = ProgressBar.new()
	_loading_bar.show_percentage = false
	_loading_bar.custom_minimum_size = Vector2(380, 5)
	_loading_bar.max_value = 1.0
	_loading_bar.step = 0.0
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.55)
	bg.set_corner_radius_all(3)
	var fill := StyleBoxFlat.new()
	fill.bg_color = GOLD
	fill.set_corner_radius_all(3)
	fill.shadow_color = Color(1.0, 0.8, 0.4, 0.6)
	fill.shadow_size = 4
	_loading_bar.add_theme_stylebox_override("background", bg)
	_loading_bar.add_theme_stylebox_override("fill", fill)
	_loading.add_child(_loading_bar)


func set_loading(ratio: float, text: String) -> void:
	_loading.visible = true
	_loading_label.text = text
	_loading_pct.text = "%d%%" % int(round(ratio * 100.0))
	var tw := create_tween()
	tw.tween_property(_loading_bar, "value", ratio, 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func finish_loading() -> void:
	set_loading(1.0, "The museum is open")
	var tw := create_tween()
	tw.tween_interval(2.0)
	tw.tween_property(_loading, "modulate:a", 0.0, 0.8)
	tw.tween_callback(func(): _loading.visible = false)


func _process(_delta: float) -> void:
	if _loading.visible:
		# バーの光をゆっくり脈動させる
		var fill: StyleBoxFlat = _loading_bar.get_theme_stylebox("fill")
		fill.shadow_size = int(3 + 3 * (0.5 + 0.5 * sin(Time.get_ticks_msec() / 250.0)))


func _build_mute() -> void:
	_mute_button = Button.new()
	_mute_button.text = "SOUND ON"
	_mute_button.flat = true
	_mute_button.focus_mode = Control.FOCUS_NONE
	_mute_button.add_theme_font_override("font", GalleryFonts.title())
	_mute_button.add_theme_font_size_override("font_size", 13)
	_mute_button.add_theme_color_override("font_color", Color(0.95, 0.9, 0.8, 0.8))
	_mute_button.anchor_left = 1.0
	_mute_button.anchor_right = 1.0
	_mute_button.offset_left = -130
	_mute_button.offset_right = -14
	_mute_button.offset_top = 44
	_mute_button.offset_bottom = 70
	_mute_button.pressed.connect(func():
		var audio: GalleryAudio = get_node_or_null("%Audio")
		if audio:
			set_muted(audio.toggle_mute()))
	add_child(_mute_button)


# ---------------------------------------------------------------------------
# モーダル
# ---------------------------------------------------------------------------
## title: 見出し / bbcode: 本文 (RichTextLabel の BBCode) / texture: 左に表示する画像
## image_only=true なら画像を全面に表示 (フロアマップ用)
func show_modal(title: String, bbcode: String, texture: Texture2D = null, image_only: bool = false) -> void:
	_clear_custom()
	_title.text = title
	_body.text = bbcode
	_image.texture = texture
	_image.visible = texture != null
	_scroll.visible = not image_only
	_image.size_flags_stretch_ratio = 1.0 if image_only else 1.1
	_scroll.scroll_vertical = 0
	_open()


## 任意のコントロール (表など) をモーダルに表示する
func show_custom(title: String, content: Control) -> void:
	_clear_custom()
	_title.text = title
	_image.visible = false
	_scroll.visible = false
	_custom.add_child(content)
	content.set_anchors_preset(Control.PRESET_FULL_RECT)
	_custom.visible = true
	_open()


func _open() -> void:
	var was_open := is_modal_open()
	_modal.visible = true
	hover_label.text = ""
	touch_controls.set_enabled(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var audio: GalleryAudio = get_node_or_null("%Audio")
	if audio and not was_open:
		audio.play("ui_open", -10.0)


func _clear_custom() -> void:
	for c in _custom.get_children():
		c.queue_free()
	_custom.visible = false


func update_modal_body(bbcode: String) -> void:
	if is_modal_open():
		_body.text = bbcode


func close_modal() -> void:
	if not is_modal_open():
		return
	_modal.visible = false
	_image.texture = null
	_clear_custom()
	_closed_frame = Engine.get_process_frames()
	touch_controls.set_enabled(true)
	var audio: GalleryAudio = get_node_or_null("%Audio")
	if audio:
		audio.play("ui_close", -12.0)
	modal_closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if is_modal_open() and event.is_action_pressed("ui_cancel"):
		close_modal()
		get_viewport().set_input_as_handled()


func _build_modal() -> void:
	_modal = Control.new()
	_modal.name = "Modal"
	_modal.set_anchors_preset(Control.PRESET_FULL_RECT)
	_modal.mouse_filter = Control.MOUSE_FILTER_STOP
	_modal.visible = false
	add_child(_modal)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			close_modal())  # 枠外クリックで閉じる
	_modal.add_child(dim)

	_panel = PanelContainer.new()
	_panel.anchor_left = 0.07
	_panel.anchor_right = 0.93
	_panel.anchor_top = 0.07
	_panel.anchor_bottom = 0.93
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.11, 0.12, 0.16, 0.97)
	style.border_color = GOLD
	style.set_border_width_all(2)
	style.set_corner_radius_all(14)
	style.set_content_margin_all(26)
	_panel.add_theme_stylebox_override("panel", style)
	_modal.add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	_panel.add_child(vbox)

	var header := HBoxContainer.new()
	vbox.add_child(header)
	_title = Label.new()
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.add_theme_font_override("font", GalleryFonts.title())
	_title.add_theme_font_size_override("font_size", 30)
	_title.add_theme_color_override("font_color", Color(0.95, 0.91, 0.84))
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	header.add_child(_title)
	var close := Button.new()
	close.text = "  CLOSE  "
	close.add_theme_font_override("font", GalleryFonts.title())
	close.add_theme_font_size_override("font_size", 18)
	close.pressed.connect(close_modal)
	header.add_child(close)

	var line := ColorRect.new()
	line.color = Color(GOLD, 0.6)
	line.custom_minimum_size = Vector2(0, 2)
	vbox.add_child(line)

	var content := HBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 26)
	vbox.add_child(content)

	_image = TextureRect.new()
	_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_image.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_image.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(_image)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(_scroll)

	_custom = Control.new()
	_custom.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_custom.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_custom.visible = false
	content.add_child(_custom)

	_body = RichTextLabel.new()
	_body.bbcode_enabled = true
	_body.fit_content = true
	_body.scroll_active = false
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var bold := FontVariation.new()
	bold.base_font = GalleryFonts.body()
	bold.variation_embolden = 0.7
	_body.add_theme_font_override("bold_font", bold)
	_body.add_theme_font_size_override("normal_font_size", 22)
	_body.add_theme_font_size_override("bold_font_size", 24)
	_body.add_theme_color_override("default_color", Color(0.88, 0.86, 0.82))
	_body.meta_clicked.connect(func(meta): OS.shell_open(str(meta)))
	_scroll.add_child(_body)


## BBCode として解釈されないようにエスケープ (UGC のテキスト対策)
static func bb_escape(text: String) -> String:
	return text.replace("[", "[lb]")
