-- Учебная база SQL-практикума: маркетплейс с поставщиками.
-- Выполняется автоматически при первом старте контейнера.
-- Данные синтетические и намеренно «грязные»: дубли, пропуски, расхождения,
-- сбои интеграций. Все дефекты заложены специально — их и предстоит найти.

SET client_min_messages = warning;
SET TIME ZONE 'UTC';

CREATE TABLE categories (
    id        int PRIMARY KEY,
    parent_id int REFERENCES categories(id),
    name      text NOT NULL
);

CREATE TABLE suppliers (
    id               int PRIMARY KEY,
    name             text NOT NULL,
    integration_type text NOT NULL CHECK (integration_type IN ('api', 'sftp', 'manual')),
    sla_days         int  NOT NULL,
    is_active        boolean NOT NULL DEFAULT true
);

CREATE TABLE products (
    id          int PRIMARY KEY,
    sku         text NOT NULL,
    name        text NOT NULL,
    category_id int REFERENCES categories(id),
    supplier_id int NOT NULL REFERENCES suppliers(id),
    price       numeric(12,2) NOT NULL,
    is_active   boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL
);

CREATE TABLE customers (
    id            int PRIMARY KEY,
    email         text NOT NULL,
    segment       text NOT NULL CHECK (segment IN ('B2B', 'B2C')),
    region        text NOT NULL,
    registered_at timestamptz NOT NULL
);

CREATE TABLE orders (
    id           bigint PRIMARY KEY,
    customer_id  int NOT NULL REFERENCES customers(id),
    supplier_id  int NOT NULL REFERENCES suppliers(id),
    channel      text NOT NULL CHECK (channel IN ('web', 'app', 'api')),
    status       text NOT NULL,
    total_amount numeric(12,2) NOT NULL,
    created_at   timestamptz NOT NULL,
    promised_at  timestamptz
);

CREATE TABLE order_items (
    order_id   bigint NOT NULL REFERENCES orders(id),
    line_no    int NOT NULL,
    product_id int NOT NULL REFERENCES products(id),
    qty        int NOT NULL,
    price      numeric(12,2) NOT NULL,
    PRIMARY KEY (order_id, line_no)
);

-- История статусов пишут разные системы: маркетплейс и системы поставщиков.
-- Первичного ключа нет намеренно: так выглядят многие журналы событий.
CREATE TABLE order_status_history (
    order_id   bigint NOT NULL REFERENCES orders(id),
    status     text NOT NULL,
    changed_at timestamptz NOT NULL,
    source     text NOT NULL
);

CREATE TABLE shipments (
    id           bigint PRIMARY KEY,
    order_id     bigint NOT NULL REFERENCES orders(id),
    shipped_at   timestamptz NOT NULL,
    delivered_at timestamptz
);

CREATE TABLE payments (
    id          bigint PRIMARY KEY,
    order_id    bigint NOT NULL REFERENCES orders(id),
    provider_id text NOT NULL,
    status      text NOT NULL CHECK (status IN ('SUCCESS', 'REFUND')),
    amount      numeric(12,2) NOT NULL,
    paid_at     timestamptz NOT NULL
);

-- Ежедневная выгрузка остатков и цен от поставщика (фид).
CREATE TABLE supplier_feed_loads (
    id          bigint PRIMARY KEY,
    supplier_id int NOT NULL REFERENCES suppliers(id),
    loaded_at   timestamptz NOT NULL,
    rows_loaded int NOT NULL,
    status      text NOT NULL CHECK (status IN ('OK', 'ERROR'))
);

-- Остаток на складе поставщика на конец дня по части товаров.
CREATE TABLE stock_snapshots (
    product_id    int  NOT NULL REFERENCES products(id),
    snapshot_date date NOT NULL,
    on_hand       int  NOT NULL,
    PRIMARY KEY (product_id, snapshot_date)
);

-- Витрина, которую когда-то собрал BI. По ней строится еженедельный отчёт руководству.
CREATE TABLE report_daily_revenue (
    report_date date NOT NULL,
    orders_cnt  int  NOT NULL,
    revenue     numeric(14,2) NOT NULL,
    loaded_at   timestamptz NOT NULL
);

COMMENT ON TABLE orders IS 'Заказ покупателя у одного поставщика. Сроки и суммы — в UTC и рублях';
COMMENT ON COLUMN orders.promised_at IS 'Обещанная покупателю дата доставки (created_at + SLA поставщика)';
COMMENT ON TABLE report_daily_revenue IS 'Витрина BI: выручка доставленных заказов по дням';
