@echo off
setlocal
title OmniGallery Server
cd /d "%~dp0backend"

rem ---- 初回のみ: 仮想環境の作成とパッケージのインストール ----
if exist ".venv\Scripts\python.exe" goto :deps
echo [setup] 仮想環境を作成しています...
python -m venv .venv
if errorlevel 1 goto :error
".venv\Scripts\python.exe" -m pip install -r requirements.txt
if errorlevel 1 goto :error

:deps
rem スマホ確認用 HTTPS の証明書を作るパッケージ (入っていれば何もしない)
".venv\Scripts\python.exe" -m pip install -q -r requirements-local.txt > nul 2>&1

if exist "..\godot\build\web\index.html" goto :start
echo.
echo [注意] Godot の Web エクスポートがまだありません: godot\build\web\index.html
echo        Godot で「プロジェクト → エクスポート → Web」を実行してください。

:start
echo.
echo ============================================================
echo  OmniGallery を起動します  (終了するにはこの画面で Ctrl+C)
echo.
echo  スマホは同じ Wi-Fi で、下に表示される https の URL を開いてください。
echo  初回は「安全ではない接続」の警告が出るので
echo  「詳細」→「アクセスする」(iPhone は「このWebサイトを閲覧」) で進みます。
echo  ※初回は Windows ファイアウォールの許可ダイアログが出たら「許可」
echo ============================================================

rem サーバーが立ち上がるのを少し待ってからブラウザを開く
start "" /b cmd /c "ping -n 4 127.0.0.1 > nul & start http://127.0.0.1:8000/"

".venv\Scripts\python.exe" run_server.py
goto :eof

:error
echo.
echo [エラー] セットアップに失敗しました。Python 3.10 以降がインストールされているか確認してください。
pause