# common-web

auth HTTP API의 응답 형식과 기본 전역 예외 처리를 제공합니다.

## 제공 기능과 API

- `ApiResponse<T>`와 `ok(data)`, `error(code, message)`: 성공·오류 payload와 timestamp를 생성합니다.
- `GlobalExceptionHandler`: validation 오류, `ConstraintViolationException`, `IllegalArgumentException`, 그 밖의 `Exception`을 각각 표준 응답으로 변환합니다.

## 사용

```kotlin
implementation(project(":libs:common-web"))
```

## 의존 관계

Spring Web, Bean Validation, Lombok에 의존하며 auth-service에는 루트 Gradle 설정으로 추가됩니다.

## 주의사항과 한계

- 도메인 예외(`EmailAlreadyExistsException`, `AccountNotFoundException`, `InvalidCredentialsException`) 전용 handler가 없습니다. 현재는 일반 예외 handler에 잡혀 HTTP 500이 될 수 있습니다.
- 일반 예외의 상세 내용은 로그에만 남고 응답은 고정된 `INTERNAL_ERROR`입니다.
- 오류 코드 카탈로그, 페이징 응답, 다중 validation 오류 응답은 없습니다.
- msa-platform 동명 모듈은 `ApiResponse`만 제공하며 패키지도 `com.msaplatform`으로 달라 바이너리 호환되지 않습니다.
