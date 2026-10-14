# claude-statusline

Статус-строка для [Claude Code](https://code.claude.com/docs/en/statusline) — основная строка под промптом и строки саб-агентов в панели агентов.

```
Opus 5.5 [xhigh]  |  claude-statusline  |  ctx:██████░░░░ 55% (110k/200k)  |  5h:████░░ 70% ×1.4 (59m) · 7d:██░░░░ 30% (3d11h)
```

## Файлы

| Файл | Что делает |
| :- | :- |
| `statusline.sh` | Основная строка (`statusLine` в settings.json) |
| `subagent-statusline.sh` | Строки саб-агентов (`subagentStatusLine` в settings.json) |

Нужны `bash` 4+ (на Windows — Git Bash) и `jq`.

## Основная строка

`модель [effort] | папка | контекст | 5h · 7d лимиты`

### Модель и уровень думания

`Opus 5.5 [xhigh]` — модель и `effort`. Хвост вида `(1M context)` срезается: размер окна и так виден в блоке контекста. Если thinking выключен — `[no think]`.

### Папка

`claude-statusline` — имя текущей папки (`workspace.current_dir`), синим.

### Контекст

`ctx:██████░░░░ 55% (110k/200k)` — заполнение окна и сколько токенов из скольки.

Цвет берётся как **худший** из двух критериев — процент окна и абсолютное число токенов:

| Уровень | % окна | или токенов | Что делать |
| :- | :- | :- | :- |
| 🟢 зелёный | < 50% | < 400k | всё ок |
| 🟡 жёлтый | 50–70% | 400–600k | пора задуматься о `/compact` (или `/clear`, если задача закончена) |
| 🔴 красный | 70–85% | 600–800k | сжимать сейчас |
| 🟥 **⚠ 87% /compact** (белый на красном фоне) | ≥ 85% | ≥ 800k | критично: вот-вот сработает авто-компакт |

Почему так:

- **Процент** нужен для окна 200k: авто-компакт там срабатывает примерно на ~93% (окно минус ~13k под ответ). Сжимать вручную лучше заранее — авто-компакт случается в момент, когда модель хуже всего понимает, что пригодится дальше, и суммаризирует наугад. Распространённая рекомендация сообщества — начинать думать о компакте после 50–60%.
- **Абсолютные токены** нужны для окна 1M: там пороги 400k / 600k / 800k (40/60/80%). Официального порога для 1M нет — Anthropic заявляет, что Opus держит точность на всём окне ([78.3% MRCR v2 на 1M](https://claude.com/blog/1m-context-ga)). Но длинный контекст — это дороже, медленнее и больше шума от старых задач («context rot», по словам сотрудника Anthropic заметный с ~300–400k), поэтому на 40% стоит задуматься о `/compact` или `/clear`, а критично — только ближе к концу окна.

Процент берётся из `context_window.used_percentage` (считается только по input-токенам, как и в самом Claude Code).

### Лимиты 5h и 7d

`5h:████░░ 70% ×1.4 (59m)` — использовано %, кратность перерасхода, время до сброса.

Цвет зависит не от самого процента, а от **темпа** расхода. Темп — во сколько раз текущая средняя скорость больше допустимой:

```
текущая скорость  = использовано% / прошло времени окна
допустимая        = осталось%     / осталось времени до сброса
темп (×)          = текущая / допустимая
```

Пример: в 5-часовом окне ровный расход — 100% / 300 мин ≈ 0.33%/мин. Если за 2 часа ушло 60%, скорость 0.5%/мин, а на оставшиеся 40% за 3 часа можно тратить 0.22%/мин → темп ×2.25: такими темпами лимит кончится до сброса.

| Темп | Цвет |
| :- | :- |
| < ×1.0 | 🟢 укладываешься (множитель не показывается) |
| ×1.0–1.5 | 🟡 упрёшься в лимит до сброса |
| ×1.5–2.5 | 🔴 сильно быстрее, чем можно |
| ≥ ×2.5 или использовано ≥ 95% | 🟥 критично |

Дополнительно: использовано ≥ 80% — минимум красный, как бы медленно ни тратилось.

Первые минуты окна считаются так, будто прошло не меньше 15 минут (для 7d — 6 часов), иначе один запрос сразу после сброса давал бы гигантский множитель.

### Пороги через переменные окружения

Все пороги можно поменять через `env` в settings.json:

| Переменная | По умолчанию |
| :- | :- |
| `CTX_WARN_PCT` / `CTX_HIGH_PCT` / `CTX_CRIT_PCT` | 50 / 70 / 85 |
| `CTX_WARN_TOK` / `CTX_HIGH_TOK` / `CTX_CRIT_TOK` | 400000 / 600000 / 800000 |
| `PACE_WARN` / `PACE_HIGH` / `PACE_CRIT` (×100) | 100 / 150 / 250 |
| `NO_COLOR` | выключает цвета |

## Строки саб-агентов

```
●  Explore  opus-5.5 [high]  ctx:█░░░░░ 23% (234k/1M)  1m37s  · Searching src/ for login handlers…
✔  reviewer  5k tok  32s  · Review
✘  general-purpose  haiku-5.5  ctx:█████░ 90% (180k/200k)  1h6m  · x
```

Статус (`●` работает, `✔` готово, `✘` упал, `■` убит), имя или тип агента, модель и effort, контекст агента с теми же цветовыми зонами, сколько работает, и текущая задача — обрезается по ширине терминала.

## Установка

### Вариант 1: сказать Claude

Открой Claude Code в этой папке и напиши:

> Установи статус-лайн из этого проекта: скопируй `statusline.sh` и `subagent-statusline.sh` в `~/.claude/` и пропиши `statusLine` и `subagentStatusLine` в `~/.claude/settings.json`, как в README.

### Вариант 2: вручную

1. Скопировать скрипты:

   ```bash
   cp statusline.sh subagent-statusline.sh ~/.claude/
   chmod +x ~/.claude/statusline.sh ~/.claude/subagent-statusline.sh
   ```

2. Добавить в `~/.claude/settings.json`:

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "bash ~/.claude/statusline.sh",
       "padding": 0,
       "refreshInterval": 30
     },
     "subagentStatusLine": {
       "type": "command",
       "command": "bash ~/.claude/subagent-statusline.sh"
     }
   }
   ```

   `refreshInterval` (секунды) нужен, чтобы таймеры до сброса лимитов и темп обновлялись, пока сессия простаивает. Без него строка перерисовывается только по событиям.

3. Перезапускать Claude Code не обязательно — статус-строка подхватывается при следующем обновлении.

Альтернатива без копирования — указать путь прямо на файлы в этой папке, тогда правки в проекте сразу видны в Claude Code:

```json
"command": "bash \"/c/Users/<you>/path/to/claude-statusline/statusline.sh\""
```

## Проверка

```bash
echo '{"model":{"display_name":"Opus 5.5 (1M context)"},"effort":{"level":"high"},"context_window":{"used_percentage":55,"total_input_tokens":110000,"context_window_size":200000}}' | bash statusline.sh

echo '{"columns":120,"tasks":[{"id":"a","agentType":"Explore","status":"running","label":"Searching","startTime":0,"model":"claude-opus-5-5","contextWindowSize":200000,"tokenCount":50000}]}' | bash subagent-statusline.sh
```

## Источники

- [Документация Claude Code: status line](https://code.claude.com/docs/en/statusline) — поля JSON, `subagentStatusLine`, `refreshInterval`
- [Claude Code auto-compact: что его вызывает](https://www.morphllm.com/claude-code-auto-compact) — порог ~187k из 200k
- [Auto-compact на ~420k в окне 1M](https://claudeissues.com/issue/40757-auto-compact-triggers-at-420k-tokens-despite-opus-having-1m-context-window-thres)
- [Context rot с ~300–400k токенов (со слов сотрудника Anthropic, пересказ)](https://youmind.com/landing/x-viral-articles/claude-code-internal-best-practices)
- [1M context GA: точность на всём окне](https://claude.com/blog/1m-context-ga)
- [CLAUDE_AUTOCOMPACT_PCT_OVERRIDE](https://github.com/anthropics/claude-code/issues/11819)
