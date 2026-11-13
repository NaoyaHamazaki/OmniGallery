class_name ApiClient
extends Node
## バックエンドとの HTTP 通信をまとめたヘルパー。各関数は await して使う。
##   var data = await api.get_json("/api/artworks")

## 空のときは自動判定: Web 版なら配信元オリジン、エディタ/デスクトップなら http://127.0.0.1:8000
@export var base_url: String = ""

## 直近の JSON リクエストの所要時間 (デバッグ表示用)
var last_latency_ms: int = -1
var last_error: String = ""


func _ready() -> void:
	if base_url.is_empty():
		base_url = _detect_base_url()


func _detect_base_url() -> String:
	# 起動引数で上書き可能:  godot -- --api=http://127.0.0.1:8011
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--api="):
			return arg.trim_prefix("--api=")
	if OS.has_feature("web"):
		var origin = JavaScriptBridge.eval("window.location.origin")
		# エディタの「ブラウザで実行」(localhost:8060) の場合は API が別ポート
		if origin is String and not origin.ends_with(":8060"):
			return origin
	return "http://127.0.0.1:8000"


func resolve(path: String) -> String:
	if path.begins_with("http://") or path.begins_with("https://"):
		return path
	return base_url + path


## 成功時はレスポンス本文、失敗時は空配列を返す。
func get_bytes(path: String, timeout: float = 60.0) -> PackedByteArray:
	var req := HTTPRequest.new()
	req.timeout = timeout
	# Web 版はブラウザ (fetch) が gzip/br を自動で解凍済み。Godot 側でも解凍しようとすると
	# Railway などの経路で圧縮された応答が result=8 (BODY_DECOMPRESS_FAILED) になるので無効にする
	req.accept_gzip = not OS.has_feature("web")
	add_child(req)
	var err := req.request(resolve(path))
	if err != OK:
		req.queue_free()
		last_error = "request error %s: %s" % [path, error_string(err)]
		push_warning(last_error)
		return PackedByteArray()
	var res: Array = await req.request_completed
	req.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] != 200:
		last_error = "GET %s failed (result=%d, http=%d)" % [path, res[0], res[1]]
		push_warning(last_error)
		return PackedByteArray()
	return res[3]


func get_json(path: String) -> Variant:
	var started := Time.get_ticks_msec()
	var text := ""
	if OS.has_feature("web"):
		text = await _web_get_text(resolve(path), 15.0)
	else:
		var body := await get_bytes(path, 15.0)
		text = body.get_string_from_utf8()
	if text.is_empty():
		return null
	last_latency_ms = Time.get_ticks_msec() - started
	return JSON.parse_string(text)


var _js_seq := 0


## Web 版の JSON 取得はブラウザの fetch を直接使う。
## Railway などの中継サーバーが JSON を gzip 圧縮すると、ブラウザが解凍済みのデータを Godot の HTTPRequest が
## もう一度解凍しようとして失敗する (result=8 BODY_DECOMPRESS_FAILED) ため。
func _web_get_text(url: String, timeout: float) -> String:
	_js_seq += 1
	var key := JSON.stringify("r%d" % _js_seq)
	JavaScriptBridge.eval("""(function(){
		window.__og = window.__og || {};
		var k = %s;
		fetch(%s, {cache: 'no-store'})
			.then(function(r){ return r.text().then(function(t){ window.__og[k] = {s: r.status, t: t}; }); })
			.catch(function(e){ window.__og[k] = {s: 0, t: String(e)}; });
	})()""" % [key, JSON.stringify(url)], true)
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var status = JavaScriptBridge.eval("window.__og[%s] ? window.__og[%s].s : -1" % [key, key], true)
		if status == null or float(status) < 0.0:
			continue
		var text = JavaScriptBridge.eval("window.__og[%s].t" % key, true)
		JavaScriptBridge.eval("delete window.__og[%s]" % key, true)
		if int(status) != 200:
			last_error = "GET %s failed (http=%d) %s" % [url, int(status), str(text).left(120)]
			push_warning(last_error)
			return ""
		return str(text)
	last_error = "GET %s timed out" % url
	return ""


var _last_decode_frame := -1


## 重い処理 (画像デコード・glTF 解析) を 1 フレームに 1 件ずつに制限する順番待ち。
## Web 版はシングルスレッドなので、同じフレームに重い処理が重なると画面が固まるため。
func decode_turn() -> void:
	while Engine.get_process_frames() == _last_decode_frame:
		await get_tree().process_frame
	_last_decode_frame = Engine.get_process_frames()


## 画像をダウンロードして ImageTexture にする (失敗時は null)。
func get_texture(path: String) -> ImageTexture:
	var body := await get_bytes(path)
	if body.is_empty():
		return null
	await decode_turn()
	var image := decode_image(body)
	if image == null:
		return null
	image.generate_mipmaps()  # 遠くから見たときのチラつき防止
	return ImageTexture.create_from_image(image)


## 拡張子ではなく先頭バイト(マジックナンバー)で形式を判定してデコードする。
static func decode_image(body: PackedByteArray) -> Image:
	if body.size() < 12:
		return null
	var image := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if body[0] == 0xFF and body[1] == 0xD8:
		err = image.load_jpg_from_buffer(body)
	elif body[0] == 0x89 and body[1] == 0x50 and body[2] == 0x4E and body[3] == 0x47:
		err = image.load_png_from_buffer(body)
	elif body.slice(0, 4).get_string_from_ascii() == "RIFF" and body.slice(8, 12).get_string_from_ascii() == "WEBP":
		err = image.load_webp_from_buffer(body)
	return image if err == OK else null
