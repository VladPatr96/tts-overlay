# Сторонние компоненты

Сам виджет — MIT (см. `LICENSE`). Ниже — что взято со стороны.

## edge/ — файлы из проекта edge-tts

`edge/drm.py`, `edge/constants.py`, `edge/exceptions.py`, `edge/__init__.py` —
копии из [rany2/edge-tts](https://github.com/rany2/edge-tts) (ветка `master`).
Лицензия проекта — **LGPL-3.0**, текст лежит в `edge/LICENSE.edge-tts.txt`.

Зачем они здесь: опубликованный пакет edge-tts 7.2.7 отдаёт 403 на рукопожатии
с сервисом Microsoft. Файлы из `master` содержат новый формат DRM-токена
(`Sec-MS-GEC` версии 2), который сервис принимает. Изменения вносятся только
в `edge/edge-worker.py` — сам `edge_tts` ставится обычным `pip install edge-tts`.

Пакет `edge-tts` (LGPL-3.0) и `miniaudio` (MIT) используются как обычные
зависимости — в репозиторий не копируются.

## Движки синтеза

| Что | Лицензия | Как получено |
| --- | --- | --- |
| Silero v5 | MIT | `pip install silero` + модель `v5_ru.pt` (в репозиторий не входит) |
| Piper | MIT | бинарник и голоса с [HuggingFace](https://huggingface.co/rhasspy/piper-voices) (в репозиторий не входят) |
| PyTorch | BSD-3-Clause | `pip install torch` (только для Silero) |
| Яндекс SpeechKit | коммерческий API | ключ пользователя |
| OpenRouter | коммерческий API | ключ пользователя |
| faster-whisper | MIT | `pip install faster-whisper`; модель Whisper качается в кэш Hugging Face при первом запуске (в репозиторий не входит) |
| sounddevice | MIT | `pip install sounddevice` (запись с микрофона для распознавания) |
| Edge TTS | неофициальный эндпоинт Microsoft | используется как есть, бесплатно, без гарантий |

Модели и бинарники намеренно не лежат в репозитории — они большие и лицензируются отдельно.
