# common-outbox

도메인 이벤트를 트랜잭션에 함께 저장하고 PostgreSQL에서 polling해 Kafka로 발행합니다.

## 제공 기능과 API

- `OutboxEvent`, `OutboxEventRepository`: `outbox_events` 엔티티와 `FOR UPDATE SKIP LOCKED` 미발행 조회를 제공합니다.
- `OutboxEventPublisher.publish(DomainEvent)`: 기존 트랜잭션(`MANDATORY`) 안에서 이벤트를 JSON으로 저장합니다. `outbox_events.id`는 `DomainEvent.eventId`와 동일합니다 (COMMON-02).
- `OutboxPollingPublisher.publishPendingEvents()`: 기본 1초 간격, 최대 100건씩 Kafka에 동기 전송합니다. **메시지 키는 outbox id(`eventId`)**이며, 성공한 이벤트를 발행 완료 처리합니다.
- `OutboxAutoConfiguration`: `msa.outbox.enabled`가 true(기본값)일 때 scheduling, component scan, JPA repository를 활성화하도록 작성되어 있습니다.

## 사용

```kotlin
implementation(project(":libs:common-outbox"))
```

설정 키는 `msa.outbox.enabled`, `polling-interval`, `batch-size`, `topic-prefix`입니다.

## 의존 관계

`common-event`, Spring Data JPA, Jackson, Lombok에 의존합니다. msa-platform common-outbox와 달리 repository·저장 publisher·polling publisher까지 구현되어 있습니다.

## 주의사항과 한계

- **현재 Gradle 파일에 `spring-kafka` 의존성이 없지만 코드가 `KafkaTemplate`을 사용하므로 이 모듈 단독 컴파일이 실패합니다.** 의존 서비스가 추가해도 Gradle의 모듈 컴파일 classpath 문제는 해결되지 않습니다.
- auto-configuration imports 메타데이터가 없어 `OutboxAutoConfiguration`이 의존성 추가만으로 등록되지 않을 수 있습니다.
- Kafka 전송 성공과 DB의 `publishedAt` 갱신은 원자적이지 않아 장애 시 중복 발행될 수 있으며 별도 dead-letter/최대 재시도 정책이 없습니다.
- 알 수 없는 aggregate는 `unknown.events`로 발행됩니다.
- PostgreSQL `jsonb`, `uuid`, `SKIP LOCKED` 및 `outbox_events` 스키마를 전제로 합니다.
- msa-platform 버전은 엔티티만 제공하고 패키지도 `com.msaplatform`으로 달라 이 `com.msaauth` 모듈과 바이너리 호환되지 않습니다.
