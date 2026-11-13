class_name FloorMap
extends Control
## フロアマップ (1F / 2F を左右に並べて描画)。SubViewport の中に置き、そのテクスチャを
## 館内の案内板とモーダル表示の両方で使う。プレイヤーの現在地もリアルタイムに描く。

var building: Building
var player: Node3D

const BG := Color("1f2433")
const GOLD := Color("c9a45c")
const TEXT := Color("ece6da")
const SUB := Color("9a96a0")
const STYLE := {
	"wall": Color("d9d4ca"),
	"void": Color("12141a"),
	"stairs": Color("8d929c"),
	"esc_up": Color("5f88a8"),
	"esc_down": Color("7a9b6a"),
	"elevator": Color("b08d57"),
	"bench": Color("8a6a48"),
	"painting": Color("c9a45c"),
	"featured": Color("ffd27a"),
	"pedestal": Color("e07a3f"),
	"map": Color("5fb0c9"),
	"terminal": Color("9b7fd1"),
	"entrance": Color("7fc99b"),
}
const LEGEND := [
	["painting", "Painting"], ["featured", "Main work"], ["pedestal", "3D work"], ["stairs", "Stairs"],
	["esc_up", "Escalator up"], ["esc_down", "Escalator down"], ["elevator", "Elevator"], ["map", "Floor map"],
]

var _t := 0.0


func _process(delta: float) -> void:
	_t += delta
	if _t > 0.2:
		_t = 0.0
		queue_redraw()


func _draw() -> void:
	var font := GalleryFonts.body()
	var title_font := GalleryFonts.title()
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	draw_string(title_font, Vector2(30, 48), "FLOOR MAP", HORIZONTAL_ALIGNMENT_LEFT, -1, 30, GOLD)
	draw_string(font, Vector2(240, 48), "OmniGallery", HORIZONTAL_ALIGNMENT_LEFT, -1, 22, SUB)
	if building == null:
		return
	var pw := (size.x - 90.0) / 2.0
	var ph := pw * (Building.Z_MAX - Building.Z_MIN) / (Building.X_MAX - Building.X_MIN)
	var player_floor := Building.floor_of(player.global_position.y) if player else -1
	for f in Building.FLOORS:
		var panel := Rect2(30.0 + f * (pw + 30.0), 100.0, pw, ph)
		var title: String = building.floor_titles[f]
		draw_string(title_font, panel.position + Vector2(0, -12), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 20,
			GOLD if f == player_floor else TEXT)
		_draw_floor(f, panel, font)
		if f == player_floor and not Outdoor.is_outdoor(player.global_position):
			_draw_player(panel, font)
	_draw_legend(font, Vector2(30, 100 + ph + 40))


func _to_map(panel: Rect2, x: float, z: float) -> Vector2:
	var u := (x - Building.X_MIN) / (Building.X_MAX - Building.X_MIN)
	var v := (z - Building.Z_MIN) / (Building.Z_MAX - Building.Z_MIN)
	return panel.position + Vector2(u * panel.size.x, v * panel.size.y)


func _rect_to_map(panel: Rect2, r: Rect2) -> Rect2:
	var a := _to_map(panel, r.position.x, r.position.y)
	var b := _to_map(panel, r.end.x, r.end.y)
	return Rect2(a, b - a)


func _draw_floor(f: int, panel: Rect2, font: Font) -> void:
	# 床: ギャラリー (寄木) と 吹き抜け側 (石)
	var gallery := Rect2(Building.X_MIN, Building.Z_MIN, Building.PARTITION_X - Building.X_MIN, Building.Z_MAX - Building.Z_MIN)
	var atrium := Rect2(Building.PARTITION_X, Building.Z_MIN, Building.X_MAX - Building.PARTITION_X, Building.Z_MAX - Building.Z_MIN)
	draw_rect(_rect_to_map(panel, gallery), Color("4a3a2c"))
	draw_rect(_rect_to_map(panel, atrium), Color("4f4b44"))
	var order := ["void", "stairs", "esc_up", "esc_down", "elevator", "bench", "wall", "entrance", "painting",
		"featured", "pedestal", "map", "terminal"]
	for kind in order:
		for item in building.map_items:
			if item["floor"] != f or item["kind"] != kind:
				continue
			var r := _rect_to_map(panel, item["rect"])
			var c: Color = STYLE.get(kind, Color.WHITE)
			if kind == "pedestal":
				draw_circle(r.get_center(), maxf(r.size.x, 7.0) / 2.0, c)
			else:
				draw_rect(r.grow(1.0) if kind in ["painting", "featured"] else r, c)
			if kind in ["esc_up", "esc_down"] and r.size.y > 40:
				_draw_arrow(r, kind == "esc_up")
			var label: String = item["label"]
			if label != "" and r.size.x > 18:
				var fs := 13
				var tw := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
				var pos := r.get_center() + Vector2(-tw / 2.0, fs / 2.5)
				if kind in ["stairs", "esc_up", "esc_down"] and f == 0:
					pos.y = r.end.y + 16  # 斜路の下に表示
				draw_string(font, pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, TEXT)
	draw_rect(_rect_to_map(panel, Rect2(Building.X_MIN, Building.Z_MIN, Building.X_MAX - Building.X_MIN,
		Building.Z_MAX - Building.Z_MIN)), STYLE["wall"], false, 3.0)


func _draw_arrow(r: Rect2, up: bool) -> void:
	var c := r.get_center()
	var h := r.size.y * 0.3
	var tip := c + Vector2(0, -h if up else h)
	var tail := c + Vector2(0, h if up else -h)
	draw_line(tail, tip, TEXT, 2.0)
	var s := 6.0
	var back := tip + Vector2(0, s if up else -s)
	draw_colored_polygon(PackedVector2Array([tip, back + Vector2(-s, 0), back + Vector2(s, 0)]), TEXT)


func _draw_player(panel: Rect2, font: Font) -> void:
	var p := player.global_position
	var c := _to_map(panel, p.x, p.z)
	var fwd := -player.global_transform.basis.z
	var dir := Vector2(fwd.x, fwd.z).normalized()
	var side := Vector2(-dir.y, dir.x)
	draw_colored_polygon(PackedVector2Array([c + dir * 16, c - dir * 6 + side * 8, c - dir * 6 - side * 8]),
		Color(1, 0.3, 0.3, 0.9))
	draw_circle(c, 6.0, Color("ff4d4d"))
	draw_string(font, c + Vector2(9, -9), "YOU", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color("ff8080"))


func _draw_legend(font: Font, origin: Vector2) -> void:
	var x := origin.x
	for entry in LEGEND:
		var c: Color = STYLE[entry[0]]
		draw_rect(Rect2(x, origin.y - 12, 14, 14), c)
		draw_string(font, Vector2(x + 20, origin.y), entry[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 15, TEXT)
		x += 26 + font.get_string_size(entry[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x + 22
	draw_circle(Vector2(x + 6, origin.y - 5), 6.0, Color("ff4d4d"))
	draw_string(font, Vector2(x + 20, origin.y), "You", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, TEXT)
