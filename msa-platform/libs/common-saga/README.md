# common-saga

Saga 실행 상태를 PostgreSQL에 저장하기 위한 기본 모델을 제공합니다.

## 제공 기능과 API

- `SagaInstance`: `saga_instances` 테이블에 매핑되는 JPA 엔티티입니다.
- `SagaInstance.start(sagaType, payload)`: `STARTED` 상태의 saga를 생성합니다.
- `moveTo(step, state)`: 현재 단계와 상태, 수정 시각을 변경합니다.
- `SagaState`: `STARTED`, `IN_PROGRESS`, `COMPLETED`, `COMPENSATING`, `FAILED`.
- **낙관적 락 (COM-04)**: `version` 필드에 `@Version`이 있습니다. 동시 reply로
  인한 lost update 시 `OptimisticLockException`이 나므로 재조회 후 재시도해야 합니다.
  DB 컬럼은 commerce-service `V1__init.sql`의 `saga_instances.version`과 일치해야 합니다.

## 사용

```kotlin
implementation(project(":libs:common-saga"))
```

## 의존 관계

`common-event`, Spring Data JPA, Hibernate JSON 타입, Lombok에 의존합니다.

## 주의사항과 한계

- 엔티티와 상태 enum만 있으며 repository, orchestrator, 단계 실행, 보상 로직은 없습니다.
- payload는 PostgreSQL `jsonb`를 전제로 하며 스키마 마이그레이션은 제공하지 않습니다.
- 스텝 이력(`commerce_saga_step_history`)의 attempt/멱등 UNIQUE는 서비스 migration에
  있으며, 이 라이브러리는 해당 테이블용 엔티티를 제공하지 않습니다.