"""stt-worker.py — запись с микрофона и локальное распознавание речи.

Протокол: команды приходят в stdin, ответы уходят в stdout, результаты ложатся
в файлы рядом с записью (PowerShell забирает их в своём таймере, ничего не блокируя).

    rec|<wav>   начать запись
    stop        остановить запись, сохранить WAV, рядом положить <wav>.done
    stt|<wav>   распознать локально (faster-whisper): текст в <wav>.txt,
                маркер готовности — <wav>.ok
    quit        выход

Ошибка всегда пишется в <wav>.err, чтобы вызывающая сторона могла её показать.

Запись: WAV 16 кГц, моно, 16 бит — такой файл понимают и faster-whisper,
и OpenRouter (input_audio, format wav), и Яндекс SpeechKit.
"""

import os
import sys
import threading
import time
import wave

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.abspath(__file__))
LOG_PATH = os.path.join(ROOT, "stt-worker.log")
TARGET_RATE = 16000
CHANNELS = 1

try:
    import sounddevice as sd
except Exception as exc:  # нет portaudio или пакета — запись невозможна
    sd = None
    _SD_ERROR = str(exc)
else:
    _SD_ERROR = ""


def log(message):
    line = "%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), message)
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as handle:
            handle.write(line)
    except Exception:
        pass
    sys.stdout.write(line)
    sys.stdout.flush()


def fail(message):
    """Ошибка команды: пишем в <wav>.err (если путь известен) и в stdout."""
    log("ERR %s" % message)
    path = _pending_err_path or _current_wav
    if path:
        try:
            with open(path + ".err", "w", encoding="utf-8") as handle:
                handle.write(message)
        except Exception:
            pass


_pending_err_path = None
_current_wav = None


def resample(samples, src_rate, dst_rate):
    """Линейная передискретизация int16 (numpy не требуется)."""
    if src_rate == dst_rate or not samples:
        return samples
    import array

    data = array.array("h")
    data.frombytes(samples)
    ratio = src_rate / float(dst_rate)
    count = int(len(data) / ratio)
    out = array.array("h", bytes(count * 2))
    for i in range(count):
        pos = i * ratio
        i0 = int(pos)
        frac = pos - i0
        a = data[i0] if i0 < len(data) else 0
        b = data[i0 + 1] if i0 + 1 < len(data) else a
        out[i] = int(a + (b - a) * frac)
    return out.tobytes()


class Recorder:
    def __init__(self):
        self.lock = threading.Lock()
        self.frames = []
        self.stream = None
        self.path = None
        self.rate = TARGET_RATE

    def start(self, path):
        if sd is None:
            raise RuntimeError("нет sounddevice: %s" % _SD_ERROR)
        with self.lock:
            if self.stream is not None:
                raise RuntimeError("запись уже идёт")
            self.frames = []
            self.path = path
            rate = TARGET_RATE
            try:
                self.stream = self._open(rate)
            except Exception as exc:
                log("микрофон не открылся на %d Гц: %s" % (rate, exc))
                device = self._default_device()
                if device is None:
                    raise
                rate = int(round(sd.query_devices(device)["default_samplerate"]))
                log("пробую устройство %d на %d Гц" % (device, rate))
                self.stream = self._open(rate, device)
            self.rate = rate
            self.stream.start()
            log("запись началась: %s @ %d Гц" % (path, rate))

    @staticmethod
    def _default_device():
        try:
            devices = sd.query_devices()
            for index, info in enumerate(devices):
                if info["max_input_channels"] > 0:
                    return index
        except Exception:
            pass
        return None

    def _open(self, rate, device=None):
        def callback(indata, frames, time_info, status):
            if status:
                log("статус: %s" % status)
            self.frames.append(bytes(indata))

        return sd.RawInputStream(
            samplerate=rate,
            channels=CHANNELS,
            dtype="int16",
            device=device,
            callback=callback,
        )

    def stop(self):
        with self.lock:
            if self.stream is None:
                raise RuntimeError("запись не идёт")
            self.stream.stop()
            self.stream.close()
            self.stream = None
            data = b"".join(self.frames)
            self.frames = []
            path = self.path
            rate = self.rate
        if rate != TARGET_RATE:
            data = resample(data, rate, TARGET_RATE)
        with wave.open(path, "wb") as out:
            out.setnchannels(CHANNELS)
            out.setsampwidth(2)
            out.setframerate(TARGET_RATE)
            out.writeframes(data)
        seconds = len(data) / 2.0 / TARGET_RATE
        log("запись остановлена: %s, %.1f с" % (path, seconds))
        return path, seconds


_MODELS = {}


def get_model(name):
    """Модель faster-whisper грузится один раз и живёт между запросами."""
    if name in _MODELS:
        return _MODELS[name]
    from faster_whisper import WhisperModel

    try:
        model = WhisperModel(name, device="cpu", compute_type="int8", local_files_only=True)
        log("модель %s: локальный кэш" % name)
    except Exception as exc:
        log("модель %s нет в кэше (%s), качаю" % (name, exc))
        model = WhisperModel(name, device="cpu", compute_type="int8")
    _MODELS[name] = model
    return model


def transcribe(path, model_name, language):
    model = get_model(model_name)
    segments, info = model.transcribe(path, language=language or None, vad_filter=True, beam_size=5)
    text = " ".join(segment.text.strip() for segment in segments).strip()
    return text


def warm_up():
    """Фоновая загрузка модели: первая диктовка не ждёт импорт и чтение с диска."""
    name = os.environ.get("STT_MODEL", "base")
    try:
        get_model(name)
        log("модель %s готова" % name)
    except Exception as exc:
        log("модель %s не загрузилась: %s" % (name, exc))


def main():
    global _pending_err_path, _current_wav
    recorder = Recorder()
    log("воркер запущен, порт=%s" % (_SD_ERROR or "ok"))
    sys.stdout.write("READY\n")
    sys.stdout.flush()

    loader = threading.Thread(target=warm_up, daemon=True)
    loader.start()

    for raw in sys.stdin:
        line = raw.strip().lstrip("\ufeff").strip()
        if not line:
            continue
        parts = line.split("|")
        command = parts[0].lower()
        argument = parts[1] if len(parts) > 1 else ""
        _pending_err_path = argument if argument.lower().endswith(".wav") else None

        try:
            if command == "rec":
                _current_wav = argument
                recorder.start(argument)
                sys.stdout.write("REC-STARTED %s\n" % argument)
            elif command == "stop":
                path, seconds = recorder.stop()
                with open(path + ".done", "w", encoding="utf-8") as handle:
                    handle.write("%.3f" % seconds)
                sys.stdout.write("REC %s %.3f\n" % (path, seconds))
            elif command == "stt":
                text = transcribe(argument, os.environ.get("STT_MODEL", "base"), os.environ.get("STT_LANG", "ru"))
                with open(argument + ".txt", "w", encoding="utf-8") as handle:
                    handle.write(text)
                with open(argument + ".ok", "w", encoding="utf-8") as handle:
                    handle.write(text)
                sys.stdout.write("OK %s\n" % (argument + ".txt"))
            elif command == "quit":
                break
            else:
                log("неизвестная команда: %s" % line)
        except Exception as exc:
            fail("%s: %s" % (type(exc).__name__, exc))
        finally:
            sys.stdout.flush()

    log("воркер остановлен")


if __name__ == "__main__":
    main()
