import os
import sys
import numpy as np
import torch
from silero import silero_tts

TEXT = "Проверка: в тексте есть английские слова OpenRouter и CPU, и модель должна их прочитать."
CANDIDATES = {
    "v5_ru": ["eugene", "kseniya", "aidar", "baya", "xenia"],
    "v5_6_ru": ["eugene", "kseniya", "aidar", "baya", "xenia"],
    "v5_cis_base": ["ru_eugene", "eugene", "ru_aidar", "aidar", "ru_kseniya", "kseniya"],
}

model_name = sys.argv[1]
out_path = sys.argv[2]

model = None
speaker = None
for name in CANDIDATES.get(model_name, ["eugene"]):
    try:
        m, _ = silero_tts(language="ru", speaker=model_name)
        audio = m.apply_tts(text="проверка", speaker=name, sample_rate=48000)
        model = m
        speaker = name
        break
    except Exception:
        continue

if model is None:
    sys.stdout.write("FAIL\n")
    sys.exit(1)

audio = model.apply_tts(text=TEXT, speaker=speaker, sample_rate=48000)
samples = audio.detach().cpu().numpy()
pcm = (samples * 32767).astype("int16")
with open(out_path, "wb") as out:
    out.write(pcm.tobytes())
sys.stdout.write("%s|%s|%.2f\n" % (model_name, speaker, len(pcm) / 2 / 48000))
