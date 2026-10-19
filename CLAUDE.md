# tts-overlay

Оверлей для Windows: выделяешь текст в любой программе, жмёшь горячую клавишу — текст озвучивается. Один скрипт на PowerShell 7 + WPF, без сборки и установщиков.

## Устройство

| Файл | Что делает |
|---|---|
| `tts-overlay.ps1` | всё приложение: оверлей, хоткеи, перехват выделения, очередь кусков, кэш, счётчики затрат, панель `⚙` |
| `lib-text.ps1` | подготовка текста перед синтезом: числа, даты, деньги, дроби, словарь произношения, сборка SSML |
| `edge/edge-worker.py` | воркер Edge TTS: DRM-токен, параллельные попытки, mp3 → WAV |
| `silero/silero-worker.py` | воркер Silero: модель в памяти, автоударения и «ё» |
| `sapi/sapi-speak.ps1` | синтез SAPI 5 в отдельном процессе |
| `install.ps1`, `start.cmd`, `stop-overlay.ps1` | автозапуск, запуск, остановка |
| `pronounce.json` | словарь произношения (создаётся автоматически) |

## Правила

- **Ключи не в репозитории.** `config.json` в `.gitignore`; шаблон — `config.example.json`. Никаких реальных ключей в коде, README и issue.
- **`config.json`, `usage.json`, `cache/`, `spool/`, логи** — runtime-состояние, в git не идёт.
- **Модели и бинарники** (`piper/app/`, `piper/voices/*.onnx`, `silero/*.pt`) — тоже не в git: они большие и лицензируются отдельно.
- **Файлы в `edge/` кроме `edge-worker.py` — вендорские**: `drm.py`, `constants.py`, `exceptions.py` скопированы из [edge-tts](https://github.com/rany2/edge-tts) (LGPL-3.0), потому что опубликованный 7.2.7 отдаёт 403. Не править их без нужды, при правке — держать лицензию (`edge/LICENSE.edge-tts.txt`).
- **Пути в коде — относительные** (через `$Root` в PowerShell и `os.path.dirname(__file__)` в Python). Абсолютные пути живут только в `config.json`.
- **Стиль PowerShell**: `$ErrorActionPreference = 'Stop'`, функции с `Verb-Noun`, логи через `Write-Log` в `tts-overlay.log`.
- **Изменения в логике синтеза** проверяются на слух и по логу: `pwsh -File tts-overlay.ps1 -Say "проверка"`, затем смотреть `tts-overlay.log`.
- **Перед правкой оверлея** остановить процесс: `pwsh -File stop-overlay.ps1` (иначе старый процесс перезапишет файлы).

## Проверка после правки

```powershell
pwsh -File stop-overlay.ps1
pwsh -File tts-overlay.ps1          # запустить
pwsh -File tts-overlay.ps1 -Say "Проверка произношения: API, 16.10.2026, 1500 рублей"
Get-Content tts-overlay.log -Tail 20
pwsh -File stop-overlay.ps1
```

## Лицензия

MIT (см. `LICENSE`), сторонние компоненты — в `NOTICE.md`.
