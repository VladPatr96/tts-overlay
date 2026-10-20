import os
import sys
import numpy as np
import torch
from silero import silero_tts

SPEAKERS = ["aidar", "baya", "kseniya", "xenia", "eugene"]
MAX_CHARS = 400

MODEL_SPEAKER = sys.argv[1] if len(sys.argv) > 1 else "v5_ru"

model, _ = silero_tts(language="ru", speaker=MODEL_SPEAKER)
sys.stdout.write("READY\n")
sys.stdout.flush()


def fail(out_path, reason):
    """Ответ об ошибке: пустой .pcm — оверлей видит файл и уходит в fallback без таймаута."""
    try:
        with open(out_path, "wb") as dst:
            dst.write(b"")
    except Exception:
        pass
    sys.stdout.write("ERR %s\n" % reason)
    sys.stdout.flush()


while True:
    line = sys.stdin.readline()
    if not line:
        break
    line = line.strip()
    if not line:
        continue
    parts = line.split("|")
    if len(parts) < 2:
        continue
    speaker, req_path = parts[0], parts[1]
    put_accent = True
    put_yo = True
    if len(parts) > 2 and parts[2]:
        put_accent = parts[2] == "1"
    if len(parts) > 3 and parts[3]:
        put_yo = parts[3] == "1"
    if speaker not in SPEAKERS:
        speaker = "kseniya"
    out_path = os.path.splitext(req_path)[0] + ".pcm"
    try:
        with open(req_path, "r", encoding="utf-8") as src:
            text = src.read().strip()
    except Exception as exc:
        # оверлей ждёт .pcm — пустой файл сразу уводит его в запасной движок
        fail(out_path, "не прочитан запрос: %s" % exc)
        continue
    if not text:
        fail(out_path, "пустой текст")
        continue

    pieces = []
    for start in range(0, len(text), MAX_CHARS):
        part = text[start:start + MAX_CHARS].strip()
        if not part:
            continue
        try:
            audio = model.apply_tts(
                text=part,
                speaker=speaker,
                sample_rate=48000,
                put_accent=put_accent,
                put_yo=put_yo,
            )
        except TypeError:
            # старая версия API без put_accent/put_yo
            audio = model.apply_tts(text=part, speaker=speaker, sample_rate=48000)
        except Exception as exc:
            sys.stdout.write("ERR %s\n" % exc)
            sys.stdout.flush()
            pieces = []
            break
        pieces.append(audio.detach().cpu().numpy())

    if not pieces:
        fail(out_path, "нет звука")
        continue
    try:
        samples = np.concatenate(pieces)
        pcm = (samples * 32767).astype("int16")
        with open(out_path, "wb") as dst:
            dst.write(pcm.tobytes())
    except Exception as exc:
        fail(out_path, "не записан звук: %s" % exc)
        continue
    sys.stdout.write("OK\n")
    sys.stdout.flush()
