---
title: "В.1 Разведка данных"
parent: "0В. SQL-практикум"
nav_order: 1
---

# В.1 Разведка незнакомой базы: схема, гранулярность, профиль данных

## Зачем это аналитику

Первые пятнадцать минут с незнакомой базой решают, чему вы потом поверите. На проекте это доступ к реплике без документации и вопрос «почему просели доставки», на live-интервью — три таблицы на экране и «посчитайте долю опоздавших заказов». И там и там ошибаются не в синтаксисе, а раньше: не выяснили, что такое одна строка таблицы, не заметили пропусков и дублей, посчитали метрику по грязным данным. Этот модуль — порядок действий, который превращает незнакомую базу в понятную: каталог, гранулярность, профиль столбцов, проверка гипотез.

## Готовность к модулю

Модуль опирается на темы ниже. Если какая-то из них незнакома или её вопросы для самопроверки даются с трудом, начните с неё.

- [А.5 SQL для аналитика](../00a-foundations/a5-sql-basics.md)
- [А.4 Реляционные БД](../00a-foundations/a4-relational-model.md)

## Куда ведёт

Тема подробнее раскрывается в модулях:

- [В.2 Соединения](v2-joins.md)
- [9.5 Качество данных](../09-data-platforms/9.5-data-quality-governance.md)

## Что понять

- [ ] **Каталог** базы: `\d` в psql и `information_schema` (`columns`, `table_constraints`) — как за пять минут найти таблицы, ключи и связи без документации.
- [ ] **Гранулярность** (grain) таблицы: что такое одна строка. Её формулируют словами и **проверяют запросом** на уникальность ключа.
- [ ] Почему неуникальный `payments.order_id` меняет любой запрос, который соединяет платежи с заказами.
- [ ] **Профиль столбца**: `count(*)`, `count(col)`, `count(DISTINCT col)`, доля `NULL`, `min`/`max`, топ значений с долями.
- [ ] `NULL` в агрегатах и сравнениях: `avg` пропускает `NULL`, `NULL = NULL` — не истина; `COALESCE` и `NULLIF` против деления на ноль.
- [ ] **Условные агрегаты**: `FILTER (WHERE ...)` и переносимая форма `SUM(CASE ...)` — сводка в одну строку на объект.
- [ ] `WHERE` против `HAVING` на живом примере: где фильтр меняет знаменатель доли.
- [ ] **Проверка гипотез** о данных: дубли после нормализации, нулевые цены, пропуски по срезам.
- [ ] Чек-лист профиля таблицы и как проговаривать разведку на собеседовании.

## Урок

<!-- LESSON:START -->
Все примеры выполняются на [стенде](lab/README.md) — учебной базе маркетплейса; запросы проверены на PostgreSQL 16.

### Шаг 1. Каталог: какие таблицы и как они связаны

Начинают не с `SELECT *`, а с каталога. В psql две команды дают почти всё: `\dt` — список таблиц, `\d orders` — столбцы, ключи, ограничения и, что особенно ценно, раздел `Referenced by` — кто ссылается на эту таблицу.

```
                          Table "public.orders"
    Column    |           Type           | Collation | Nullable | Default
--------------+--------------------------+-----------+----------+---------
 id           | bigint                   |           | not null |
 ...
 promised_at  | timestamp with time zone |           |          |
Indexes:
    "orders_pkey" PRIMARY KEY, btree (id)
...
Referenced by:
    TABLE "order_items" CONSTRAINT "order_items_order_id_fkey" FOREIGN KEY (order_id) REFERENCES orders(id)
    TABLE "order_status_history" CONSTRAINT ...
    TABLE "payments" CONSTRAINT ...
    TABLE "shipments" CONSTRAINT ...
```

Уже видно: `promised_at` — единственный столбец, допускающий `NULL`, и вокруг заказа четыре дочерние таблицы.

Если psql нет (DBeaver, веб-консоль, другая СУБД), то же самое отдаёт `information_schema` — стандартный каталог, который есть в PostgreSQL, MySQL и SQL Server. Все ключи базы одним запросом:

```sql
SELECT tc.table_name, tc.constraint_type, kcu.column_name
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
    ON kcu.constraint_name = tc.constraint_name
   AND kcu.table_schema = tc.table_schema
WHERE tc.table_schema = 'public'
  AND tc.constraint_type IN ('PRIMARY KEY', 'FOREIGN KEY')
ORDER BY tc.table_name, tc.constraint_type, kcu.column_name;
```

```
      table_name      | constraint_type |  column_name
----------------------+-----------------+---------------
 ...
 order_items          | PRIMARY KEY     | line_no
 order_items          | PRIMARY KEY     | order_id
 order_status_history | FOREIGN KEY     | order_id
 orders               | FOREIGN KEY     | customer_id
 ...
```

Отдельно полезно найти таблицы **без** первичного ключа — у них гранулярность не гарантирована ничем:

```sql
SELECT t.table_name
FROM information_schema.tables t
WHERE t.table_schema = 'public'
  AND t.table_type = 'BASE TABLE'
  AND NOT EXISTS (
      SELECT 1
      FROM information_schema.table_constraints tc
      WHERE tc.table_schema = t.table_schema
        AND tc.table_name = t.table_name
        AND tc.constraint_type = 'PRIMARY KEY'
  );
```

На стенде это `order_status_history` и `report_daily_revenue` — журнал событий и витрина. Обе таблицы ниже окажутся с дублями.

В рабочих базах внешних ключей часто нет вовсе: их не объявляют ради скорости загрузки или потому, что данные приходят из разных систем. Тогда связи ищут по именам столбцов (`information_schema.columns WHERE column_name LIKE '%\_id'`) и по пересечению значений. Размер таблиц без полного подсчёта даёт статистика: `SELECT relname, n_live_tup FROM pg_stat_user_tables` — приблизительно, но мгновенно.

### Шаг 2. Гранулярность: что такое одна строка

Гранулярность (grain) — ответ на вопрос «одна строка этой таблицы — это что?». Формулировка должна быть точной: «одна строка `orders` — один заказ», «одна строка `order_items` — одна позиция заказа», «одна строка `payments` — …». Вот здесь интуиция подводит: хочется сказать «платёж по заказу», и мысленно поставить знак равенства между платежом и заказом.

Гипотезу о гранулярности проверяют запросом: есть ли значения предполагаемого ключа, которые встречаются больше одного раза.

```sql
SELECT count(*)                    AS rows_cnt,
       count(DISTINCT id)          AS uniq_id,
       count(DISTINCT order_id)    AS uniq_orders,
       count(DISTINCT provider_id) AS uniq_provider_ids
FROM payments;
```

```
 rows_cnt | uniq_id | uniq_orders | uniq_provider_ids
----------+---------+-------------+-------------------
   149458 |  149458 |      142973 |            148910
```

Строк почти на 6,5 тысячи больше, чем заказов. Какие это заказы — показывает классическая проверка `GROUP BY ... HAVING count(*) > 1`:

```sql
SELECT status, count(*) AS orders_cnt
FROM (
    SELECT order_id, string_agg(status, '+' ORDER BY status) AS status
    FROM payments
    GROUP BY order_id
    HAVING count(*) > 1
) t
GROUP BY status;
```

```
     status      | orders_cnt
-----------------+------------
 SUCCESS+SUCCESS |        548
 REFUND+SUCCESS  |       5937
```

Две разные причины. Возврат по отменённому заказу — нормальная бизнес-ситуация: у заказа платёж и возврат. А два `SUCCESS` по одному заказу — подозрительно; что это, разберём в практике. Вывод для всех будущих запросов: **одна строка `payments` — одно событие платёжного сервиса, а не один заказ**. Любое соединение `orders JOIN payments` размножит часть заказов, и сумма `orders.total_amount` после такого соединения будет завышена. Именно этому посвящён модуль [В.2](v2-joins.md).

Та же проверка на журнале статусов: пара `(order_id, status)` по смыслу должна быть уникальна, но в 2 718 заказах событие `SHIPPED` записано дважды. Журналы без первичного ключа почти всегда содержат повторы доставки событий — это первое, что проверяют перед подсчётом «сколько заказов отгружено».

### Шаг 3. Профиль столбца

Профиль — короткая статистика столбца, по которой видно, можно ли ему доверять. Минимальный набор:

```sql
SELECT count(*)                                AS rows_cnt,
       count(promised_at)                      AS filled,
       count(*) - count(promised_at)           AS nulls,
       round(100.0 * (count(*) - count(promised_at)) / count(*), 2) AS null_pct,
       min(promised_at),
       max(promised_at)
FROM orders;
```

```
 rows_cnt | filled | nulls | null_pct |              min              |              max
----------+--------+-------+----------+-------------------------------+-------------------------------
   150300 | 149711 |   589 |     0.39 | 2025-04-03 00:00:02.287527+00 | 2025-10-05 23:49:59.628637+00
```

Меньше половины процента пропусков — кажется, мелочь. Но доля по всей таблице маскирует концентрацию: если все пропуски сидят в одном канале и одном месяце, метрика по этому срезу испорчена целиком. Это проверяется в практике.

Для категориальных столбцов — топ значений с долями. Долю удобно считать оконной суммой поверх групп; сами оконные функции подробно разбираются в В.4, здесь достаточно знать, что `sum(count(*)) OVER ()` — это «сумма по всем группам», то есть общее число строк:

```sql
SELECT status,
       count(*) AS cnt,
       round(count(*) * 100.0 / sum(count(*)) OVER (), 1) AS pct
FROM orders
GROUP BY status
ORDER BY cnt DESC;
```

```
  status   |  cnt   | pct
-----------+--------+------
 DELIVERED | 134050 | 89.2
 CANCELLED |  12337 |  8.2
 SHIPPED   |   2226 |  1.5
 PAID      |   1207 |  0.8
 NEW       |    480 |  0.3
```

Обратите внимание на `100.0`, а не `100`: при делении целых PostgreSQL отбрасывает дробную часть. Здесь это сошло бы с рук — `sum()` от `bigint` возвращает `numeric`, — но с целым знаменателем, например `count(*) * 100 / (SELECT count(*) FROM orders)`, доли превратились бы в 89, 8, 1, 0 и 0, а без множителя 100 — в сплошные нули. Писать `100.0` — привычка, которая страхует от этого всегда.

Для числовых столбцов смотрят `min`, `max`, медиану и подозрительные значения. Профиль `orders.total_amount` показывает минимум 0,00 — у 220 заказов сумма нулевая. Заказ на ноль рублей — это либо подарок, либо ошибка справочника цен; гипотеза проверяется в практике.

### NULL: три ловушки в агрегатах

Модуль А.5 показал, что `count(col)` пропускает `NULL`. На реальных метриках это проявляется тоньше.

**Метрика молча теряет строки.** Доля опоздавших заказов:

```sql
SELECT count(*) AS delivered,
       count(*) FILTER (WHERE s.delivered_at > o.promised_at)  AS late,
       count(*) FILTER (WHERE s.delivered_at <= o.promised_at) AS on_time,
       count(*) FILTER (WHERE o.promised_at IS NULL)           AS unknown
FROM orders o
JOIN shipments s ON s.order_id = o.id
WHERE o.status = 'DELIVERED';
```

```
 delivered | late  | on_time | unknown
-----------+-------+---------+---------
    134050 | 20081 |  113414 |     555
```

`late + on_time` не равно `delivered`: 555 заказов ни опоздавшие, ни вовремя — для них сравнение с `NULL` дало «неизвестно». Если считать «вовремя» как «всё, что не опоздало», эти заказы незаметно запишутся в хорошие. Правило: у метрики-доли всегда три корзины, и третью показывают явно.

**`avg` усредняет только заполненное.** Средняя задержка, где у неопоздавших задержка `NULL`, и та же средняя, где она 0:

```sql
SELECT round(avg(CASE WHEN s.delivered_at > o.promised_at
                      THEN extract(epoch FROM s.delivered_at - o.promised_at) / 3600 END), 1) AS avg_delay_late_only,
       round(avg(CASE WHEN s.delivered_at > o.promised_at
                      THEN extract(epoch FROM s.delivered_at - o.promised_at) / 3600 ELSE 0 END), 1) AS avg_delay_all
FROM orders o
JOIN shipments s ON s.order_id = o.id
WHERE o.status = 'DELIVERED';
```

```
 avg_delay_late_only | avg_delay_all
---------------------+---------------
                30.2 |           4.5
```

Оба числа верны, но отвечают на разные вопросы: «насколько опаздывают опоздавшие» и «сколько в среднем теряет заказ». Разница в семь раз — повод уточнить определение у заказчика метрики.

**`NULL = NULL` — не истина.** `SELECT NULL = NULL` возвращает `NULL`, поэтому соединение или сравнение по столбцу с пропусками теряет строки, где пропуски с обеих сторон. Для сравнения «с учётом NULL» есть стандартный `IS NOT DISTINCT FROM`. Тот же механизм ломает `NOT IN` при `NULL` в подзапросе — подробный разбор в [В.2](v2-joins.md).

**Деление на ноль.** Доля отмен по всем поставщикам, включая тех, у кого нет заказов:

```sql
SELECT s.id,
       count(o.id) AS orders_cnt,
       count(o.id) FILTER (WHERE o.status = 'CANCELLED') * 100.0 / count(o.id) AS cancel_pct
FROM suppliers s
LEFT JOIN orders o ON o.supplier_id = s.id
GROUP BY s.id;
-- ERROR:  division by zero
```

У поставщиков 39 и 40 заказов нет. `NULLIF(x, 0)` возвращает `NULL`, если `x = 0`, и деление на `NULL` даёт `NULL` вместо ошибки: `... / NULLIF(count(o.id), 0)`. Если в отчёте нужен ноль, а не пусто, оборачивают в `COALESCE(..., 0)` — но осознанно: «0% отмен» и «отменять было нечего» — разные утверждения.

### Условные агрегаты: сводка в одну строку

Частая задача: по каждому поставщику в одной строке — сколько заказов доставлено, отменено, в работе. Новичок пишет три запроса с разными `WHERE` и склеивает в Excel. Условный агрегат делает это за один проход:

```sql
SELECT supplier_id,
       count(*)                                     AS orders_cnt,
       count(*) FILTER (WHERE status = 'DELIVERED') AS delivered,
       count(*) FILTER (WHERE status = 'CANCELLED') AS cancelled
FROM orders
GROUP BY supplier_id
ORDER BY supplier_id;
```

```
 supplier_id | orders_cnt | delivered | cancelled
-------------+------------+-----------+-----------
           1 |       4017 |      3599 |       330
           2 |       3916 |      3501 |       301
           3 |       4076 |      3624 |       324
 ...
```

`FILTER` — синтаксис стандарта SQL:2003, но из распространённых СУБД его поддерживает в основном PostgreSQL (и SQLite). Переносимая форма, которую понимают все, включая MySQL, Oracle и SQL Server:

```sql
SUM(CASE WHEN status = 'DELIVERED' THEN 1 ELSE 0 END) AS delivered
```

Результат тот же. На собеседовании стоит написать `FILTER` и сказать, что знаете и вторую форму, — или сразу писать `CASE`, если СУБД не PostgreSQL.

### WHERE против HAVING: где фильтр меняет знаменатель

Задача: поставщики с долей отмен выше 8,5% за третий квартал. Первая попытка — отфильтровать отменённые в `WHERE`:

```sql
SELECT supplier_id,
       count(*) FILTER (WHERE status = 'CANCELLED') * 100.0 / count(*) AS cancel_pct
FROM orders
WHERE status = 'CANCELLED'
GROUP BY supplier_id;
```

У всех поставщиков получится 100%: `WHERE` выбросил остальные заказы до группировки, и знаменатель стал равен числителю. Условие на строку («заказ за третий квартал») идёт в `WHERE`, условие на группу («доля больше 8,5%») — в `HAVING`:

```sql
SELECT supplier_id,
       round(count(*) FILTER (WHERE status = 'CANCELLED') * 100.0 / count(*), 1) AS cancel_pct
FROM orders
WHERE created_at >= '2025-07-01' AND created_at < '2025-10-01'
GROUP BY supplier_id
HAVING count(*) FILTER (WHERE status = 'CANCELLED') * 100.0 / count(*) > 8.5
ORDER BY cancel_pct DESC;
```

Вернутся восемь поставщиков с долями от 8,6 до 9,2%. Псевдоним `cancel_pct` в `HAVING` в PostgreSQL использовать нельзя — выражение повторяют или выносят группировку в CTE.

### Чек-лист: профиль любой новой таблицы

1. Сколько строк и за какой период (`min`/`max` по времени создания).
2. Гранулярность словами и проверка уникальности ключа: `count(*)` против `count(DISTINCT ключ)`, затем `GROUP BY ключ HAVING count(*) > 1`.
3. Для каждого важного столбца — доля `NULL`, а для подозрительных — в разрезе каналов, источников и месяцев.
4. Категории: топ значений с долями; нет ли «почти одинаковых» значений (регистр, пробелы).
5. Числа: `min`, `max`, нули и отрицательные значения.
6. Связи: у всех ли дочерних строк есть родитель и у всех ли родителей ожидаемые дети.
7. Записать найденное: что такое строка, какие дефекты, какие допущения в метрике.

### Типичные ошибки

- Считать, что одна строка таблицы — это один бизнес-объект, не проверив ключ. Особенно в журналах, платежах и витринах.
- Смотреть долю `NULL` по всей таблице и не смотреть по срезам.
- Делить целые числа и получать нули вместо долей.
- Считать «вовремя = не опоздал» и записывать неизвестное в хорошее.
- Фильтровать в `WHERE` то, что должно быть в `HAVING`, и получать долю 100%.
- Искать дубли точным сравнением строк, когда они отличаются регистром или пробелом.
- Заменять `NULL` на ноль через `COALESCE` по привычке, не задав вопрос, что означает пропуск.

### Как говорить об этом на собеседовании

Live-задача на SQL почти всегда начинается с таблиц, которые вы видите впервые. Сильный кандидат не бросается писать запрос, а тратит минуту на уточнения вслух: «Правильно понимаю, что одна строка `payments` — это одна транзакция, а не один заказ? Могут ли быть возвраты и повторные уведомления? Выручку считаем по доставленным заказам или по платежам?». Если доступ к базе есть, он проверяет гипотезу запросом и проговаривает: «сначала посмотрю, уникален ли `order_id` в платежах, иначе соединение размножит строки».

Второй сильный ход — назвать проверки, которые вы бы сделали на реальных данных: доля пропусков в ключевом столбце по срезам, дубли после нормализации, нули и отрицательные значения. Даже если времени их выполнить нет, интервьюер слышит, что вы не поверите первому числу.

### Коротко

- Разведка идёт в порядке: каталог → гранулярность → профиль → гипотезы.
- `\d` и `information_schema` показывают таблицы, ключи и связи; таблицы без первичного ключа — первые кандидаты на дубли.
- Гранулярность формулируют словами и проверяют `GROUP BY ключ HAVING count(*) > 1`. `payments.order_id` не уникален: возвраты и повторные уведомления.
- Профиль столбца: `count(*)`, `count(col)`, `count(DISTINCT col)`, доля `NULL`, `min`/`max`, топ значений с долями.
- `NULL` создаёт третью корзину в любой доле; `avg` пропускает `NULL`; `NULLIF` спасает от деления на ноль.
- `FILTER (WHERE ...)` даёт сводку в одну строку; переносимая форма — `SUM(CASE ...)`.
- `WHERE` фильтрует строки, `HAVING` — группы; неверный выбор меняет знаменатель.
<!-- LESSON:END -->

## Читать дальше

- Документация PostgreSQL: [psql — метакоманды `\d`](https://www.postgresql.org/docs/current/app-psql.html), [information_schema.columns](https://www.postgresql.org/docs/current/infoschema-columns.html), [information_schema.table_constraints](https://www.postgresql.org/docs/current/infoschema-table-constraints.html).
- Документация PostgreSQL: [агрегатные выражения и FILTER](https://www.postgresql.org/docs/current/sql-expressions.html#SYNTAX-AGGREGATES), [COALESCE и NULLIF](https://www.postgresql.org/docs/current/functions-conditional.html), [агрегатные функции](https://www.postgresql.org/docs/current/functions-aggregate.html), [IS DISTINCT FROM и сравнения с NULL](https://www.postgresql.org/docs/current/functions-comparison.html).
- Алан Бьюли, «Изучаем SQL» — главы о группировке и о NULL.
- Джо Селко, «SQL for Smarties» — главы о NULL и трёхзначной логике.

## Практика

Задачи решаются на [стенде](lab/README.md). Сначала решите сами с таймером, потом сверяйтесь с разбором.

### Задача 1. Профиль таблицы заказов

Одним запросом верните одну строку с профилем `orders`: число строк, число уникальных `id`, число уникальных покупателей и поставщиков, первая и последняя дата создания, число пропусков в `promised_at`, число заказов с нулевой суммой, минимальная, максимальная и медианная сумма. Сформулируйте гранулярность таблицы. Таймер: 10 минут.

<details markdown="1">
<summary>Решение и разбор</summary>

```sql
SELECT count(*)                           AS rows_cnt,
       count(DISTINCT id)                 AS uniq_id,
       count(DISTINCT customer_id)        AS customers,
       count(DISTINCT supplier_id)        AS suppliers,
       min(created_at)                    AS first_created,
       max(created_at)                    AS last_created,
       count(*) - count(promised_at)      AS promised_nulls,
       count(*) FILTER (WHERE total_amount = 0) AS zero_amount,
       min(total_amount)                  AS min_amount,
       max(total_amount)                  AS max_amount,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY total_amount) AS median_amount
FROM orders;
```

Получится около 150 тысяч заказов, `uniq_id` равен числу строк (гранулярность «один заказ» подтверждена — `id` первичный ключ), около 15 тысяч покупателей и 38 поставщиков из 40. Период — с 1 апреля по 30 сентября 2025 года. Пропусков в `promised_at` — 589, нулевых сумм — 220, медиана около 20 тысяч при среднем около 40 тысяч: распределение сумм сильно скошено вправо, и «средний чек» без медианы вводит в заблуждение.

Три находки для блокнота: двое поставщиков без заказов (ещё понадобятся для `NULLIF`), пропуски в обязательном по смыслу `promised_at`, нулевые суммы. `percentile_cont ... WITHIN GROUP` — стандартный SQL, есть в PostgreSQL, Oracle и SQL Server (там как оконная функция); в MySQL его нет.

</details>

### Задача 2. Уникальность ключа в платежах

Проверьте, уникален ли `order_id` в `payments`. Для заказов с двумя и более строками определите, какие бывают комбинации статусов. Для двух `SUCCESS` по одному заказу выясните, чем строки отличаются друг от друга. Что это значит для запроса «сумма оплат по заказам»? Таймер: 10 минут.

<details markdown="1">
<summary>Решение и разбор</summary>

```sql
SELECT status, count(*) AS orders_cnt
FROM (
    SELECT order_id, string_agg(status, '+' ORDER BY status) AS status
    FROM payments
    GROUP BY order_id
    HAVING count(*) > 1
) t
GROUP BY status;

SELECT provider_id, count(*) AS rows_cnt, max(paid_at) - min(paid_at) AS spread
FROM payments
GROUP BY provider_id
HAVING count(*) > 1
ORDER BY provider_id;
```

Около 6 тысяч заказов имеют пару «платёж + возврат» — это норма. 548 заказов имеют два `SUCCESS`, и во втором запросе видно: у них **одинаковый `provider_id`** и разница во времени ровно 2 секунды. Это повторное уведомление платёжного сервиса (вебхук пришёл дважды), а не повторная оплата: деньги покупатель заплатил один раз.

Следствия. Сумма `payments.amount` по таким заказам вдвое больше суммы заказа. Настоящий ключ платежа — `provider_id` (вместе со статусом), и при расчётах повторы надо схлопывать по нему. А в системе, которая принимает уведомления, нет идемпотентности — это требование, которое аналитик выносит в постановку. Знать гранулярность «одна строка — одно уведомление провайдера» нужно до любого соединения с заказами.

</details>

### Задача 3. Дубли артикулов

Проверьте, есть ли в `products` повторяющиеся артикулы `sku`. Сначала точным сравнением, затем после нормализации `lower(trim(sku))`. Для найденных групп выведите идентификаторы товаров и поставщиков. Продавались ли оба товара-близнеца? Таймер: 10 минут.

<details markdown="1">
<summary>Решение и разбор</summary>

```sql
SELECT sku, count(*)
FROM products
GROUP BY sku
HAVING count(*) > 1;
-- 0 строк

SELECT lower(trim(sku))                AS sku_norm,
       count(*)                        AS cnt,
       array_agg(id ORDER BY id)       AS ids,
       array_agg(DISTINCT supplier_id) AS suppliers
FROM products
GROUP BY lower(trim(sku))
HAVING count(*) > 1
ORDER BY sku_norm;
```

```
 sku_norm  | cnt |   ids    | suppliers
-----------+-----+----------+-----------
 sku-00001 |   2 | {1,4961} | {1}
 sku-00002 |   2 | {2,4962} | {2}
 ...
```

Точное сравнение говорит «дублей нет», нормализованное находит 40 пар — у одного и того же поставщика. Чем именно отличаются строки, видно, если обрамить значение: `'[' || sku || ']'` даёт `[SKU-00001]` и `[sku-00001 ]` — нижний регистр и пробел в конце. Проверить, что в обеих строках пары были продажи:

```sql
WITH dup AS (
    SELECT lower(trim(sku)) AS sku_norm, min(id) AS first_id, max(id) AS second_id
    FROM products
    GROUP BY lower(trim(sku))
    HAVING count(*) > 1
)
SELECT count(*) AS dup_groups,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM order_items i WHERE i.product_id = d.first_id)
                          AND EXISTS (SELECT 1 FROM order_items i WHERE i.product_id = d.second_id)) AS both_sold
FROM dup d;
```

В 38 парах из 40 продавались оба товара. Значит, любой отчёт «продажи по артикулу» делит продажи одного товара на две строки, а остатки и цены ведутся по двум карточкам. Для постановки: нормализация артикула при загрузке и уникальный индекс по `lower(trim(sku))` в пределах поставщика.

</details>

### Задача 4. Заказы без обещанной даты по каналу и месяцу

Посчитайте долю заказов без `promised_at` в разрезе канала и месяца создания. Выведите только срезы, где пропуски есть. Сколько доставленных заказов из-за этого выпадает из метрики «доля опозданий»? Таймер: 10 минут.

<details markdown="1">
<summary>Решение и разбор</summary>

```sql
SELECT channel,
       date_trunc('month', created_at)::date AS month,
       count(*)                              AS orders_cnt,
       count(*) - count(promised_at)         AS no_promise,
       round(100.0 * (count(*) - count(promised_at)) / count(*), 1) AS no_promise_pct
FROM orders
GROUP BY channel, date_trunc('month', created_at)
HAVING count(*) - count(promised_at) > 0
ORDER BY channel, month;
```

```
 channel |   month    | orders_cnt | no_promise | no_promise_pct
---------+------------+------------+------------+----------------
 api     | 2025-04-01 |       4134 |        589 |           14.2
```

Одна строка. По таблице было 0,4% пропусков, а в срезе «api, апрель» — 14%: все пропуски сосредоточены в одном канале и одном месяце, с 1 по 30 апреля. Это след интеграции: API-клиенты в апреле не передавали дату или маркетплейс её не рассчитывал. Из доставленных заказов 555 выпадают из сравнения `delivered_at > promised_at` (запрос из раздела про `NULL`). Метрику опозданий по api за апрель нельзя показывать без оговорки — или нужно восстановить дату правилом из README: `created_at + sla_days` поставщика.

`date_trunc` и `::date` — PostgreSQL. В стандартной записи — `CAST(... AS date)`; усечение до месяца в других СУБД делается своими функциями (`DATE_FORMAT` в MySQL, `DATETRUNC` в SQL Server 2022, `TRUNC(..., 'MM')` в Oracle).

</details>

### Задача 5. Сводка статусов по поставщику

Для заказов, созданных в сентябре, выведите по каждому поставщику: всего заказов, доставлено, отменено, в работе (`PAID` и `SHIPPED`) и долю «в работе» в процентах. Оставьте только поставщиков с долей в работе больше 10%. Решите через `FILTER`, затем перепишите одну колонку через `SUM(CASE ...)`. Что объединяет найденных поставщиков? Таймер: 12 минут.

<details markdown="1">
<summary>Решение и разбор</summary>

```sql
SELECT o.supplier_id,
       s.integration_type,
       count(*)                                                AS orders_cnt,
       count(*) FILTER (WHERE o.status = 'DELIVERED')          AS delivered,
       count(*) FILTER (WHERE o.status = 'CANCELLED')          AS cancelled,
       count(*) FILTER (WHERE o.status IN ('PAID', 'SHIPPED')) AS in_progress,
       round(100.0 * count(*) FILTER (WHERE o.status IN ('PAID', 'SHIPPED')) / count(*), 1) AS in_progress_pct
FROM orders o
JOIN suppliers s ON s.id = o.supplier_id
WHERE o.created_at >= '2025-09-01' AND o.created_at < '2025-10-01'
GROUP BY o.supplier_id, s.integration_type
HAVING count(*) FILTER (WHERE o.status IN ('PAID', 'SHIPPED')) * 100.0 / count(*) > 10
ORDER BY in_progress_pct DESC;
```

Вернётся около десятка поставщиков с долей от 10 до 14%, и в верхней части — почти сплошь `sftp`: 31, 27, 30, 35, 26, 34. Переносимая форма колонки: `SUM(CASE WHEN o.status IN ('PAID', 'SHIPPED') THEN 1 ELSE 0 END) AS in_progress`.

Разбор. Условие «созданы в сентябре» — на строку, поэтому в `WHERE`; «доля больше 10%» — на группу, поэтому в `HAVING`. Сентябрьские заказы ещё не успели доехать, и поставщики, которые возят дольше, копят хвост «в работе» — первый сигнал, что файловые интеграции опаздывают. Подтверждать это надо уже метрикой опозданий по доставленным заказам, а не долей незавершённых: последняя зависит и от того, как распределены заказы внутри месяца.

</details>

### Задача 6. Товары с нулевой ценой, которые продавались

Найдите товары с `price = 0`, по которым есть позиции заказов. Для каждого выведите артикул, поставщика, признак активности, число заказов и проданных штук. Сколько всего заказов содержат такие позиции и сколько из них доставлено? Подсказка: понадобится соединение `products` с `order_items`; число заказов считайте через `count(DISTINCT ...)`. Таймер: 12 минут.

<details markdown="1">
<summary>Решение и разбор</summary>

```sql
SELECT p.id, p.sku, p.supplier_id, p.is_active,
       count(DISTINCT i.order_id) AS orders_cnt,
       sum(i.qty)                 AS units
FROM products p
JOIN order_items i ON i.product_id = p.id
WHERE p.price = 0
GROUP BY p.id, p.sku, p.supplier_id, p.is_active
ORDER BY orders_cnt DESC;

SELECT count(DISTINCT i.order_id) AS orders_cnt,
       count(DISTINCT i.order_id) FILTER (WHERE o.status = 'DELIVERED') AS delivered,
       count(DISTINCT i.order_id) FILTER (WHERE o.total_amount = 0)     AS zero_total
FROM order_items i
JOIN products p ON p.id = i.product_id
JOIN orders o   ON o.id = i.order_id
WHERE p.price = 0;
```

Нулевая цена у 15 товаров, 14 из них продавались — от 49 до 75 заказов каждый, один даже неактивен. Всего таких заказов около 900, из них около 800 доставлено, и 220 — целиком нулевые (те самые нулевые суммы из задачи 1). Среди «бесплатных» товаров есть и `sku-00035` — повторно заведённая карточка из задачи 3: дефекты справочника накладываются друг на друга.

Где ловушка. `count(*)` после соединения посчитал бы позиции, а не заказы: строки `order_items` на заказ может быть несколько. Поэтому `count(DISTINCT i.order_id)`. Почему соединение меняет количество строк и как не ошибиться в суммах — тема модуля [В.2](v2-joins.md). Для бизнеса вывод: товары отгружались бесплатно, потеря выручки реальна, а проверка «цена больше нуля» при сохранении карточки — требование к справочнику.

</details>

## Вопросы для самопроверки

1. Вам дали доступ к незнакомой базе без документации. Что вы сделаете в первые 15 минут?
2. Что такое гранулярность таблицы? Как проверить её запросом?
3. В таблице платежей `order_id` не уникален. Какие могут быть причины и чем это грозит отчёту по выручке?
4. Почему `count(*)` и `count(promised_at)` дают разные числа, а доля «вовремя» плюс доля «опоздал» не равна 100%?
5. Как найти дубли, которые отличаются только регистром и пробелами?
6. Напишите одной строкой на поставщика число доставленных и отменённых заказов. Как это сделать в СУБД без `FILTER`?
7. Почему запрос с `WHERE status = 'CANCELLED'` показывает долю отмен 100%? Где должно стоять условие на долю?
8. Как избежать деления на ноль при расчёте доли и когда нельзя заменять `NULL` нулём?

## Заметки

<!-- Свои формулировки, ошибки, ссылки. -->
