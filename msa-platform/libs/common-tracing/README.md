# common-tracing

HTTP 요청의 trace ID를 응답, 로그 MDC, 도메인 이벤트 컨텍스트로 연결합니다.

## 제공 기능과 API

- `TraceHttpFilter`: `X-Trace-Id` 요청 헤더를 사용하거나 UUID를 생성해 같은 응답 헤더에 기록합니다.
- 처리 중 `TraceContext`와 MDC의 `traceId`를 설정하고 요청 종료 시 정리합니다.
- `Ordered.HIGHEST_PRECEDENCE`로 동작하는 `OncePerRequestFilter`입니다.

## 사용

```kotlin
implementation(project(":libs:common-tracing"))
```

## 의존 관계

`common-event`, Spring Web(Servlet), SLF4J에 의존합니다. msa-platform의 모든 service 프로젝트에는 루트 Gradle 설정으로 자동 추가됩니다.

## 주의사항과 한계

- `@Component` 스캔 범위에 `com.msaplatform.common.tracing`이 포함되어야 실제 필터가 등록됩니다.
- Servlet/ThreadLocal 기반이며 WebFlux와 비동기 작업의 컨텍스트 전파는 지원하지 않습니다.
- OpenTelemetry span 생성이나 외부 tracing backend 연동은 없습니다.
- msa-auth 동명 모듈은 `com.msaauth` 패키지이므로 바이너리 호환되지 않습니다.
