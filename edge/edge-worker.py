"""Воркер Edge TTS: синтезирует речь и кладёт WAV.

Сервис Microsoft отдаёт звук не всегда: часть запросов заканчивается ошибкой
(403 на рукопожатии или «нет звука»). Поэтому делаем несколько попыток,
причём параллельно — берём первую успешную.

Аудио приходит mp3, поэтому декодируем его через miniaudio и отдаём WAV.
"""

import asyncio
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

import edge_tts
import edge_tts.communicate as ec
import miniaudio
from edge.drm import DRM as MasterDRM

# свежий DRM-токен (v2) из исходников edge-tts и версия 2-...
ec.DRM = MasterDRM
ec.SEC_MS_GEC_VERSION = "2-143.0.3650.75"
# свою разметку SSML не экранируем и не режем на части — иначе теги рвутся
ec.escape = lambda s: s
ec.split_text_by_byte_length = lambda text, limit: [text]

LEAD_SECONDS = 0.0
VOICES_FILE = os.path.join(ROOT, "edge", "voices.txt")
PAUSE_FILE = os.path.join(ROOT, "edge", "paused.txt")
LOG_FILE = os.path.join(os.environ.get("TEMP", "."), "edge-worker.log")
ATTEMPTS_IN_PARALLEL = 2
MAX_ROUNDS = 3
TOTAL_BUDGET = 14.0
PAUSE_SECONDS = 180


def log(*a):
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(" ".join(str(x) for x in a) + "\n")
    except Exception:
        pass


def write_wav(path: str, pcm: bytes, rate: int, channels: int = 1, bits: int = 16) -> None:
    block_align = channels * (bits // 8)
    lead = int(rate * block_align * LEAD_SECONDS)
    data_len = len(pcm) + lead
    with open(path, "wb") as f:
        f.write(b"RIFF")
        f.write(struct_pack("<I", 36 + data_len))
        f.write(b"WAVEfmt ")
        f.write(struct_pack("<IHHIIHH", 16, 1, channels, rate, rate * block_align, block_align, bits))
        f.write(b"data")
        f.write(struct_pack("<I", data_len))
        f.write(b"\x00" * lead)
        f.write(pcm)


def struct_pack(fmt: str, *values) -> bytes:
    import struct

    return struct.pack(fmt, *values)


async def one_shot(text: str, voice: str, tmp_path: str, rate: str, pitch: str) -> int:
    """Одна попытка: вернуть размер полученного mp3 (0 — звука не было)."""
    comm = edge_tts.Communicate(text, voice, rate=rate, pitch=pitch)
    total = 0
    with open(tmp_path, "wb") as f:
        async for chunk in comm.stream():
            if chunk["type"] == "audio":
                f.write(chunk["data"])
                total += len(chunk["data"])
    return total


async def one_shot_limited(text: str, voice: str, tmp_path: str, rate: str, pitch: str) -> int:
    # сервис иногда молчит — ограничиваем попытку по времени, чтобы не ждать
    return await asyncio.wait_for(one_shot(text, voice, tmp_path, rate, pitch), timeout=12)


async def attempt_once(text: str, voice: str, out_path: str, rate: str, pitch: str) -> int:
    """Попытка с несколькими параллельными запросами: берём первый успешный."""
    tasks = []
    tmp_of = {}
    for i in range(ATTEMPTS_IN_PARALLEL):
        tmp = f"{out_path}.try{i}.mp3"
        task = asyncio.create_task(one_shot_limited(text, voice, tmp, rate, pitch))
        tmp_of[task] = tmp
        tasks.append(task)
    best = 0
    best_tmp = None
    pending = set(tasks)
    try:
        # asyncio.wait отдаёт сами задачи, поэтому видно, какая попытка завершилась
        while pending:
            done, pending = await asyncio.wait(pending, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                try:
                    size = task.result()
                except Exception:
                    continue
                if size > best:
                    best = size
                    best_tmp = tmp_of[task]
    finally:
        for task in tasks:
            if not task.done():
                task.cancel()
    if best_tmp and os.path.exists(best_tmp):
        decoded = miniaudio.decode_file(best_tmp)
        channels = getattr(decoded, "nchannels", None) or getattr(decoded, "channels", 1)
        write_wav(out_path, decoded.samples.tobytes(), decoded.sample_rate, int(channels))
    for i in range(ATTEMPTS_IN_PARALLEL):
        try:
            os.remove(f"{out_path}.try{i}.mp3")
        except OSError:
            pass
    return best


def pause_edge(seconds: int) -> None:
    """Сервис Microsoft периодически перестаёт отдавать звук — делаем паузу,
    чтобы не тратить время на заведомо бесполезные попытки."""
    try:
        tmp = PAUSE_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("%.0f" % (time.time() + seconds))
        os.replace(tmp, PAUSE_FILE)
    except Exception:
        pass


def resume_edge() -> None:
    for path in (PAUSE_FILE, PAUSE_FILE + ".tmp"):
        try:
            if os.path.exists(path):
                os.remove(path)
        except Exception:
            pass


def edge_paused() -> bool:
    """Пауза активна? Битый или пустой файл — просто убираем."""
    try:
        if not os.path.exists(PAUSE_FILE):
            return False
        with open(PAUSE_FILE, "r", encoding="utf-8") as f:
            raw = f.read().strip()
        if not raw:
            resume_edge()
            return False
        until = float(raw)
        if time.time() >= until:
            resume_edge()
            return False
        return True
    except Exception:
        resume_edge()
        return False


async def synth(text: str, voice: str, out_path: str, as_ssml: bool = False,
                rate: str = "+0%", pitch: str = "+0Hz") -> None:
    if edge_paused():
        raise RuntimeError("Edge на паузе: сервис не отвечает")
    started = time.time()
    last_error = None
    for round_no in range(MAX_ROUNDS):
        try:
            size = await attempt_once(text, voice, out_path, rate, pitch)
            if size > 0:
                resume_edge()
                log("готово:", out_path, size, "байт")
                return
            last_error = RuntimeError("звука не пришло")
        except Exception as exc:
            last_error = exc
        log("раунд", round_no + 1, "не вышел:", type(last_error).__name__, last_error)
        # сервис молчит волнами — дальше ждать бесполезно, отдаём ошибку сразу
        if time.time() - started >= TOTAL_BUDGET:
            break
        await asyncio.sleep(0.4)
    pause_edge(PAUSE_SECONDS)
    raise last_error if last_error else RuntimeError("не удалось синтезировать")


async def warmup() -> None:
    """Прогрев: короткий запрос при старте, чтобы первый реальный был быстрее."""
    try:
        size = await attempt_once("Готов.", "ru-RU-DmitryNeural",
                                 os.path.join(os.environ.get("TEMP", "."), "edge-warmup.wav"), "+0%", "+0Hz")
        if size > 0:
            log("прогрев выполнен")
        else:
            pause_edge(PAUSE_SECONDS)
            log("прогрев: звука нет, ставлю паузу")
    except Exception as exc:
        pause_edge(PAUSE_SECONDS)
        log("прогрев не удался:", type(exc).__name__, exc)


async def save_voices() -> None:
    try:
        voices = await edge_tts.list_voices()
        ru = sorted(v["ShortName"] for v in voices if v["Locale"].lower().startswith("ru"))
        with open(VOICES_FILE, "w", encoding="utf-8") as f:
            f.write("\n".join(ru))
        log("голоса:", ru)
    except Exception as exc:
        log("не удалось получить список голосов:", exc)


async def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        await synth("Привет. Это самопроверка Edge TTS.", "ru-RU-DmitryNeural",
                   os.path.join(os.environ.get("TEMP", "."), "edge-selftest.wav"))
        print("OK", flush=True)
        return
    print("READY", flush=True)
    asyncio.create_task(warmup())
    loop = asyncio.get_event_loop()
    while True:
        line = await loop.run_in_executor(None, sys.stdin.readline)
        if not line:
            break
        line = line.strip()
        if not line:
            continue
        parts = line.split("|")
        if len(parts) < 2:
            continue
        voice, req_path = parts[0], parts[1]
        mode = parts[2] if len(parts) > 2 else "text"
        rate = parts[3] if len(parts) > 3 and parts[3] else "+0%"
        pitch = parts[4] if len(parts) > 4 and parts[4] else "+0Hz"
        out_path = os.path.splitext(req_path)[0] + ".wav"
        err_path = req_path + ".err"
        try:
            with open(req_path, "r", encoding="utf-8") as f:
                text = f.read().strip()
            if text:
                await synth(text, voice, out_path, mode == "ssml", rate, pitch)
                if os.path.exists(err_path):
                    os.remove(err_path)
            else:
                with open(err_path, "w", encoding="utf-8") as f:
                    f.write("пустой текст")
        except Exception as exc:
            log("ошибка:", type(exc).__name__, exc)
            try:
                with open(err_path, "w", encoding="utf-8") as f:
                    f.write("%s: %s" % (type(exc).__name__, exc))
            except Exception:
                pass


try:
    asyncio.run(main())
except KeyboardInterrupt:
    pass
