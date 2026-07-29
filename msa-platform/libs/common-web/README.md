# common-web

HTTP API의 성공·실패 응답 형식을 통일하는 모델을 제공합니다.

## 제공 기능과 API

- `ApiResponse<T>`: `success`, `data`, `error`, `timestamp` 필드를 갖습니다.
- `ApiResponse.ok(data)`: 성공 응답을 생성합니다.
- `ApiResponse.error(code, message)`: `ErrorInfo`를 포함한 실패 응답을 생성합니다.

## 사용

```kotlin
implementation(project(":libs:common-web"))
```

## 의존 관계

Spring Web, Bean Validation, Lombok에 의존합니다. msa-platform의 모든 service 프로젝트에는 루트 Gradle 설정으로 자동 추가됩니다.

## 주의사항과 한계

- 예외 처리기, 오류 코드 카탈로그, 페이징 응답은 제공하지 않습니다.
- HTTP 상태 코드는 `ApiResponse`가 정하지 않으므로 controller가 `ResponseEntity` 등으로 지정해야 합니다.
- msa-auth의 common-web에는 `GlobalExceptionHandler`도 있지만, 패키지가 각각 `com.msaplatform`/`com.msaauth`라 바이너리 호환되지 않습니다.
