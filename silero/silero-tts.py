import sys
import torch
from silero import silero_tts

MODEL_SPEAKER = "v5_ru"
SPEAKERS = ["aidar", "baya", "kseniya", "xenia", "eugene"]
MAX_CHARS = 400

raw = sys.stdin.buffer.read()
if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
    text = raw.decode("utf-16")
else:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        text = raw.decode("cp1251", errors="replace")

speaker = sys.argv[1] if len(sys.argv) > 1 else "kseniya"
if speaker not in SPEAKERS:
    speaker = "kseniya"

text = text.strip()
if not text:
    sys.exit(0)

model, _ = silero_tts(language="ru", speaker=MODEL_SPEAKER)

pieces = []
for start in range(0, len(text), MAX_CHARS):
    part = text[start:start + MAX_CHARS].strip()
    if not part:
        continue
    audio = model.apply_tts(text=part, speaker=speaker, sample_rate=48000)
    pieces.append(audio.detach().cpu().numpy())

import numpy as np
samples = np.concatenate(pieces) if pieces else np.zeros(0, dtype="float32")
pcm = (samples * 32767).astype("int16")
sys.stdout.buffer.write(pcm.tobytes())
sys.stdout.buffer.flush()
