---
title: "Стенд для лабораторных"
parent: "2. PostgreSQL изнутри"
nav_order: 10
---

# Стенд для лабораторных

Локальный PostgreSQL 17 в Docker с учебными данными. Только для экспериментов: никаких рабочих баз, дампов и данных заказчиков.

## Запуск

Нужен Docker Desktop. Из папки `02-postgresql/labs`:

```bash
docker compose up -d
docker compose logs -f db     # дождаться "database system is ready to accept connections"
```

Первый старт занимает около минуты: скрипт [`init/01-seed.sql`](https://github.com/PaulJurichM/architect-study-plan/blob/main/02-postgresql/labs/init/01-seed.sql) создаёт таблицы и генерирует миллион заказов.

## Подключение

В каждой лабораторной нужны **две или три сессии одновременно**. Откройте несколько терминалов и в каждом выполните:

```bash
docker compose exec db psql -U study study
```

Или подключитесь любым клиентом (DBeaver, DataGrip, VS Code): `localhost:55432`, база `study`, пользователь и пароль `study`. В графических клиентах отключите автокоммит, иначе `BEGIN` будет вести себя неожиданно.

Полезно в каждой сессии задать своё приглашение, чтобы не путаться:

```sql
\set PROMPT1 'A %/=# '    -- во второй сессии 'B %/=# ', в третьей 'C %/=# '
```

## Что лежит в базе

| Таблица | Строк | Для чего |
|---|---|---|
| `accounts` | 2 | Лаба 1: lost update, non-repeatable read |
| `doctors` | 2 | Лаба 1: write skew |
| `tasks` | 20 | Лаба 2: очередь на `SKIP LOCKED` |
| `customers` | 100 000 | Лаба 3: соединения. 1% клиентов — VIP |
| `cities` | 20 | Справочник: город однозначно определяет регион |
| `orders` | 1 000 000 | Лаба 3: статусы распределены 95% `DONE`, 4% `CANCELLED`, 1% `NEW`; город и регион коррелированы; `created_at` растёт вместе с `id` |

## Сброс

```bash
docker compose down -v    # удалит том с данными
docker compose up -d      # создаст всё заново
```

## Лабораторные

1. [Изоляция и аномалии](lab-01-isolation.md)
2. [Блокировки](lab-02-locks.md)
3. [Планировщик и индексы](lab-03-planner.md)
