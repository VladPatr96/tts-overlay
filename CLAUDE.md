# tts-overlay

Оверлей для Windows: выделяешь текст в любой программе, жмёшь горячую клавишу — текст озвучивается. PowerShell 7 + WPF: главный скрипт и модули `lib-*.ps1` рядом, без сборки и установщиков. Запуск — всегда `tts-overlay.ps1`.

## Устройство

| Файл | Что делает |
|---|---|
| `tts-overlay.ps1` | главный скрипт: параметры, оверлей, хоткеи, перехват выделения, очередь кусков, кэш, счётчики затрат, панель `⚙`; подключает модули. Части выносятся в `lib-*.ps1` по [ADR 0001](docs/adr/0001-module-layout.md) |
| `lib-core.ps1` | лог (`Write-Log`), конфиг (`Get-DefaultConfig`, `Import-Config`, `Save-Config`), ключ OpenRouter (`Get-ApiKey`) |
| `lib-usage.ps1` | учёт затрат, баланс OpenRouter, курс ЦБ, строки затрат в интерфейсе (`Add-Usage`, `Update-CostLine`, `Refresh-Balance`, `Refresh-Rate`) |
| `lib-providers.ps1` | движки (OpenRouter, Яндекс, Edge, Silero, SAPI, Piper): карта движков `Get-ProviderMap`, запросы, воркеры, голоса, форматы, WAV-утилиты, `Invoke-ProviderFallback` |
| `lib-playback.ps1` | очередь кусков, кэш озвученного, воспроизведение: `Split-Text`, `Get-CachePath`, `Request-More`, `Try-Play-Next`, `Start-Speaking`, `Stop-Speaking`, `Toggle-Pause` |
| `lib-input.ps1` | ввод: горячие клавиши (`Register-Hotkeys`), перехват выделенного (`Get-SelectedText`, `Speak-Selection`), буфер обмена (`Speak-Clipboard`, `Set-ClipboardText`) |
| `lib-stt.ps1` | диктовка: воркер распознавания, запись с микрофона, распознавание (OpenRouter или faster-whisper), результат в буфер (`Start-VoiceRecording`, `Start-VoiceRecognition`, `Update-VoiceState`) |
| `lib-text.ps1` | подготовка текста перед синтезом: числа, даты, деньги, дроби, словарь произношения, сборка SSML |
| `edge/edge-worker.py` | воркер Edge TTS: DRM-токен, параллельные попытки, mp3 → WAV |
| `silero/silero-worker.py` | воркер Silero: модель в памяти, автоударения и «ё» |
| `silero/silero-tts.py`, `silero/compare-models.py` | **оставлены, не используются**: разовый синтез Silero и сравнение моделей; на них указывает только ключ `sileroScript` в конфиге |
| `stt/stt-worker.py` | воркер распознавания: запись с микрофона (`sounddevice`) и локальный faster-whisper |
| `sapi/sapi-speak.ps1` | синтез SAPI 5 в отдельном процессе |
| `install.ps1`, `start.cmd`, `stop-overlay.ps1` | автозапуск, запуск, остановка |
| `pronounce.json` | словарь произношения (создаётся автоматически) |

## Правила

- **Ключи не в репозитории.** `config.json` в `.gitignore`; шаблон — `config.example.json`. Никаких реальных ключей в коде, README и issue.
- **`config.json`, `usage.json`, `cache/`, `spool/`, логи** — runtime-состояние, в git не идёт.
- **Модели и бинарники** (`piper/app/`, `piper/voices/*.onnx`, `silero/*.pt`) — тоже не в git: они большие и лицензируются отдельно.
- **Файлы в `edge/` кроме `edge-worker.py` — вендорские**: `drm.py`, `constants.py`, `exceptions.py` скопированы из [edge-tts](https://github.com/rany2/edge-tts) (LGPL-3.0), потому что опубликованный 7.2.7 отдаёт 403. Не править их без нужды, при правке — держать лицензию (`edge/LICENSE.edge-tts.txt`).
- **Новые функции — в модуль своего слоя** (`lib-*.ps1`), а не в главный скрипт. Модуль — только функции; общее состояние (`$Cfg`, `$script:*`, окно) остаётся в главном скрипте. Новый модуль добавляется в список `foreach ($lib in …)` в начале `tts-overlay.ps1`.
- **Различия движков — в карте `Get-ProviderMap`** (`lib-providers.ps1`), а не в проверках `if ($Cfg.provider -eq …)`. Новый движок — запись в карте + воркер (README, «Как добавить движок»). Сбой движка обрабатывает `Invoke-ProviderFallback`, копий этой логики не заводить.
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

## Документы

- `GLOSSARY.md` — термины проекта (движок, кусок, сессия, воркер, fallback); называй вещи так же в коде и задачах.
- `docs/adr/` — решения: [0001 — модули по слоям](docs/adr/0001-module-layout.md), [0002 — логи воркеров вне `tts-overlay.log`](docs/adr/0002-worker-logs.md).

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
