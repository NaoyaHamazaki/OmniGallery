class_name DevShots
extends Node
## 開発用: 起動引数 --shots=<保存先フォルダ> を付けると、決められた視点のスクリーンショットを撮って終了する。
##   Godot.exe --path godot -- --api=http://127.0.0.1:8000 --shots=C:/tmp/shots

const VIEWS := [
	# name, 足元の位置, 注視点
	["00_parking", Vector3(-3.0, -1.2, 40.0), Vector3(-3.0, 4.0, 10.0)],
	["00b_portico", Vector3(-6.0, -1.2, 21.0), Vector3(-3.0, 4.5, 10.0)],
	["00c_door", Vector3(-3.0, 0.0, 15.0), Vector3(-3.0, 2.2, 10.0)],
	["00d_taxi", Vector3(0.8, -1.2, 39.0), Vector3(4.65, -0.4, 34.0)],
	["00e_trees_lamps", Vector3(-9.0, -1.2, 31.0), Vector3(-15.0, 0.8, 24.0)],
	["01_entrance_eyestop", Vector3(-3.0, 0.0, 8.3), Vector3(-3.0, 1.9, -10.0)],
	["01b_ceiling", Vector3(-3.0, 0.0, 3.0), Vector3(-3.0, 5.0, -2.0)],
	["01c_elevator_cabin", Vector3(12.0, 0.0, -5.6), Vector3(12.0, 0.2, -8.6)],
	["02_1f_pedestal", Vector3(-6.8, 0.0, 5.2), Vector3(-9.5, 1.3, 1.0)],
	["03_1f_west_wall", Vector3(-9.0, 0.0, 0.0), Vector3(-15.0, 1.7, -2.5)],
	["04_atrium_ramps", Vector3(9.9, 0.0, 9.4), Vector3(13.5, 2.6, 0.0)],
	["05_map_board", Vector3(-1.4, 0.0, 7.0), Vector3(0.0, 1.5, 5.0)],
	["05b_map_board_far", Vector3(-3.0, 0.0, 9.5), Vector3(0.0, 1.3, 5.0)],
	["06_debug_terminal", Vector3(-4.6, 0.0, 6.6), Vector3(-6.0, 1.3, 5.0)],
	["07_2f_landing_elevator", Vector3(12.5, 5.5, -2.2), Vector3(12.0, 6.8, -7.1)],
	["08_2f_gallery_eyestop", Vector3(8.0, 5.5, -4.0), Vector3(-15.0, 7.5, -4.0)],
	["09_2f_models", Vector3(-5.5, 5.5, 0.2), Vector3(-9.0, 6.7, 3.5)],
	["10_2f_balcony_void", Vector3(9.8, 5.5, 8.5), Vector3(13.0, 3.0, 0.0)],
]

var out_dir := ""
var selftest := false


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shots="):
			out_dir = arg.trim_prefix("--shots=")
		if arg == "--selftest":
			selftest = true
	if out_dir == "" and not selftest:
		queue_free()


## 開発用: --selftest で移動系 (階段・エスカレーター・エレベーター・柵) の動作を検証して終了する
func run_selftest(gm: Node) -> void:
	var p: CharacterBody3D = gm.player
	var results: Array = []
	# T. タクシー (イースターエッグ): 乗って走る / 大階段の手前で止まる / 降りる
	var taxi: Taxi = gm.outdoor.get_node("Taxi")
	var start: Vector3 = taxi.global_position
	taxi._enter()
	Input.action_press("move_forward")
	await _wait(2.5)
	Input.action_release("move_forward")
	await _wait(2.0)
	results.append(["taxi drives", taxi.global_position.distance_to(start) > 6.0 and p.driving == taxi, taxi.global_position])
	taxi.global_position = Vector3(-3.0, -1.15, 26.0)
	taxi.rotation.y = 0.0
	Input.action_press("move_forward")
	await _wait(4.0)
	Input.action_release("move_forward")
	await _wait(1.5)
	results.append(["taxi blocked before grand steps", taxi.global_position.z > Outdoor.STEPS_Z, taxi.global_position])
	taxi.leave()
	await _wait(0.3)
	results.append(["get out of taxi", p.driving == null and not p.get_node("CollisionShape3D").disabled, p.global_position])
	taxi.global_position = start  # 駐車場に戻しておく
	taxi.rotation.y = 0.0
	# 0. 広場から大階段を上り、自動ドアを通って館内へ
	await _walk(p, Vector3(-3.0, -1.15, 24.0), 0.0, 8.0)
	results.append(["plaza -> grand steps -> auto door -> lobby", p.global_position.z < 9.0 and p.global_position.y > -0.2, p.global_position])
	# 1. 階段を歩いて上る (乗り口で自動移動に切り替わる)
	await _walk(p, Vector3(11.4, 0.05, 9.0), 0.0, 6.0)
	results.append(["stairs: walk up to 2F", p.global_position.y > 5.3, p.global_position])
	# 2. 上りエスカレーター: 乗ったら立ち止まる
	await _walk(p, Vector3(13.3, 0.05, 8.8), 0.0, 0.6)
	await _wait(14.0)
	results.append(["escalator up carries player", p.global_position.y > 5.3, p.global_position])
	# 3. 下りエスカレーター
	await _walk(p, Vector3(14.9, 5.55, -2.2), PI, 0.6)
	await _wait(14.0)
	results.append(["escalator down carries player", p.global_position.y < 0.3, p.global_position])
	# 4. エレベーターで 2F へ
	p.global_position = Vector3(12.0, 0.1, -8.6)
	await _wait(1.0)
	gm.building.elevator.request_floor(1)
	await _wait(9.0)
	results.append(["elevator to 2F", p.global_position.y > 5.3, p.global_position])
	gm.building.elevator.request_floor(0)
	await _wait(9.0)
	results.append(["elevator back to 1F", p.global_position.y < 0.3, p.global_position])
	# 5. 3D 作品の柵の中には入れない (台座 (-9.5, 1.0)、柵は ±1.25)
	await _walk(p, Vector3(-9.5, 0.05, 5.0), 0.0, 4.0)
	results.append(["pedestal barrier blocks", p.global_position.z > 2.5, p.global_position])
	# 6. 外壁を抜けない
	await _walk(p, Vector3(-12.0, 0.05, -5.0), PI / 2.0, 3.0)
	results.append(["outer wall blocks", p.global_position.x > Building.X_MIN, p.global_position])
	var ok := true
	for r in results:
		print("[selftest] %s  %s  pos=%s" % ["PASS" if r[1] else "FAIL", r[0], r[2]])
		ok = ok and r[1]
	print("[selftest] RESULT: %s" % ("ALL PASS" if ok else "FAILED"))
	get_tree().quit(0 if ok else 1)


func _walk(p: CharacterBody3D, start: Vector3, yaw: float, seconds: float) -> void:
	p.global_position = start
	p.velocity = Vector3.ZERO
	p.rotation.y = yaw
	await _wait(0.3)
	Input.action_press("move_forward")
	await _wait(seconds)
	Input.action_release("move_forward")
	var limit := 30.0
	while p.in_transit and limit > 0.0:  # 自動移動中なら終わるまで待つ
		await _wait(0.25)
		limit -= 0.25
	await _wait(0.3)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds, true, true).timeout


func run(gm: Node) -> void:
	DirAccess.make_dir_recursive_absolute(out_dir)
	var player: CharacterBody3D = gm.player
	var head: Node3D = player.get_node("Head")
	player.set_physics_process(false)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)  # FPS 計測のため
	for v in VIEWS:
		var eye: Vector3 = v[1] + Vector3(0, 1.55, 0)
		var dir: Vector3 = v[2] - eye
		player.global_position = v[1]
		player.rotation.y = atan2(-dir.x, -dir.z)
		head.rotation.x = atan2(dir.y, Vector2(dir.x, dir.z).length())
		await _wait(0.9)  # ホログラムの立ち上がりなどアニメーションを待つ
		var t0 := Time.get_ticks_usec()
		await _frames(60)
		var fps := 60.0 / ((Time.get_ticks_usec() - t0) / 1000000.0)
		print("[perf] %s  %.0f fps  draw=%d objects=%d" % [v[0], fps,
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)])
		_save(v[0])
	# モーダル (作品説明・フロアマップ・デバッグ情報)
	var b: Building = gm.building
	for c in gm.find_children("Painting_starry-night", "", false, false):
		var body: Node = c.get_child(c.get_child_count() - 1)
		Interact.run(body)
	await _frames(15)
	_save("11_modal_artwork")
	gm.ui.close_modal()
	b._open_map()
	await _frames(15)
	_save("12_modal_map")
	gm.ui.close_modal()
	var term := gm.get_node_or_null("DebugTerminal")
	if term:
		term._open()
		await get_tree().create_timer(1.5).timeout
		_save("13_modal_debug")
		for tc in gm.ui.find_children("*", "TabContainer", true, false):
			tc.current_tab = 1
		await _frames(10)
		_save("14_modal_debug_db")
	get_tree().quit()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _save(name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	img.save_png(out_dir.path_join(name + ".png"))
	print("[shots] ", name)
