---
title: "Лаба 1. Изоляция и аномалии"
parent: "2. PostgreSQL изнутри"
nav_order: 11
---

# Лаба 1. Изоляция и аномалии

Цель — увидеть каждую аномалию своими глазами и понять, какой механизм её закрывает. Две сессии: **A** и **B**. Выполняйте шаги строго по порядку и переключайтесь между окнами. Перед каждым экспериментом сбрасывайте данные:

```sql
UPDATE accounts SET balance = 100;
UPDATE doctors SET on_call = true;
```

После каждого эксперимента запишите в «Заметки» модуля [2.2](../2.2-isolation.md) одну фразу: что произошло и почему.

---

## Эксперимент 1. Non-repeatable read в Read Committed

| Шаг | A | B |
|---|---|---|
| 1 | `BEGIN;` | |
| 2 | `SELECT balance FROM accounts WHERE id = 1;` → 100 | |
| 3 | | `UPDATE accounts SET balance = 50 WHERE id = 1;` (автокоммит) |
| 4 | `SELECT balance FROM accounts WHERE id = 1;` → **50** | |
| 5 | `COMMIT;` | |

Внутри одной транзакции A одно и то же чтение вернуло разные значения: в Read Committed снимок берётся на каждый оператор.

**Повторите** с `BEGIN ISOLATION LEVEL REPEATABLE READ;` на шаге 1. На шаге 4 будет 100: снимок один на всю транзакцию.

---

## Эксперимент 2. Lost update в Read Committed

Приложение читает баланс, считает новое значение у себя и записывает результат.

| Шаг | A (списание 10) | B (пополнение 50) |
|---|---|---|
| 1 | `BEGIN;` | `BEGIN;` |
| 2 | `SELECT balance FROM accounts WHERE id = 1;` → 100 | |
| 3 | | `SELECT balance FROM accounts WHERE id = 1;` → 100 |
| 4 | `UPDATE accounts SET balance = 90 WHERE id = 1;` | |
| 5 | | `UPDATE accounts SET balance = 150 WHERE id = 1;` — **ждёт** |
| 6 | `COMMIT;` | UPDATE выполнился |
| 7 | | `COMMIT;` |
| 8 | `SELECT balance FROM accounts WHERE id = 1;` → **150** | |

Списание потеряно, должно было получиться 140. Ни одной ошибки, всё «успешно».

**Повторите** с `BEGIN ISOLATION LEVEL REPEATABLE READ;` в обеих сессиях. На шаге 6 сессия B получит `ERROR: could not serialize access due to concurrent update`. Потери нет, но B должна повторить транзакцию целиком.

**Три способа закрыть lost update в Read Committed** — проверьте каждый:

1. Атомарное изменение: `UPDATE accounts SET balance = balance - 10 WHERE id = 1;` — вычисление внутри базы, по актуальной версии строки.
2. Пессимистичная блокировка: на шаге 2 и 3 — `SELECT balance FROM accounts WHERE id = 1 FOR UPDATE;`. Сессия B будет ждать уже на чтении и прочитает 90.
3. Оптимистичная блокировка: добавьте столбец версии и обновляйте с условием.
   ```sql
   ALTER TABLE accounts ADD COLUMN version int NOT NULL DEFAULT 0;
   -- в каждой сессии: прочитать balance и version, затем
   UPDATE accounts SET balance = :new, version = version + 1
   WHERE id = 1 AND version = :read_version;
   -- "UPDATE 0" означает, что кто-то успел раньше: перечитать и повторить
   ```

---

## Эксперимент 3. Write skew в Repeatable Read

Инвариант: на смене должен оставаться хотя бы один дежурный. Каждый врач проверяет, что дежурных двое, и снимает дежурство с себя.

| Шаг | A (Иванов) | B (Петров) |
|---|---|---|
| 1 | `BEGIN ISOLATION LEVEL REPEATABLE READ;` | `BEGIN ISOLATION LEVEL REPEATABLE READ;` |
| 2 | `SELECT count(*) FROM doctors WHERE shift_id = 1 AND on_call;` → 2 | |
| 3 | | `SELECT count(*) FROM doctors WHERE shift_id = 1 AND on_call;` → 2 |
| 4 | `UPDATE doctors SET on_call = false WHERE id = 1;` | |
| 5 | | `UPDATE doctors SET on_call = false WHERE id = 2;` |
| 6 | `COMMIT;` | `COMMIT;` |
| 7 | `SELECT * FROM doctors;` → **оба не дежурят** | |

Обе транзакции обновили **разные** строки, поэтому конфликта записи нет, и Snapshot Isolation его не видит. Инвариант нарушен.

**Повторите** с `BEGIN ISOLATION LEVEL SERIALIZABLE;`. Одна из транзакций получит `ERROR: could not serialize access due to read/write dependencies among transactions` (SQLSTATE `40001`).

**Альтернатива без Serializable** — материализовать конфликт: на шаге 2 и 3 заблокировать все строки смены.

```sql
SELECT * FROM doctors WHERE shift_id = 1 FOR UPDATE;
```

Вторая сессия будет ждать и после ожидания увидит актуальное состояние. Если бы строк смены не существовало (например, при бронировании свободного слота), блокировать было бы нечего. Тогда нужна отдельная строка-«замок» (сама смена или слот) либо ограничение `EXCLUDE`.

---

## Эксперимент 4 (дополнительно). Ограничение исключения для бронирований

```sql
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE TABLE bookings (
    room   int,
    during tstzrange,
    EXCLUDE USING gist (room WITH =, during WITH &&)
);
INSERT INTO bookings VALUES (1, '[2026-10-01 10:00, 2026-10-01 11:00)');
INSERT INTO bookings VALUES (1, '[2026-10-01 10:30, 2026-10-01 11:30)');  -- ошибка
```

Попробуйте вставить пересекающиеся интервалы из двух параллельных транзакций. Вторая будет ждать первую и упадёт после её фиксации. Инвариант держит сама база при любом уровне изоляции.

---

## Выводы, которые нужно уметь сформулировать

- Какой уровень изоляции какие аномалии допускает — именно в PostgreSQL.
- Почему Repeatable Read и Serializable требуют повтора транзакции в приложении, и что это требование к разработке.
- Какие механизмы закрывают аномалию без повышения уровня: атомарный UPDATE, `FOR UPDATE`, версия строки, ограничения целостности.
