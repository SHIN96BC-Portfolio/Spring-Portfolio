# common-tracing

auth HTTP 요청의 trace ID를 응답, MDC, 도메인 이벤트 컨텍스트에 연결합니다.

## 제공 기능과 API

- `TraceHttpFilter`: `X-Trace-Id`를 수용하거나 UUID를 생성하고 응답 헤더에 되돌려 줍니다.
- 처리 중 `TraceContext`와 MDC `traceId`를 설정하고 종료 시 제거합니다.
- Servlet `OncePerRequestFilter`이며 최우선 순서로 동작합니다.

## 사용

```kotlin
implementation(project(":libs:common-tracing"))
```

## 의존 관계

`common-event`, Spring Web(Servlet), SLF4J에 의존하며 auth-service에는 루트 Gradle 설정으로 추가됩니다.

## 주의사항과 한계

- 클래스가 `@Component`여도 auth-service 기본 스캔(`com.msaauth`)에는 포함되지만, 다른 시작 패키지의 애플리케이션에서는 scan/import가 필요합니다.
- Servlet/ThreadLocal 방식으로 WebFlux와 비동기 실행의 trace 전파를 지원하지 않습니다.
- OpenTelemetry span이나 외부 tracing backend 연동은 없습니다.
- msa-platform 동명 모듈은 `com.msaplatform` 패키지라 바이너리 호환되지 않습니다.
