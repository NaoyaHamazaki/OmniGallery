"""ローカル起動用 (起動用.bat から呼ばれる)。

    HTTP  : http://127.0.0.1:8000/          PC 用 (localhost は「安全なコンテキスト」扱いなのでそのまま動く)
    HTTPS : https://<LAN の IP>:8443/        スマホ用 (自己署名証明書を自動生成)

Godot 4.7 の Web ビルドは「安全なコンテキスト (HTTPS か localhost)」でしか起動しないため、
同じ Wi-Fi のスマホから http://192.168.x.x で開くとエラーになる。そこで HTTPS も同時に立ち上げる。
スマホでは最初に「この接続ではプライバシーが保護されません」等の警告が出るので、詳細 → アクセスする で進む。
本番 (Railway) は Railway が正式な HTTPS を提供するので、このスクリプトは使わない。
"""

from __future__ import annotations

import asyncio
import datetime
import ipaddress
import os
import socket
from pathlib import Path

import uvicorn

BASE = Path(__file__).resolve().parent
CERT_DIR = BASE / "data" / "certs"
HTTP_PORT = int(os.getenv("OMNI_HTTP_PORT", "8000"))
HTTPS_PORT = int(os.getenv("OMNI_HTTPS_PORT", "8443"))


def local_ips() -> list[str]:
    ips = {"127.0.0.1"}
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ips.add(info[4][0])
    except OSError:
        pass
    try:  # 既定ルートの IP (パケットは送信しない)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))
            ips.add(s.getsockname()[0])
    except OSError:
        pass
    return sorted(i for i in ips if not i.startswith("169.254."))


def ensure_cert(ips: list[str]) -> tuple[Path, Path] | None:
    """LAN の IP を含む自己署名証明書を用意する (IP が変わったら作り直す)。"""
    try:
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
    except ImportError:
        print("[https] cryptography が無いため HTTPS は起動しません (pip install cryptography)")
        return None
    cert, key, stamp = CERT_DIR / "cert.pem", CERT_DIR / "key.pem", CERT_DIR / "ips.txt"
    if cert.exists() and key.exists() and stamp.exists() and stamp.read_text() == ",".join(ips):
        return cert, key
    CERT_DIR.mkdir(parents=True, exist_ok=True)
    pkey = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "OmniGallery Local")])
    now = datetime.datetime.now(datetime.timezone.utc)
    san = [x509.DNSName("localhost")] + [x509.IPAddress(ipaddress.ip_address(i)) for i in ips]
    crt = (
        x509.CertificateBuilder()
        .subject_name(name).issuer_name(name)
        .public_key(pkey.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(now + datetime.timedelta(days=397))  # iOS の上限 (825日) 未満
        .add_extension(x509.SubjectAlternativeName(san), critical=False)
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
        .sign(pkey, hashes.SHA256())
    )
    key.write_bytes(pkey.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL,
                                       serialization.NoEncryption()))
    cert.write_bytes(crt.public_bytes(serialization.Encoding.PEM))
    stamp.write_text(",".join(ips))
    print("[https] 自己署名証明書を作成しました:", ", ".join(ips))
    return cert, key


async def main() -> None:
    ips = local_ips()
    pair = ensure_cert(ips)
    servers = [uvicorn.Server(uvicorn.Config("main:app", host="0.0.0.0", port=HTTP_PORT))]
    if pair:
        servers.append(uvicorn.Server(uvicorn.Config(
            "main:app", host="0.0.0.0", port=HTTPS_PORT, ssl_certfile=str(pair[0]), ssl_keyfile=str(pair[1]))))
    print()
    print(f"  PC     : http://127.0.0.1:{HTTP_PORT}/")
    if pair:
        for ip in ips:
            if ip != "127.0.0.1":
                print(f"  スマホ : https://{ip}:{HTTPS_PORT}/   (警告が出たら「詳細」→「アクセスする」)")
    print()
    tasks = [asyncio.create_task(_serve(s)) for s in servers]
    _, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    for s in servers:  # Ctrl+C (またはポート使用中で起動失敗) でどちらかが止まったら、もう片方も止める
        s.should_exit = True
    await asyncio.gather(*pending, return_exceptions=True)


async def _serve(server: uvicorn.Server) -> None:
    try:
        await server.serve()
    except SystemExit:
        print(f"[server] port {server.config.port} を開けませんでした (別のサーバーが起動中ではありませんか?)")


if __name__ == "__main__":
    asyncio.run(main())
