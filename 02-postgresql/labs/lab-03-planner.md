---
title: "Лаба 3. Планировщик и индексы"
parent: "2. PostgreSQL изнутри"
nav_order: 13
---

# Лаба 3. Планировщик и индексы

Одна сессия. Везде используйте `EXPLAIN (ANALYZE, BUFFERS)`. Главное, на что смотреть: **оценка `rows` против `actual rows`**, тип узла и `Buffers`.

Для чистоты эксперимента можно отключить параллельность: `SET max_parallel_workers_per_gather = 0;`

---

## Эксперимент 1. Селективность решает: индекс берётся не всегда

```sql
CREATE INDEX orders_status_idx ON orders (status);

EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE status = 'NEW';       -- ~1% строк
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE status = 'DONE';      -- ~95% строк
```

Для `NEW` будет Index Scan или Bitmap Heap Scan, для `DONE` — Seq Scan. Индекс есть, но читать 95% таблицы через индекс дороже, чем подряд.

Посмотрите, откуда планировщик знает частоты:

```sql
SELECT attname, n_distinct, most_common_vals, most_common_freqs
FROM pg_stats WHERE tablename = 'orders' AND attname = 'status';
```

Проверьте себя: возьмите частоту `NEW` из `most_common_freqs`, умножьте на число строк и сравните с `rows=` в плане.

**Идея для требований**: если «горячий» запрос всегда ищет `NEW`, частичный индекс будет в десятки раз меньше:

```sql
CREATE INDEX orders_new_idx ON orders (created_at) WHERE status = 'NEW';
SELECT pg_size_pretty(pg_relation_size('orders_status_idx')) AS full_idx,
       pg_size_pretty(pg_relation_size('orders_new_idx'))    AS partial_idx;
```

---

## Эксперимент 2. Коррелированные столбцы ломают оценку

Город однозначно определяет регион, но планировщик по умолчанию считает условия независимыми и перемножает их селективности.

```sql
EXPLAIN (ANALYZE) SELECT count(*) FROM orders
WHERE city = 'Казань' AND region = 'Татарстан';
```

Сравните оценку с фактом: планировщик ошибается примерно в пять раз в меньшую сторону. На одной таблице это безобидно, но в соединении такая ошибка приводит к Nested Loop там, где нужен Hash Join.

```sql
CREATE STATISTICS orders_geo (dependencies) ON city, region FROM orders;
ANALYZE orders;

EXPLAIN (ANALYZE) SELECT count(*) FROM orders
WHERE city = 'Казань' AND region = 'Татарстан';
```

Теперь оценка близка к факту.

---

## Эксперимент 3. Устаревшая статистика

```sql
CREATE TABLE events (id int, kind text) WITH (autovacuum_enabled = off);
INSERT INTO events SELECT g, 'A' FROM generate_series(1, 100000) g;
CREATE INDEX ON events (kind);
ANALYZE events;

-- после ANALYZE «пришла» новая пачка данных
INSERT INTO events SELECT g, 'B' FROM generate_series(1, 100000) g;

EXPLAIN (ANALYZE) SELECT * FROM events WHERE kind = 'B';   -- rows=1 против 100 000
ANALYZE events;
EXPLAIN (ANALYZE) SELECT * FROM events WHERE kind = 'B';
```

Ошибка в 100 000 раз. Так бывает после массовой загрузки, когда autovacuum ещё не успел собрать статистику. Отсюда требование к ETL и миграциям: после массовой загрузки явно выполнять `ANALYZE`.

---

## Эксперимент 4. Функция над столбцом убивает индекс

```sql
CREATE INDEX orders_created_idx ON orders (created_at);

EXPLAIN SELECT * FROM orders WHERE date(created_at) = '2025-03-01';
EXPLAIN SELECT * FROM orders
WHERE created_at >= '2025-03-01' AND created_at < '2025-03-02';
```

В первом случае Seq Scan, во втором Index Scan. Попробуйте создать индекс по выражению `date(created_at)` и прочитайте ошибку: для `timestamptz` результат зависит от часового пояса сессии, поэтому функция не `IMMUTABLE`. Вывод: условия пишутся диапазоном по «голому» столбцу.

---

## Эксперимент 5. Порядок столбцов в составном индексе

Запрос: последние 20 заказов клиента.

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders WHERE customer_id = 4242 ORDER BY created_at DESC LIMIT 20;
```

Создайте по очереди два индекса и сравните планы и `Buffers` (перед созданием второго удалите первый):

```sql
CREATE INDEX orders_cust_created ON orders (customer_id, created_at);
-- DROP INDEX orders_cust_created;
CREATE INDEX orders_created_cust ON orders (created_at, customer_id);
```

С первым индексом база сразу находит полтора десятка заказов клиента и читает единицы страниц. Со вторым идёт по всему индексу от конца времени и отфильтровывает чужие заказы: тысячи страниц вместо десятка. Сравните `Buffers` — разница в сотни раз. Правило: сначала столбцы с равенством, потом диапазон и сортировка.

Затем добавьте `INCLUDE (amount, status)` и выберите только эти столбцы — получите Index Only Scan. Посмотрите на `Heap Fetches` и выполните `VACUUM orders`, чтобы увидеть, как их число падает (роль visibility map).

---

## Эксперимент 6. Методы соединения

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.segment, count(*)
FROM orders o JOIN customers c ON c.id = o.customer_id
WHERE o.status = 'NEW'
GROUP BY c.segment;
```

Посмотрите, какой метод соединения выбран. Затем по очереди запретите его и сравните время:

```sql
SET enable_hashjoin = off;   -- что выбрано теперь?
SET enable_mergejoin = off;  -- а теперь?
RESET ALL;
```

Отдельно сравните план для одного клиента (`WHERE o.customer_id = 4242`): там выиграет Nested Loop. Сформулируйте, при каких размерах входов выигрывает каждый метод.

---

## Эксперимент 7. Поиск по подстроке

```sql
EXPLAIN (ANALYZE) SELECT * FROM customers WHERE name LIKE '%er 4242%';
CREATE INDEX customers_name_trgm ON customers USING gin (name gin_trgm_ops);
EXPLAIN (ANALYZE) SELECT * FROM customers WHERE name LIKE '%er 4242%';
```

---

## Итог лабы

Возьмите любой план из экспериментов 2, 5 или 6, вставьте в [explain.tensor.ru](https://explain.tensor.ru) и сравните его подсказки со своим разбором. В «Заметки» модуля [2.4](../2.4-planner.md) запишите пять правил чтения плана своими словами.
