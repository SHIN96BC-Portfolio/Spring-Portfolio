# Kafka Usage Guide

## 토픽 목록

| 토픽 | 발행자 | 파티션 키 |
|------|--------|----------|
| auth.events | msa-auth | accountId |
| user.events | msa-platform (user-service) | userId |
| commerce.events | msa-platform (commerce-service) | userId |
| fashion.events | msa-platform (fashion-service) | authorId |
| social.events | msa-platform (social-service) | authorId |
| point.events | msa-platform (point-service) | userId |
| recommendation.events | msa-platform (recommendation-service) | userId |
| notification.events | msa-platform (notification-service) | - |
| media.events | msa-platform (media-service) | - |
| saga.commands | Saga Orchestrator | sagaId |
| saga.replies | Saga Participant | sagaId |

## 이벤트 스키마

각 이벤트의 JSON Schema: [event-schemas/](../kafka/event-schemas/)

## Producer 설정 표준

```yaml
spring.kafka.producer:
  bootstrap-servers: localhost:29092  # 로컬 개발
  acks: all
  key-serializer: org.apache.kafka.common.serialization.StringSerializer
  value-serializer: org.springframework.kafka.support.serializer.JsonSerializer
  properties:
    enable.idempotence: true
    max.in.flight.requests.per.connection: 5
```

## Consumer 설정 표준

```yaml
spring.kafka.consumer:
  bootstrap-servers: localhost:29092
  group-id: ${service-name}  # 서비스마다 다름
  auto-offset-reset: earliest
  key-deserializer: org.apache.kafka.common.serialization.StringDeserializer
  value-deserializer: org.springframework.kafka.support.serializer.JsonDeserializer
  properties:
    spring.json.trusted.packages: "*"
```

## DLQ (Dead Letter Queue)

각 토픽마다 `<topic>.dlq` 자동 생성.

Consumer 실패 시 자동으로 DLQ로 이동. 상세 로직은 common-kafka 라이브러리 참고.

## 개발용 UI

http://localhost:8090
