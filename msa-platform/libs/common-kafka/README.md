# common-kafka

Kafka 이벤트 직렬화에 사용할 공통 Jackson `ObjectMapper`를 구성합니다.

## 제공 기능과 API

- `KafkaAutoConfiguration`: `JavaTimeModule`을 등록하고 날짜를 ISO-8601 문자열로 쓰는 `@Primary ObjectMapper` bean을 제공합니다.

## 사용

```kotlin
implementation(project(":libs:common-kafka"))
```

## 의존 관계

`common-event`, Spring Boot, Spring Kafka, Jackson Databind/JSR-310에 의존합니다.

## 주의사항과 한계

- producer/consumer factory, listener, topic, serializer 설정은 제공하지 않습니다.
- 현재 `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`가 없어 의존성 추가만으로 자동 구성이 등록되지 않을 수 있습니다. 필요하면 애플리케이션에서 `KafkaAutoConfiguration`을 명시적으로 import하십시오.
- `@Primary` ObjectMapper가 애플리케이션의 기존 mapper 선택에 영향을 줄 수 있습니다.
- msa-auth 동명 모듈은 `com.msaauth`, 이 모듈은 `com.msaplatform` 패키지이며 바이너리 호환되지 않습니다.
