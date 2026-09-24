-- Учебные данные для лабораторных блока 2.
-- Выполняется автоматически при первом старте контейнера.

CREATE EXTENSION IF NOT EXISTS pageinspect;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Лаба 1: счета для lost update и non-repeatable read
CREATE TABLE accounts (
    id      int PRIMARY KEY,
    owner   text NOT NULL,
    balance numeric NOT NULL
);
INSERT INTO accounts VALUES (1, 'alice', 100), (2, 'bob', 100);

-- Лаба 1: дежурства для write skew
CREATE TABLE doctors (
    id       int PRIMARY KEY,
    name     text NOT NULL,
    shift_id int NOT NULL,
    on_call  boolean NOT NULL
);
INSERT INTO doctors VALUES (1, 'Иванов', 1, true), (2, 'Петров', 1, true);

-- Лаба 2: очередь задач
CREATE TABLE tasks (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payload    text NOT NULL,
    status     text NOT NULL DEFAULT 'NEW',
    created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO tasks (payload) SELECT 'task #' || g FROM generate_series(1, 20) g;

-- Лаба 3: клиенты и заказы (1 млн строк, неравномерные распределения)
CREATE TABLE customers (
    id      int PRIMARY KEY,
    name    text NOT NULL,
    segment text NOT NULL
);
INSERT INTO customers
SELECT g,
       'customer ' || g,
       CASE WHEN g % 100 = 0 THEN 'VIP' ELSE 'REGULAR' END
FROM generate_series(1, 100000) g;

-- Справочник: город жёстко определяет регион (коррелированные столбцы)
CREATE TABLE cities (
    city   text PRIMARY KEY,
    region text NOT NULL
);
INSERT INTO cities VALUES
    ('Казань', 'Татарстан'), ('Набережные Челны', 'Татарстан'), ('Альметьевск', 'Татарстан'),
    ('Екатеринбург', 'Свердловская'), ('Нижний Тагил', 'Свердловская'),
    ('Новосибирск', 'Новосибирская'), ('Бердск', 'Новосибирская'),
    ('Самара', 'Самарская'), ('Тольятти', 'Самарская'), ('Сызрань', 'Самарская'),
    ('Пермь', 'Пермский'), ('Березники', 'Пермский'),
    ('Уфа', 'Башкортостан'), ('Стерлитамак', 'Башкортостан'),
    ('Краснодар', 'Краснодарский'), ('Сочи', 'Краснодарский'), ('Новороссийск', 'Краснодарский'),
    ('Воронеж', 'Воронежская'), ('Ростов-на-Дону', 'Ростовская'), ('Таганрог', 'Ростовская');

CREATE TABLE orders (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id int NOT NULL REFERENCES customers(id),
    status      text NOT NULL,
    city        text NOT NULL,
    region      text NOT NULL,
    amount      numeric(12,2) NOT NULL,
    created_at  timestamptz NOT NULL
);

INSERT INTO orders (customer_id, status, city, region, amount, created_at)
SELECT 1 + (random() * 99999)::int,
       CASE WHEN r < 0.95 THEN 'DONE' WHEN r < 0.99 THEN 'CANCELLED' ELSE 'NEW' END,
       c.city,
       c.region,
       round((random() * 10000)::numeric, 2),
       timestamptz '2025-01-01' + (g * interval '30 seconds')
FROM (
    SELECT g, random() AS r, 1 + floor(random() * 20)::int AS city_no
    FROM generate_series(1, 1000000) g
) s
JOIN (SELECT row_number() OVER (ORDER BY city) AS n, city, region FROM cities) c
  ON c.n = s.city_no;

ANALYZE;
