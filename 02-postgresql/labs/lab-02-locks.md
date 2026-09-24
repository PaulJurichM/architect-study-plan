---
title: "Лаба 2. Блокировки"
parent: "2. PostgreSQL изнутри"
nav_order: 12
---

# Лаба 2. Блокировки

Три сессии: **A**, **B** и **C**. Сессия **C** — наблюдатель. Держите в ней наготове запрос:

```sql
SELECT pid,
       pg_blocking_pids(pid) AS blocked_by,
       state,
       wait_event_type,
       wait_event,
       left(query, 60) AS query
FROM pg_stat_activity
WHERE datname = 'study' AND pid <> pg_backend_pid()
ORDER BY pid;
```

И второй — какие блокировки удерживаются и ожидаются:

```sql
SELECT l.pid, l.locktype, l.relation::regclass, l.mode, l.granted
FROM pg_locks l
JOIN pg_stat_activity a USING (pid)
WHERE a.datname = 'study' AND l.pid <> pg_backend_pid()
ORDER BY l.pid, l.granted DESC;
```

Сброс перед экспериментами: `UPDATE accounts SET balance = 100; UPDATE tasks SET status = 'NEW';`

---

## Эксперимент 1. Дедлок

| Шаг | A | B |
|---|---|---|
| 1 | `BEGIN;` | `BEGIN;` |
| 2 | `UPDATE accounts SET balance = balance - 10 WHERE id = 1;` | |
| 3 | | `UPDATE accounts SET balance = balance - 10 WHERE id = 2;` |
| 4 | `UPDATE accounts SET balance = balance + 10 WHERE id = 2;` — ждёт | |
| 5 | | `UPDATE accounts SET balance = balance + 10 WHERE id = 1;` |
| 6 | | через ~1 с: `ERROR: deadlock detected` |
| 7 | `COMMIT;` | `ROLLBACK;` |

Между шагами 4 и 5 выполните в **C** оба диагностических запроса и найдите, кто кого ждёт.

Встречные переводы: A переводит 1 → 2, B переводит 2 → 1. Каждая держит одну строку и ждёт другую. PostgreSQL проверяет граф ожиданий через `deadlock_timeout` и убивает одну из транзакций.

**Исправление**: блокировать строки в одном и том же порядке, например по возрастанию `id`, независимо от направления перевода. Повторите эксперимент, где обе сессии сначала обновляют строку с `id = 1`. Вместо дедлока будет обычное ожидание.

---

## Эксперимент 2. Очередь задач на `SKIP LOCKED`

Два воркера разбирают одну очередь.

| Шаг | A (воркер 1) | B (воркер 2) |
|---|---|---|
| 1 | `BEGIN;` | `BEGIN;` |
| 2 | `SELECT id FROM tasks WHERE status = 'NEW' ORDER BY id LIMIT 3 FOR UPDATE SKIP LOCKED;` → 1, 2, 3 | |
| 3 | | тот же запрос → **4, 5, 6** |
| 4 | `UPDATE tasks SET status = 'DONE' WHERE id IN (1,2,3); COMMIT;` | `UPDATE tasks SET status = 'DONE' WHERE id IN (4,5,6); COMMIT;` |

**Повторите** без `SKIP LOCKED` (просто `FOR UPDATE`): B будет ждать, пока A не завершится. С `NOWAIT` B сразу получит ошибку.

Подумайте и запишите: что будет с задачей, если воркер упал посреди обработки? (Транзакция откатится, блокировка снимется, задачу возьмёт другой воркер.) А если обработка включает вызов внешнего API, который уже выполнился? Это мост к идемпотентности и Outbox в блоке 3.

---

## Эксперимент 3. Очередь блокировок при DDL — главная ловушка миграций

| Шаг | A (долгий отчёт) | B (миграция) | C (обычные пользователи) |
|---|---|---|---|
| 1 | `BEGIN; SELECT count(*) FROM accounts;` — транзакцию не завершать | | |
| 2 | | `ALTER TABLE accounts ADD COLUMN note text;` — **ждёт** | |
| 3 | | | `SELECT * FROM accounts;` — **тоже ждёт!** |

На шаге 3 откройте четвёртое окно (или прервите C через Ctrl+C) и выполните диагностические запросы. Цепочка такая: A держит `AccessShareLock`, B ждёт `AccessExclusiveLock`, а C со своим `AccessShareLock` встаёт в очередь **за** B, хотя с A не конфликтует. Таблица недоступна даже на чтение, хотя сам ALTER выполнился бы мгновенно.

Завершите A (`COMMIT;`): B и C выполнятся сразу.

**Правильная миграция**:

```sql
SET lock_timeout = '2s';
ALTER TABLE accounts ADD COLUMN note2 text;
-- при ошибке "canceling statement due to lock timeout" подождать и повторить
```

Повторите шаги 1–3 с `lock_timeout` в сессии B. B упадёт через 2 секунды, и C больше не зависнет.

---

## Эксперимент 4. Какие команды какие блокировки берут

В сессии A выполните `BEGIN;` и одну из команд ниже, не завершая транзакцию. В C посмотрите `pg_locks`. Затем `ROLLBACK;`.

```sql
SELECT * FROM orders WHERE id = 1;
UPDATE orders SET amount = amount WHERE id = 1;
CREATE INDEX ON orders (amount);
-- CREATE INDEX CONCURRENTLY нельзя выполнить внутри транзакции: запустите его без BEGIN
-- и в это время посмотрите pg_locks из C
ALTER TABLE orders ADD COLUMN comment text;
```

Составьте табличку «команда → режим блокировки → что она блокирует» и сверьте с матрицей в документации ([Explicit Locking](https://www.postgresql.org/docs/current/explicit-locking.html)).

---

## Эксперимент 5. Advisory lock — «только один экземпляр делает ночной расчёт»

| Шаг | A | B |
|---|---|---|
| 1 | `SELECT pg_try_advisory_lock(42);` → `t` | |
| 2 | | `SELECT pg_try_advisory_lock(42);` → `f`, «кто-то уже считает» |
| 3 | `SELECT pg_advisory_unlock(42);` | |
| 4 | | `SELECT pg_try_advisory_lock(42);` → `t` |

Блокировка сессионная: она переживает `COMMIT` и снимается при отключении. Вариант для транзакции — `pg_try_advisory_xact_lock`.

---

## Выводы, которые нужно уметь сформулировать

- Почему дедлок — это ошибка проектирования процесса, а не «проблема базы», и как его предотвратить.
- Как устроена очередь задач на PostgreSQL и где у неё предел по сравнению с брокером.
- Почему любая DDL-миграция на проде должна идти с `lock_timeout`, и что ещё обязательно включить в требования к миграциям.
