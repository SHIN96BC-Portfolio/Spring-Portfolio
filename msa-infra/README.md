# msa-infra

> 공유 인프라 레포 - Kafka, Redis, 관찰 가능성 스택, 클라우드 배포

## 역할

여러 애플리케이션(msa-auth, msa-platform)이 공유하는 인프라를 관리합니다.

## 소유 자원

- **Apache Kafka** - 이벤트 브로커 (KRaft 모드)
- **Redis** - 분산 락, 캐시
- **관찰 가능성 스택** - Prometheus, Grafana, Loki, Tempo
- **Terraform** - AWS 인프라 코드
- **이벤트 카탈로그** - 통합 스키마 관리

## 왜 별도 레포?

Kafka와 같은 공유 인프라는 특정 애플리케이션의 소유가 아닌 여러 시스템이 공유하는 자원입니다.
실무의 인프라팀 관리 방식을 반영했습니다.

자세한 이유: [ADR-0001](./docs/adr/0001-separate-infrastructure-layer.md)

## 시작하기

### 로컬 실행

```bash
cd docker
docker-compose up -d
```

띄워지는 것:
- Kafka (port 9092)
- Kafka UI (port 8090)
- Redis (port 6379)
- Prometheus (port 9090)
- Grafana (port 3001)
- Loki (port 3100)
- Tempo (port 3200)

### 네트워크

모든 레포가 같은 Docker 네트워크(`msa-network`)를 공유합니다.
msa-auth, msa-platform 실행 전에 이 레포부터 띄우세요.

## 다른 레포에서 사용

msa-auth, msa-platform 각각의 docker-compose.yml에:

```yaml
networks:
  msa-network:
    external: true
    name: msa-network
```

## 폴더 구조

```
msa-infra/
├── docker/              로컬 개발용 인프라
├── kafka/               토픽/스키마 정의
├── observability/       모니터링 설정
├── terraform/           클라우드 IaC
└── docs/                문서
```

## 문서

- [인프라 가이드](./docs/infrastructure-guide.md)
- [Kafka 사용 가이드](./docs/kafka-usage-guide.md)
- [이벤트 카탈로그](./docs/event-catalog.md)
- [ADR](./docs/adr/)
