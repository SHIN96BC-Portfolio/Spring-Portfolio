# msa-auth

> OAuth 2.0 Identity Provider - 여러 서비스가 공유하는 인증 인프라

## 역할

Auth0나 Keycloak처럼 독립된 Identity Provider입니다.
자체 인증 + 소셜 로그인 (카카오 등) + OAuth 2.0 Provider를 제공합니다.

**우리 msa-platform도 이 auth의 클라이언트 중 하나**입니다.

## 왜 별도 레포?

- 개념: auth는 특정 애플리케이션 소유가 아닌 독립 시스템
- 재사용: 다른 프로젝트에서도 활용 가능
- 배포: 안정성 중요, 별도 주기 관리

자세한 이유: [ADR-0001](./docs/adr/0001-auth-as-independent-service.md)

## 주요 기능

- 이메일/비밀번호 인증
- JWT 발급/검증/갱신
- 카카오 OAuth 클라이언트 (외부 → 우리)
- OAuth 2.0 Provider (우리 → 외부) ⭐
- 인증 시도 이력 추적

## 시작하기

### 사전 조건

msa-infra가 먼저 실행되어야 합니다.

```bash
cd ../msa-infra/docker
docker-compose up -d
```

### 이 레포 실행

```bash
# 1. postgres-auth 띄우기
cd docker
docker-compose up -d

# 2. 빌드
cd ..
./gradlew build

# 3. 실행 (IntelliJ 또는 CLI)
./gradlew :auth-service:bootRun
```

### 동작 확인

```bash
# 헬스체크
curl http://localhost:8083/actuator/health

# 회원가입
curl -X POST http://localhost:8083/api/auth/signup \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"pw12345678"}'
```

## 폴더 구조 (헥사고날)

```
auth-service/src/main/java/com/msaauth/
├── domain/          도메인 (순수 - Spring/JPA 모름)
├── application/     유스케이스 (Port & Service)
├── adapter/         어댑터 (Web, Persistence, Kafka)
├── infrastructure/  인프라 헬퍼 (BCrypt, JWT)
└── config/          Spring 설정
```

자세한 설계: [ARCHITECTURE.md](./ARCHITECTURE.md)

## 문서

- [OAuth Provider 가이드](./docs/oauth-provider-guide.md)
- [API 스펙 (OpenAPI)](./docs/api/openapi.yaml)
- [ADR](./docs/adr/)
