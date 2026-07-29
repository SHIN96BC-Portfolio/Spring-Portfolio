# common-kafka

auth 이벤트 직렬화에 사용할 공통 Jackson `ObjectMapper`를 구성합니다.

## 제공 기능과 API

- `KafkaAutoConfiguration`: Java 시간 타입을 ISO-8601 문자열로 처리하는 `@Primary ObjectMapper` bean을 제공합니다.

## 사용

```kotlin
implementation(project(":libs:common-kafka"))
```

## 의존 관계

`common-event`, Spring Boot, Spring Kafka, Jackson Databind/JSR-310에 의존합니다. auth-service에는 루트 Gradle 설정으로 추가됩니다.

## 주의사항과 한계

- Kafka producer/consumer, listener, topic과 오류 처리는 구성하지 않습니다.
- auto-configuration imports 메타데이터가 없어 의존성만으로 `KafkaAutoConfiguration`이 등록되지 않을 수 있습니다. 필요하면 명시적으로 import하십시오.
- `@Primary` mapper가 애플리케이션의 기존 mapper 선택에 영향을 줄 수 있습니다.
- msa-platform 동명 모듈은 `com.msaplatform`, 이 모듈은 `com.msaauth` 패키지이므로 바이너리 호환되지 않습니다.
