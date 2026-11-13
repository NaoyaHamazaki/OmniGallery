class_name HoloKiosk
extends Node3D
## 案内用のホログラム端末 (フロアマップ / デバッグ情報で共用)。
##   遠くから: 台座の発光部が光っているだけ (文字は読ませない)
##   近づくと: 投影ビームとホログラムパネルが立ち上がり、プレイヤーの方を向く
##   クリック/タップ: on_click (モーダル表示) を呼ぶ

const SHOW_DISTANCE := 3.8
const PANEL_HEIGHT := 1.6  # パネル中心の高さ

const HOLO_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

uniform vec4 holo_color : source_color = vec4(0.35, 0.85, 1.0, 1.0);
uniform sampler2D tex : source_color, filter_linear;
uniform bool use_tex = false;
uniform float fade = 1.0;

void fragment() {
	vec2 uv = UV;
	float scan = 0.7 + 0.3 * sin(uv.y * 260.0 - TIME * 6.0);
	float flicker = 0.93 + 0.07 * sin(TIME * 41.0) * sin(TIME * 17.0);
	float sweep = smoothstep(0.06, 0.0, abs(fract(TIME * 0.35) - uv.y)) * 0.6;
	float inner = smoothstep(0.0, 0.02, uv.x) * smoothstep(0.0, 0.02, 1.0 - uv.x)
		* smoothstep(0.0, 0.03, uv.y) * smoothstep(0.0, 0.03, 1.0 - uv.y);
	vec3 c;
	if (use_tex) {
		vec3 t = texture(tex, uv).rgb;
		float l = dot(t, vec3(0.3, 0.59, 0.11));
		c = holo_color.rgb * (0.1 + pow(l, 0.7) * 1.9);
	} else {
		// 手続き的な「データ表示」: グリッド + 伸び縮みする棒グラフ
		vec2 g = fract(uv * vec2(14.0, 8.0));
		float grid = (step(0.94, g.x) + step(0.92, g.y)) * 0.25;
		float col = floor(uv.x * 12.0);
		float h = 0.2 + 0.55 * abs(sin(col * 1.9 + TIME * (0.8 + mod(col, 3.0) * 0.4)));
		float bar = step(1.0 - uv.y, h) * step(0.2, fract(uv.x * 12.0)) * step(0.08, 1.0 - uv.y);
		c = holo_color.rgb * (0.06 + grid + bar * 0.55);
	}
	c = c * scan + holo_color.rgb * ((1.0 - inner) * 0.9 + sweep * 0.25);
	ALBEDO = c * flicker * fade;
}
"""

var on_click: Callable
var _player: Node3D
var _holo: Node3D
var _panel_mat: ShaderMaterial
var _beam_mat: StandardMaterial3D
var _glow_mat: StandardMaterial3D
var _title: Label3D
var _subtitle: Label3D
var _amount := 0.0
var _t := 0.0
var _base_color := Color.WHITE


## title: ホログラム上部の短い見出し / texture: パネルに投影する画像 (null なら手続き模様)
func setup(b: Building, player: Node3D, title: String, hover_text: String, callable: Callable,
		texture: Texture2D = null, panel_size: Vector2 = Vector2(1.1, 0.6), color: Color = Color(0.35, 0.85, 1.0)) -> void:
	_player = player
	on_click = callable
	_base_color = color

	# 台座 (文字なし。発光する投影部だけ)
	var base := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.26
	cyl.bottom_radius = 0.34
	cyl.height = 0.9
	base.mesh = cyl
	base.material_override = b.mat_dark
	base.position.y = 0.45
	add_child(base)
	var rim := MeshInstance3D.new()
	var rim_mesh := CylinderMesh.new()
	rim_mesh.top_radius = 0.3
	rim_mesh.bottom_radius = 0.3
	rim_mesh.height = 0.04
	rim.mesh = rim_mesh
	rim.material_override = b.mat_metal
	rim.position.y = 0.92
	add_child(rim)
	_glow_mat = StandardMaterial3D.new()
	_glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_glow_mat.albedo_color = color
	var glow := MeshInstance3D.new()
	var disk := CylinderMesh.new()
	disk.top_radius = 0.2
	disk.bottom_radius = 0.2
	disk.height = 0.01
	glow.mesh = disk
	glow.material_override = _glow_mat
	glow.position.y = 0.945
	add_child(glow)
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = 0.4
	light.omni_range = 1.6
	light.position.y = 1.1
	light.light_cull_mask = Building.LAYER_INDOOR
	add_child(light)

	# ホログラム (近づくと立ち上がる)
	_holo = Node3D.new()
	_holo.position.y = 0.95
	add_child(_holo)
	_beam_mat = StandardMaterial3D.new()
	_beam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_beam_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_beam_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_beam_mat.albedo_color = Color(color.r, color.g, color.b, 0.0)
	var beam := MeshInstance3D.new()
	var cone := CylinderMesh.new()
	var beam_h := PANEL_HEIGHT - 0.95 - panel_size.y / 2.0 + 0.05
	cone.top_radius = panel_size.x * 0.45
	cone.bottom_radius = 0.18
	cone.height = beam_h
	cone.cap_top = false
	cone.cap_bottom = false
	beam.mesh = cone
	beam.material_override = _beam_mat
	beam.position.y = beam_h / 2.0
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_holo.add_child(beam)

	var shader := Shader.new()
	shader.code = HOLO_SHADER
	_panel_mat = ShaderMaterial.new()
	_panel_mat.shader = shader
	_panel_mat.set_shader_parameter("holo_color", color)
	_panel_mat.set_shader_parameter("use_tex", texture != null)
	if texture:
		_panel_mat.set_shader_parameter("tex", texture)
	var panel := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = panel_size
	panel.mesh = quad
	panel.material_override = _panel_mat
	panel.position.y = PANEL_HEIGHT - 0.95
	panel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_holo.add_child(panel)

	# 見出しは短い単語のみ (パネル幅に収まる大きさに固定)
	_title = _holo_label(title, 36, panel.position.y + panel_size.y / 2.0 + 0.09, color)
	_subtitle = _holo_label("", 26, panel.position.y - panel_size.y / 2.0 - 0.07, color)

	Interact.add_box(self, Vector3(maxf(panel_size.x, 0.8), 2.1, 0.8), Vector3(0, 1.05, 0), hover_text, _click)
	_apply(0.0)


func set_subtitle(text: String) -> void:
	_subtitle.text = text


func _holo_label(text: String, font_size: int, y: float, color: Color) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font = GalleryFonts.title()
	l.font_size = font_size
	l.pixel_size = 0.0028
	l.outline_size = 0
	l.modulate = Color(color.r, color.g, color.b, 0.0)
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	l.position.y = y
	l.shaded = false
	_holo.add_child(l)
	return l


func _click() -> void:
	if on_click.is_valid():
		on_click.call()


func _process(delta: float) -> void:
	_t += delta
	var near := false
	if _player:
		var d := _player.global_position - global_position
		near = Vector2(d.x, d.z).length() < SHOW_DISTANCE and absf(d.y) < 2.5
		if near or _amount > 0.0:
			# ホログラムはプレイヤーの方を向く (Y 軸のみ)
			_holo.global_rotation.y = atan2(d.x, d.z)
	var target := 1.0 if near else 0.0
	if not is_equal_approx(_amount, target):
		_amount = move_toward(_amount, target, delta * 2.5)
	_apply(_amount)
	# 発光部の脈動 (遠くからでも「何かある」と分かる程度)
	var pulse := 0.75 + 0.25 * sin(_t * 2.2)
	var c := _base_color * pulse
	c.a = 1.0
	_glow_mat.albedo_color = c
	if _amount > 0.0:
		_holo.position.y = 0.95 + sin(_t * 1.6) * 0.012


func _apply(a: float) -> void:
	var e := ease(a, -2.0)  # 立ち上がりを滑らかに
	_holo.visible = a > 0.001
	_holo.scale = Vector3(lerpf(0.6, 1.0, e), maxf(e, 0.001), 1.0)
	_panel_mat.set_shader_parameter("fade", e)
	_beam_mat.albedo_color.a = 0.13 * e
	_title.modulate.a = e
	_subtitle.modulate.a = e * 0.85
