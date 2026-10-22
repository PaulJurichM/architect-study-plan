-- Генерация данных. Период: 1 апреля — 30 сентября 2025 года, все времена в UTC.
-- «Сейчас» для этой базы — 1 октября 2025 года, 00:00 UTC.
-- setseed делает данные воспроизводимыми: у всех, кто поднимет стенд, получатся те же цифры.

SET client_min_messages = warning;
SET TIME ZONE 'UTC';
SELECT setseed(0.42);

-- Категории: 5 корневых, 20 подкатегорий, 60 листовых
INSERT INTO categories (id, parent_id, name)
SELECT g, NULL, (ARRAY['Электроника', 'Дом и сад', 'Офис', 'Стройка', 'Автотовары'])[g]
FROM generate_series(1, 5) g;

INSERT INTO categories (id, parent_id, name)
SELECT g, 1 + (g - 6) % 5, 'Подкатегория ' || (g - 5)
FROM generate_series(6, 25) g;

INSERT INTO categories (id, parent_id, name)
SELECT g, 6 + (g - 26) % 20, 'Раздел ' || (g - 25)
FROM generate_series(26, 85) g;

-- Поставщики: 1–25 работают по API, 26–35 присылают файлы по SFTP, 36–40 ведутся вручную
INSERT INTO suppliers (id, name, integration_type, sla_days, is_active)
SELECT g,
       'Поставщик ' || lpad(g::text, 2, '0'),
       CASE WHEN g <= 25 THEN 'api' WHEN g <= 35 THEN 'sftp' ELSE 'manual' END,
       2 + g % 4,
       g < 39
FROM generate_series(1, 40) g;

-- Товары: у каждого поставщика по 125 позиций
INSERT INTO products (id, sku, name, category_id, supplier_id, price, is_active, created_at)
SELECT g,
       'SKU-' || lpad(g::text, 5, '0'),
       'Товар ' || g,
       CASE WHEN g % 50 = 0 THEN NULL ELSE 26 + floor(random() * 60)::int END,
       1 + (g - 1) % 40,
       CASE WHEN g % 333 = 0 THEN 0 ELSE round((100 + random() ^ 2 * 20000)::numeric, 2) END,
       random() > 0.05,
       timestamptz '2024-06-01' + random() * interval '300 days'
FROM generate_series(1, 5000) g;

-- Дефект справочника: 40 последних товаров заведены повторно с «тем же» артикулом
-- в нижнем регистре и с пробелом в конце
UPDATE products p
SET sku = lower(o.sku) || ' '
FROM products o
WHERE p.id BETWEEN 4961 AND 5000
  AND o.id = p.id - 4960;

-- Покупатели: каждый пятый — юрлицо
INSERT INTO customers (id, email, segment, region, registered_at)
SELECT g,
       CASE WHEN g % 5 = 0 THEN 'buyer' || g || '@company' || (g % 300) || '.example'
            ELSE 'user' || g || '@mail.example' END,
       CASE WHEN g % 5 = 0 THEN 'B2B' ELSE 'B2C' END,
       (ARRAY['Москва', 'Санкт-Петербург', 'Татарстан', 'Свердловская', 'Новосибирская',
              'Краснодарский', 'Самарская', 'Грузия'])[1 + floor(random() * 8)::int],
       timestamptz '2025-01-01' + random() * interval '272 days'
FROM generate_series(1, 20000) g;

-- Дефект: 150 человек зарегистрировались повторно с тем же адресом, но с заглавной буквы
UPDATE customers c
SET email = initcap(substr(o.email, 1, 1)) || substr(o.email, 2),
    registered_at = o.registered_at + interval '3 days'
FROM customers o
WHERE c.id BETWEEN 19851 AND 20000
  AND o.id = c.id - 19850;

-- ===== Заказы =====
-- Покупают около трёх четвертей зарегистрированных; юрлица делают больше заказов
CREATE TEMP TABLE buyers AS
SELECT id, segment, registered_at,
       row_number() OVER (PARTITION BY segment ORDER BY id) AS rn
FROM customers
WHERE id % 13 NOT IN (3, 7, 9)
  AND registered_at < timestamptz '2025-09-25';

CREATE TEMP TABLE buyer_cnt AS
SELECT segment, count(*) AS n FROM buyers GROUP BY segment;

CREATE TEMP TABLE o AS
WITH picks AS (
    SELECT g,
           CASE WHEN random() < 0.4 THEN 'B2B' ELSE 'B2C' END AS seg,
           random() AS r_cust, random() AS r_time, random() AS r_sup,
           random() AS r_chan, random() AS r_cancel, random() AS r_pay,
           random() AS r_ship, random() AS r_deliv, random() AS r_delay
    FROM generate_series(1, 150000) g
)
SELECT p.g, NULL::int AS orig_g, b.id AS customer_id, b.segment,
       greatest(b.registered_at, timestamptz '2025-04-01')
         + (timestamptz '2025-10-01' - greatest(b.registered_at, timestamptz '2025-04-01'))
           * (p.r_time ^ 1.6) AS created_at,
       1 + floor(p.r_sup * 38)::int AS supplier_id,
       p.r_chan, p.r_cancel, p.r_pay, p.r_ship, p.r_deliv, p.r_delay
FROM picks p
JOIN buyer_cnt bc ON bc.segment = p.seg
JOIN buyers b ON b.segment = p.seg AND b.rn = 1 + floor(p.r_cust * bc.n)::int;

-- Дефект: двойной клик — у каждого 500-го заказа есть копия через 2–5 секунд.
-- Копию потом отменяет поддержка, но в базе она остаётся
INSERT INTO o
SELECT 1000000 + g, g, customer_id, segment, created_at + interval '1 second' * (2 + floor(random() * 4)),
       supplier_id, r_chan, 0.01, r_pay, r_ship, r_deliv, r_delay
FROM o
WHERE g % 500 = 1;

-- Идентификаторы растут вместе со временем создания
CREATE TEMP TABLE o2 AS
SELECT row_number() OVER (ORDER BY created_at, g) AS id, o.*
FROM o;

CREATE TEMP TABLE o3 AS
SELECT o2.id, o2.g, o2.orig_g, o2.customer_id, o2.supplier_id, o2.created_at, s.sla_days, s.integration_type,
       CASE WHEN o2.segment = 'B2B' THEN CASE WHEN o2.r_chan < 0.5 THEN 'api' ELSE 'web' END
            ELSE CASE WHEN o2.r_chan < 0.6 THEN 'app' ELSE 'web' END END AS channel,
       o2.r_cancel < 0.08 AS cancelled,
       o2.r_cancel < 0.04 AS cancel_before_pay,
       o2.r_cancel BETWEEN 0.08 AND 0.083 AS abandoned,
       o2.created_at + interval '1 minute' * (1 + floor(o2.r_pay * 30)) AS paid_at,
       o2.r_ship, o2.r_deliv, o2.r_delay
FROM o2
JOIN suppliers s ON s.id = o2.supplier_id;

CREATE TEMP TABLE o4 AS
SELECT o3.*,
       o3.paid_at + interval '2 hours' + interval '1 day' * (o3.r_ship * o3.sla_days * 0.5) AS shipped_at
FROM o3;

CREATE TEMP TABLE o5 AS
SELECT o4.*,
       o4.shipped_at
         + interval '1 day' * (0.5 + o4.r_deliv * (o4.sla_days * 0.5))
         -- поставщики на файловом обмене часто опаздывают
         + CASE WHEN o4.integration_type = 'sftp' AND o4.r_delay < 0.35
                THEN interval '1 day' * (1 + floor(o4.r_delay * 1000)::int % 5) ELSE interval '0' END
         -- 10–14 июля у поставщика 31 не было фида: заказы принимались по устаревшим остаткам
         + CASE WHEN o4.supplier_id = 31 AND o4.created_at >= timestamptz '2025-07-08'
                     AND o4.created_at < timestamptz '2025-07-16'
                THEN interval '1 day' * (4 + floor(o4.r_delay * 5)) ELSE interval '0' END
         AS delivered_at
FROM o4;

INSERT INTO orders (id, customer_id, supplier_id, channel, status, total_amount, created_at, promised_at)
SELECT id, customer_id, supplier_id, channel,
       CASE WHEN cancelled THEN 'CANCELLED'
            WHEN abandoned OR paid_at >= timestamptz '2025-10-01' THEN 'NEW'
            WHEN shipped_at >= timestamptz '2025-10-01' THEN 'PAID'
            WHEN delivered_at >= timestamptz '2025-10-01' THEN 'SHIPPED'
            ELSE 'DELIVERED' END,
       0,
       created_at,
       CASE WHEN channel = 'api' AND created_at < timestamptz '2025-05-01' AND id % 7 = 0 THEN NULL
            ELSE created_at + interval '1 day' * sla_days END
FROM o5;

-- Позиции заказа: 1–4 строки, только товары поставщика заказа
INSERT INTO order_items (order_id, line_no, product_id, qty, price)
SELECT o.id, l.line_no, l.product_id, l.qty, p.price
FROM orders o
CROSS JOIN LATERAL (
    SELECT n AS line_no,
           o.supplier_id + 40 * floor(random() * 125)::int AS product_id,
           1 + floor(random() ^ 3 * 10)::int AS qty
    FROM generate_series(1, 1 + floor(random() ^ 2 * 4)::int + (o.id * 0)::int) n
) l
JOIN products p ON p.id = l.product_id;

-- У копий «двойного клика» те же позиции, что у исходного заказа
DELETE FROM order_items i USING o5 WHERE o5.id = i.order_id AND o5.orig_g IS NOT NULL;
INSERT INTO order_items (order_id, line_no, product_id, qty, price)
SELECT c.id, i.line_no, i.product_id, i.qty, i.price
FROM o5 c
JOIN o5 src ON src.g = c.orig_g
JOIN order_items i ON i.order_id = src.id
WHERE c.orig_g IS NOT NULL;

-- Сумма заказа = сумма позиций. Дефект: у каждого 200-го заказа применена скидка 10%,
-- которой нет в позициях
UPDATE orders o
SET total_amount = CASE WHEN o.id % 200 = 0 THEN round(s.sum * 0.9, 2) ELSE s.sum END
FROM (SELECT order_id, sum(qty * price) AS sum FROM order_items GROUP BY order_id) s
WHERE s.order_id = o.id;

-- ===== Отгрузки =====
INSERT INTO shipments (id, order_id, shipped_at, delivered_at)
SELECT row_number() OVER (ORDER BY o5.shipped_at, o5.id), o5.id, o5.shipped_at,
       CASE WHEN ord.status = 'DELIVERED' THEN o5.delivered_at END
FROM o5
JOIN orders ord ON ord.id = o5.id
WHERE ord.status IN ('SHIPPED', 'DELIVERED');

-- ===== История статусов =====
CREATE TEMP TABLE h AS
SELECT o.id AS order_id, 'NEW' AS status, o.created_at AS changed_at, 'marketplace' AS source
FROM orders o
UNION ALL
SELECT o.id, 'PAID', o5.paid_at, 'marketplace'
FROM orders o JOIN o5 ON o5.id = o.id
WHERE o.status IN ('PAID', 'SHIPPED', 'DELIVERED') OR (o.status = 'CANCELLED' AND NOT o5.cancel_before_pay)
UNION ALL
SELECT s.order_id, 'SHIPPED', s.shipped_at, 'supplier'
FROM shipments s
UNION ALL
SELECT s.order_id, 'DELIVERED', s.delivered_at, 'supplier'
FROM shipments s WHERE s.delivered_at IS NOT NULL
UNION ALL
SELECT o.id, 'CANCELLED',
       CASE WHEN o5.cancel_before_pay THEN o.created_at + interval '1 hour' * (1 + floor(o5.r_ship * 47))
            ELSE o5.paid_at + interval '1 hour' * (1 + floor(o5.r_ship * 71)) END,
       'marketplace'
FROM orders o JOIN o5 ON o5.id = o.id
WHERE o.status = 'CANCELLED';

-- Дефект: система поставщика 33 пишет московское время, помеченное как UTC (сдвиг −3 часа)
UPDATE h
SET changed_at = changed_at - interval '3 hours'
FROM orders o
WHERE o.id = h.order_id AND o.supplier_id = 33 AND h.source = 'supplier';

INSERT INTO order_status_history (order_id, status, changed_at, source)
SELECT order_id, status, changed_at, source FROM h;

-- Дефект: повторная доставка события при ретраях — дубль SHIPPED через секунду у каждого 50-го заказа
INSERT INTO order_status_history (order_id, status, changed_at, source)
SELECT order_id, status, changed_at + interval '1 second', source
FROM h
WHERE status = 'SHIPPED' AND order_id % 50 = 0;

-- ===== Платежи =====
CREATE TEMP TABLE pay AS
SELECT o.id AS order_id, 'pay_' || substr(md5(o.id::text), 1, 12) AS provider_id, 'SUCCESS' AS status,
       CASE WHEN o.id % 200 = 3 THEN o.total_amount - round((0.01 + random() * 0.99)::numeric, 2)
            ELSE o.total_amount END AS amount,
       o5.paid_at
FROM orders o JOIN o5 ON o5.id = o.id
WHERE (o.status IN ('PAID', 'SHIPPED', 'DELIVERED') OR (o.status = 'CANCELLED' AND NOT o5.cancel_before_pay))
  -- дефект: доставлено, но оплаты в системе нет
  AND NOT (o.status = 'DELIVERED' AND o.id % 300 = 7)
UNION ALL
-- дефект: платёжный сервис прислал уведомление дважды
SELECT o.id, 'pay_' || substr(md5(o.id::text), 1, 12), 'SUCCESS', o.total_amount, o5.paid_at + interval '2 seconds'
FROM orders o JOIN o5 ON o5.id = o.id
WHERE o.status IN ('PAID', 'SHIPPED', 'DELIVERED') AND o.id % 250 = 0
UNION ALL
-- возвраты по заказам, отменённым после оплаты
SELECT o.id, 'ref_' || substr(md5(o.id::text), 1, 12), 'REFUND', -o.total_amount, h.changed_at + interval '2 hours'
FROM orders o
JOIN o5 ON o5.id = o.id
JOIN h ON h.order_id = o.id AND h.status = 'CANCELLED'
WHERE o.status = 'CANCELLED' AND NOT o5.cancel_before_pay;

INSERT INTO payments (id, order_id, provider_id, status, amount, paid_at)
SELECT row_number() OVER (ORDER BY paid_at, order_id, status), order_id, provider_id, status, amount, paid_at
FROM pay;

-- ===== Фиды поставщиков =====
CREATE TEMP TABLE feed AS
SELECT s.id AS supplier_id,
       d::date + interval '3 hours' + interval '1 minute' * floor(random() * 50) AS loaded_at,
       118 + floor(random() * 8)::int AS rows_loaded,
       CASE WHEN random() < 0.02 THEN 'ERROR' ELSE 'OK' END AS status
FROM suppliers s
CROSS JOIN generate_series(date '2025-04-01', date '2025-09-30', interval '1 day') d
WHERE s.is_active
  -- ручные поставщики загружают остатки только по будням
  AND NOT (s.integration_type = 'manual' AND extract(isodow FROM d) > 5)
  -- дефект: у поставщика 31 пять дней не было ни одной загрузки
  AND NOT (s.id = 31 AND d BETWEEN date '2025-07-10' AND date '2025-07-14');

-- После ошибки загрузка повторяется через час
INSERT INTO feed
SELECT supplier_id, loaded_at + interval '1 hour', rows_loaded, 'OK'
FROM feed WHERE status = 'ERROR';
UPDATE feed SET rows_loaded = 0 WHERE status = 'ERROR';

-- Дефект: у поставщика 33 загрузка «успешна», но пустая
UPDATE feed SET rows_loaded = 0
WHERE supplier_id = 33
  AND loaded_at::date IN (date '2025-09-03', date '2025-09-04', date '2025-09-05',
                          date '2025-09-10', date '2025-09-11', date '2025-09-12');

-- Дефект: в августе фид поставщика 34 загружался дважды в день
INSERT INTO feed
SELECT supplier_id, loaded_at + interval '20 minutes', rows_loaded, status
FROM feed
WHERE supplier_id = 34 AND loaded_at >= timestamptz '2025-08-01' AND loaded_at < timestamptz '2025-09-01'
  AND status = 'OK';

INSERT INTO supplier_feed_loads (id, supplier_id, loaded_at, rows_loaded, status)
SELECT row_number() OVER (ORDER BY loaded_at, supplier_id), supplier_id, loaded_at, rows_loaded, status
FROM feed;

-- ===== Остатки: 400 товаров (по 10 у каждого поставщика) =====
INSERT INTO stock_snapshots (product_id, snapshot_date, on_hand)
SELECT p.id, d::date,
       greatest(0, floor(18 + 22 * sin(extract(doy FROM d) / 9.0 + p.id) + random() * 10 - 6))::int
FROM products p
CROSS JOIN generate_series(date '2025-04-01', date '2025-09-30', interval '1 day') d
WHERE p.id <= 400
  -- без фида нет и снимков остатков
  AND NOT (p.supplier_id = 31 AND d BETWEEN date '2025-07-10' AND date '2025-07-14');

-- ===== Витрина BI =====
-- Выручка доставленных заказов по дню доставки (UTC), загружается в 04:00 следующего дня
INSERT INTO report_daily_revenue (report_date, orders_cnt, revenue, loaded_at)
SELECT s.delivered_at::date, count(*), sum(o.total_amount),
       s.delivered_at::date + interval '1 day 4 hours'
FROM shipments s
JOIN orders o ON o.id = s.order_id
WHERE s.delivered_at IS NOT NULL
GROUP BY s.delivered_at::date;

-- Дефект: загрузка за 12 июля упала, день отсутствует
DELETE FROM report_daily_revenue WHERE report_date = date '2025-07-12';
-- Дефект: 3 августа загружено дважды
INSERT INTO report_daily_revenue
SELECT report_date, orders_cnt, revenue, loaded_at + interval '6 hours'
FROM report_daily_revenue WHERE report_date = date '2025-08-03';

ANALYZE;
