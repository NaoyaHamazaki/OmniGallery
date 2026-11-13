# OmniGallery PoC

ブラウザ上でFPS視点で歩き回れるバーチャル美術館のPoCです。作品データ・画像・3Dモデル・内装テクスチャはすべてFastAPIから動的に取得します。

```
起動用.bat                  サーバー起動 (初回は環境構築も自動)
backend/
  main.py                   FastAPI (1ファイル)。API / 静的ファイル / Web ビルド配信 / OGP 差し込み
  data/omnigallery.db       SQLite (起動時に自動作成。作品・フロアのテーブル)
  static/artworks/          絵画 (Wikimedia Commons, パブリックドメイン)   ┐
  static/models/            3Dモデル glb (Khronos glTF Sample Assets)       ├ 初回起動時に自動ダウンロード
  static/textures/          床・壁テクスチャ (Poly Haven, CC0)              ┘
  static/brand/             favicon / apple-touch-icon / OGP 画像
godot/                      Godot 4.7 プロジェクト (GL Compatibility)
  scenes/main.tscn
  scripts/
    api_client.gd           HTTP 通信 (await で JSON / 画像 / バイナリ取得)
    building.gd             建物の生成 (2フロア・階段・エスカレーター・ベンチ・案内板・照明)
    elevator.gd             エレベーター (かご・乗場ドア・ボタン)
    gallery_manager.gd      作品の配置 (絵画 / 3D作品 / スポットライト / モーダル)
    floor_map.gd            フロアマップの描画 (案内板とモーダルで共用)
    debug_terminal.gd       デバッグ端末 (構成情報の表示)
    ui.gd                   HUD とモーダル
    player.gd               FPS 操作 + クリック/タップで調べる
    touch_controls.gd       スマホ用バーチャルスティック
    interact.gd             クリック可能オブジェクトの共通処理
    dev_shots.gd            開発用 (スクリーンショット撮影 / 自動テスト)
  icon.svg / splash.png     アイコンと起動画面
tools/make_brand_assets.py  アイコン・OGP 画像の生成スクリプト (Pillow)
```

## かんたん起動

`起動用.bat` をダブルクリック → 初回は仮想環境を自動作成 → サーバー起動 → ブラウザで `http://127.0.0.1:8000/` が開きます。
コンソールにスマホ用URL (`https://192.168.x.x:8443/`) も表示されます。同じWi-Fiのスマホから開いてください (初回はWindowsファイアウォールの許可が必要)。

> Godot 4.7 の Web ビルドは「安全なコンテキスト (HTTPS か localhost)」でしか起動しないため、スマホからは `http://192.168...` では動きません。
> `backend/run_server.py` が自己署名証明書で HTTPS (8443) も同時に起動します。スマホで初回に出る警告は「詳細 → アクセスする」(iPhone は「このWebサイトを閲覧」) で進めてください。
> Railway に載せた場合は正式な HTTPS になるので警告は出ません。

※ `起動用.bat` は Shift_JIS で保存しています (UTF-8 だと cmd で日本語が化けるため)。編集する場合はエディタのエンコーディングに注意してください。

## 館内でできること

| 機能 | 内容 |
|---|---|
| 前庭からのアプローチ | 駐車場からスタートし、広場・大階段・列柱の玄関へ。歩いている間に館内を読み込み、準備が整うと自動ドアが開く (扉の上と画面上部に進捗) |
| 自動移動 | 階段・エスカレーターは乗り口で前に進むと自動で上り下り (視点は動かせる)。移動中に移動先フロアを準備し、間に合わなければ降り口で待機。エレベーターもドアが閉まってから準備完了を待って動く |
| 注視 | マウスホイールでズーム (中ボタンで戻す)。ズーム中は視点の感度も下がる |
| 調べる | 2m 以内に近づいたものだけクリック可能。操作案内は画面の上から 3/4 の位置 |
| サウンド | 控えめな BGM (館内で少し大きく) と効果音 (足音・モーダル・エレベーター到着・自動ドア)。M キーまたは右上のボタンでミュート。音源は `tools/make_audio.py` で合成した自作 |
| 作品の詳細 | 作品・キャプション台をクリック (スマホはタップ) → 画像・作者・解説・クレジットをモーダル表示 |
| フロア移動 | 吹き抜けに **階段** / **上りエスカレーター** / **下りエスカレーター**、北側に **エレベーター** (呼びボタン・かご内ボタンをクリック) |
| 3D作品 | 台座の上で回転展示。ロープの柵の内側には入れない。手前のキャプション台に説明 |
| フロアマップ | 1F 入口脇と 2F エスカレーター降り口のホログラム端末。近づくとマップのホログラムが立ち上がり、クリックで拡大 (現在地 YOU をリアルタイム表示) |
| デバッグ端末 | 1F 入口脇のホログラム端末 (緑)。クリックでクライアント状態・サーバー構成を表示し、DB はテーブルごとのタブで「CREATE 文・列の構造・格納データ」を表で確認できる (`OMNI_DEBUG=0` で非表示) |

## ロード対策 (実装済み / 今後の提案)

実装済み:
- **時間分割での生成**: 建物の生成は 1 フレーム 4ms までに区切り、画像デコード・glTF 解析は 1 フレーム 1 件ずつ (Web 版はシングルスレッドのため、重い処理が重なると固まる)
- **屋外アプローチ**: 歩いている間に 1F を読み込み、2F は館内に入ってから裏で読み込む
- **描画の下準備 (シェーダーのウォームアップ)**: 画面外の小さなカメラでフロアを見回し、初めて天井などを見たときのカクつきを先に済ませる。2F 分はフロア移動 (自動移動・エレベーター) の間に実行
- **見えない側を描かない**: 入口から離れたら、屋外にいる間は館内を、館内にいる間は屋外を描画しない (Web 版では遮蔽カリングが使えないため)
- **wasm の事前 gzip 圧縮**: 39MB → 約 10MB で配信 (ETag で 2 回目以降は 304)
- **独自ロード画面**: 小さなロゴと金色のプログレスバー (`godot/web_shell.html`)

今後の提案:
- **画像の多段階読み込み**: まず 256px のサムネイルを貼り、近づいたら高解像度に差し替え (バックエンドで縮小版を生成)
- **画像・テクスチャの WebP / KTX2 化**: 転送量とデコード時間を削減。KTX2 (Basis Universal) なら GPU 圧縮のまま転送でき VRAM も節約
- **glb の最適化**: アップロード時に gltf-transform 等でテクスチャ縮小・Draco/meshopt 圧縮 (UGC の容量制限とセット)
- **キャッシュ**: 素材 URL にハッシュを付けて `Cache-Control: immutable`、PWA (Godot の Progressive Web App 書き出し) で 2 回目以降はオフラインキャッシュから起動
- **エンジンの軽量化**: 使わない機能 (2D 物理など) を外したカスタムエクスポートテンプレートで wasm を 2〜3 割削減
- **CDN**: 本番は静的ファイル (wasm・画像・glb) を Cloudflare などの CDN から配信

### 空間・照明の設計

- 階高 5.5m / 天井高 5.0m の高い天井
- 壁はわずかに暖かいオフホワイト (#E8E3D9 付近)、Roughness 1 / Metallic 0 の完全マット。凹凸は漆喰テクスチャの法線マップのみ
- 床はヘリンボーンの寄木 (ギャラリー) と石張り (吹き抜け)
- アイストップ: 1F 入口の正面突き当たりに「星月夜」、2F 吹き抜けからの入口正面に「神奈川沖浪裏」
- 各フロア中央に背もたれのないベンチ
- 環境光は暗め。各作品に天井から斜め下 約55度のスポットライト。色温度は作品データの `light_kelvin` (古典絵画 3000K 電球色 / 3D・プロダクト 5000K 昼白色)
- 3D作品のスポットはぼかし付きのソフトシャドウ (絵画は壁に密着しているため影を省略して軽量化)

## 操作

- PC: クリックで視点操作開始 / 照準を合わせてクリックで調べる / WASD・矢印キーで移動 / Shift でダッシュ / Esc でマウス解放・モーダルを閉じる
- スマホ: 左半分でバーチャルスティック / 右半分ドラッグで視点 / タップで調べる。最初のタップで全画面 + 横画面ロック (Android Chrome)。iPhone Safari は API 非対応のため縦持ち時に「横向きにしてください」を表示

## API

| エンドポイント | 内容 |
|---|---|
| `GET /api/config` | アプリ名・バージョン・デバッグフラグ・フロア一覧 |
| `GET /api/artworks` | 公開中の作品一覧 (`kind`: painting / model、`floor`、`featured`、`light_kelvin`、`display_size` など) |
| `GET /api/debug/info` | 構成情報 (DB テーブル・行数・ストレージ・ビルド日時・リクエスト数など)。絶対パスや環境変数は返さない |
| `GET /game/` | Godot の Web ビルド。`index.html` に OGP・favicon のメタタグを差し込んで返す |

作品を差し替えたいときは `main.py` の `SEED_ARTWORKS` を編集して再起動します (将来は UGC 投稿 API から `artworks` テーブルに入る想定)。

## Godot 側を変更したとき

Godot エディタで **プロジェクト → エクスポート → Web → プロジェクトのエクスポート** (保存先 `build/web/index.html`、デバッグ付きのチェックは外す)。ブラウザを再読み込みすれば反映されます。

コマンドラインでも書き出せます:

```powershell
$G = "C:\Users\right\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe"
& $G --headless --path godot --export-release "Web" build/web/index.html
```

> Python 側 (`main.py`) を変更したら、`起動用.bat` を Ctrl+C で止めて再実行。

### 開発用コマンド

```powershell
# 移動系の自動テスト (階段・エスカレーター・エレベーター・柵・外壁)。バックエンド起動中に実行
& $G --headless --path godot -- --selftest
# 決まった視点のスクリーンショットと FPS を保存
& $G --path godot -- --shots=C:/tmp/shots
# API の接続先を変える
& $G --path godot -- --api=http://127.0.0.1:8011
```

初めて Godot を使う場合のセットアップ手順 (インストール・テンプレート導入) は Godot 公式のダウンロードページから標準版を入手し、エディタの「エディター → エクスポートテンプレートの管理 → ダウンロードしてインストール」を一度実行してください。

## Web 公開時の注意点

| 症状 | 原因と対策 |
|---|---|
| `index.html` をダブルクリックで開くと動かない | `file://` では動かない。必ずHTTPサーバー経由で開く (`/game/`)。 |
| 「SharedArrayBuffer」「Cross-Origin Isolation」エラー | スレッド有効のビルドは COOP/COEP ヘッダーが必要。同梱プリセットは `Thread Support` をオフにしているので不要。 |
| 作品・画像の取得に失敗する | Web版の HTTPRequest はブラウザの fetch を使うため CORS の対象。外部サイトの画像を直接読むと失敗しやすいので、素材はバックエンド (将来はS3+CloudFrontでCORS設定) から配信する。 |
| HTTPSで公開したら API に繋がらない | Mixed Content。ページが https なら API も https にする。 |
| `.wasm` の MIME エラーで起動しない | サーバーが `application/wasm` を返す必要がある (`main.py` で登録済み)。 |
| 再エクスポートしたのに古い版が動く | `/game/` 配下は `Cache-Control: no-cache` で毎回更新確認させている (未変更なら 304)。別サーバーで配信するときも同様の設定を。 |
| SNS でシェアしても画像が出ない | OGP はクローラーが外部から取得するため、LAN 内 (`192.168...`) や localhost の URL では表示されない。公開ドメインで配信したときに有効になる。 |
| 日本語のタイトルが表示されない | Web版はOSフォントを使えない。日本語を出すなら Noto Sans JP 等のフォントをプロジェクトに入れる。PoC では英語表記。 |

## 素材のライセンス

- 絵画: パブリックドメイン (Wikimedia Commons)
- 3Dモデル: Sheen Chair / Toy Car (CC0)、Damask Chair (CC BY 4.0, Eric Chadwick / Wayfair)、Fox (モデル CC0 PixelMannen、リグ・アニメーション CC BY 4.0 tomkranis、glTF 変換 CC BY 4.0 AsoboStudio & scurest) — 各作品のモーダルにもクレジットを表示
- テクスチャ: Poly Haven (CC0) — herringbone_parquet / marble_01 / plastered_wall
- フォント: Cinzel / EB Garamond (SIL Open Font License, `godot/fonts/OFL-*.txt`)
- BGM・効果音: `tools/make_audio.py` で合成した自作音源

## デプロイ

Railway へのデプロイ手順は [docs/DEPLOY_RAILWAY.md](docs/DEPLOY_RAILWAY.md) を参照 (`Dockerfile` / `railway.json` 同梱)。

## 今後 (要件定義書との対応)

- いいね (リアクション)、アップロード (glb / 画像) と容量・ポリゴン制限、通報・審査フロー、S3 保存
- 日本語フォント、作者の SNS リンク、展示の入れ替え (スロット割り当ての管理画面)
- エスカレーターの見た目を階段状に (現在は斜面に縞模様テクスチャを流しているだけで滑らかに見える。段板メッシュを斜面に沿って移動させ、上下端で水平に畳まれる表現にする。当たり判定は今の斜面のままで可)
