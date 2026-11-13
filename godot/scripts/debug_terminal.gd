class_name DebugTerminal
extends Node3D
## デバッグ用の案内端末 (config.debug=true のときだけ 1F 入口脇に置かれる)。
## 近づくとデータ表示風のホログラムが立ち上がり、クリックでサーバーの構成情報
## (/api/debug/info: テーブル状況・ストレージ・ビルド情報など公開して問題ない範囲) をモーダルで表示する。

var _gm: Node  # gallery_manager
var _api: ApiClient
var _ui: GalleryUI
var _player: Node3D
var _kiosk: HoloKiosk
var _t := 0.0


func setup(gallery_manager: Node, spot: Dictionary) -> void:
	_gm = gallery_manager
	_api = gallery_manager.api
	_ui = gallery_manager.ui
	_player = gallery_manager.player
	var b: Building = gallery_manager.building
	position = spot["pos"]
	var d: Vector3 = spot["toward"] - spot["pos"]
	rotation.y = atan2(d.x, d.z)
	_kiosk = HoloKiosk.new()
	add_child(_kiosk)
	_kiosk.setup(b, _player, "DEBUG", "Debug information", _open, null, Vector2(0.9, 0.55), Color(0.45, 1.0, 0.65))
	b.add_map_item(0, Rect2(position.x - 0.4, position.z - 0.4, 0.8, 0.8), "terminal", "DBG")


func _process(delta: float) -> void:
	_t += delta
	if _t >= 0.5:
		_t = 0.0
		# ホログラム下部には短い数値だけ (詳細はクリックでモーダル)
		_kiosk.set_subtitle("%d FPS" % Engine.get_frames_per_second())


func _open() -> void:
	_ui.show_modal("Debug Information", _client_bbcode() + "\n[i]Loading server info...[/i]")
	var info = await _api.get_json("/api/debug/info")
	if not _ui.is_modal_open():
		return
	if not info is Dictionary:
		_ui.update_modal_body(_client_bbcode() + "\n[color=#ff8080]Failed to load /api/debug/info: %s[/color]"
			% GalleryUI.bb_escape(_api.last_error))
		return
	# タブ: 概要 + テーブルごとの「構造」と「格納データ」
	var tabs := TabContainer.new()
	tabs.add_theme_font_override("font", GalleryFonts.title())
	tabs.add_theme_font_size_override("font_size", 15)
	var overview := _rich(_client_bbcode() + _server_bbcode(info))
	overview.name = "Overview"
	tabs.add_child(overview)
	for t in info.get("database", {}).get("tables", []):
		var page := _table_page(t)
		page.name = "Table %s" % t.get("name", "?")  # ノード名に ":" は使えない
		tabs.add_child(page)
	_ui.show_custom("Debug Information", tabs)


func _rich(bbcode: String) -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var rt := RichTextLabel.new()
	rt.bbcode_enabled = true
	rt.fit_content = true
	rt.scroll_active = false
	rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rt.add_theme_font_size_override("normal_font_size", 20)
	rt.add_theme_font_size_override("bold_font_size", 21)
	rt.add_theme_color_override("default_color", Color(0.88, 0.86, 0.82))
	rt.text = bbcode
	scroll.add_child(rt)
	return scroll


## 1 テーブル分のページ: CREATE 文 / 列の構造 / 格納データ (横にも縦にもスクロールできる表)
func _table_page(t: Dictionary) -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	var cols: Array = t.get("columns", [])
	var rows: Array = t.get("rows", [])
	var head := Label.new()
	head.text = "%s   -   %d rows%s" % [t.get("name"), int(t.get("row_count", 0)),
		"  (showing first %d)" % rows.size() if t.get("truncated", false) else ""]
	head.add_theme_font_override("font", GalleryFonts.title())
	head.add_theme_color_override("font_color", Color(0.79, 0.64, 0.36))
	v.add_child(head)

	var sql := Label.new()  # CREATE 文は 1 行に省略表示 (マウスを乗せると全文)
	sql.text = str(t.get("sql", "")).replace("\n", " ").replace("    ", " ")
	sql.tooltip_text = str(t.get("sql", ""))
	sql.mouse_filter = Control.MOUSE_FILTER_PASS
	sql.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	sql.clip_text = true
	sql.add_theme_font_size_override("font_size", 14)
	sql.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	v.add_child(sql)

	var structure := _tree(["#", "Column", "Type", "Not null", "Default", "PK"])
	structure.custom_minimum_size.y = 34 + 26 * mini(cols.size(), 4)
	var root := structure.create_item()
	for i in cols.size():
		var c: Dictionary = cols[i]
		_row(structure, root, [i, c.get("name"), c.get("type"), "yes" if c.get("notnull") else "",
			"" if c.get("default") == null else str(c.get("default")), "PK" if c.get("pk") else ""])
	v.add_child(structure)

	var data_label := Label.new()
	data_label.text = "Data"
	data_label.add_theme_font_override("font", GalleryFonts.title())
	v.add_child(data_label)
	var names: Array = cols.map(func(c): return c.get("name"))
	var data := _tree(names)
	data.size_flags_vertical = Control.SIZE_EXPAND_FILL
	data.custom_minimum_size.y = 200
	var droot := data.create_item()
	for r in rows:
		_row(data, droot, r)
	v.add_child(data)
	return v


func _tree(titles: Array) -> Tree:
	var tree := Tree.new()
	tree.columns = titles.size()
	tree.column_titles_visible = true
	tree.hide_root = true
	tree.select_mode = Tree.SELECT_ROW
	tree.add_theme_font_size_override("font_size", 16)
	tree.add_theme_font_size_override("title_button_font_size", 15)
	for i in titles.size():
		tree.set_column_title(i, str(titles[i]))
		tree.set_column_expand(i, true)
		tree.set_column_clip_content(i, true)
		tree.set_column_custom_minimum_width(i, 70 if i == 0 else 150)
	return tree


func _row(tree: Tree, parent: TreeItem, values: Array) -> void:
	var item := tree.create_item(parent)
	for i in mini(values.size(), tree.columns):
		var text := "NULL" if values[i] == null else str(values[i])
		if values[i] is float and float(values[i]) == floorf(values[i]):
			text = str(int(values[i]))
		item.set_text(i, text.replace("\n", " "))
		item.set_tooltip_text(i, text)  # 長い値はマウスを乗せると全文表示


func _section(title: String) -> String:
	return "\n[font_size=22][color=#c9a45c][b]%s[/b][/color][/font_size]\n" % title


func _table(rows: Array) -> String:
	var s := "[table=2]"
	for r in rows:
		s += "[cell][color=#9a96a0]%s[/color]   [/cell][cell]%s[/cell]" % [
			GalleryUI.bb_escape(str(r[0])), GalleryUI.bb_escape(str(r[1]))]
	return s + "[/table]\n"


func _client_bbcode() -> String:
	var v := Engine.get_version_info()
	var vp := get_viewport().get_visible_rect().size
	var p := _player.global_position
	return _section("Client") + _table([
		["Engine", "Godot %s" % v.get("string", "?")],
		["Platform", "%s%s" % [OS.get_name(), " (web)" if OS.has_feature("web") else ""]],
		["Renderer", "%s / %s" % [ProjectSettings.get_setting("rendering/renderer/rendering_method"),
			RenderingServer.get_video_adapter_name()]],
		["Viewport", "%d x %d" % [vp.x, vp.y]],
		["FPS", int(Engine.get_frames_per_second())],
		["Draw calls", int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))],
		["Objects", int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))],
		["Video memory", "%.1f MB" % (Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0)],
		["Position", "%dF  (%.1f, %.1f, %.1f)" % [Building.floor_of(p.y) + 1, p.x, p.y, p.z]],
		["API base", _api.base_url],
		["API latency", "%d ms" % _api.last_latency_ms],
		["Artworks", "%d loaded / %d failed" % [_gm.loaded_count, _gm.failed_count]],
	])


func _server_bbcode(info: Dictionary) -> String:
	var app: Dictionary = info.get("app", {})
	var rt: Dictionary = info.get("runtime", {})
	var dbi: Dictionary = info.get("database", {})
	var st: Dictionary = info.get("storage", {})
	var wb: Dictionary = info.get("web_build", {})
	var s := _section("Server") + _table([
		["App", "%s %s  (debug=%s)" % [app.get("name"), app.get("version"), app.get("debug")]],
		["Server time", app.get("server_time")],
		["Uptime", "%d s" % int(app.get("uptime_sec", 0))],
		["Runtime", "Python %s / FastAPI %s / %s" % [rt.get("python"), rt.get("fastapi"), rt.get("os")]],
		["CORS", ", ".join(info.get("cors", {}).get("allow_origins", []))],
		["Web build", "built %s  (wasm %s MB)" % [wb.get("built_at"), wb.get("wasm_mb")]],
	])
	s += _section("Database  (%s %s, %s, %s KB)" % [dbi.get("engine"), rt.get("sqlite"), dbi.get("file"), dbi.get("size_kb")])
	var rows: Array = []
	for t in dbi.get("tables", []):
		var names: Array = t.get("columns", []).map(func(c): return str(c.get("name")))
		rows.append([t.get("name"), "%d rows   [%s]   -> see the DB tab" % [int(t.get("row_count", 0)), ", ".join(names)]])
	rows.append(["by kind", JSON.stringify(dbi.get("artworks_by_kind", {}))])
	rows.append(["by floor", JSON.stringify(dbi.get("artworks_by_floor", {}))])
	s += _table(rows)
	var srows: Array = []
	for k in st:
		srows.append([k, "%d files / %s MB" % [int(st[k].get("files", 0)), st[k].get("size_mb")]])
	s += _section("Storage") + _table(srows)
	s += _section("Requests since start") + _table(_dict_rows(info.get("requests", {})))
	s += _section("Endpoints") + GalleryUI.bb_escape(", ".join(info.get("endpoints", []))) + "\n"
	return s


func _dict_rows(d: Dictionary) -> Array:
	var out: Array = []
	for k in d:
		out.append(["/" + str(k), d[k]])
	return out
