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

<!-- hq:start -->
## Штаб hq

Задачи, решения и память по этому проекту живут в штабе `D:/projects/my_projects/hq`, карточка — `projects/tts-overlay/README.md`.

- **Что в работе** — раздел «Открытые задачи» в карточке и файлы `projects/tts-overlay/tasks/<номер>-<slug>.md`. Это зеркало GitHub Issues: руками не правь, оно пересобирается.
- **Что уже решали** — «Память решений» в карточке и разборы в `projects/tts-overlay/memory/`. Упёрся или задача похожа на прошлую — сперва посмотри туда, а не решай заново.
- **Что было в прошлых сессиях** — выжимки в `projects/tts-overlay/sessions/`: их сохраняют хуки при сжатии и сбросе контекста. Перед новой задачей посмотри выжимки по теме — номер задачи, `topic` и `keywords` во frontmatter.
- **Задача** — один GitHub issue с категорией `bug` или `enhancement` и проверяемым условием готовности. Заводит его человек командой `/relay`; без этого issue не создавай. В `Done` переводит только человек: слиянием PR или словом «принято».
- **Где человеку не хватило знаний** — путаница терминов, «не знаю» на вопрос специалиста — запиши тему для изучения: `relay learn add` (правила — в скилле `relay`).

## Agent skills

Скиллы Мэтта Покока (`/wayfinder`, `/grilling`, `/to-spec`, `/to-tickets`, `/implement-spec`, `/triage` и другие) работают с трекером штаба так.

### Issue tracker

Задачи этого проекта — GitHub Issues в `VladPatr96/tts-overlay`. Все команды `gh` — с `-R VladPatr96/tts-overlay`. PRs as a request surface: no.

- **Задача** — issue с категорией `bug` или `enhancement`; её заводит человек командой `/relay`. Сам задачу не создавай.
- **Спецификация** (`/to-spec`, «publish to the issue tracker») — не новый issue, а тело задачи, из которой идёт работа: `node "D:/projects/my_projects/hq/skills/relay/scripts/relay.mjs" map <номер> --body <файл.md> --spec`: флаг ставит пометку спецификации, по ней relay подсказывает следующий шаг. Роль `needs-triage` у задачи меняется на `ready-for-agent`.
- **Тикеты** (`/to-tickets`) — sub-issues задачи, без категории `bug`/`enhancement`: на доску и в таблицу задач не попадают.
- **Wayfinding** (`/wayfinder`) — карта — сама задача: ставь на неё `wayfinder:map`, области — её sub-issues с `wayfinder:grilling|research|prototype|task`, блокировки — родные зависимости GitHub, захват — назначение исполнителя.
- **Закрытие** — задачу (issue с категорией) сам не закрывай: её закрывает слияние PR человеком (`Closes #<номер>` в описании PR) или человек словом «принято» (`/relay принято`). Тикеты и области закрывать можно. Последний шаг `/implement-spec` — PR готов к ревью, а не закрытие задачи.
- **Состояние** — меток состояния нет: назначен исполнитель — в работе; готовый к ревью PR или поле доски «На приёмке» — на приёмке; закрыт — Done.

### Triage labels

Стандартные роли, строки совпадают с именами: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`.

### Domain docs

Single-context: `GLOSSARY.md` в корне репозитория, ADR — `docs/adr/`.
<!-- hq:end -->
