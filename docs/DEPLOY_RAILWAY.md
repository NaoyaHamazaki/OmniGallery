# Railway へのデプロイ手順 (OmniGallery PoC)

## 構成

```
GitHub リポジトリ ──(push で自動デプロイ)──▶ Railway サービス (Docker コンテナ 1 つ)
                                              └ FastAPI (uvicorn)
                                                 ├ /api/...        作品 API
                                                 ├ /static/...     画像・glb・テクスチャ
                                                 └ /game/          Godot の Web ビルド (gzip 配信)
```

FastAPI がゲーム本体も配信するので、ゲームと API が **同一オリジン** になり CORS で詰まりません。

### COOP / COEP ヘッダーについて (docs/デプロイに伴い.txt への補足)

COOP/COEP (Cross-Origin Isolation) ヘッダーが必要なのは **Godot の Web 書き出しで「スレッドサポート」をオンにした場合だけ** です。
このプロジェクトの書き出し設定 (`godot/export_presets.cfg`) は `variant/thread_support=false` なので **不要** です。
むしろ付けると外部リソース (Google Fonts など) の読み込みに制約が出るため、付けない構成にしています。

## リポジトリに含めるもの / 含めないもの

| パス | 扱い | 理由 |
|---|---|---|
| `backend/` (main.py, requirements.txt, static/) | 含める | 作品画像・3Dモデル・テクスチャもコミット (起動時に外部から再ダウンロードしなくて済む) |
| `godot/build/web/` | **含める** | Railway 上では Godot を動かさないので、手元で書き出したものを載せる |
| `Dockerfile` / `.dockerignore` / `railway.json` | 含める | Railway のビルド・起動設定 |
| `backend/.venv/`, `backend/data/`, `godot/.godot/`, `*.gz` | 含めない (`.gitignore` 済み) | 仮想環境 / 起動時に自動生成される DB / Godot のキャッシュ / サーバーが作る圧縮版 |

> `index.wasm` は約 39MB あります。GitHub の 1 ファイル上限 (100MB) 未満なので通常の push で問題ありません (50MB 超で警告は出ません)。

---

## 1. デプロイ前の準備 (毎回)

1. Godot で **プロジェクト → エクスポート → Web → プロジェクトのエクスポート** (デバッグ付きのチェックは外す)
   - コマンドなら: `& $G --headless --path godot --export-release "Web" build/web/index.html`
2. ローカルで確認: `起動用.bat` → `http://127.0.0.1:8000/`

## 2. GitHub の設定

### 2-1. リポジトリを作る (初回のみ)

1. https://github.com/new を開く
2. Repository name: 例 `omnigallery` / **Private** を推奨 (PoC のため) / README・.gitignore・License は **追加しない** (手元にあるため)
3. 「Create repository」

### 2-2. 手元のフォルダを push する (初回のみ)

プロジェクトフォルダで PowerShell を開き:

```powershell
git init
git branch -M main
git add .
git status        # backend/.venv や backend/data が含まれていないことを確認
git commit -m "OmniGallery PoC"
git remote add origin https://github.com/NaoyaHamazaki/OmniGallery.git
git push -u origin main
```

> GitHub CLI (`gh`) を使う場合は `gh repo create omnigallery --private --source . --push` で 2-1 と 2-2 をまとめて実行できます。

### 2-3. 2 回目以降の更新

```powershell
git add .
git commit -m "変更内容"
git push
```

push すると Railway が自動で再デプロイします (下記 3-2 の設定)。

## 3. Railway の設定

### 3-1. プロジェクト作成

1. https://railway.com にログイン (GitHub アカウントでのログインが簡単)
2. **New Project → Deploy from GitHub repo**
3. 初回は「Configure GitHub App」で Railway に対象リポジトリへのアクセスを許可 (Only select repositories → `omnigallery` を推奨)
4. リポジトリを選ぶ → **Deploy Now**
   - ルートの `Dockerfile` と `railway.json` が自動で使われます (Builder: Dockerfile)

### 3-2. サービスの設定 (サービスを開いて Settings タブ)

| 項目 | 設定値 | 補足 |
|---|---|---|
| Source → Branch | `main` | このブランチへの push で自動デプロイ |
| Source → Root Directory | 空のまま (リポジトリのルート) | `backend` にすると `godot/build/web` が含まれなくなるので **変更しない** |
| Build → Builder | Dockerfile (自動) | `railway.json` で指定済み |
| Deploy → Start Command | 空のまま | Dockerfile の CMD を使う (`--proxy-headers` 付き) |
| Deploy → Healthcheck Path | `/api/config` | `railway.json` で指定済み |
| Deploy → Restart Policy | On Failure | `railway.json` で指定済み |
| Networking → Public Networking | **Generate Domain** をクリック | `xxxx.up.railway.app` が発行される。ポートを聞かれたら `8080` などそのまま (Railway が `PORT` 環境変数で渡す値) |
| Region | 日本から使うなら Asia (Singapore など) | 体感速度に影響 |

### 3-3. 環境変数 (Variables タブ)

| 変数 | 値 | 説明 |
|---|---|---|
| `OMNI_DEBUG` | `1` (PoC 中) / `0` (一般公開時) | `0` でデバッグ端末と `/api/debug/info` を無効化 |
| `PORT` | **設定しない** | Railway が自動で設定する |

### 3-4. 動作確認

1. Deployments タブでビルドログ → `Application startup complete` が出ていれば起動成功
2. 発行されたドメインを開く: `https://xxxx.up.railway.app/` → `/game/` に移動してロード画面 → 駐車場から開始
3. `https://xxxx.up.railway.app/api/artworks` の `url` が `https://` で始まっていること (http だと Mixed Content で画像が出ない)
4. SNS のシェア確認: X (Twitter) の投稿画面に URL を貼る / https://www.opengraph.xyz/ などで OGP 画像が出るか

## 4. 注意点・よくあるつまずき

| 症状 | 原因と対策 |
|---|---|
| ビルドで `godot/build/web: not found` | Web ビルドをコミットしていない。`.gitignore` で除外していないか確認し、書き出し → commit → push |
| 画像が表示されない (コンソールに Mixed Content) | API の URL が http になっている。Dockerfile の `--proxy-headers --forwarded-allow-ips='*'` を消していないか確認 |
| デプロイのたびに DB が初期化される | コンテナのファイルは再デプロイで消える。PoC はシード作品を毎回入れ直す設計なので問題なし。UGC を保存するようになったら **Volume** (サービスを右クリック → Attach Volume、Mount path `/app/backend/data`) か **Railway の PostgreSQL** に移行 |
| 投稿画像が消える (将来) | 同上。画像は Volume ではなく S3 / Cloudflare R2 などのオブジェクトストレージに置くのが本番向け |
| 初回表示が遅い | wasm は gzip 配信で約 10MB。リージョンを近くに。さらに速くする案は README の「ロード対策」参照 |
| しばらくアクセスがないと遅い | Settings の **Serverless (App Sleeping)** をオンにしているとスリープから復帰に数秒かかる。デモ前は一度開いておく |
| 料金 | Hobby プラン (月額制 + 使用量)。常時起動の小さなサービス 1 つなら少額だが、Usage タブで確認を |

## 5. (任意) GitHub Actions で Godot の書き出しを自動化

毎回手元で書き出してコミットする代わりに、push 時に GitHub Actions で Godot をヘッドレス実行して `build/web` を作ることもできます
(Godot 本体とエクスポートテンプレート約 1GB をダウンロードするため 3〜5 分かかる)。PoC の段階では手元書き出し + コミットで十分です。
