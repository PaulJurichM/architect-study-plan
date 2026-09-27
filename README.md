---
title: Главная
nav_order: 1
permalink: /
---

# Architect Study Plan

Программа прокачки системного аналитика до архитектора решений. В каждом модуле — урок на 15–20 минут чтения, практика на своём материале и вопросы в формате собеседования. Два подготовительных этапа закрывают базу, одиннадцать блоков основной программы ведут от того, как устроены интеграции и PostgreSQL «под капотом», через микросервисы, System Design и ИИ-системы — к архитектурной практике и роли архитектора.

Цель не «знать определения», а **уметь объяснить механизм и обосновать выбор**: почему здесь Saga, а не распределённая транзакция; почему планировщик не взял индекс; почему gateway и балансировщик — разные компоненты. Именно это спрашивают на собеседованиях уровня senior и именно это отличает сильную постановку от слабой.

## С чего начать

| Кто вы | Откуда начинать |
|---|---|
| Бизнес-аналитик, который переходит в системный анализ, или junior | [Этап 0А. Техническая база](00a-foundations/README.md) — с первого модуля |
| Системный аналитик уровня middle | [Входной тест этапа 0Б](00b-bridge/README.md#входной-тест): что знаете уверенно — пропускаете, остальное проходите |
| Senior-аналитик, готовитесь к архитектору | Сразу этап 1. Раздел «Готовность к модулю» в начале каждого модуля подскажет, если нужно вернуться к базе |

Входные тесты есть у обоих подготовительных этапов. В каждом модуле есть раздел **«Готовность к модулю»**: на какие темы он опирается, со ссылками. Если тема оттуда незнакома — сначала она.

Хотите пройти программу у себя со своим прогрессом — [сделайте свою копию](start.md).

## Дорожная карта

Четыре этапа по 4–6 часов в неделю. Подготовка: 0А (10 недель) и 0Б (9 недель) — проходятся по необходимости. Основная программа: этап 1 (12 недель) — фундамент: PostgreSQL, интеграции, микросервисы и итоговый проект; этап 2 (19 недель) — всё, что спрашивают у архитектора сверх фундамента.

```mermaid
flowchart TD
    subgraph P0["Подготовка"]
        A["Этап 0А: Техническая база"] --> B["Этап 0Б: Мост к архитектуре"]
    end
    subgraph P1["Этап 1 · недели 1–12"]
        B2["Блок 2: PostgreSQL"] --> B3["Блок 3: Микросервисы и DDD"]
        B1["Блок 1: HTTP и безопасность"] -.-> B3
        B3 --> C["Итоговый проект"]
    end
    subgraph P2["Этап 2 · недели 13–31"]
        B7["Блок 7: System Design"] --> B5["Блок 5: ИИ-системы"]
        B6["Блок 6: Архитектурная практика"] -.-> B11["Блок 11: Роль архитектора"]
        B5 --> B8["Блок 8: Интеграции"]
        B8 --> B9["Блок 9: Данные"]
        B9 --> B10["Блок 10: Инфраструктура"]
    end
    B --> B2
    B --> B1
    C --> B7
```

Как подготовка связана с основной программой — модуль за модулем:

| Подготовка | Готовит к модулям |
|---|---|
| [А.1 Как устроено приложение](00a-foundations/a1-how-apps-work.md) | 3.1 |
| [А.2 Как работает веб](00a-foundations/a2-web-http-basics.md) | 1.1, 1.3 |
| [А.3 Данные и форматы](00a-foundations/a3-data-formats.md) | 5.1, 8.4, 8.6 |
| [А.4 Реляционные БД](00a-foundations/a4-relational-model.md) | 2.1, 9.2 |
| [А.5 SQL для аналитика](00a-foundations/a5-sql-basics.md) | 2.4, 9.1 |
| [А.6 API и интеграции](00a-foundations/a6-integrations-intro.md) | 3.4, 8.4 |
| [А.7 UML и BPMN](00a-foundations/a7-uml-bpmn.md) | 6.3 |
| [А.8 Процесс разработки](00a-foundations/a8-dev-process.md) | 2.6, 10.2, 11.3 |
| [А.9 Системные требования](00a-foundations/a9-system-requirements.md) | 3.2, 5.7, 6.1, 11.1 |
| [Б.1 Сеть для интеграций](00b-bridge/b1-networking.md) | 1.1, 3.3 |
| [Б.2 Основы безопасности](00b-bridge/b2-security-basics.md) | 1.2, 1.4, 1.5, 5.5 |
| [Б.3 Контракты API](00b-bridge/b3-api-contracts.md) | 1.3, 5.3, 8.2, 8.3 |
| [Б.4 SQL и транзакции](00b-bridge/b4-sql-transactions.md) | 2.1, 2.2, 2.3, 2.4, 2.5, 5.2 |
| [Б.5 Асинхронный обмен](00b-bridge/b5-async-messaging.md) | 3.4, 3.5, 7.5, 8.1, 8.5, 9.3 |
| [Б.6 Архитектура приложения](00b-bridge/b6-app-architecture.md) | 3.1, 3.3, 3.7, 5.6, 7.1, 7.2, 7.3, 7.5, 10.1, 10.3 |
| [Б.7 Описание решения](00b-bridge/b7-documenting-solutions.md) | итоговый проект, 6.1, 6.2, 6.3 |
| [Б.8 Распределённые системы](00b-bridge/b8-distributed-basics.md) | 3.5, 3.6, 3.7, 7.1, 7.4, 10.4 |

Основной трек — одна тема в неделю; параллельный — по часу в неделю, небольшими порциями.

### Этап 0А. Техническая база

| Неделя этапа | Модуль |
|---|---|
| 1 | [А.1 Как устроено приложение: клиент, сервер, база данных](00a-foundations/a1-how-apps-work.md) |
| 2 | [А.2 Как работает веб: URL, HTTP-запрос и ответ](00a-foundations/a2-web-http-basics.md) |
| 3 | [А.3 Данные и форматы: JSON, XML, CSV, типы данных](00a-foundations/a3-data-formats.md) |
| 4 | [А.4 Реляционные базы данных: таблицы, ключи, связи, ER-диаграммы](00a-foundations/a4-relational-model.md) |
| 5–6 | [А.5 SQL для аналитика: от SELECT до JOIN и GROUP BY](00a-foundations/a5-sql-basics.md) |
| 7 | [А.6 API и интеграции глазами аналитика](00a-foundations/a6-integrations-intro.md) |
| 8 | [А.7 Моделирование: UML и BPMN для системного аналитика](00a-foundations/a7-uml-bpmn.md) |
| 9 | [А.8 Процесс разработки: от задачи до релиза](00a-foundations/a8-dev-process.md) |
| 10 | [А.9 От бизнес-требования к системному: user story, use case, спецификация](00a-foundations/a9-system-requirements.md) |

### Этап 0Б. Мост к архитектуре

| Неделя этапа | Модуль |
|---|---|
| 1 | [Б.1 Сеть для интеграций: IP, порты, DNS, TCP, прокси](00b-bridge/b1-networking.md) |
| 2 | [Б.2 Основы безопасности: криптография, аутентификация, авторизация](00b-bridge/b2-security-basics.md) |
| 3 | [Б.3 Проектирование контракта API: ресурсы, OpenAPI, ошибки, совместимость](00b-bridge/b3-api-contracts.md) |
| 4–5 | [Б.4 SQL глубже и транзакции: оконные функции, индексы, EXPLAIN, конкурентность](00b-bridge/b4-sql-transactions.md) |
| 6 | [Б.5 Асинхронный обмен: очереди, брокеры, гарантии доставки](00b-bridge/b5-async-messaging.md) |
| 7 | [Б.6 Архитектура приложения: слои, монолит и сервисы, инфраструктура](00b-bridge/b6-app-architecture.md) |
| 8 | [Б.7 Описание решения: спецификация интеграции, диаграммы, нефункциональные требования](00b-bridge/b7-documenting-solutions.md) |
| 9 | [Б.8 Распределённые системы: базовые понятия](00b-bridge/b8-distributed-basics.md) |

### Этап 1. Фундамент

| Неделя | Основной трек | Параллельный трек |
|---|---|---|
| 1 | [2.1 MVCC и хранение](02-postgresql/2.1-mvcc-storage.md) | [1.1 Путь HTTP-запроса](01-http-rest-security/1.1-request-lifecycle.md) |
| 2 | [2.2 Изоляция транзакций](02-postgresql/2.2-isolation.md) + [лаба 1](02-postgresql/labs/lab-01-isolation.md) | [1.2 TLS и PKI](01-http-rest-security/1.2-tls-pki.md) |
| 3 | [2.3 Блокировки](02-postgresql/2.3-locks.md) + [лаба 2](02-postgresql/labs/lab-02-locks.md) | [1.2 TLS и PKI](01-http-rest-security/1.2-tls-pki.md) |
| 4 | [2.4 Планировщик](02-postgresql/2.4-planner.md) + [2.5 Индексы](02-postgresql/2.5-indexes.md) + [лаба 3](02-postgresql/labs/lab-03-planner.md) | [1.3 REST-семантика](01-http-rest-security/1.3-rest-semantics.md) |
| 5 | [2.6 WAL, репликация, миграции](02-postgresql/2.6-wal-replication-migrations.md) · [3.1 Зачем микросервисы](03-microservices-ddd/3.1-why-microservices.md) | [1.3 REST-семантика](01-http-rest-security/1.3-rest-semantics.md) |
| 6 | [3.2 Стратегический DDD](03-microservices-ddd/3.2-strategic-ddd.md) | [1.4 OAuth 2.0, OIDC, JWT](01-http-rest-security/1.4-oauth-oidc-jwt.md) |
| 7 | [3.3 Сеть: OSI, балансировщик, gateway, mesh](03-microservices-ddd/3.3-network-gateway-lb.md) | [1.4 OAuth 2.0, OIDC, JWT](01-http-rest-security/1.4-oauth-oidc-jwt.md) |
| 8 | [3.4 Коммуникация и брокеры](03-microservices-ddd/3.4-communication.md) | [1.5 Защита API](01-http-rest-security/1.5-api-security.md) |
| 9 | [3.5 Данные: Saga, Outbox, CQRS](03-microservices-ddd/3.5-data-patterns.md) | [1.5 Защита API](01-http-rest-security/1.5-api-security.md) |
| 10 | [3.6 Устойчивость](03-microservices-ddd/3.6-resilience.md) · [3.7 Наблюдаемость](03-microservices-ddd/3.7-observability.md) | — |
| 11–12 | [Итоговый проект](04-capstone/README.md) | — |

### Этап 2. Архитектор

| Неделя | Основной трек | Параллельный трек |
|---|---|---|
| 13 | [7.1 Метод интервью](07-system-design/7.1-interview-method.md) | [6.1 Атрибуты качества](06-architecture-practice/6.1-quality-attributes.md) |
| 14 | [7.2 Оценки на салфетке](07-system-design/7.2-estimation.md) | [6.1 Атрибуты качества](06-architecture-practice/6.1-quality-attributes.md) |
| 15 | [7.3 Кэширование](07-system-design/7.3-caching.md) | [6.2 ADR](06-architecture-practice/6.2-adr.md) |
| 16 | [7.4 Масштабирование данных](07-system-design/7.4-scaling-data.md) | [6.3 C4 и arc42](06-architecture-practice/6.3-c4-arc42.md) |
| 17 | [7.5 Строительные блоки](07-system-design/7.5-building-blocks.md) | [6.4 Анализ компромиссов](06-architecture-practice/6.4-tradeoff-analysis.md) |
| 18 | [7.6 Классические задачи](07-system-design/7.6-classic-cases.md) | [6.5 Эволюция и легаси](06-architecture-practice/6.5-evolutionary-architecture.md) |
| 19 | [5.1 Как работают LLM](05-ai-engineering/5.1-llm-basics.md) | [11.1 Стейкхолдеры](11-architect-role/11.1-stakeholders.md) |
| 20 | [5.2 RAG](05-ai-engineering/5.2-rag.md) | [11.2 Архитектурное ревью](11-architect-role/11.2-architecture-review.md) |
| 21 | [5.3 Агенты, инструменты, MCP](05-ai-engineering/5.3-agents-tools-mcp.md) | [11.3 Оценка трудоёмкости](11-architect-role/11.3-estimation.md) |
| 22 | [5.4 Оценка качества](05-ai-engineering/5.4-evals.md) | [11.4 Фасилитация](11-architect-role/11.4-facilitation.md) |
| 23 | [5.5 Безопасность LLM](05-ai-engineering/5.5-llm-security.md) | [11.5 Поведенческое интервью](11-architect-role/11.5-behavioral-interview.md) |
| 24 | [5.6 ML-системы в эксплуатации](05-ai-engineering/5.6-ml-in-production.md) | [11.5 Поведенческое интервью](11-architect-role/11.5-behavioral-interview.md) |
| 25 | [5.7 Требования к ИИ-функции](05-ai-engineering/5.7-ai-feature-requirements.md) | — |
| 26 | [8.1 EIP](08-integration-patterns/8.1-eip.md) · [8.2 gRPC и GraphQL](08-integration-patterns/8.2-grpc-graphql.md) | — |
| 27 | [8.3 Жизненный цикл API](08-integration-patterns/8.3-api-lifecycle.md) · [8.4 Пакетные интеграции](08-integration-patterns/8.4-batch-file-integration.md) · [8.5 CDC](08-integration-patterns/8.5-cdc-data-sync.md) · [8.6 Легаси и шины](08-integration-patterns/8.6-legacy-esb.md) | — |
| 28 | [9.1 OLTP и OLAP](09-data-platforms/9.1-oltp-olap.md) · [9.2 Моделирование DWH](09-data-platforms/9.2-dwh-modeling.md) | — |
| 29 | [9.3 Конвейеры и потоки](09-data-platforms/9.3-pipelines-streaming.md) · [9.4 Аналитические СУБД](09-data-platforms/9.4-analytical-engines.md) · [9.5 Качество данных](09-data-platforms/9.5-data-quality-governance.md) | — |
| 30 | [10.1 Kubernetes](10-infrastructure-delivery/10.1-containers-kubernetes.md) · [10.2 CI/CD и релизы](10-infrastructure-delivery/10.2-cicd-release.md) | — |
| 31 | [10.3 Облака](10-infrastructure-delivery/10.3-cloud.md) · [10.4 DR](10-infrastructure-delivery/10.4-dr-multiregion.md) · [10.5 SRE и FinOps](10-infrastructure-delivery/10.5-sre-finops.md) | — |

Блоки 8–10 плотнее по графику: многое там знакомо по практике, и задача — систематизировать, а не учить с нуля. Если тема идёт тяжело — растягивайте, график ориентировочный.

## Как устроен каждый модуль

- **Зачем это аналитику** — где тема всплывает в постановках, интеграциях и на собеседовании.
- **Готовность к модулю** — на какие модули он опирается. В подготовительных модулях есть и обратная связь — **Куда ведёт**: где тема раскрывается дальше.
- **Что понять** — механизмы, которые нужно усвоить; работает как чек-лист.
- **Урок** — основной текст: механизмы, примеры, схемы, типичные ошибки, как говорить об этом на собеседовании.
- **Читать дальше** — книги, документация и главы [system-design.space](https://system-design.space/) для углубления. Необязательно.
- **Практика** — руками, на своём материале и стенде (никогда не на базе или стенде заказчика).
- **Вопросы для самопроверки** — в формате собеседования. Модуль закрыт, когда на каждый вопрос можешь ответить вслух за 2–3 минуты, с примером и без подглядывания.
- **Заметки** — свои формулировки, ошибки, находки. Самое ценное в репозитории.

## Отслеживание прогресса

- Каждый модуль — отдельный issue, каждый блок и этап — milestone. Общая картина — на странице [Прогресс](progress.md): полоски по блокам и статус каждого модуля. В начале каждого модуля тоже есть плашка со статусом и ссылкой на его issue.
- Внутри issue — раздел «Готовность»: на какие модули опирается этот, и чек-лист «проверил готовность / прочитал урок / сделал практику / ответил на вопросы / записал заметки». Issue закрывается, когда отмечены все пункты.
- Заметки коммитятся прямо в файл модуля, в раздел «Заметки». Коммит со ссылкой `Closes #N` закрывает issue автоматически.
- Issues, milestones и метки создаёт GitHub Actions — workflow [«Синхронизировать issues»]({{ site.gh_edit_repository }}/blob/main/.github/workflows/sync-issues.yml) по данным из `scripts/modules.json`. Он запускается сам, когда меняется этот файл, и вручную на вкладке Actions. Существующие issues находятся по пути к файлу модуля, отмеченные галочки сохраняются.

## Этапы и блоки

- [Этап 0А. Техническая база](00a-foundations/README.md)
- [Этап 0Б. Мост к архитектуре](00b-bridge/README.md)

1. [HTTP, REST и безопасность интеграций](01-http-rest-security/README.md)
2. [PostgreSQL изнутри](02-postgresql/README.md)
3. [Микросервисы, DDD и устойчивость](03-microservices-ddd/README.md)
4. [Итоговый проект](04-capstone/README.md)
5. [ИИ в архитектуре систем](05-ai-engineering/README.md)
6. [Архитектурная практика и документирование](06-architecture-practice/README.md)
7. [System Design для собеседований](07-system-design/README.md)
8. [Интеграционные паттерны за пределами REST](08-integration-patterns/README.md)
9. [Данные и аналитические системы](09-data-platforms/README.md)
10. [Инфраструктура и поставка](10-infrastructure-delivery/README.md)
11. [Архитектор как роль](11-architect-role/README.md)

[Общая библиография](resources.md)

## Правило репозитория

Репозиторий публичный. Никаких названий заказчиков, внутренних систем, схем, логов и данных с реальных проектов — только обезличенные учебные примеры. Тексты уроков оригинальные: материалы других авторов только упоминаются в разделах «Читать дальше».

## Как сделана программа

Структуру программы, связи между модулями, требования к урокам и примеры из предметных областей задавал автор. Тексты уроков написаны с помощью Claude (Anthropic): уроки параллельно готовили несколько агентов, а факты в них проверяли отдельные агенты по документации и первоисточникам. Если найдёте ошибку, заведите issue или поправьте файл через «Редактировать на GitHub».
