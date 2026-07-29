# common-outbox

PostgreSQL용 Outbox 이벤트 엔티티만 제공하는 최소 라이브러리입니다.

## 제공 기능과 API

- `OutboxEvent`: `outbox_events` 테이블에 매핑되는 JPA 엔티티입니다.
- `OutboxEvent.create(...)`: aggregate, 이벤트 버전, JSON payload, trace ID를 담은 이벤트를 생성합니다. **첫 인자 `eventId`는 `DomainEvent.eventId`와 동일한 UUID**여야 하며 DB `outbox_events.id`·Kafka key·`processed_events.event_id`와 맞춥니다 (COMMON-02).
- `markPublished()`, `isPublished()`: 발행 시각을 기록하고 상태를 확인합니다.

## 사용

```kotlin
implementation(project(":libs:common-outbox"))
```

## 의존 관계

`common-event`, Spring Data JPA, Hibernate JSON 타입, Jackson, Lombok에 의존합니다.

## 주의사항과 한계

- 이 모듈은 **엔티티만** 제공합니다. repository, 트랜잭션 내 저장 publisher, polling, Kafka 발행, 재시도는 구현되어 있지 않습니다.
- `payload`는 PostgreSQL `jsonb`, ID는 `uuid`를 전제로 하므로 테이블 마이그레이션은 사용하는 서비스가 준비해야 합니다.
- Kafka를 구독하는 서비스는 동일 DB에 `processed_events`를 두며, **PK는 `(event_id, consumer_group)`** 입니다 (플랫폼 감사 COMMON-01). `event_id`만 PK이면 한 서비스 DB에서 consumer group이 둘 이상일 때 두 번째 그룹이 멱등 기록을 못 합니다.
- **LOW-O6**: 대량 발행 시 `idx_outbox_published_purge` (`published_at` partial)로 오래된 published 행 purge 스윕에 사용합니다. 플랫폼 각 서비스 `V1__init.sql`에 포함.
- msa-auth의 common-outbox에는 repository와 polling publisher까지 있지만 패키지가 각각 `com.msaplatform`/`com.msaauth`라 바이너리 호환되지 않습니다.
