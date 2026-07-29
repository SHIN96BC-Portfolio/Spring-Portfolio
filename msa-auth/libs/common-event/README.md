# common-event

auth 영역의 도메인 이벤트 공통 메타데이터와 추적 컨텍스트를 정의합니다.

## 제공 기능과 API

- `DomainEvent`: 이벤트 ID·타입·발생 시각·버전·trace ID를 생성하며, 하위 클래스에 `partitionKey()`, `aggregateType()`, `aggregateId()`, `eventData()` 구현을 요구합니다.
- `TraceContext`: `set`, `currentTraceId`, `clear`로 현재 스레드의 trace ID를 관리하고 값이 없으면 `"no-trace"`를 반환합니다.

외부 이벤트는 다음 envelope로 직렬화합니다.

```json
{
  "eventId": "UUID",
  "eventType": "AccountRegistered",
  "eventVersion": 1,
  "occurredAt": "ISO-8601",
  "traceId": "trace-id",
  "data": {
    "accountId": "UUID"
  }
}
```

공통 메타데이터와 도메인 payload를 분리해 발행 서비스의 내부 필드 구조가 바뀌어도 소비 DTO와 JSON Schema 계약을 유지합니다.

## 사용

```kotlin
implementation(project(":libs:common-event"))
```

## 의존 관계

Jackson Databind/JSR-310과 Lombok에 의존합니다. common-outbox, common-kafka, common-tracing의 기반 모듈이며 auth-service에도 루트 Gradle 설정을 통해 추가됩니다.

## 주의사항과 한계

- `TraceContext`는 `ThreadLocal` 기반이라 비동기·리액티브 경계로 자동 전파되지 않습니다.
- 발행기와 스키마 레지스트리는 제공하지 않습니다. 이벤트 호환성은 서비스별 JSON Schema와 계약 테스트로 검증해야 합니다.
- msa-platform 동명 모듈은 `com.msaplatform`, 이 모듈은 `com.msaauth` 패키지입니다. 소스 형태가 비슷해도 바이너리 호환되지 않습니다.
