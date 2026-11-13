class_name GalleryFonts
extends RefCounted
## 美術館らしいフォント。
##   見出し・サイン: Cinzel (ローマ碑文由来のセリフ体)
##   本文: EB Garamond (古典的なオールドスタイル)
## どちらも SIL Open Font License (fonts/OFL-*.txt)。日本語グリフは含まないので表示は英語。

static var _title: Font
static var _body: Font


static func title() -> Font:
	if _title == null:
		_title = load("res://fonts/Cinzel.ttf")
	return _title


static func body() -> Font:
	if _body == null:
		_body = load("res://fonts/EBGaramond.ttf")
	return _body
