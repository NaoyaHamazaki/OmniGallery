"""BGM と効果音を合成して godot/audio/*.wav に書き出す (標準ライブラリのみ。ライセンスフリーの自作音源)。

    python tools/make_audio.py
"""

from __future__ import annotations

import math
import random
import struct
import wave
from pathlib import Path

RATE = 22050
OUT = Path(__file__).resolve().parent.parent / "godot" / "audio"


def note(name: str) -> float:
    names = {"C": -9, "D": -7, "E": -5, "F": -4, "G": -2, "A": 0, "B": 2}
    semis = names[name[0]] + (12 * (int(name[-1]) - 4))
    return 440.0 * 2 ** (semis / 12)


def save(name: str, samples: list[float], peak: float = 0.6) -> None:
    m = max(abs(s) for s in samples) or 1.0
    k = peak / m
    OUT.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUT / f"{name}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s * k)) * 32767)) for s in samples))
    print(f"{name}.wav  {len(samples) / RATE:.1f}s")


def bell(buf: list[float], start: float, freq: float, amp: float, decay: float, length: float) -> None:
    s0 = int(start * RATE)
    for i in range(int(length * RATE)):
        t = i / RATE
        env = math.exp(-t / decay) * min(1.0, t / 0.004)
        v = (math.sin(2 * math.pi * freq * t) + 0.35 * math.sin(2 * math.pi * freq * 2.76 * t) * math.exp(-t * 3)
             + 0.15 * math.sin(2 * math.pi * freq * 5.4 * t) * math.exp(-t * 6))
        j = s0 + i
        if j < len(buf):
            buf[j] += v * env * amp


def lowpass(buf: list[float], a: float) -> list[float]:
    out, y = [], 0.0
    for x in buf:
        y += a * (x - y)
        out.append(y)
    return out


def make_bgm() -> None:
    """やわらかいパッドのコード進行 + まばらなベル。32 秒でシームレスにループする。"""
    seg = 8.0
    chords = [
        ["C3", "E3", "G3", "B3", "D4"],
        ["A2", "C3", "E3", "G3", "B3"],
        ["F2", "A2", "C3", "E3", "G3"],
        ["G2", "C3", "D3", "E3", "A3"],
    ]
    total = int(seg * len(chords) * RATE)
    buf = [0.0] * total
    for ci, chord in enumerate(chords):
        start = ci * seg
        dur = seg + 3.0  # 次のコードと重ねる
        n = int(dur * RATE)
        s0 = int(start * RATE)
        freqs = [note(x) for x in chord]
        for i in range(n):
            t = i / RATE
            env = min(1.0, t / 2.5) * min(1.0, max(0.0, (dur - t) / 3.0))
            v = 0.0
            for f in freqs:
                v += math.sin(2 * math.pi * f * t) + 0.6 * math.sin(2 * math.pi * (f + 0.18) * t)
                v += 0.12 * math.sin(2 * math.pi * f * 2 * t)
            buf[(s0 + i) % total] += v * env * 0.05  # 末尾は先頭に回り込ませてループを滑らかに
    rnd = random.Random(7)
    melody = ["E5", "G5", "A5", "C6", "D5", "G5", "E5", "A5"]
    t = 1.5
    while t < seg * len(chords) - 2:
        bell(buf, t, note(rnd.choice(melody)), 0.10, 1.4, 3.0)
        t += rnd.choice([2.5, 3.0, 3.5, 4.0])
    # 簡易リバーブ (フィードバックディレイ、ループ境界をまたいで回り込む)
    for d, g in ((int(0.37 * RATE), 0.32), (int(0.53 * RATE), 0.22)):
        for i in range(total * 2):
            j = i % total
            buf[j] += buf[(j - d) % total] * g * (1 if i < total else 0.5)
    save("bgm_gallery", lowpass(buf, 0.35), 0.55)


def make_sfx() -> None:
    rnd = random.Random(1)
    # 足音: 低いドンと短いノイズ
    n = int(0.11 * RATE)
    step = []
    for i in range(n):
        t = i / RATE
        step.append(math.sin(2 * math.pi * 85 * t) * math.exp(-t * 40) * 0.8 + (rnd.random() * 2 - 1) * math.exp(-t * 70) * 0.5)
    save("step", lowpass(step, 0.25), 0.5)
    # モーダルを開く: 2音のチャイム
    buf = [0.0] * int(1.0 * RATE)
    bell(buf, 0.0, note("G5"), 0.5, 0.35, 1.0)
    bell(buf, 0.09, note("D6"), 0.4, 0.4, 0.9)
    save("ui_open", buf, 0.45)
    # 閉じる: 低めの短いベル
    buf = [0.0] * int(0.5 * RATE)
    bell(buf, 0.0, note("D5"), 0.5, 0.18, 0.5)
    save("ui_close", buf, 0.35)
    # エレベーター到着: ポーン
    buf = [0.0] * int(2.0 * RATE)
    bell(buf, 0.0, note("E6"), 0.5, 0.8, 2.0)
    bell(buf, 0.45, note("C6"), 0.5, 0.9, 1.5)
    save("ding", buf, 0.5)
    # 自動ドア: こもったスライド音
    n = int(1.1 * RATE)
    door = []
    for i in range(n):
        t = i / n
        door.append((rnd.random() * 2 - 1) * math.sin(math.pi * t) ** 1.5 * 0.6 + math.sin(2 * math.pi * 55 * i / RATE) * 0.15 * math.sin(math.pi * t))
    save("door", lowpass(lowpass(door, 0.06), 0.1), 0.45)


if __name__ == "__main__":
    make_bgm()
    make_sfx()
