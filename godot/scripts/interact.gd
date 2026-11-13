class_name Interact
extends RefCounted
## クリック(タップ)で反応するオブジェクトを作るためのユーティリティ。
## 当たり判定 (StaticBody3D) にメタデータとして「表示テキスト」と「実行する処理」を持たせ、
## player.gd がレイキャストで当たった相手のメタデータを見て呼び出す。

const META_CALL := "interact"
const META_TEXT := "interact_text"


## parent の子として箱形の当たり判定を作り、クリック時の処理を登録する。
static func add_box(parent: Node3D, size: Vector3, offset: Vector3, text: String, callable: Callable) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = offset
	parent.add_child(body)
	attach(body, text, callable)
	return body


static func attach(body: CollisionObject3D, text: String, callable: Callable) -> void:
	body.set_meta(META_CALL, callable)
	body.set_meta(META_TEXT, text)


static func text_of(collider: Object) -> String:
	if collider and collider.has_meta(META_TEXT):
		return str(collider.get_meta(META_TEXT))
	return ""


static func run(collider: Object) -> bool:
	if collider and collider.has_meta(META_CALL):
		var c: Callable = collider.get_meta(META_CALL)
		if c.is_valid():
			c.call()
			return true
	return false
