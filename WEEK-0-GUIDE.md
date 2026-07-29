# Week 0 - 병렬 진행 가이드

> 매일 결과가 나오는 5일 셋업 플랜

## 목표

Week 0 종료 시:
- 3개 레포 폴더 구조 완성
- Kafka, DB 인프라 뜸
- msa-auth의 회원가입 API 동작
- msa-platform의 user-service가 msa-auth의 이벤트 구독
- 12개 서비스 모두 Hello World 응답

**Week 1부터 도메인 본격 구현.**

---

## Day 1: msa-infra 최소 셋업 + msa-auth 골격

### 오전 (1~2시간): msa-infra

```bash
cd msa-infra/docker
docker-compose up -d

# 확인
docker ps
docker exec msa-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list

# 출력에 auth.events, user.events 등 11개 토픽이 보이면 성공
```

### 오후 (3~4시간): msa-auth 골격

```bash
cd ../../msa-auth

# Gradle wrapper 초기화 (처음 한 번)
gradle wrapper --gradle-version 8.5

# postgres-auth 띄우기
cd docker
docker-compose up -d
cd ..

# 빌드
./gradlew build

# 실행 (IntelliJ 또는 CLI)
./gradlew :auth-service:bootRun
```

### Day 1 완료 조건

```bash
# Health check 응답이 나와야 함
curl http://localhost:8083/actuator/health

# 응답 예시:
# {"status":"UP","components":{"db":{"status":"UP"}, ...}}
```

---

## Day 2: msa-auth 회원가입 완성

### 오늘 할 일

이미 골격이 준비되어 있으니 다음만 확인:

1. Flyway가 V1__init.sql 실행하는지 확인
```bash
docker exec msa-postgres-auth psql -U auth -d authdb -c "\dt"
# account, refresh_token, outbox_events 등 테이블 보이면 성공
```

2. 회원가입 API 테스트
```bash
curl -X POST http://localhost:8083/api/auth/signup \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"pw12345678"}'

# 응답:
# {"success":true,"data":{"accountId":"...","email":"test@example.com"}}
```

3. Outbox 이벤트 확인
```bash
docker exec msa-postgres-auth psql -U auth -d authdb -c "SELECT event_type, payload FROM outbox_events;"
# AccountRegistered 이벤트가 있어야 함
```

4. Kafka로 발행됐는지 확인
```bash
docker exec msa-kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic auth.events \
  --from-beginning \
  --max-messages 1

# JSON 이벤트가 출력되면 성공
```

### Day 2 완료 조건

- 회원가입 API 200 응답
- outbox_events 테이블에 이벤트 저장됨
- auth.events 토픽에서 이벤트 확인됨
- Kafka UI (http://localhost:8090) 에서도 확인 가능

---

## Day 3: msa-platform 골격 + user-service Hello World

### 오전 (2시간): 인프라

```bash
cd msa-platform

# Gradle wrapper 초기화
gradle wrapper --gradle-version 8.5

# DB 인스턴스들 띄우기
cd docker
docker-compose up -d

# 확인
docker ps | grep msa-postgres

# 8개 PostgreSQL + 1개 MongoDB 보여야 함
cd ..
```

### 오후 (2~3시간): 빌드 & user-service 실행

```bash
# 전체 빌드 (오래 걸림 - 초기)
./gradlew build

# user-service 실행
./gradlew :services:user-service:bootRun

# 다른 터미널에서 확인
curl http://localhost:8084/hello
# {"service":"user-service","message":"Hello from user-service!"}

curl http://localhost:8084/actuator/health
```

### Day 3 완료 조건

- 12개 서비스 모두 빌드 성공
- user-service 실행 성공
- Hello 응답 확인

---

## Day 4: 이벤트 연동 (핵심!)

### 목표

**msa-auth의 회원가입 → AccountRegistered 이벤트 → msa-platform의 user-service가 구독 → user_profile 자동 생성**

이 흐름이 완성되면 진짜 MSA 이벤트 드리븐 아키텍처가 동작하는 겁니다.

### 작업 순서

**1. user-service에 이벤트 컨슈머 추가**

`msa-platform/services/user-service/src/main/java/com/msaplatform/userservice/adapter/in/kafka/AccountEventConsumer.java` 새 파일:

```java
package com.msaplatform.userservice.adapter.in.kafka;

import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.kafka.annotation.KafkaListener;
import org.springframework.stereotype.Component;

@Slf4j
@Component
@RequiredArgsConstructor
public class AccountEventConsumer {

    private final ObjectMapper objectMapper;

    @KafkaListener(topics = "auth.events", groupId = "user-service")
    public void onAuthEvent(String message) {
        log.info("Received auth event: {}", message);
        // TODO: JSON 파싱 → AccountRegistered 확인 → user_profile 생성
    }
}
```

**2. user-service의 도메인 만들기**

`user-service/src/main/resources/db/migration/V2__user_profile.sql`:

```sql
CREATE TABLE user_profile (
    id            BIGSERIAL PRIMARY KEY,
    account_id    UUID UNIQUE NOT NULL,
    nickname      VARCHAR(50) UNIQUE NOT NULL,
    avatar_url    VARCHAR(500),
    bio           TEXT,
    status        VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    created_at    TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_user_profile_account ON user_profile(account_id);
CREATE INDEX idx_user_profile_nickname ON user_profile(nickname);
```

**3. 흐름 테스트**

```bash
# msa-auth에서 회원가입
curl -X POST http://localhost:8083/api/auth/signup \
  -H "Content-Type: application/json" \
  -d '{"email":"newuser@example.com","password":"pw12345678"}'

# user-service 로그 확인 - "Received auth event" 로그 있어야 함
# tail -f logs/user-service.log
```

### Day 4 완료 조건

- msa-auth의 회원가입 → auth.events 발행 → user-service에서 로그 확인
- 이벤트 드리븐 아키텍처의 첫 동작 확인

---

## Day 5: 나머지 11개 서비스 골격 실행

### 목표

모든 서비스가 뜨는지 확인.

### 실행 순서

```bash
# 터미널을 여러 개 열거나, IntelliJ 여러 창

./gradlew :services:edge-gateway:bootRun
./gradlew :services:user-bff:bootRun
./gradlew :services:admin-bff:bootRun
./gradlew :services:commerce-service:bootRun
./gradlew :services:point-service:bootRun
./gradlew :services:fashion-service:bootRun
./gradlew :services:social-service:bootRun
./gradlew :services:recommendation-service:bootRun
./gradlew :services:activity-feed-service:bootRun
./gradlew :services:notification-service:bootRun
./gradlew :services:media-service:bootRun
```

### 확인 스크립트

```bash
# 12개 서비스 헬스체크
for port in 8080 8081 8082 8084 8085 8086 8087 8088 8089 8090 8091 8092; do
  echo -n "Port $port: "
  curl -s http://localhost:$port/actuator/health | jq -r '.status' 2>/dev/null || echo "DOWN"
done
```

모두 UP 나오면 Week 0 완료!

---

## Week 0 완료 후

이제 Week 1부터 도메인 본격 구현.

### Week 1 예정 작업

- msa-auth의 로그인 API 완성
- msa-platform의 user-service 도메인 완성 (프로필, 팔로우)
- 회원가입 → user_profile 자동 생성 실제 동작

### 트러블슈팅

**Q: Kafka 연결 안 됨**
- msa-infra의 docker-compose가 먼저 떠 있는지 확인
- msa-network 네트워크 존재 확인: `docker network ls | grep msa`

**Q: DB 연결 안 됨**
- 각 레포의 docker-compose가 떠 있는지 확인
- 포트 충돌 확인: `netstat -an | grep 5432`

**Q: Gradle 빌드 실패**
- Java 21 설치 확인: `java -version`
- `./gradlew clean build --refresh-dependencies`

**Q: 서비스 실행 시 Bean 충돌**
- 각 서비스는 다른 SpringBootApplication 클래스 사용
- 같은 JVM에서 여러 서비스 실행 X (각각 다른 JVM)

---

## 참고

- 각 레포 내부 폴더 구조: 각 레포의 README 참고
- 공통 라이브러리 사용법: `libs/*/README.md`
- 이벤트 카탈로그: `msa-infra/docs/event-catalog.md`
