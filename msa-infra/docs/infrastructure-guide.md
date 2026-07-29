# Infrastructure Guide

## 로컬 개발 환경 시작

### 1. 인프라 먼저 (이 레포)

```bash
cd docker
docker-compose up -d
```

**띄워지는 것:**
- Kafka (9092)
- Kafka UI (http://localhost:8090)
- Redis (6379)

**동작 확인:**
```bash
# Kafka 토픽 목록
docker exec msa-kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list

# Redis
docker exec msa-redis redis-cli -a redispw ping
```

### 2. msa-auth 실행

```bash
cd ../msa-auth/docker
docker-compose up -d          # postgres-auth 뜸
cd ..
./gradlew :auth-service:bootRun   # 또는 IntelliJ
```

### 3. msa-platform 실행

```bash
cd ../msa-platform/docker
docker-compose up -d          # PostgreSQL × 8, MongoDB 뜸
cd ..
./gradlew build
# 각 서비스는 IntelliJ에서 실행
```

## 네트워크 구조

모든 컨테이너는 `msa-network`라는 Docker 네트워크를 공유합니다.

msa-infra가 이 네트워크를 생성하고, 다른 레포들은 external로 참조합니다.

**주의:** msa-infra를 반드시 먼저 실행해야 네트워크가 생성됩니다.

## 관찰 가능성 스택 (선택)

Tier 1 후반부에 도입:

```bash
docker-compose -f docker-compose.yml -f docker-compose.observability.yml up -d
```

**접근:**
- Grafana: http://localhost:3001 (admin/admin)
- Prometheus: http://localhost:9090
- Tempo: http://localhost:3200
