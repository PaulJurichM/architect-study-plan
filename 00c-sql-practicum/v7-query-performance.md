---
title: "В.7 Быстрые запросы"
parent: "0В. SQL-практикум"
nav_order: 7
---

# В.7 Производительность запроса аналитика: план, фильтры, индексы, вежливость к базе

## Зачем это аналитику

Аналитик пишет запросы к живым базам: к реплике продакшена, к хранилищу, к копии, которую делят с десятком коллег. Запрос, который на стенде шёл секунду, на настоящих объёмах идёт сорок минут, держит соединение и мешает соседям, а иногда и приложению. Устройство планировщика и индексов разбирается в блоке 2; здесь — прикладная гигиена: как прочитать план на минимально нужном уровне, какие привычки в написании запроса дают выигрыш в десятки раз и как попросить у разработки индекс так, чтобы его сделали. На собеседовании это звучит как «отчёт тормозит, что будете делать?» — и ответ «добавлю индекс» без плана считается слабым.

## Готовность к модулю

Модуль опирается на темы ниже. Если какая-то из них незнакома или её вопросы для самопроверки даются с трудом, начните с неё.

- [Б.4 SQL и транзакции](../00b-bridge/b4-sql-transactions.md)
- [В.3 CTE и декомпозиция](v3-cte-decomposition.md)

## Куда ведёт

Тема подробнее раскрывается в модулях:

- [2.4 Планировщик](../02-postgresql/2.4-planner.md)
- [2.5 Индексы в глубину](../02-postgresql/2.5-indexes.md)

## Что понять

- [ ] **`EXPLAIN` против `EXPLAIN (ANALYZE, BUFFERS)`**: первый только планирует, второй **выполняет** запрос — изменяющие запросы проверяют внутри `BEGIN ... ROLLBACK`.
- [ ] Минимум чтения плана: дерево снизу вверх, **оценка `rows` против `actual rows`**, `Seq Scan` против `Index Scan`, `loops`, где тратится время.
- [ ] **Функция над столбцом ломает индекс**: `created_at::date = ...` и `lower(email) = ...`; лечится диапазоном по «голому» столбцу или **индексом по выражению**.
- [ ] Индекс для эксперимента создаётся **внутри транзакции** и откатывается — так можно доказать эффект, ничего не меняя в общей базе.
- [ ] **Фильтровать рано, агрегировать до соединения**: это и правильность (нет размножения строк), и скорость.
- [ ] **Коррелированный подзапрос** в `SELECT` выполняется на каждую строку внешнего запроса (`SubPlan`, большой `loops`).
- [ ] `EXISTS` и `IN` дают полусоединение; `JOIN` + `DISTINCT` — **запах**: сначала размножили, потом схлопнули.
- [ ] `LIMIT` без `ORDER BY` недетерминирован; `OFFSET` на больших смещениях читает и выбрасывает всё, что пропускает.
- [ ] **Вежливость к базе**: реплика или копия, `statement_timeout`, короткие транзакции, выгрузка порциями, никакого `SELECT *` по широким таблицам.
- [ ] **Запрос на индекс** для разработки: запрос, частота, объём, план до, ожидаемый эффект, цена на запись.

## Урок

<!-- LESSON:START -->
Примеры выполняются на [стенде](lab/README.md); запросы проверены на PostgreSQL 16. Время выполнения зависит от машины, поэтому все миллисекунды ниже — ориентир «у меня около N мс»; важно соотношение, а не абсолют. На стенде нет индексов, кроме первичных ключей, — как на многих репликах, где индексы сделаны под приложение, а не под ваши отчёты.

### План — до догадок

Порядок действий при медленном запросе один и тот же: сначала план, потом гипотеза, потом проверка гипотезы новым планом. Два режима:

- `EXPLAIN запрос` — только строит план и показывает оценки. Запрос не выполняется, это безопасно всегда.
- `EXPLAIN (ANALYZE, BUFFERS) запрос` — **выполняет** запрос и добавляет фактические числа: время, строки, прочитанные страницы. Для `SELECT` это просто долго, для `UPDATE`/`DELETE`/`INSERT` — это настоящее изменение данных. Такие запросы проверяют только так:

```sql
BEGIN;
EXPLAIN (ANALYZE, BUFFERS) UPDATE ...;
ROLLBACK;
```

Задача: посчитать заказы за 15 июля. Типичная первая версия:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM orders WHERE created_at::date = date '2025-07-15';
```

```
 Finalize Aggregate  (cost=5036.37..5036.38 rows=1 width=8) (actual time=13.904..15.738 rows=1 loops=1)
   Buffers: shared hit=3096
   ->  Gather  (cost=5036.16..5036.37 rows=2 width=8) (actual time=13.897..15.732 rows=3 loops=1)
         Workers Planned: 2
         Workers Launched: 2
         ->  Partial Aggregate  (...) (actual time=10.262..10.263 rows=1 loops=3)
               ->  Parallel Seq Scan on orders  (cost=0.00..4035.38 rows=313 width=0) (actual time=1.894..10.237 rows=259 loops=3)
                     Filter: ((created_at)::date = '2025-07-15'::date)
                     Rows Removed by Filter: 49841
                     Buffers: shared hit=3096
 Execution Time: 15.814 ms
```

Что из этого нужно аналитику:

1. **Читать снизу вверх.** Самый вложенный узел — `Parallel Seq Scan on orders`: таблица читается целиком тремя процессами (основной и два рабочих, отсюда `loops=3`). Выше частичные агрегаты собираются в `Gather` и сводятся в итог.
2. **Строки: оценка против факта.** `rows=313` против `actual rows=259` на процесс — оценка близка. В параллельных узлах оба числа указаны на один процесс; всего строк 259 × 3 = 777.
3. **Сколько работы выброшено.** `Rows Removed by Filter: 49841` на процесс — ради 778 строк прочитаны все 150 тысяч. `Buffers: shared hit=3096` — это вся таблица, все её страницы.
4. **Где время.** `actual time` у узла — «до первой строки..до последней», включая детей. Узел, на котором время резко растёт относительно дочерних, и есть узкое место.

Оценка не всегда так близка. Запрос «заказы канала api без обещанной даты»:

```
 ->  Parallel Seq Scan on orders  (cost=0.00..3878.81 rows=57 width=0) (actual rows=196 loops=3)
       Filter: ((promised_at IS NULL) AND (channel = 'api'::text))
```

Планировщик ждал 57 строк на процесс, получил 196 — в три с половиной раза больше. Он считает условия независимыми: доля `NULL` в `promised_at` (0,44%) умножается на долю канала api (21%). А в данных пропуски `promised_at` есть только у api — столбцы связаны, и перемножение занижает оценку. Здесь это безвредно, а в запросе с соединениями такая ошибка выбирает неверный метод соединения; механизм разбирается в [2.4](../02-postgresql/2.4-planner.md).

### Функция над столбцом: ::date против диапазона

Индекса по `created_at` на стенде нет. Чтобы проверить, поможет ли он, не обязательно просить администратора: в PostgreSQL `CREATE INDEX` транзакционный, и индекс можно создать, проверить и откатить. Другие сессии его не увидят, данные не изменятся.

```sql
BEGIN;
CREATE INDEX orders_created_at_idx ON orders (created_at);

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM orders WHERE created_at::date = date '2025-07-15';

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM orders
WHERE created_at >= timestamptz '2025-07-15'
  AND created_at <  timestamptz '2025-07-16';
ROLLBACK;
```

Первый запрос индекс почти не использует:

```
 ->  Parallel Index Only Scan using orders_created_at_idx on orders  (...) (actual time=10.368..14.306 rows=259 loops=3)
       Filter: ((created_at)::date = '2025-07-15'::date)
       Rows Removed by Filter: 49841
 Execution Time: 31.384 ms
```

Индекс прочитан целиком, условие применено фильтром к каждой записи — `Filter`, а не `Index Cond`. У меня это даже медленнее, чем без индекса (около 30 мс против 15). Индекс упорядочен по `created_at`, а не по `created_at::date`, и база не может найти в нём «участок 15 июля» по выражению.

Второй запрос — тот же смысл, условие на «голом» столбце:

```
 Aggregate  (cost=23.36..23.37 rows=1 width=8) (actual time=0.135..0.135 rows=1 loops=1)
   Buffers: shared hit=6
   ->  Index Only Scan using orders_created_at_idx on orders  (...) (actual time=0.018..0.091 rows=778 loops=1)
         Index Cond: ((created_at >= '2025-07-15 00:00:00+00'::timestamp with time zone) AND (created_at < '2025-07-16 00:00:00+00'::timestamp with time zone))
 Execution Time: 0.147 ms
```

`Index Cond` вместо `Filter`, шесть страниц вместо трёх тысяч, у меня около 0,15 мс — в сто раз быстрее. Правило: **условие по дате пишется полуоткрытым диапазоном `>= начало AND < следующее начало`**. Оно же корректно для любых долей секунды и переносится в любую СУБД, а `::date` — синтаксис PostgreSQL (в стандарте `CAST(created_at AS date)`).

Индекс по выражению `created_at::date` создать нельзя: PostgreSQL ответит `functions in index expression must be marked IMMUTABLE`. Приведение `timestamptz` к дате зависит от часового пояса сессии — тот же момент в Москве и в UTC приходится на разные даты (это тема [В.5](v5-dates-timezones.md)). Индекс по `((created_at AT TIME ZONE 'UTC')::date)` создаётся и работает, но только для запросов с тем же выражением слово в слово.

То же с `lower(email)`. Поиск покупателя без учёта регистра — частая задача, а дубли покупателей с заглавной буквой на стенде есть:

```sql
BEGIN;
CREATE INDEX customers_email_idx ON customers (email);
EXPLAIN ANALYZE SELECT * FROM customers WHERE lower(email) = 'user42@mail.example';
-- Seq Scan on customers (... rows=100 ...) (actual ... rows=2 loops=1)
--   Filter: (lower(email) = 'user42@mail.example'::text)

CREATE INDEX customers_lower_email_idx ON customers (lower(email));
EXPLAIN ANALYZE SELECT * FROM customers WHERE lower(email) = 'user42@mail.example';
-- Bitmap Index Scan on customers_lower_email_idx (... rows=100 ...) (actual ... rows=2 loops=1)
ROLLBACK;
```

Индекс по `email` для `lower(email)` бесполезен, индекс по выражению используется. Заметьте и оценку: `rows=100` при факте 2. Для выражения у планировщика нет статистики, и он берёт фиксированную долю 0,5% от 20 000 строк. После `ANALYZE` статистика по индексированному выражению появляется, и оценка становится точной.

### Фильтровать рано, агрегировать до соединения

В [В.2](v2-joins.md) соединение заказов с позициями и платежами размножало строки и завышало суммы. У того же правила есть вторая сторона — скорость. Задача: по поставщику число заказов, штук в позициях и оплаченная сумма.

Неправильный запрос — соединить всё и сложить (для краткости два поставщика за весь период):

```sql
SELECT o.supplier_id, count(DISTINCT o.id) AS orders_cnt,
       sum(i.qty) AS units, sum(p.amount) AS paid
FROM orders o
JOIN order_items i ON i.order_id = o.id
LEFT JOIN payments p ON p.order_id = o.id
WHERE o.supplier_id IN (31, 32)
GROUP BY o.supplier_id;
```

```
 supplier_id | orders_cnt | units |     paid
-------------+------------+-------+--------------
          31 |       3966 | 24438 | 354788403.33
          32 |       4090 | 25859 | 445278764.69
```

Быстро (около 75 мс) и неверно: оплата умножена на число позиций, позиции — на число платежей. `count(DISTINCT o.id)` маскирует проблему в одном столбце и не спасает остальные. Правильный ответ — 23 396 штук и около 141 млн по поставщику 31.

Теперь тот же отчёт по всем поставщикам за неделю 7–13 июля. Исправление «предагрегировать каждую таблицу до гранулярности заказа» верное, но если сделать его в лоб, агрегируются все 290 тысяч позиций и 150 тысяч платежей, а фильтр по неделе применяется уже после. У меня около 500–700 мс, и в плане видна `HashAggregate` по платежам со сбросом на диск (`Disk Usage`). Правильный порядок — сначала отобрать заказы, потом агрегировать только их детали:

```sql
WITH target AS (
    SELECT id, supplier_id
    FROM orders
    WHERE created_at >= timestamptz '2025-07-07'
      AND created_at <  timestamptz '2025-07-14'
),
items AS (
    SELECT i.order_id, sum(i.qty) AS units
    FROM order_items i
    JOIN target t ON t.id = i.order_id
    GROUP BY i.order_id
),
pays AS (
    SELECT p.order_id, sum(p.amount) AS paid
    FROM payments p
    JOIN target t ON t.id = p.order_id
    GROUP BY p.order_id
)
SELECT t.supplier_id, count(*) AS orders_cnt, sum(i.units) AS units, sum(p.paid) AS paid
FROM target t
JOIN items i ON i.order_id = t.id
LEFT JOIN pays p ON p.order_id = t.id
GROUP BY t.supplier_id;
```

У меня около 250 мс, в два-три раза быстрее, и без диска. На `target` ссылаются три раза, поэтому PostgreSQL материализует его один раз (`CTE target` в плане). Без индексов позиции и платежи всё равно читаются целиком; с индексами по `order_id` выигрыш был бы на порядки.

Ещё нагляднее с оконной функцией. «Последний статус заказов поставщика 31 за 8–15 июля»: если пронумеровать всю историю, а потом соединить с отобранными заказами, база сортирует 579 тысяч событий (`Sort Method: external merge Disk`), у меня около 500 мс. Если сначала отобрать 153 заказа и нумеровать только их события, сортируется 600 строк в памяти — около 90 мс. Окно не может «протолкнуть» фильтр внутрь себя, если фильтр стоит по другой таблице; это делаете вы.

### Коррелированный подзапрос: работа на каждую строку

Тот же «последний статус» часто пишут так:

```sql
SELECT o.id, o.created_at,
       (SELECT h.status
        FROM order_status_history h
        WHERE h.order_id = o.id
        ORDER BY h.changed_at DESC
        LIMIT 1) AS last_status
FROM orders o
WHERE o.supplier_id = 31
  AND o.created_at >= timestamptz '2025-07-08'
  AND o.created_at <  timestamptz '2025-07-16';
```

```
 Seq Scan on orders o (actual time=131.173..3251.051 rows=153 loops=1)
   SubPlan 1
     ->  Limit (actual time=20.478..20.478 rows=1 loops=153)
           ->  Sort (actual time=20.475..20.475 rows=1 loops=153)
                 ->  Seq Scan on order_status_history h (actual time=0.810..20.459 rows=4 loops=153)
                       Filter: (order_id = o.id)
                       Rows Removed by Filter: 579097
 Execution Time: 3265.542 ms
```

`SubPlan` с `loops=153`: для каждого из 153 заказов журнал читается целиком. 20 мс × 153 ≈ 3,1 секунды. Соединение с сортировкой (`DISTINCT ON` или `ROW_NUMBER`, как в [В.4](v4-window-functions.md)) читает журнал один раз — около 70 мс. На 153 строках разница в 45 раз; на 15 тысячах строк подзапрос шёл бы пять минут. С индексом по `order_status_history (order_id, changed_at)` подзапрос стал бы быстрым — но на реплике его нет, а соединение быстрое и без него.

### EXISTS, IN и DISTINCT как запах

«Покупатели, у которых есть доставленный заказ». Частая версия — соединить и убрать дубли:

```sql
SELECT DISTINCT c.id, c.email, c.region
FROM customers c
JOIN orders o ON o.customer_id = c.id
JOIN order_items i ON i.order_id = o.id   -- «на всякий случай»
WHERE o.status = 'DELIVERED';
```

В плане 259 тысяч строк соединения сворачиваются в 15 078 покупателей через `HashAggregate` — у меня около 180 мс. `DISTINCT` здесь исправляет размножение, которое запрос сам и создал. Вопрос «есть ли» задаётся через `EXISTS`:

```sql
SELECT c.id, c.email, c.region
FROM customers c
WHERE EXISTS (
    SELECT 1 FROM orders o
    WHERE o.customer_id = c.id AND o.status = 'DELIVERED'
);
```

Те же 15 078 строк, около 45 мс. План — полусоединение: заказы сворачиваются до уникальных `customer_id`, и каждый покупатель проверяется один раз. `c.id IN (SELECT customer_id ...)` PostgreSQL планирует так же. Разница появляется у отрицаний: `NOT IN` с подзапросом, где может встретиться `NULL`, возвращает пустой результат и плохо планируется, поэтому для «нет ни одного» — `NOT EXISTS`.

### LIMIT без ORDER BY и OFFSET

«Покажи 10 000 доставок для проверки» — и два запуска подряд:

```sql
SELECT min(order_id), max(order_id)
FROM (SELECT order_id FROM order_status_history WHERE status = 'DELIVERED' LIMIT 10000) t;
```

```
  min  |  max
-------+-------
 43334 | 55979
 52829 | 65611
 62225 | 75214
```

Каждый запуск — другие строки. Без `ORDER BY` база отдаёт первые попавшиеся, а PostgreSQL ещё и позволяет новому последовательному чтению подхватить чужое, уже идущее, с середины таблицы (synchronized seqscans). Выборка «для проверки» невоспроизводима: коллега получит другие строки. Правило: `LIMIT` — только вместе с `ORDER BY` по уникальному ключу. В стандарте SQL и в других СУБД — `FETCH FIRST 10 ROWS ONLY` или `TOP 10`, правило то же.

Постраничная выгрузка через `OFFSET` деградирует с номером страницы: `ORDER BY id LIMIT 100 OFFSET 140000` читает 140 100 строк индекса и выбрасывает 140 000 — у меня около 200 мс на страницу. Ключевая пагинация (keyset) `WHERE id > :последний_id ORDER BY id LIMIT 100` начинает с нужного места — около 0,1 мс на любой странице.

### Временные таблицы для расследования

Расследование — это десяток запросов к одному срезу. Пересчитывать срез каждый раз — нагружать базу и рисковать, что он «поплывёт» между запросами. Срез сохраняют во временную таблицу: она видна только вашей сессии и исчезает при отключении.

```sql
CREATE TEMP TABLE late_31 AS
SELECT o.id, o.customer_id, o.channel, o.created_at, o.promised_at, sh.delivered_at
FROM orders o
JOIN shipments sh ON sh.order_id = o.id
WHERE o.supplier_id = 31
  AND o.created_at >= timestamptz '2025-07-01'
  AND o.created_at <  timestamptz '2025-08-01';

ANALYZE late_31;
```

568 строк, дальше любые разрезы по ним — доли миллисекунды. `ANALYZE` нужен потому, что autovacuum временные таблицы не обслуживает, и без статистики планировщик гадает. На проекте с доступом только на чтение временные таблицы могут быть запрещены — тогда то же делают CTE или выгрузкой среза.

### Вежливость к базе

- **Где работать.** На реплике или копии, не на основной базе продакшена. Долгий запрос на реплике тоже не бесплатен: он может задерживать применение изменений или очистку на основной базе — уточните у администратора, как настроена ваша.
- **Ограничить время.** В начале сессии `SET statement_timeout = '60s';` — запрос, который пошёл не туда, будет прерван базой, а не будет работать час:

```
SET statement_timeout = '200ms';
SELECT count(*) FROM order_status_history a JOIN order_status_history b USING (order_id);
ERROR:  canceling statement due to statement timeout
```

- **Не держать транзакцию открытой.** Клиент с выключенным автокоммитом после одного `SELECT` держит транзакцию часами, и очистка таблиц стоит. Закончили — `COMMIT` или `ROLLBACK`, а в DBeaver и аналогах — автокоммит для чтения.
- **Выгружать порциями** по ключу или по дням, а не одним запросом на десятки миллионов строк.
- **Выбирать столбцы.** `SELECT *` по широкой таблице тащит по сети всё, включая JSON и тексты, и лишает базу Index Only Scan.

### Как попросить индекс

Разработка отказывает в индексах не из вредности: каждый индекс замедляет запись и занимает место. Запрос должен показать, что выгода больше цены. Шаблон с цифрами со стенда:

> **Запрос.** Еженедельный отчёт по опозданиям: заказы поставщика за неделю, `WHERE supplier_id = :s AND created_at >= :from AND created_at < :to`. Текст запроса и план приложены.
> **Частота.** 40 поставщиков × раз в неделю + разбор инцидентов, около 200 запусков в неделю.
> **Объём.** `orders` — 150 тыс. строк, растёт примерно на 1 400 в день.
> **План сейчас.** `Parallel Seq Scan on orders`, `Rows Removed by Filter` ≈ 150 тыс. ради 130 строк, около 20 мс; на продакшен-объёме — пропорционально больше.
> **Предложение.** `CREATE INDEX ON orders (supplier_id, created_at)` — равенство впереди, диапазон вторым.
> **Ожидаемый эффект.** Проверено в транзакции с откатом на копии: `Index Only Scan`, около 0,07 мс.
> **Цена.** Размер около 4,6 МБ; одна дополнительная запись в индекс на каждую вставку заказа — при 1 400 вставках в день незаметно. Альтернатива без индекса — выгружать данные в хранилище.

### Типичные ошибки

- Начинать с «добавим индекс», не посмотрев план.
- Запускать `EXPLAIN ANALYZE` для `UPDATE` или `DELETE` вне транзакции с откатом.
- Писать фильтр по дню как `created_at::date = ...` или `date(created_at) = ...`.
- Лечить размножение строк `DISTINCT`'ом вместо предагрегации или `EXISTS`.
- Ставить фильтр после тяжёлой работы: окно или агрегат по всей таблице, а отбор — во внешнем запросе.
- Скалярный подзапрос в `SELECT` по большой таблице без индекса.
- `LIMIT` без `ORDER BY` в выборке, которую будут сравнивать или пересылать.
- Работать на основной базе без `statement_timeout` и с открытой транзакцией.

### Как говорить об этом на собеседовании

Вопрос «отчёт тормозит, что будете делать» проверяет порядок мысли. Сильный ответ: «Сначала `EXPLAIN (ANALYZE, BUFFERS)` на копии. Смотрю, какой узел съедает время, где оценка строк расходится с фактом и сколько строк выбрасывается фильтром. Типовые причины в аналитических запросах — функция над столбцом в условии, коррелированный подзапрос на каждую строку, агрегация после соединения и фильтр в самом конце. Их исправляю переписыванием. Если нужен индекс, проверяю эффект в транзакции с откатом и приношу разработке запрос, частоту, план до и после и цену на запись». Если спросят про другую СУБД: `EXPLAIN` там свой (в SQL Server — план выполнения, в MySQL — `EXPLAIN ANALYZE` с версии 8.0.18), а принципы те же.

### Коротко

- План до догадок: `EXPLAIN` безопасен, `EXPLAIN ANALYZE` выполняет запрос.
- В плане: снизу вверх, `rows` против `actual rows`, `Filter` против `Index Cond`, `Rows Removed by Filter`, `loops`.
- Функция над столбцом ломает индекс; дату фильтруют полуоткрытым диапазоном, регистр — индексом по выражению.
- Индекс для эксперимента — в транзакции с `ROLLBACK`.
- Сначала отобрать, потом агрегировать детали до гранулярности, потом соединять.
- Коррелированный подзапрос — `SubPlan` с большим `loops`; заменять соединением.
- «Есть ли» — `EXISTS`; `DISTINCT` после соединения — признак размножения.
- `LIMIT` только с `ORDER BY`; вместо `OFFSET` — ключевая пагинация.
- Вежливость: реплика, `statement_timeout`, короткие транзакции, порции, нужные столбцы.
<!-- LESSON:END -->

## Читать дальше

- Документация PostgreSQL: [Using EXPLAIN](https://www.postgresql.org/docs/current/using-explain.html), [EXPLAIN](https://www.postgresql.org/docs/current/sql-explain.html), [Indexes on Expressions](https://www.postgresql.org/docs/current/indexes-expressional.html), [Multicolumn Indexes](https://www.postgresql.org/docs/current/indexes-multicolumn.html), [Subquery Expressions](https://www.postgresql.org/docs/current/functions-subquery.html) (`EXISTS`, `IN`, `NOT IN`), [LIMIT and OFFSET](https://www.postgresql.org/docs/current/queries-limit.html), [Client Connection Defaults](https://www.postgresql.org/docs/current/runtime-config-client.html) (`statement_timeout`, `idle_in_transaction_session_timeout`).
- Маркус Винанд, «SQL Performance Explained» и сайт [use-the-index-luke.com](https://use-the-index-luke.com/) — функции в условиях, составные индексы, пагинация без `OFFSET`.
- Рогов, «PostgreSQL изнутри», часть IV «Выполнение запросов» — когда захочется понять, почему план именно такой.

## Практика

Задачи решаются на стенде. Сначала сами, с таймером, потом сверяйтесь с разбором. Индексы создавайте только внутри `BEGIN ... ROLLBACK`.

### Задача 1. Ускорить отчёт по неделе

Отчёт «заказы и опоздания по поставщикам за неделю 7–13 июля» написан так и у меня выполняется около 1–1,5 секунды:

```sql
SELECT s.id, s.name,
       (SELECT count(*) FROM orders o
        WHERE o.supplier_id = s.id
          AND o.created_at::date BETWEEN date '2025-07-07' AND date '2025-07-13') AS orders_cnt,
       (SELECT count(*) FROM orders o
        JOIN shipments sh ON sh.order_id = o.id
        WHERE o.supplier_id = s.id
          AND o.created_at::date BETWEEN date '2025-07-07' AND date '2025-07-13'
          AND sh.delivered_at > o.promised_at) AS late_cnt
FROM suppliers s
ORDER BY s.id;
```

Перепишите его без индексов так, чтобы он стал быстрее в десятки раз и вернул тот же результат (40 строк, у поставщиков 39–40 нули). Сравните планы и докажите равенство результатов запросом. Таймер: 20 минут.

<details markdown="1">
<summary>Решение и разбор</summary>

```sql
WITH week_orders AS (
    SELECT o.supplier_id,
           count(*) AS orders_cnt,
           count(*) FILTER (WHERE sh.delivered_at > o.promised_at) AS late_cnt
    FROM orders o
    LEFT JOIN shipments sh ON sh.order_id = o.id
    WHERE o.created_at >= timestamptz '2025-07-07'
      AND o.created_at <  timestamptz '2025-07-14'
    GROUP BY o.supplier_id
)
SELECT s.id, s.name,
       coalesce(w.orders_cnt, 0) AS orders_cnt,
       coalesce(w.late_cnt, 0)   AS late_cnt
FROM suppliers s
LEFT JOIN week_orders w ON w.supplier_id = s.id
ORDER BY s.id;
```

У меня около 40 мс против 1–1,7 секунды. В исходном плане два `SubPlan` с `loops=40`: на каждого поставщика `orders` читается целиком два раза, а `shipments` — ещё раз (`Seq Scan on shipments ... loops=38`). Всего около 286 тысяч прочитанных страниц (`Buffers: shared hit=285682`) против 4 тысяч в новом плане: каждая таблица читается один раз, `Hash Right Join` и одна группировка.

Важные детали переписывания:

- `LEFT JOIN shipments`, а не `JOIN`: иначе `orders_cnt` посчитает только отгруженные заказы — это другой показатель.
- `LEFT JOIN` от `suppliers` и `coalesce`, иначе поставщики без заказов (39 и 40) пропадут, а в исходном отчёте они есть с нулями.
- `BETWEEN '2025-07-07' AND '2025-07-13'` по датам равен полуоткрытому `>= 07-07 AND < 07-14` по времени. `BETWEEN` по `timestamptz` с правой границей `'2025-07-13'` потерял бы весь день 13 июля.
- `FILTER` — синтаксис PostgreSQL; переносимо — `sum(CASE WHEN ... THEN 1 ELSE 0 END)`.

Проверка равенства — разность множеств в обе стороны:

```sql
(SELECT s.id,
        (SELECT count(*) FROM orders o WHERE o.supplier_id = s.id
           AND o.created_at::date BETWEEN date '2025-07-07' AND date '2025-07-13'),
        (SELECT count(*) FROM orders o JOIN shipments sh ON sh.order_id = o.id
          WHERE o.supplier_id = s.id
            AND o.created_at::date BETWEEN date '2025-07-07' AND date '2025-07-13'
            AND sh.delivered_at > o.promised_at)
 FROM suppliers s)
EXCEPT
(WITH week_orders AS (
     SELECT o.supplier_id, count(*) AS orders_cnt,
            count(*) FILTER (WHERE sh.delivered_at > o.promised_at) AS late_cnt
     FROM orders o LEFT JOIN shipments sh ON sh.order_id = o.id
     WHERE o.created_at >= timestamptz '2025-07-07' AND o.created_at < timestamptz '2025-07-14'
     GROUP BY o.supplier_id)
 SELECT s.id, coalesce(w.orders_cnt, 0), coalesce(w.late_cnt, 0)
 FROM suppliers s LEFT JOIN week_orders w ON w.supplier_id = s.id);
```

0 строк; то же в обратную сторону. Бонус к разбору: в результате у поставщика 31 опоздали 110 заказов из 130, у остальных — от нуля до полусотни. Запомните эту строку, она понадобится в [В.8](v8-interview-case.md).

</details>

### Задача 2. Где планировщик ошибся и почему

Выполните `EXPLAIN ANALYZE` для запроса «сколько событий `PAID` записала система поставщика»:

```sql
SELECT count(*) FROM order_status_history
WHERE status = 'PAID' AND source = 'supplier';
```

Найдите узел, где оценка строк расходится с фактом, оцените, во сколько раз, и объясните, откуда планировщик взял своё число. Таймер: 10 минут.

<details markdown="1">
<summary>Решение и разбор</summary>

```
 ->  Parallel Seq Scan on order_status_history  (cost=0.00..8594.38 rows=28193 width=0) (actual rows=0 loops=3)
       Filter: ((status = 'PAID'::text) AND (source = 'supplier'::text))
       Rows Removed by Filter: 193034
```

Планировщик ждал около 28 тысяч строк на процесс (примерно 67 тысяч всего), получил ноль. Оценку можно восстановить по статистике:

```sql
SELECT attname, most_common_vals, most_common_freqs
FROM pg_stats
WHERE tablename = 'order_status_history' AND attname IN ('status', 'source');
```

Доля `PAID` около 25%, доля `supplier` около 47%. Планировщик считает условия независимыми и перемножает: 0,25 × 0,47 × 579 тыс. ≈ 67 тыс. А столбцы связаны жёстко: `PAID` пишет только маркетплейс, `supplier` пишет только `SHIPPED` и `DELIVERED`. На этом простом запросе ошибка безвредна — всё равно `Seq Scan`. Но если такой фильтр стоит под соединением, завышенная или заниженная в тысячи раз оценка выбирает не тот метод соединения. Исправление на уровне базы — расширенная статистика (`CREATE STATISTICS ... (dependencies, mcv)`), её разбирает [2.4](../02-postgresql/2.4-planner.md). Аналитику важно уметь показать это расхождение и объяснить его — этого достаточно для задачи разработке.

Второй пример на стенде с той же причиной: `channel = 'api' AND promised_at IS NULL` — оценка занижена в три с половиной раза, потому что `NULL` в `promised_at` встречаются только у канала api. Это и есть заложенный дефект данных, и план его «видит».

</details>

### Задача 3. lower(email): доказать на плане

Покажите на планах, что для поиска `lower(email) = 'user42@mail.example'` индекс по `email` не используется, а индекс по `lower(email)` используется. Всё — в одной транзакции с откатом. Объясните, почему поиск вернул две строки, и почему оценка до `ANALYZE` равна 100. Таймер: 15 минут.

<details markdown="1">
<summary>Решение и разбор</summary>

```sql
BEGIN;
CREATE INDEX customers_email_idx ON customers (email);
EXPLAIN ANALYZE SELECT * FROM customers WHERE lower(email) = 'user42@mail.example';
EXPLAIN ANALYZE SELECT * FROM customers WHERE email = 'user42@mail.example';
CREATE INDEX customers_lower_email_idx ON customers (lower(email));
EXPLAIN ANALYZE SELECT * FROM customers WHERE lower(email) = 'user42@mail.example';
ANALYZE customers;
EXPLAIN ANALYZE SELECT * FROM customers WHERE lower(email) = 'user42@mail.example';
ROLLBACK;
```

Четыре плана:

1. `Seq Scan on customers ... rows=100 ... actual rows=2`, `Filter: (lower(email) = ...)` — индекс по `email` есть, но не используется.
2. `Index Scan using customers_email_idx ... Index Cond: (email = ...)` — тот же индекс работает для условия на «голом» столбце, но находит одну строку: регистр важен.
3. `Bitmap Index Scan on customers_lower_email_idx ... rows=100 ... actual rows=2` — индекс по выражению используется.
4. После `ANALYZE` — `rows=2`: статистика по индексированному выражению собрана.

Две строки — это дефект справочника: покупатель 19892 зарегистрировался повторно с адресом `User42@mail.example`. Таких пар 150. Оценка 100 — это фиксированные 0,5% от 20 000 строк, которые планировщик подставляет для равенства на выражении без статистики.

Для разработки отсюда два вывода: уникальность email должна проверяться без учёта регистра (уникальный индекс по `lower(email)` или тип `citext`), а поиск — тем же выражением, что в индексе.

</details>

### Задача 4. DISTINCT → EXISTS

Запрос ниже возвращает покупателей, которые хоть раз заказывали у поставщика 31. Перепишите его без `DISTINCT`, сравните результат и планы. Таймер: 10 минут.

```sql
SELECT DISTINCT c.id, c.email, c.region
FROM customers c
JOIN orders o ON o.customer_id = c.id
JOIN order_items i ON i.order_id = o.id
WHERE o.supplier_id = 31;
```

<details markdown="1">
<summary>Решение и разбор</summary>

```sql
SELECT c.id, c.email, c.region
FROM customers c
WHERE EXISTS (
    SELECT 1 FROM orders o
    WHERE o.customer_id = c.id AND o.supplier_id = 31
);
```

Оба запроса возвращают 3 393 покупателя. В исходном плане соединение даёт около 7,7 тысячи строк (3 966 заказов × позиции), `Nested Loop` с `loops=3966` по индексу позиций, затем двухступенчатый `HashAggregate` убирает дубли. Соединение с `order_items` вообще не нужно: у каждого заказа на стенде есть позиции, и на результат оно не влияет — только множит строки. В новом плане заказы поставщика сворачиваются до уникальных `customer_id` (`HashAggregate`) и соединяются с покупателями один раз. Вариант с `c.id IN (SELECT o.customer_id ...)` даёт такой же план.

На этом объёме разница скромная (у меня около 40 против 30 мс). На запросе «покупатели с доставленным заказом» — 180 против 45 мс, потому что размножаются уже 130 тысяч заказов. Главное здесь не миллисекунды: `DISTINCT` после соединения прячет вопрос «а сколько строк должно было получиться». Если завтра кто-то добавит в такой запрос `sum(...)`, он получит размноженные суммы.

</details>

### Задача 5. Выгрузка порциями

Нужно выгрузить все заказы (`id`, `created_at`, `status`, `total_amount`) порциями по 1 000 строк. Покажите, почему `ORDER BY id LIMIT 1000 OFFSET N` деградирует к последним страницам, и напишите запрос порции через ключ. Что сделать, чтобы выгрузка не «съезжала», если во время неё появляются новые заказы? Таймер: 10 минут.

<details markdown="1">
<summary>Решение и разбор</summary>

```sql
EXPLAIN (ANALYZE, COSTS OFF)
SELECT id, created_at FROM orders ORDER BY id LIMIT 100 OFFSET 140000;
-- Limit (actual time=203.144..203.209 rows=100 loops=1)
--   ->  Index Scan using orders_pkey on orders (actual time=0.020..195.742 rows=140100 loops=1)

-- порция через ключ: подставляется последний id предыдущей порции
SELECT id, created_at, status, total_amount
FROM orders
WHERE id > 140000
ORDER BY id
LIMIT 1000;
```

С `OFFSET` база читает 140 100 строк по индексу и отдаёт последние 100; у меня около 200 мс, и на каждой следующей странице больше. Ключевая порция всегда начинается с `Index Cond: (id > ...)` — около 0,1 мс на любой странице. Суммарно выгрузка через `OFFSET` растёт квадратично от числа страниц, через ключ — линейно.

Чтобы выгрузка не «съезжала», верхнюю границу фиксируют заранее: запомнить `max(id)` в начале и добавить `AND id <= :max_id`. Новые заказы попадут в следующую выгрузку. Сортировка по неуникальному столбцу (`created_at`) для порций не годится без второго ключа: `ORDER BY created_at, id` и условие `(created_at, id) > (:last_ts, :last_id)` — сравнение строк, которое есть в PostgreSQL и в стандарте, но не во всех СУБД.

</details>

### Задача 6. Запрос на индекс для разработки

Аналитики каждый день разбирают историю статусов по отдельным заказам: «последний статус», «когда отгружен», «сколько был в оплате». Запросы вида `WHERE order_id = :id ORDER BY changed_at`. Проверьте эффект подходящего индекса в транзакции с откатом и напишите запрос разработке по шаблону из урока: запрос, частота, объём, план до, предложение, ожидаемый эффект, цена. Таймер: 20 минут.

<details markdown="1">
<summary>Решение и разбор</summary>

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT status, changed_at FROM order_status_history
WHERE order_id = 104231 ORDER BY changed_at;

BEGIN;
CREATE INDEX osh_order_changed_idx ON order_status_history (order_id, changed_at);
EXPLAIN (ANALYZE, BUFFERS)
SELECT status, changed_at FROM order_status_history
WHERE order_id = 104231 ORDER BY changed_at;
SELECT pg_size_pretty(pg_relation_size('osh_order_changed_idx'));
ROLLBACK;
```

До: `Parallel Seq Scan` по всем 579 тысячам событий, около 20–40 мс на один заказ и чтение всей таблицы (около 5 тысяч страниц). После: `Index Scan using osh_order_changed_idx`, `Index Cond: (order_id = ...)`, без отдельной сортировки — строки уже идут по `changed_at`, доли миллисекунды и несколько страниц. Размер индекса — около 17 МБ.

Пример формулировки:

> **Запрос.** Разбор истории статусов по заказу: `SELECT status, changed_at FROM order_status_history WHERE order_id = :id ORDER BY changed_at`. Используется также в коррелированных подзапросах отчётов «последний статус».
> **Частота.** Около 500 ручных запусков в день при разборе обращений, плюс два ежедневных отчёта.
> **Объём.** 579 тыс. событий, около 4 событий на заказ, рост около 5 тыс. событий в день.
> **План сейчас.** Полное чтение таблицы на каждый заказ, 20–40 мс; в отчётах — `SubPlan` с тысячами итераций, минуты.
> **Предложение.** `CREATE INDEX ON order_status_history (order_id, changed_at)`: равенство по заказу впереди, сортировка вторым столбцом.
> **Ожидаемый эффект.** Проверено на копии в транзакции с откатом: `Index Scan`, доли миллисекунды, сортировка не нужна.
> **Цена.** Около 17 МБ; одна запись в индекс на каждое событие статуса, при 5 тыс. событий в день — незаметно. Журнал только дописывается, обновлений индексированных столбцов нет.

Почему именно этот индекс: `order_id` сравнивается на равенство — он первый; `changed_at` даёт порядок — он второй. Отдельный индекс только по `order_id` тоже ускорит поиск, но оставит сортировку. Числа «500 запусков в день» в формулировке — пример: в реальной задаче частоту берут из журнала запросов или честно оценивают.

</details>

## Вопросы для самопроверки

1. Чем `EXPLAIN` отличается от `EXPLAIN ANALYZE` и как безопасно проверить план `UPDATE`?
2. В плане `rows=57`, `actual rows=196 loops=3`. Сколько строк вернул узел и во сколько раз ошибся планировщик? Какая возможная причина?
3. Почему `WHERE created_at::date = '2025-07-15'` не использует индекс по `created_at` и как переписать условие? Почему нельзя создать индекс по `created_at::date`?
4. Как доказать пользу индекса на общей базе, ничего в ней не меняя?
5. Отчёт соединяет заказы, позиции и платежи и считает суммы. Какие две проблемы здесь могут быть и как их решает предагрегация?
6. Как в плане выглядит коррелированный подзапрос и почему он медленный?
7. Почему `DISTINCT` после соединения называют запахом? Чем его заменить?
8. Какие правила вежливости к общей базе вы соблюдаете и как сформулируете разработке запрос на индекс?

## Заметки

<!-- Свои формулировки, ошибки, ссылки. -->
