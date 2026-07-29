# common-event

서비스 간 도메인 이벤트의 공통 메타데이터와 추적 컨텍스트를 정의합니다.

## 제공 기능과 API

- `DomainEvent`: `eventId`, `eventType`, `occurredAt`, `eventVersion`, `traceId`를 생성합니다. 구현 클래스는 `partitionKey()`, `aggregateType()`, `aggregateId()`를 제공해야 합니다.
- `TraceContext`: 현재 스레드의 trace ID를 `set`, `currentTraceId`, `clear`로 관리하며 값이 없으면 `"no-trace"`를 반환합니다.
- `external.AccountRegisteredEvent`: auth의 계정 등록 이벤트를 역직렬화하기 위한 record입니다.

## 사용

```kotlin
implementation(project(":libs:common-event"))
```

## 의존 관계

Jackson Databind/JSR-310과 Lombok에 의존하며 다른 사내 라이브러리에는 의존하지 않습니다. common-kafka, common-outbox, common-saga, common-tracing의 기반 모듈입니다.

## 주의사항과 한계

- `TraceContext`는 `ThreadLocal` 기반이라 비동기·리액티브 실행으로 자동 전파되지 않습니다.
- 이벤트 스키마 레지스트리, 호환성 검사, 발행 기능은 제공하지 않습니다.
- msa-auth의 동명 라이브러리는 패키지가 `com.msaauth`이고 이 모듈은 `com.msaplatform`입니다. 클래스 이름과 형태가 비슷해도 바이너리 호환되지 않으므로 서로 대체할 수 없습니다.
