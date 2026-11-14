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
	["02c_local_media", Vector3(4.0, 0.0, -3.0), Vector3(8.85, 1.7, -3.0)],
	["02a_upload_test_lite", Vector3(-6.5, 0.0, 0.5), Vector3(-3.0, 2.0, -3.5)],
	["02_1f_pedestal", Vector3(-6.8, 0.0, 5.2), Vector3(-9.5, 1.3, 1.0)],
	["03_1f_west_wall", Vector3(-9.0, 0.0, 0.0), Vector3(-15.0, 1.7, -2.5)],
	["04_atrium_ramps", Vector3(9.9, 0.0, 9.4), Vector3(13.5, 2.6, 0.0)],
	["05_map_board", Vector3(-1.4, 0.0, 7.0), Vector3(0.0, 1.5, 5.0)],
	["05b_map_board_far", Vector3(-3.0, 0.0, 9.5), Vector3(0.0, 1.3, 5.0)],
	["05c_submit_kiosk", Vector3(1.4, 0.0, 8.0), Vector3(3.0, 1.4, 6.5)],
	["06_debug_terminal", Vector3(-4.6, 0.0, 6.6), Vector3(-6.0, 1.3, 5.0)],
	["07_2f_landing_elevator", Vector3(12.5, 5.5, -2.2), Vector3(12.0, 6.8, -7.1)],
	["08_2f_gallery_eyestop", Vector3(8.0, 5.5, -4.0), Vector3(-15.0, 7.5, -4.0)],
	["09_2f_models", Vector3(-5.5, 5.5, 0.2), Vector3(-9.0, 6.7, 3.5)],
	["10_2f_balcony_void", Vector3(9.8, 5.5, 8.5), Vector3(13.0, 3.0, 0.0)],
]

var out_dir := ""
var selftest := false
var touch := false
var only := ""  # --only=<名前の先頭> : その視点だけ撮る (作品追加時の部分確認用)


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shots="):
			out_dir = arg.trim_prefix("--shots=")
		if arg == "--selftest":
			selftest = true
		if arg == "--touch":  # スマホの画面 (スティック・MENU ボタン) で撮る
			touch = true
		if arg.begins_with("--only="):
			only = arg.trim_prefix("--only=")
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
	# 外周の生け垣にめり込まない (南と西)。正面から突っ込むので車体の半分の長さ 2.2 - 余裕 0.15
	taxi.teleport(Vector3(5.0, Outdoor.GROUND_Y + 0.05, Outdoor.LOT_Z - 8.0), PI)
	Input.action_press("move_forward")
	await _wait(3.0)
	Input.action_release("move_forward")
	await _wait(1.0)
	results.append(["taxi stops at south hedge", taxi.global_position.z < Outdoor.LOT_Z - Outdoor.HEDGE_T - 2.2 + 0.15, taxi.global_position])
	taxi.teleport(Vector3(Outdoor.X0 + 8.0, Outdoor.GROUND_Y + 0.05, 40.0), PI / 2.0)  # 西を向く
	Input.action_press("move_forward")
	await _wait(3.0)
	Input.action_release("move_forward")
	await _wait(1.0)
	results.append(["taxi stops at west hedge", taxi.global_position.x > Outdoor.X0 + Outdoor.HEDGE_T + 2.2 - 0.15, taxi.global_position])
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
	# 7. タイムアタック: ゲートからコースへ → 自動運転で 1 周 → ランキング登録 → 美術館へ戻る
	var ta: TimeAttack = gm.get_node("%TimeAttack")
	if TimeAttack.ENABLED:
		await _selftest_course(gm, taxi, ta, results)
	else:
		print("[selftest] SKIP  time attack (closed: TimeAttack.ENABLED = false)")
	taxi.teleport(start, 0.0)

	var ok := true
	for r in results:
		print("[selftest] %s  %s  pos=%s" % ["PASS" if r[1] else "FAIL", r[0], r[2]])
		ok = ok and r[1]
	print("[selftest] RESULT: %s" % ("ALL PASS" if ok else "FAILED"))
	get_tree().quit(0 if ok else 1)


func _selftest_course(gm: Node, taxi: Taxi, ta: TimeAttack, results: Array) -> void:
	taxi._enter()
	taxi.teleport(Vector3(Outdoor.GATE_X, Outdoor.GROUND_Y + 0.05, Outdoor.LOT_Z - 6.0), PI)  # 南 (ゲート) を向く
	Input.action_press("move_forward")
	var waited := 0.0
	while not ta.active and waited < 8.0:
		await _wait(0.25)
		waited += 0.25
	Input.action_release("move_forward")
	results.append(["hidden hedge passage leads to the course", ta.active, taxi.global_position])
	while ta.state != TimeAttack.State.RUNNING and waited < 15.0:
		await _wait(0.1)
		waited += 0.1
	var lap_start := Time.get_ticks_msec()
	while ta.state == TimeAttack.State.RUNNING and Time.get_ticks_msec() - lap_start < 240000:
		await get_tree().physics_frame
		taxi.ai_input = _autopilot(taxi, ta)
	taxi.ai_input = Vector2.ZERO
	results.append(["lap finished (%.1f s, target ~90 s)" % (ta.last_ms / 1000.0), ta.state == TimeAttack.State.FINISHED, taxi.global_position])
	await _wait(3.0)
	ta._name = [3, 4, 21]  # "DEV"
	await ta._submit()
	results.append(["ranking saved (rank %d)" % ta.last_rank, ta.last_rank >= 1, Vector3.ZERO])
	await ta.exit_course()
	results.append(["back to museum parking", not ta.active and taxi.global_position.z < Outdoor.LOT_Z, taxi.global_position])
	taxi.leave()


## 次のチェックポイントへ向かう簡易自動運転 (戻り値はスティック入力と同じ形式)
var _ap_idx := 1


func _autopilot(taxi: Taxi, ta: TimeAttack) -> Vector2:
	var p := Vector2(taxi.global_position.x - TimeAttack.ORIGIN.x, taxi.global_position.z - TimeAttack.ORIGIN.z)
	var route := TimeAttack.ROUTE
	if p.distance_to(route[_ap_idx]) < 6.0:  # 頂点に近づいたら次の頂点へ
		_ap_idx = (_ap_idx + 1) % route.size()
	var target: Vector2 = route[_ap_idx]
	var to := (target - p).normalized()
	var yaw := taxi.rotation.y
	var fwd := Vector2(-sin(yaw), -cos(yaw))
	var left := Vector2(-cos(yaw), sin(yaw))  # yaw が増える (= 左に曲がる) 方向
	var ang := atan2(to.dot(left), to.dot(fwd))
	var steer := clampf(ang * 2.5, -1.0, 1.0)
	var throttle := 1.0 if absf(ang) < 0.35 else 0.45
	return Vector2(-steer, -throttle)


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
	if touch:
		gm.ui.touch_controls._set_active(true)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)  # FPS 計測のため
	for v in VIEWS:
		if only != "" and not str(v[0]).begins_with(only):
			continue
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
	# 投稿テスト作品: 高品質版に差し替えて同じ視点で撮る
	if gm._models.has("upload-test-01") and only == "":
		player.global_position = Vector3(-6.5, 0.0, 0.5)
		var d: Vector3 = Vector3(-3.0, 2.0, -3.5) - (player.global_position + Vector3(0, 1.55, 0))
		player.rotation.y = atan2(-d.x, -d.z)
		head.rotation.x = atan2(d.y, Vector2(d.x, d.z).length())
		await gm._on_ui_action("hq:upload-test-01")
		await _wait(1.0)
		_save("02b_upload_test_hq")
	if only != "" and only != "modals":  # --only=modals: 視点は撮らずモーダルだけ撮る
		get_tree().quit()
		return
	# タイムアタックのコース (閉鎖中は撮らない)
	if TimeAttack.ENABLED:
		await _shots_course(gm, player)
	await _save_modals(gm)


func _shots_course(gm: Node, player: CharacterBody3D) -> void:
	player.set_physics_process(true)
	var taxi: Taxi = gm.outdoor.get_node("Taxi")
	var ta: TimeAttack = gm.get_node("%TimeAttack")
	taxi._enter()
	await ta.enter()
	await _wait(1.5)
	_save("15_course_countdown")
	await _wait(2.5)
	taxi.ai_input = Vector2(0, -1)
	await _wait(2.0)
	taxi.ai_input = Vector2.ZERO
	_save("16_course_driving")
	var cam: Camera3D = taxi._cam
	taxi.set_process(false)
	cam.global_position = TimeAttack.ORIGIN + Vector3(110, 210, 230)
	cam.look_at(TimeAttack.ORIGIN + Vector3(110, 0, 80), Vector3.UP)
	cam.far = 600.0
	await _frames(10)
	_save("17_course_overview")
	cam.far = 220.0
	taxi.set_process(true)
	await ta.exit_course()
	taxi.leave()
	player.set_physics_process(false)


## モーダル (作品説明・フロアマップ・出品受付・メニュー・デバッグ情報)
func _save_modals(gm: Node) -> void:
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
	await _frames(5)
	gm.ui.open_submit_info()
	await _frames(15)
	_save("12b_modal_submit")
	gm.ui.close_modal()
	gm.ui.open_menu()
	await _frames(15)
	_save("12c_modal_menu")
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
