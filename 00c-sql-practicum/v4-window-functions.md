---
title: "В.4 Оконные функции"
parent: "0В. SQL-практикум"
nav_order: 4
---

# В.4 Оконные функции в работе: дедупликация, последнее состояние, интервалы, серии

## Зачем это аналитику

Журналы событий, платежи, остатки и витрины почти никогда не бывают чистыми. В них есть дубли от повторных доставок, пропущенные дни, сдвинутые часы. Оконные функции — главный инструмент, чтобы навести в таких данных порядок, не теряя строк: выбрать одну правильную запись из нескольких, найти последнее состояние, посчитать время между событиями, найти серии и пропуски. На собеседовании это самый частый класс live-задач: «последний статус каждого заказа», «топ-3 товара в категории», «самая длинная серия дней без продаж», «скользящее среднее за неделю». Синтаксис окон знают многие. Отличает кандидата другое: он сам говорит, по какому правилу выбирает строку, и знает, где окно тихо посчитает не то.

## Готовность к модулю

Модуль опирается на темы ниже. Если какая-то из них незнакома или её вопросы для самопроверки даются с трудом, начните с неё.

- [Б.4 SQL и транзакции](../00b-bridge/b4-sql-transactions.md)
- [В.3 CTE и декомпозиция](v3-cte-decomposition.md)

## Куда ведёт

Тема подробнее раскрывается в модулях:

- [В.5 Время и даты](v5-dates-timezones.md)
- [9.2 Моделирование DWH](../09-data-platforms/9.2-dwh-modeling.md)

## Что понять

- [ ] **Анатомия окна**: `PARTITION BY` — группы, `ORDER BY` — порядок, **рамка (frame)** — какие строки группы видит функция для текущей строки.
- [ ] **Порядок вычисления**: окна считаются после `WHERE`, `GROUP BY` и `HAVING`, поэтому фильтровать по окну можно только снаружи, в CTE или подзапросе.
- [ ] **Дедупликация через `ROW_NUMBER`**: признак дубля в `PARTITION BY`, **правило выбора** в `ORDER BY`, плюс уникальный столбец для однозначности.
- [ ] **Последнее состояние**: `ROW_NUMBER ... DESC` и `rn = 1` или `DISTINCT ON` в PostgreSQL; сверка с текущим статусом в основной таблице.
- [ ] **`LAG` и `LEAD`** смещаются на строки, а не на события нужного типа: дубли и сдвинутые часы ломают пары.
- [ ] **`percentile_cont`** — агрегат с `WITHIN GROUP`, а не оконная функция.
- [ ] **`ROWS` против `RANGE`**: семь строк — не то же самое, что семь дней, если в ряду пропуски.
- [ ] **`ROW_NUMBER`, `RANK`, `DENSE_RANK`** дают разные топ-N при равенстве значений.
- [ ] **`last_value`** с рамкой по умолчанию возвращает текущую строку, а не последнюю.
- [ ] **Острова и пропуски (gaps and islands)**: «дата минус номер строки» даёт ключ серии.

## Урок

<!-- LESSON:START -->
Все примеры построены на [стенде](lab/README.md) маркетплейса; запросы проверены на PostgreSQL 16. Определения оконных функций даны в [Б.4](../00b-bridge/b4-sql-transactions.md), здесь — практика и ловушки.

### Анатомия окна и порядок вычисления

Окно задаётся тремя частями (это схема, а не запрос):

```
функция() OVER (
    PARTITION BY ...   -- на какие независимые группы делить строки
    ORDER BY ...       -- в каком порядке строки внутри группы
    ROWS | RANGE BETWEEN ... AND ...   -- рамка: какие строки группы видит функция
)
```

Если `ORDER BY` в окне нет, рамка — вся группа. Если `ORDER BY` есть, рамка по умолчанию — `RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`: от начала группы до текущей строки **и всех её ровесников** с тем же значением ключа сортировки. Из этой строки умолчаний вырастают две ловушки урока — с нарастающим итогом и с `last_value`.

Окна вычисляются после `WHERE`, `GROUP BY` и `HAVING`, но до `ORDER BY` и `LIMIT`. Поэтому так нельзя:

```sql
SELECT order_id, status, changed_at,
       row_number() OVER (PARTITION BY order_id ORDER BY changed_at DESC) AS rn
FROM order_status_history
WHERE row_number() OVER (PARTITION BY order_id ORDER BY changed_at DESC) = 1;
```

```
ERROR:  window functions are not allowed in WHERE
```

`WHERE` отбирает строки, по которым окно будет считаться. Фильтр по окну — это следующий шаг, поэтому окно оборачивают в CTE, как в В.3. Зато окно можно применить к результату группировки: `sum(count(*)) OVER (...)` — это окно поверх агрегата.

### Дедупликация: сначала правило, потом ROW_NUMBER

У журнала `order_status_history` нет первичного ключа, и интеграция при повторах присылает событие ещё раз. Первая мысль — `SELECT DISTINCT`:

```sql
SELECT count(*) FROM order_status_history;
SELECT count(*) FROM (SELECT DISTINCT * FROM order_status_history) d;
```

```
 count
--------
 579101

 count
--------
 579101
```

`DISTINCT` не нашёл ни одного дубля: повторное событие пришло через секунду, и строки различаются временем. Дубль — понятие бизнесовое, его нужно определить словами: «у заказа не может быть двух событий одного статуса; если они есть, верным считаем самое раннее». Это правило записывается окном:

```sql
WITH ranked AS (
    SELECT order_id, status, changed_at, source,
           row_number() OVER (PARTITION BY order_id, status
                              ORDER BY changed_at) AS rn
    FROM order_status_history
)
SELECT status, count(*) FILTER (WHERE rn > 1) AS extra_events
FROM ranked
GROUP BY status
ORDER BY status;
```

```
  status   | extra_events
-----------+--------------
 CANCELLED |            0
 DELIVERED |            0
 NEW       |            0
 PAID      |            0
 SHIPPED   |         2718
```

Около 2,7 тысячи лишних `SHIPPED`. `PARTITION BY` задаёт признак дубля, `ORDER BY` — правило выбора. Если бы у двух дублей совпало и время, правило пришлось бы дополнить уникальным столбцом; в журнале без ключа такого столбца нет, и тогда `rn` между запусками может достаться разным строкам. Для подсчёта это не важно, для выбора атрибутов (`source`) — важно.

С платежами то же самое, но признак дубля другой: идентификатор платежа у провайдера.

```sql
WITH ranked AS (
    SELECT id, order_id, provider_id, amount, paid_at,
           row_number() OVER (PARTITION BY provider_id ORDER BY paid_at, id) AS rn
    FROM payments
)
SELECT count(*) FILTER (WHERE rn > 1)       AS extra_payments,
       sum(amount) FILTER (WHERE rn > 1)    AS extra_amount
FROM ranked;
```

```
 extra_payments | extra_amount
----------------+--------------
            548 |  21472091.10
```

Около 550 повторных уведомлений и примерно 21 млн рублей «лишних» поступлений, если суммировать платежи наивно. Правило выбора «самое раннее уведомление, при равенстве — меньший `id`» стоит записать в постановку: это решение аналитика, а не СУБД.

### Последнее состояние: ROW_NUMBER, DISTINCT ON и сверка с основной таблицей

Шаблон из Б.4 — последнее событие истории и сравнение с `orders.status`, который приложение хранит отдельно:

```sql
WITH ranked AS (
    SELECT order_id, status, changed_at,
           row_number() OVER (PARTITION BY order_id ORDER BY changed_at DESC) AS rn
    FROM order_status_history
)
SELECT o.status AS current_status, r.status AS last_in_history, count(*)
FROM ranked r
JOIN orders o ON o.id = r.order_id
WHERE r.rn = 1
GROUP BY 1, 2
ORDER BY 1, 2;
```

```
 current_status | last_in_history | count
----------------+-----------------+--------
 CANCELLED      | CANCELLED       |  12337
 DELIVERED      | DELIVERED       | 134050
 NEW            | NEW             |    480
 PAID           | PAID            |   1207
 SHIPPED        | PAID            |      5
 SHIPPED        | SHIPPED         |   2221
```

Пять заказов в статусе `SHIPPED`, у которых последнее событие истории — `PAID`. Все пять — у поставщика 33. Его система пишет время отгрузки на три часа раньше настоящего, и у части заказов отгрузка в журнале оказалась раньше оплаты. Окно сработало верно; неверны данные, и сверка с основной таблицей их показала.

В PostgreSQL то же самое короче:

```sql
SELECT DISTINCT ON (order_id) order_id, status, changed_at
FROM order_status_history
ORDER BY order_id, changed_at DESC;
```

`DISTINCT ON (ключ)` оставляет первую строку каждой группы в порядке `ORDER BY`, который должен начинаться с того же ключа. Это расширение PostgreSQL. В других СУБД пишут `ROW_NUMBER` и `rn = 1`, а в части из них (Snowflake, BigQuery, ClickHouse) есть `QUALIFY` — фильтр по окну без обёртки в CTE.

### LAG и LEAD: время между событиями

Задача: сколько часов проходит от оплаты до отгрузки у каждого поставщика. Естественное решение — оставить в истории `PAID` и `SHIPPED` и взять предыдущее событие через `LAG`:

```sql
WITH pay_ship AS (
    SELECT o.supplier_id, h.order_id, h.status, h.changed_at,
           lag(h.status)     OVER w AS prev_status,
           lag(h.changed_at) OVER w AS prev_at
    FROM order_status_history h
    JOIN orders o ON o.id = h.order_id
    WHERE h.status IN ('PAID', 'SHIPPED')
    WINDOW w AS (PARTITION BY h.order_id ORDER BY h.changed_at)
)
SELECT prev_status, status, count(*)
FROM pay_ship
WHERE supplier_id = 33
GROUP BY 1, 2
ORDER BY 3 DESC, 1, 2;
```

```
 prev_status | status  | count
-------------+---------+-------
             | PAID    |  3749
 PAID        | SHIPPED |  3560
 SHIPPED     | PAID    |   112
             | SHIPPED |   112
 SHIPPED     | SHIPPED |    77
```

`LAG` смещается на строку, а не на событие нужного типа. У поставщика 33 112 заказов «отгружены раньше оплаты»: пара `PAID → SHIPPED` у них не образуется, и они молча выпадают из расчёта. Дубли дают пары `SHIPPED → SHIPPED`. `WINDOW w AS (...)` — стандартный способ не повторять одно и то же определение окна.

Когда событий каждого типа у заказа должно быть по одному, надёжнее развернуть их в столбцы условной агрегацией и вычитать:

```sql
WITH events AS (               -- 1 строка = заказ
    SELECT order_id,
           min(changed_at) FILTER (WHERE status = 'PAID')    AS paid_at,
           min(changed_at) FILTER (WHERE status = 'SHIPPED') AS shipped_at
    FROM order_status_history
    GROUP BY order_id
)
SELECT count(*)                                     AS orders_cnt,
       count(*) FILTER (WHERE shipped_at < paid_at) AS shipped_before_paid
FROM events
WHERE paid_at IS NOT NULL AND shipped_at IS NOT NULL;
```

```
 orders_cnt | shipped_before_paid
------------+---------------------
     136276 |                 112
```

Теперь в расчёт попадают все отгруженные заказы, а 112 аномальных видны явно, а не теряются. Что с ними делать — задача 5. `min` одновременно решает вопрос дублей по правилу «самое раннее». Окно `LAG` остаётся инструментом для последовательностей, где важен именно соседний элемент: двойной клик, пауза между сессиями, смена цены.

**Медиана и перцентили — не оконные функции.** Среднее время отгрузки искажают хвосты, поэтому руководитель просит медиану и 90-й перцентиль. В PostgreSQL это `percentile_cont(0.5) WITHIN GROUP (ORDER BY x)` — упорядоченный агрегат (ordered-set aggregate). Он сворачивает группу в одну строку, как `avg`, и с `OVER` не работает:

```sql
SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY revenue) OVER ()
FROM report_daily_revenue;
```

```
ERROR:  OVER is not supported for ordered-set aggregate percentile_cont
```

Синтаксис `WITHIN GROUP` взят из стандарта SQL. В Oracle `PERCENTILE_CONT` бывает и агрегатом, и оконной функцией, в SQL Server — только оконной (`WITHIN GROUP (...) OVER (PARTITION BY ...)`, `OVER` обязателен), в PostgreSQL — только агрегатом. Полный расчёт перцентилей по типу интеграции — задача 5.

### Нарастающий итог и доля от целого

Два самых частых окна поверх агрегата:

```sql
WITH daily AS (                -- витрина без повторной загрузки 3 августа
    SELECT DISTINCT ON (report_date) report_date, revenue
    FROM report_daily_revenue
    ORDER BY report_date, loaded_at DESC
),
monthly AS (
    SELECT date_trunc('month', report_date)::date AS month, sum(revenue) AS revenue
    FROM daily
    GROUP BY 1
)
SELECT month,
       round(revenue / 1e6, 1)                           AS revenue_mln,
       round(sum(revenue) OVER (ORDER BY month) / 1e6, 1) AS running_mln,
       round(100 * revenue / sum(revenue) OVER (), 1)     AS share_pct
FROM monthly
ORDER BY month;
```

```
   month    | revenue_mln | running_mln | share_pct
------------+-------------+-------------+-----------
 2025-04-01 |       694.0 |       694.0 |      12.8
 2025-05-01 |       642.8 |      1336.9 |      11.9
 2025-06-01 |       705.3 |      2042.2 |      13.0
 2025-07-01 |       812.2 |      2854.3 |      15.0
 2025-08-01 |      1079.4 |      3933.7 |      20.0
 2025-09-01 |      1472.6 |      5406.3 |      27.2
```

`sum() OVER (ORDER BY month)` — нарастающий итог: рамка по умолчанию от начала до текущей строки. `sum() OVER ()` — итог по всей выборке, знаменатель доли. Ловушка рамки по умолчанию: если ключ сортировки не уникален, например нарастающий итог по `report_date` в витрине с двумя строками за 3 августа, обе строки-ровесницы получат одинаковый итог, уже включающий обе. Лечится уникальным ключом сортировки или явной рамкой `ROWS`.

### Скользящее среднее: ROWS против RANGE

Руководитель смотрит выручку со сглаживанием за 7 дней. Типичное решение — `ROWS BETWEEN 6 PRECEDING AND CURRENT ROW`. Но в витрине нет 12 июля: загрузка упала. Посмотрим, какие строки попадают в окно:

```sql
WITH daily AS (
    SELECT DISTINCT ON (report_date) report_date, revenue
    FROM report_daily_revenue
    ORDER BY report_date, loaded_at DESC
),
rolling AS (
    SELECT report_date, revenue,
           min(report_date) OVER (ORDER BY report_date
                                  ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS rows_from,
           count(*)         OVER (ORDER BY report_date
                                  RANGE BETWEEN interval '6 days' PRECEDING AND CURRENT ROW) AS days_in_range,
           avg(revenue)     OVER (ORDER BY report_date
                                  ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS avg_rows,
           avg(revenue)     OVER (ORDER BY report_date
                                  RANGE BETWEEN interval '6 days' PRECEDING AND CURRENT ROW) AS avg_range
    FROM daily
)
SELECT report_date, rows_from, days_in_range,
       round(avg_rows / 1e6, 2) AS avg_rows_mln, round(avg_range / 1e6, 2) AS avg_range_mln
FROM rolling
WHERE report_date BETWEEN '2025-07-11' AND '2025-07-19'
ORDER BY report_date;
```

```
 report_date | rows_from  | days_in_range | avg_rows_mln | avg_range_mln
-------------+------------+---------------+--------------+---------------
 2025-07-11  | 2025-07-05 |             7 |        25.31 |         25.31
 2025-07-13  | 2025-07-06 |             6 |        24.91 |         24.84
 2025-07-14  | 2025-07-07 |             6 |        24.83 |         24.82
 2025-07-15  | 2025-07-08 |             6 |        24.78 |         25.12
 2025-07-16  | 2025-07-09 |             6 |        25.26 |         24.97
 2025-07-17  | 2025-07-10 |             6 |        25.37 |         25.57
 2025-07-18  | 2025-07-11 |             6 |        25.82 |         25.75
 2025-07-19  | 2025-07-13 |             7 |        26.28 |         26.28
```

`ROWS` берёт 7 строк, и для 13 июля окно начинается 6 июля — это восемь календарных дней. `RANGE BETWEEN interval '6 days' PRECEDING` берёт строки, дата которых не дальше шести дней от текущей: окно всегда календарная неделя, но в нём шесть дней вместо семи, пока пропуск в него попадает. Ни один вариант не «чинит» пропуск. Честное решение — соединить витрину с календарём из `generate_series` и решить явно, что такое пропущенный день: ноль, «нет данных» или повод перезагрузить витрину. `RANGE` со смещением-интервалом есть в PostgreSQL с 11-й версии; в MySQL 8 и Oracle тоже есть, в SQL Server — нет, там остаётся календарь.

### Топ-N в группе: ROW_NUMBER, RANK, DENSE_RANK

Топ-3 товара по выручке в каждой корневой категории. В нашем дереве ровно три уровня, поэтому корень можно найти двумя соединениями; для дерева произвольной глубины нужна рекурсия из [В.3](v3-cte-decomposition.md).

```sql
WITH product_root AS (
    SELECT p.id AS product_id, p.sku, root.name AS root_name
    FROM products p
    JOIN categories leaf ON leaf.id = p.category_id
    JOIN categories sub  ON sub.id  = leaf.parent_id
    JOIN categories root ON root.id = sub.parent_id
),
product_revenue AS (
    SELECT i.product_id, sum(i.qty * i.price) AS revenue
    FROM order_items i
    JOIN orders o ON o.id = i.order_id
    WHERE o.status = 'DELIVERED'
    GROUP BY i.product_id
),
ranked AS (
    SELECT pr.root_name, pr.product_id, pr.sku, r.revenue,
           row_number() OVER w AS rn,
           rank()       OVER w AS rnk,
           dense_rank() OVER w AS drnk
    FROM product_root pr
    JOIN product_revenue r ON r.product_id = pr.product_id
    WINDOW w AS (PARTITION BY pr.root_name ORDER BY r.revenue DESC)
)
SELECT root_name, rn, rnk, drnk, product_id, sku, round(revenue / 1e6, 2) AS revenue_mln
FROM ranked
WHERE rnk <= 3
ORDER BY root_name, rn;
```

```
  root_name  | rn | rnk | drnk | product_id |    sku     | revenue_mln
-------------+----+-----+------+------------+------------+-------------
 Автотовары  |  1 |   1 |    1 |        752 | SKU-00752  |        4.90
 ...
 Офис        |  1 |   1 |    1 |       4272 | SKU-04272  |        5.03
 Офис        |  2 |   2 |    2 |       4953 | SKU-04953  |        4.63
 Офис        |  3 |   3 |    3 |       4977 | sku-00017  |        4.37
 ...
```

В верхней части рейтинга равенств нет, и три функции дали одно и то же. Разница проявляется, когда значения совпадают: `ROW_NUMBER` всегда вернёт ровно N строк, выбрав между равными произвольно; `RANK` вернёт всех, кто делит N-е место, и строк может стать больше N; `DENSE_RANK` вернёт N различных значений, и строк может стать намного больше. Выбор — бизнес-решение: «ровно три карточки на витрине» — `ROW_NUMBER` с дополнительным ключом сортировки, «все, кто в тройке лидеров» — `RANK`.

Заодно рейтинг поймал дефект справочника: товар 4977 с артикулом `sku-00017 ` — повторно заведённый `SKU-00017`, причём в другой категории. Выручка одного товара разделилась между двумя карточками.

### first_value и last_value: ловушка рамки

```sql
SELECT order_id, status, changed_at,
       first_value(status) OVER w AS first_status,
       last_value(status)  OVER w AS last_status_wrong,
       last_value(status)  OVER (PARTITION BY order_id ORDER BY changed_at
                                 ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_status
FROM order_status_history
WHERE order_id = 100
WINDOW w AS (PARTITION BY order_id ORDER BY changed_at)
ORDER BY changed_at;
```

```
 order_id |  status   |          changed_at           | first_status | last_status_wrong | last_status
----------+-----------+-------------------------------+--------------+-------------------+-------------
      100 | NEW       | 2025-04-01 00:14:30.439216+00 | NEW          | NEW               | DELIVERED
      100 | PAID      | 2025-04-01 00:16:30.439216+00 | NEW          | PAID              | DELIVERED
      100 | SHIPPED   | 2025-04-02 05:31:06.397147+00 | NEW          | SHIPPED           | DELIVERED
      100 | SHIPPED   | 2025-04-02 05:31:07.397147+00 | NEW          | SHIPPED           | DELIVERED
      100 | DELIVERED | 2025-04-03 01:47:18.120127+00 | NEW          | DELIVERED         | DELIVERED
```

Рамка по умолчанию заканчивается на текущей строке, поэтому `last_value` возвращает текущий статус. Нужна явная рамка до конца группы. Проще и надёжнее — `first_value` с обратной сортировкой. Заодно видно и дубль `SHIPPED` у заказа 100.

### Острова и пропуски

**Острова.** В `stock_snapshots` остаток на конец дня. Серия stock-out — подряд идущие дни с нулевым остатком. Приём: оставить только нулевые дни и вычесть из даты номер строки внутри товара. У дней одной серии дата и номер растут синхронно, разность постоянна и становится ключом группы.

```sql
WITH zero_days AS (
    SELECT product_id, snapshot_date,
           snapshot_date
             - (row_number() OVER (PARTITION BY product_id ORDER BY snapshot_date))::int AS grp
    FROM stock_snapshots
    WHERE product_id = 71 AND on_hand = 0
)
SELECT grp, min(snapshot_date) AS from_date, max(snapshot_date) AS to_date, count(*) AS days
FROM zero_days
GROUP BY grp
ORDER BY from_date;
```

```
    grp     | from_date  |  to_date   | days
------------+------------+------------+------
 2025-05-11 | 2025-05-12 | 2025-05-25 |   14
 2025-06-20 | 2025-07-05 | 2025-07-05 |    1
 2025-06-21 | 2025-07-07 | 2025-07-09 |    3
 2025-06-26 | 2025-07-15 | 2025-07-20 |    6
 ...
```

Товар 71 — поставщика 31, у которого 10–14 июля нет снимков. До и после пропуска остаток нулевой, но приём «дата минус номер» разрезал серию на 3 и 6 дней, потому что дата скакнула на шесть дней (пять пропущенных), а номер — на один. Это правильное поведение: что было с остатком в дни без данных, мы не знаем, и склеивать серию через пропуск — допущение, которое надо проговорить. Если вместо дат вычитать номера строк среди всех снимков, пропуск склеится, и получится серия в 9 дней на 14 календарных.

**Пропуски.** «Дни без успешной загрузки фида» — сравнение каждой даты со следующей через `LEAD`:

```sql
WITH load_days AS (
    SELECT DISTINCT supplier_id, loaded_at::date AS load_date
    FROM supplier_feed_loads
    WHERE status = 'OK' AND rows_loaded > 0
),
with_next AS (
    SELECT supplier_id, load_date,
           lead(load_date) OVER (PARTITION BY supplier_id ORDER BY load_date) AS next_date
    FROM load_days
)
SELECT supplier_id, load_date AS last_before_gap, next_date,
       next_date - load_date - 1 AS missing_days
FROM with_next
WHERE next_date - load_date > 1
  AND supplier_id NOT BETWEEN 36 AND 40      -- ручные поставщики не грузят по выходным
ORDER BY missing_days DESC, supplier_id;
```

```
 supplier_id | last_before_gap | next_date  | missing_days
-------------+-----------------+------------+--------------
          31 | 2025-07-09      | 2025-07-15 |            5
          33 | 2025-09-02      | 2025-09-06 |            3
          33 | 2025-09-09      | 2025-09-13 |            3
```

Пять дней без фида у поставщика 31 — та самая причина, по которой все его заказы 8–15 июля опоздали (В.3). У поставщика 33 загрузки формально были, со статусом `OK`, но пустые: условие `rows_loaded > 0` их и показало. Без него поставщик 33 выглядел бы здоровым.

**Двойной клик.** `LAG` внутри покупателя: сколько секунд прошло с предыдущего заказа.

```sql
WITH seq AS (
    SELECT id, customer_id, supplier_id, total_amount, status, created_at,
           lag(created_at)   OVER w AS prev_created_at,
           lag(supplier_id)  OVER w AS prev_supplier_id,
           lag(total_amount) OVER w AS prev_amount
    FROM orders
    WINDOW w AS (PARTITION BY customer_id ORDER BY created_at, id)
)
SELECT count(*)                                         AS suspects,
       count(*) FILTER (WHERE status = 'CANCELLED')     AS cancelled,
       min(extract(epoch FROM created_at - prev_created_at)) AS min_sec,
       max(extract(epoch FROM created_at - prev_created_at)) AS max_sec
FROM seq
WHERE created_at - prev_created_at <= interval '10 seconds'
  AND supplier_id = prev_supplier_id
  AND total_amount = prev_amount;
```

```
 suspects | cancelled | min_sec  | max_sec
----------+-----------+----------+----------
      298 |       298 | 2.000000 | 5.000000
```

Около 300 заказов-копий через 2–5 секунд, все отменены. Если убрать условие о сумме, их ровно 300: у двух пар сумма различается на 10% — у одного из заказов пары сработала скидка, которой нет в позициях. Критерий дубля «та же сумма» оказался слишком строгим из-за другого дефекта.

### Типичные ошибки

- Дедуплицировать через `DISTINCT`, когда дубли различаются временем или служебным полем.
- `ROW_NUMBER` без проговорённого правила выбора и без уникального ключа в `ORDER BY` окна.
- Доверять `orders.status` или журналу по отдельности, не сверив их.
- Считать интервал через `LAG`, не проверив, что предыдущая строка — событие нужного типа.
- Писать `percentile_cont ... OVER` и удивляться ошибке; путать медиану со средним.
- `ROWS BETWEEN 6 PRECEDING` в ряду с пропусками дат.
- Топ-N через `ROW_NUMBER` там, где бизнес ждёт «всех, кто разделил место».
- `last_value` без явной рамки.
- Склеивать серии через пропуски данных, не сказав об этом.

### Как говорить об этом на собеседовании

На задаче «последний статус» сильный ответ начинается не с кода, а с правила: «Беру последнее событие по времени; при равенстве времени нужен тай-брейк — уникальный идентификатор события или приоритет статуса. Сверю результат с текущим статусом в основной таблице: расхождения покажут проблемы интеграции». Про дубли: «`DISTINCT` не поможет, если повтор пришёл с другим временем. Признак дубля определяю по бизнес-ключу и выбираю строку `ROW_NUMBER` по явному правилу».

Хороший тон — сразу назвать ловушки: «скользящее среднее считаю по календарю, а не по строкам, потому что в витрине могут быть пропуски», «для топ-3 уточню, что делать с равенством», «медиана — это агрегат `WITHIN GROUP`, не окно». Упоминание `QUALIFY` и `DISTINCT ON` с оговоркой о переносимости показывает, что вы работали с разными СУБД.

### Коротко

- Окно: `PARTITION BY` — группы, `ORDER BY` — порядок, рамка — видимые строки; с `ORDER BY` рамка по умолчанию заканчивается на текущей строке и её ровесниках.
- Окна считаются после `WHERE` и `GROUP BY`; фильтр по окну — во внешнем запросе.
- Дедупликация: признак дубля в `PARTITION BY`, правило выбора в `ORDER BY`, проговорить правило словами.
- Последнее состояние: `ROW_NUMBER ... DESC` и `rn = 1` или `DISTINCT ON`; сверять с основной таблицей.
- `LAG` смещается на строку, а не на событие; для пар событий надёжнее условная агрегация.
- `percentile_cont` — упорядоченный агрегат, а не окно.
- `ROWS` — строки, `RANGE` с интервалом — календарь; пропуск дня не чинит ни то, ни другое.
- `ROW_NUMBER`, `RANK`, `DENSE_RANK` различаются только при равенстве, и это бизнес-решение.
- `last_value` требует явной рамки до конца группы.
- Острова: дата минус номер строки; пропуски: `LEAD` и сравнение со следующим значением.
<!-- LESSON:END -->

## Читать дальше

- Документация PostgreSQL: [Window Functions (учебник)](https://www.postgresql.org/docs/current/tutorial-window.html), [Window Function Calls (синтаксис рамок)](https://www.postgresql.org/docs/current/sql-expressions.html#SYNTAX-WINDOW-FUNCTIONS), [Window Functions (справочник функций)](https://www.postgresql.org/docs/current/functions-window.html).
- Документация PostgreSQL: [Ordered-Set Aggregate Functions](https://www.postgresql.org/docs/current/functions-aggregate.html#FUNCTIONS-ORDEREDSET-TABLE), [DISTINCT ON](https://www.postgresql.org/docs/current/sql-select.html#SQL-DISTINCT).
- Маркус Винанд, use-the-index-luke.com и modern-sql.com — оконные функции и их поддержка в разных СУБД.
- Джо Селко, «SQL for Smarties» — задачи на последовательности, острова и пропуски.

## Практика

Задачи решаются на стенде. Сначала решите сами с таймером, потом сверяйтесь с разбором.

### Задача 1. Дедупликация истории статусов

Постройте «чистую» историю статусов: по одному событию каждого статуса на заказ. Верните одной строкой: число строк в исходной истории, число строк в чистой, число лишних событий и число заказов, у которых были дубли. Отдельно проверьте, к каким заказам относятся дубли — есть ли у них закономерность. Таймер: 10 минут.

<details markdown="1">
<summary>Решение и разбор</summary>

```sql
WITH ranked AS (
    SELECT order_id, status, changed_at, source,
           row_number() OVER (PARTITION BY order_id, status
                              ORDER BY changed_at) AS rn
    FROM order_status_history
),
clean_history AS (
    SELECT order_id, status, changed_at, source
    FROM ranked
    WHERE rn = 1
)
SELECT (SELECT count(*) FROM order_status_history)                    AS raw_rows,
       (SELECT count(*) FROM clean_history)                           AS clean_rows,
       (SELECT count(*) FROM ranked WHERE rn > 1)                     AS extra_rows,
       (SELECT count(DISTINCT order_id) FROM ranked WHERE rn > 1)     AS orders_with_dups,
       (SELECT count(*) FROM ranked WHERE rn > 1 AND order_id % 50 <> 0) AS not_every_50th;
```

```
 raw_rows | clean_rows | extra_rows | orders_with_dups | not_every_50th
----------+------------+------------+------------------+----------------
   579101 |     576383 |       2718 |             2718 |              0
```

Около 2,7 тысячи лишних событий, по одному на заказ, все — `SHIPPED`, и все у заказов с номером, кратным 50. Такую закономерность стоит искать всегда: она подсказывает, что дубли порождает не поведение пользователей, а механизм интеграции, и с ним надо идти к разработке.

Правило «самое раннее» выбрано осознанно: повтор пришёл на секунду позже, первое событие — настоящее. Для `SHIPPED` это почти не влияет на интервалы, но влияет на любые подсчёты событий: «сколько отгрузок было в день» без дедупликации завышено.

</details>

### Задача 2. Топ-3 товара по выручке в каждой корневой категории

Верните топ-3 товара по выручке доставленных заказов в каждой из пяти корневых категорий: категория, место, товар, артикул, выручка. Объясните, какую функцию ранжирования вы выбрали и что произойдёт при равенстве выручки. Затем постройте «антирейтинг» — три товара с наименьшей выручкой в каждой категории (среди продававшихся) — и сравните, сколько строк вернут `ROW_NUMBER`, `RANK` и `DENSE_RANK`. Таймер: 15 минут.

<details markdown="1">
<summary>Решение и разбор</summary>

Топ-3 — запрос из урока. Равенств в верхней части нет, все три функции дают по три строки на категорию. Антирейтинг — тот же запрос с обратной сортировкой; посчитаем, сколько строк отобрала бы каждая функция:

```sql
WITH product_root AS (
    SELECT p.id AS product_id, root.name AS root_name
    FROM products p
    JOIN categories leaf ON leaf.id = p.category_id
    JOIN categories sub  ON sub.id  = leaf.parent_id
    JOIN categories root ON root.id = sub.parent_id
),
product_revenue AS (
    SELECT i.product_id, sum(i.qty * i.price) AS revenue
    FROM order_items i
    JOIN orders o ON o.id = i.order_id
    WHERE o.status = 'DELIVERED'
    GROUP BY i.product_id
),
ranked AS (
    SELECT pr.root_name, pr.product_id, r.revenue,
           row_number() OVER w AS rn,
           rank()       OVER w AS rnk,
           dense_rank() OVER w AS drnk
    FROM product_root pr
    JOIN product_revenue r ON r.product_id = pr.product_id
    WINDOW w AS (PARTITION BY pr.root_name ORDER BY r.revenue)
)
SELECT root_name,
       count(*) FILTER (WHERE rn   <= 3) AS by_row_number,
       count(*) FILTER (WHERE rnk  <= 3) AS by_rank,
       count(*) FILTER (WHERE drnk <= 3) AS by_dense_rank,
       count(*) FILTER (WHERE revenue = 0) AS zero_revenue
FROM ranked
GROUP BY root_name
ORDER BY root_name;
```

```
  root_name  | by_row_number | by_rank | by_dense_rank | zero_revenue
-------------+---------------+---------+---------------+--------------
 Автотовары  |             3 |       3 |             4 |            2
 Дом и сад   |             3 |       3 |             3 |            1
 Офис        |             3 |       4 |             6 |            4
 Стройка     |             3 |       3 |             5 |            3
 Электроника |             3 |       4 |             6 |            4
```

Внизу рейтинга равенства есть: товары с нулевой ценой продавались, но выручки не принесли. В «Офисе» четыре товара делят первое место снизу: `ROW_NUMBER` произвольно возьмёт три из четырёх, `RANK` вернёт всех четырёх, `DENSE_RANK` — четыре нулевых и ещё два следующих значения.

Как выбирать: для витрины «три карточки» — `ROW_NUMBER` с тай-брейком (`ORDER BY revenue DESC, product_id`), чтобы результат не менялся между запусками. Для отчёта «кто в тройке» — `RANK`: несправедливо выкинуть товар, который разделил третье место. `DENSE_RANK` нужен редко — когда важны именно три различных значения.

Сами нули — дефект справочника: 15 товаров заведены с ценой 0. В топе «Офиса» на третьем месте стоит товар 4977 с артикулом `sku-00017 ` — дубль карточки 17 в другой категории. Обе находки стоят строки в отчёте для владельца справочника.

</details>

### Задача 3. Самая длинная серия нулевого остатка

Для каждого из десяти товаров поставщика 1, по которым есть снимки остатков, найдите самую длинную серию подряд идущих дней с нулевым остатком: товар, число серий stock-out за период, начало и конец самой длинной серии, её длина в днях. При равной длине берите более раннюю серию. Таймер: 15 минут.

<details markdown="1">
<summary>Решение и разбор</summary>

```sql
WITH zero_days AS (
    SELECT s.product_id, s.snapshot_date,
           s.snapshot_date
             - (row_number() OVER (PARTITION BY s.product_id ORDER BY s.snapshot_date))::int AS grp
    FROM stock_snapshots s
    JOIN products p ON p.id = s.product_id
    WHERE p.supplier_id = 1
      AND s.on_hand = 0
),
streaks AS (                   -- 1 строка = серия stock-out
    SELECT product_id, grp,
           min(snapshot_date) AS from_date,
           max(snapshot_date) AS to_date,
           count(*)           AS days
    FROM zero_days
    GROUP BY product_id, grp
),
ranked AS (
    SELECT st.*,
           row_number() OVER (PARTITION BY product_id ORDER BY days DESC, from_date) AS rn,
           count(*)     OVER (PARTITION BY product_id) AS streaks_cnt
    FROM streaks st
)
SELECT product_id, streaks_cnt, from_date, to_date, days
FROM ranked
WHERE rn = 1
ORDER BY days DESC, product_id;
```

```
 product_id | streaks_cnt | from_date  |  to_date   | days
------------+-------------+------------+------------+------
          1 |           8 | 2025-09-11 | 2025-09-25 |   15
        281 |           5 | 2025-06-13 | 2025-06-27 |   15
         41 |           7 | 2025-06-26 | 2025-07-09 |   14
        121 |           7 | 2025-07-11 | 2025-07-24 |   14
        161 |           8 | 2025-04-25 | 2025-05-07 |   13
        241 |           7 | 2025-08-30 | 2025-09-11 |   13
        361 |           6 | 2025-05-05 | 2025-05-17 |   13
        201 |          10 | 2025-05-30 | 2025-06-10 |   12
         81 |          12 | 2025-06-05 | 2025-06-15 |   11
        321 |           7 | 2025-04-01 | 2025-04-11 |   11
```

Два окна над разными уровнями: первое нумерует нулевые дни внутри товара, второе ранжирует уже готовые серии. `count(*) OVER (PARTITION BY product_id)` добавляет число серий, не сворачивая строки. Тай-брейк `from_date` выполняет требование «при равенстве — более ранняя».

Ловушка проявляется у поставщика 31, а не у поставщика 1: в его снимках нет 10–14 июля, и серии, которые идут через пропуск, разрываются. Перед тем как отчитываться о stock-out, проверьте полноту снимков — число дней на товар (у большинства 183) — и скажите явно, как вы обошлись с пропусками.

</details>

### Задача 4. Скользящее среднее выручки витрины

Посчитайте 7-дневное скользящее среднее выручки по витрине `report_daily_revenue` двумя способами — через `ROWS` и через `RANGE` — и верните только те дни, где результаты расходятся. Сначала сделайте это прямо по витрине, не убирая повторов, потом — по витрине без повторной загрузки. Объясните каждое расхождение. Таймер: 15 минут.

<details markdown="1">
<summary>Решение и разбор</summary>

```sql
WITH rolling AS (
    SELECT report_date, loaded_at,
           avg(revenue) OVER (ORDER BY report_date
                              ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS avg_rows,
           avg(revenue) OVER (ORDER BY report_date
                              RANGE BETWEEN interval '6 days' PRECEDING AND CURRENT ROW) AS avg_range
    FROM report_daily_revenue
)
SELECT report_date, loaded_at,
       round(avg_rows / 1e6, 2)  AS avg_rows_mln,
       round(avg_range / 1e6, 2) AS avg_range_mln
FROM rolling
WHERE round(avg_rows / 1e6, 2) <> round(avg_range / 1e6, 2)
ORDER BY report_date, loaded_at;
```

```
 report_date |       loaded_at        | avg_rows_mln | avg_range_mln
-------------+------------------------+--------------+---------------
 2025-07-13  | 2025-07-14 04:00:00+00 |        24.91 |         24.84
 ...
 2025-07-18  | 2025-07-19 04:00:00+00 |        25.82 |         25.75
 2025-08-03  | 2025-08-04 04:00:00+00 |        29.23 |         29.11
 2025-08-03  | 2025-08-04 10:00:00+00 |        29.09 |         29.11
 2025-08-04  | 2025-08-05 04:00:00+00 |        29.64 |         29.83
 ...
 2025-08-09  | 2025-08-10 04:00:00+00 |        31.72 |         31.28
```

На сырой витрине расхождений два блока, и у них разные причины.

- **13–18 июля** — пропущенный день 12 июля. `ROWS` дотягивается до восьми календарных дней назад, `RANGE` берёт календарную неделю из шести строк.
- **3–9 августа** — 3 августа загружено дважды. Для `ROWS` повтор — лишняя строка: окно сдвигается, и две строки одной даты получают разные средние (порядок между ними не определён). Для `RANGE` обе строки — ровесники, обе попадают в окно, и 3 августа учитывается в среднем дважды.

После дедупликации (`DISTINCT ON (report_date) ... ORDER BY report_date, loaded_at DESC`, как в уроке) расходятся только шесть дней, с 13 по 18 июля. Средние при этом отличаются не больше чем на полтора процента: дневная выручка ровная. На неровном ряду — понедельничные пики, распродажи — разница будет заметной.

Ни один вариант не исправляет данные. Правильная последовательность: убрать повторные загрузки, соединить с календарём, решить, что делать с 12 июля (в источнике доставки в этот день есть — витрину надо перезагрузить), и только потом сглаживать.

</details>

### Задача 5. Время от оплаты до отгрузки по типу интеграции

Посчитайте время от оплаты до отгрузки в часах: число заказов, медиана и 90-й перцентиль по типу интеграции поставщика и общий итог. Учтите дубли `SHIPPED` в истории и аномалию поставщика 33. Сравните с «наивным» запросом, который соединяет историю саму с собой по статусам `PAID` и `SHIPPED`. Таймер: 20 минут.

<details markdown="1">
<summary>Решение и разбор</summary>

Наивный запрос:

```sql
SELECT s.integration_type,
       count(*)             AS rows_cnt,
       count(DISTINCT o.id) AS orders_cnt,
       count(*) FILTER (WHERE sh.changed_at < pd.changed_at) AS negative_cnt,
       round(percentile_cont(0.5) WITHIN GROUP (
             ORDER BY extract(epoch FROM sh.changed_at - pd.changed_at) / 3600)::numeric, 1) AS median_h,
       round(percentile_cont(0.9) WITHIN GROUP (
             ORDER BY extract(epoch FROM sh.changed_at - pd.changed_at) / 3600)::numeric, 1) AS p90_h
FROM orders o
JOIN suppliers s ON s.id = o.supplier_id
JOIN order_status_history pd ON pd.order_id = o.id AND pd.status = 'PAID'
JOIN order_status_history sh ON sh.order_id = o.id AND sh.status = 'SHIPPED'
GROUP BY s.integration_type
ORDER BY 1;
```

```
 integration_type | rows_cnt | orders_cnt | negative_cnt | median_h | p90_h
------------------+----------+------------+--------------+----------+-------
 api              |    91103 |      89389 |            0 |     20.7 |  44.2
 manual           |    11095 |      10848 |            0 |     18.4 |  37.1
 sftp             |    36796 |      36039 |          113 |     21.5 |  46.1
```

Две проблемы видны прямо в результате. Строк больше, чем заказов, — дубли `SHIPPED` размножили пары. И у SFTP есть отрицательные интервалы: отгрузка раньше оплаты. Все они у поставщика 33, и сверка с `shipments` показывает, что все события `SHIPPED` этого поставщика расходятся с таблицей отгрузок на минус три часа (у дублей — на секунду меньше): его система пишет московское время с пометкой UTC.

Исправленный запрос: одна строка на заказ, ранние события — по правилу дедупликации, время поставщика 33 сдвинуто обратно. Правильнее было бы взять время отгрузки из `shipments`, но покажем исправление журнала, раз задача про него.

```sql
WITH events AS (               -- 1 строка = заказ
    SELECT h.order_id,
           min(h.changed_at) FILTER (WHERE h.status = 'PAID') AS paid_at,
           min(h.changed_at
               + CASE WHEN o.supplier_id = 33 AND h.source = 'supplier'
                      THEN interval '3 hours' ELSE interval '0' END)
               FILTER (WHERE h.status = 'SHIPPED')             AS shipped_at
    FROM order_status_history h
    JOIN orders o ON o.id = h.order_id
    GROUP BY h.order_id
),
intervals AS (
    SELECT s.integration_type,
           extract(epoch FROM e.shipped_at - e.paid_at) / 3600 AS hours_to_ship
    FROM events e
    JOIN orders o    ON o.id = e.order_id
    JOIN suppliers s ON s.id = o.supplier_id
    WHERE e.paid_at IS NOT NULL AND e.shipped_at IS NOT NULL
)
SELECT coalesce(integration_type, 'ИТОГО') AS integration_type,
       count(*)                                       AS orders_cnt,
       count(*) FILTER (WHERE hours_to_ship < 0)      AS negative_cnt,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY hours_to_ship)::numeric, 1) AS median_h,
       round(percentile_cont(0.9) WITHIN GROUP (ORDER BY hours_to_ship)::numeric, 1) AS p90_h
FROM intervals
GROUP BY ROLLUP (integration_type)
ORDER BY integration_type;
```

```
 integration_type | orders_cnt | negative_cnt | median_h | p90_h
------------------+------------+--------------+----------+-------
 api              |      89389 |            0 |     20.7 |  44.2
 manual           |      10848 |            0 |     18.4 |  37.1
 sftp             |      36039 |            0 |     21.8 |  46.1
 ИТОГО            |     136276 |            0 |     20.8 |  44.3
```

Число заказов теперь совпадает с числом отгрузок в `shipments`, отрицательных интервалов нет. Медианы почти не изменились: дубль отстоит на секунду, а сдвиг в три часа затрагивает один поставщик из десяти. Это не повод пропускать очистку. На среднем, на подсчёте событий и на отдельном поставщике те же дефекты дают заметную ошибку, а запрос с отрицательными интервалами в отчёте подрывает доверие ко всем цифрам.

Главный вывод о бизнесе: от оплаты до отгрузки все типы интеграции тратят около суток, и разница между ними — часы. Опоздания SFTP-поставщиков из В.3 рождаются не на складе, а на этапе доставки. Обратите внимание: `percentile_cont` здесь — обычный агрегат в `GROUP BY ROLLUP`, без всякого `OVER`.

</details>

## Вопросы для самопроверки

1. Из каких трёх частей состоит определение окна и какая рамка действует по умолчанию при наличии `ORDER BY`?
2. Почему оконную функцию нельзя использовать в `WHERE` и как обойти это ограничение?
3. Как удалить дубли событий, которые различаются временем на секунду? Почему `DISTINCT` не поможет?
4. Чем `DISTINCT ON` отличается от `ROW_NUMBER() ... rn = 1` и как сделать то же в другой СУБД?
5. Почему `LAG` может дать неверный интервал между оплатой и отгрузкой?
6. Можно ли посчитать медиану оконной функцией в PostgreSQL? Что такое `WITHIN GROUP`?
7. Чем `ROWS BETWEEN 6 PRECEDING` отличается от `RANGE BETWEEN interval '6 days' PRECEDING` на ряду с пропущенным днём?
8. Когда для топ-3 вы выберете `RANK`, а когда `ROW_NUMBER`? Как найти самую длинную серию дней без остатка?

## Заметки

<!-- Свои формулировки, ошибки, ссылки. -->
