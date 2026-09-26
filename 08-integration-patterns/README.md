---
title: "8. Интеграционные паттерны"
nav_order: 9
has_children: true
---

# Блок 8. Интеграционные паттерны за пределами REST

В реальных проектах интеграции — это не только REST: gRPC между сервисами, GraphQL для фронтенда, пакетный обмен файлами с банками и поставщиками, CDC между базами, SOAP и шины у крупных заказчиков. Блок систематизирует этот зоопарк через классические интеграционные паттерны и учит выбирать способ интеграции под задачу.

| # | Модуль | Неделя |
|---|---|---|
| 8.1 | [Enterprise Integration Patterns: язык интеграций](8.1-eip.md) | 26 |
| 8.2 | [gRPC и GraphQL: когда не REST](8.2-grpc-graphql.md) | 26 |
| 8.3 | [Жизненный цикл API: контракты, версии, управление](8.3-api-lifecycle.md) | 27 |
| 8.4 | [Пакетные и файловые интеграции, ETL и сверки](8.4-batch-file-integration.md) | 27 |
| 8.5 | [CDC и синхронизация данных между системами](8.5-cdc-data-sync.md) | 27 |
| 8.6 | [Легаси-интеграции: SOAP, шины, iPaaS](8.6-legacy-esb.md) | 27 |

## Главные источники

- Gregor Hohpe, Bobby Woolf, *Enterprise Integration Patterns* (2003) и [enterpriseintegrationpatterns.com](https://www.enterpriseintegrationpatterns.com).
- JJ Geewax, *API Design Patterns* (Manning, 2021).
- Документация gRPC ([grpc.io](https://grpc.io)) и GraphQL ([graphql.org](https://graphql.org/learn/)).
- Раздел [Микросервисы и интеграции](https://system-design.space/theme/microservices-integration/) на system-design.space.

## Критерий завершения блока

Для обезличенного ландшафта из 5–7 систем (например, ERP, склад, магазины, поставщики, банк, аналитика) нарисовать карту интеграций: для каждой связи выбрать стиль (синхронный вызов, событие, пакет, CDC), протокол и формат, гарантии доставки и способ сверки. Обосновать выбор в таблице.
