# msa-platform

> MSA 포트폴리오의 메인 애플리케이션 레이어. 13개 비즈니스 도메인 서비스.

## 역할

이 레포는 실제 비즈니스 도메인 서비스들을 담습니다.
- 커머스, 패션, 소셜 도메인
- 추천/마케팅 알고리즘 (실서비스 수준)
- CQRS, Saga 등 핵심 MSA 패턴

## 사전 조건

두 개의 다른 레포가 필요합니다:

```
msa-infra    (Kafka, Redis, 관찰 가능성)
msa-auth     (Identity Provider)
```

## 시작하기

```bash
# 한 번에 (OS 자동 분기 — scripts/README.md 참고)
cd ..   # be-service-portfolio
cd scripts && ./db up
```

# 또는 수동:
# 1. msa-infra 실행
cd ../msa-infra/docker
docker compose up -d

# 2. msa-auth 실행 (postgres-auth 뜨고, IntelliJ로 실행)
cd ../../msa-auth/docker
docker compose up -d
cd ..
./gradlew :auth-service:bootRun  # 또는 IntelliJ

# 3. msa-platform 실행 (이 레포)
cd ../msa-platform/docker
docker compose up -d          # PostgreSQL × 9, MongoDB (V1 init on first volume)

cd ..
./gradlew build
```

## 서비스 목록 (13개)

| # | 서비스 | 포트 | DB |
|---|--------|------|-----|
| 1 | edge-gateway | 8080 | - |
| 2 | user-bff | 8081 | - |
| 3 | admin-bff | 8082 | - |
| 4 | user-service | 8084 | postgres-user |
| 5 | commerce-service | 8085 | postgres-commerce |
| 6 | point-service | 8086 | postgres-point |
| 7 | fashion-service | 8087 | postgres-fashion |
| 8 | social-service | 8088 | postgres-social |
| 9 | recommendation-service | 8089 | postgres-recommendation |
| 10 | activity-feed-service | 8090 | mongodb |
| 11 | notification-service | 8091 | postgres-notification |
| 12 | media-service | 8092 | postgres-media |
| 13 | content-service | 8093 | postgres-content |

**auth-service는 별도 레포 (msa-auth)에 있습니다.**

## 폴더 구조

```
msa-platform/
├── libs/                    공통 라이브러리
├── services/                13개 서비스
├── docker/                  로컬 개발 인프라
├── docs/                    문서
└── .github/workflows/       CI/CD
```

## 헥사고날 아키텍처

각 서비스는 헥사고날 구조를 따릅니다.

## PostgreSQL 시간 타입 (COMMON-03)

분산 환경에서 `TIMESTAMP WITHOUT TIME ZONE`은 서버 로컬 해석 차이로 만료·예약·이벤트 순서 비교가 어긋날 수 있습니다.

- 모든 Flyway `V1__init.sql` 시각 컬럼은 **`TIMESTAMPTZ`** (UTC 저장)입니다.
- 애플리케이션·JDBC URL·컨테이너는 **`timezone=UTC`** 를 권장합니다.
- MongoDB(activity-feed)는 별도이나, API·이벤트 envelope의 `occurredAt`은 ISO-8601 UTC 문자열을 사용합니다.

```
services/{service-name}/src/main/java/com/msaplatform/{name}/
├── domain/          도메인 (순수)
├── application/     유스케이스
├── adapter/         어댑터
└── infrastructure/  인프라
```

## 문서

- [ARCHITECTURE.md](./ARCHITECTURE.md)
- [서비스별 상세](./docs/services/)
- [ADR](./docs/adr/)
