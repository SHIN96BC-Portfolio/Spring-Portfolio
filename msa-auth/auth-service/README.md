# auth-service

계정 가입·로그인과 JWT 발급을 담당하는 인증 서비스입니다. 계정 자격 증명과 refresh token 저장을 소유하며, 사용자 프로필이나 다른 비즈니스 도메인은 다루지 않습니다.

## 책임과 경계

- 이메일 계정 생성, BCrypt 비밀번호 해시, 계정 상태 확인
- HMAC JWT access/refresh token 생성
- 계정과 refresh token 영속화, 계정 이벤트를 Outbox로 전달
- 인증 요청 이력·OAuth 관련 DB 스키마는 있으나 이를 사용하는 애플리케이션 기능은 아직 없습니다.

## 기술 정보

- Java 21, Spring Boot, Spring Security, JPA, Flyway, Kafka
- HTTP 포트: `8083`
- PostgreSQL: 기본 `localhost:5432/authdb` (`auth` / `authpw`)
- 실행 task: `:auth-service:bootRun`
- 패키징 task: `:auth-service:bootJar` → `auth-service.jar`

## 현재 HTTP API

- `POST /api/auth/signup`: `{ "email": "...", "password": "8자 이상" }`를 받아 계정을 만들고 `201`로 account ID와 email을 반환합니다.
- `POST /api/auth/login`: email/password를 검증하고 account ID, access token, refresh token, access token 만료 초를 반환합니다. User-Agent와 원격 IP를 refresh token 저장 포트로 전달합니다.

응답은 `ApiResponse<T>` 형식입니다. refresh, logout, 이메일 인증, OAuth 로그인/인가 서버, 내부 token verify, JWKS endpoint는 **구현되어 있지 않습니다**. `RefreshTokenUseCase` 인터페이스만 있고 controller와 구현체는 없습니다.

## 도메인과 이벤트

- `Account`: email, password hash, `AccountStatus`, email 인증 여부, 마지막 로그인 시각을 관리합니다.
- 값/정책: `Email`, `HashedPassword`, `RegistrationSource`, `PasswordHasher`, `TokenGenerator`.
- 이벤트: `AccountRegistered`, `AccountEmailVerified`, `AccountSuspended`.
  가입은 `AccountRegistered`를 Outbox에 저장합니다. `verifyEmail()` / `suspend(reason)`은
  각각 이벤트를 수집하지만, 이를 호출하는 애플리케이션 유스케이스(이메일 인증 API·관리자 정지)는
  아직 없습니다. OAuth 가입 시에는 `AccountRegistered`와 함께 `AccountEmailVerified`도 수집합니다.
- Flyway는 `account`, `refresh_token`, `oauth_identity`, `auth_attempt`, `outbox_events`, `oauth_client`, `oauth_authorization` 테이블을 생성합니다.

## 보안 관련 스키마 설계 (DB 감사 AUTH-01/02/03/04 반영)

- **외부 OAuth 토큰 미저장 (AUTH-01)**: `oauth_identity`는 `provider` + `provider_user_id` 연결만 저장합니다. 소셜 로그인 시 외부 토큰은 프로필 조회에 1회 사용 후 폐기하며, DB 유출 시 외부 계정 API 사칭이 가능한 평문 토큰을 아예 보관하지 않습니다(저장 최소화 원칙).
- **이메일 대소문자 정규화 (AUTH-02)**: `Email` 값 객체가 생성 시 소문자로 정규화(1차 방어)하고, DB의 `UNIQUE INDEX ON LOWER(email)`이 우회 경로까지 차단(2차 방어)합니다.
- **Refresh Token Rotation (AUTH-03)**: `refresh_token`에 `family_id`(로그인 세션 계열), `replaced_by`(rotation 체인), `revoked_at`/`revoked_reason`이 있습니다. 이미 대체된 토큰이 다시 제시되면 탈취 재사용으로 간주하고 family 전체를 폐기하는 구조입니다.
- **PKCE와 code 1회용 (AUTH-03)**: `oauth_authorization`에 `code_challenge`/`code_challenge_method`(PKCE), `redirect_uri`(토큰 교환 시 동일성 검증), `code_used_at`(code 재사용 공격 탐지), code/token 해시별 부분 UNIQUE 인덱스가 있습니다.
- **상태 전파 (AUTH-04)**: `canLogin()`은 `ACTIVE` **그리고** `email_verified`를 요구합니다.
  `AccountEmailVerified` / `AccountSuspended`로 user·point 로컬 상태를 맞춥니다.
  JSON Schema: `msa-infra/kafka/event-schemas/auth/`.

## 실행

PostgreSQL과 Kafka를 준비한 뒤 저장소의 `msa-auth` 디렉터리에서 실행합니다.

```bash
DB_HOST=localhost DB_PORT=5432 DB_NAME=authdb \
DB_USER=auth DB_PASSWORD=authpw \
KAFKA_BOOTSTRAP=localhost:29092 \
JWT_SECRET='256-bit 이상 길이의 운영용 비밀 값' \
./gradlew :auth-service:bootRun
```

기본 profile은 `local`이며 Flyway가 시작 시 마이그레이션을 수행하고 JPA는 스키마를 `validate`합니다.

## 현재 구현 상태와 알려진 제한

- `LoginService`가 요구하는 `RefreshTokenRepository`의 구현/bean이 없어 애플리케이션 시작 또는 로그인 흐름이 완성되지 않습니다. 포트는 rotation(`revokeFamily`, `replaced_by`)을 전제로 정의되어 있으나 이를 수행하는 서비스 로직도 아직 없습니다.
- Outbox auto-configuration imports 메타데이터가 없어 `@EnableScheduling`이 자동 적용되지 않을 수 있으므로 polling 발행 동작을 보장할 수 없습니다.
- JWT는 공유 대칭키 방식이며 key rotation, issuer/audience, token `typ` 검증, JWKS가 없습니다. 설정의 기본 secret은 운영에 사용하면 안 됩니다.
- refresh token 만료 저장값은 `LoginService`에 30일로 하드코딩되어 있어 `msa.jwt.refresh-expiry-seconds` 변경과 불일치할 수 있습니다.
- 보안 설정은 `/api/auth/**`, `/actuator/**`, `/oauth/**`를 모두 허용하고 CSRF를 끕니다. JWT 인증 필터는 없습니다.
- 도메인 예외 전용 HTTP 매핑이 없어 가입 중복·로그인 실패가 500 응답으로 처리될 수 있습니다.
- 이메일 가입 직후는 `email_verified=false`라 `canLogin()`이 false입니다. 인증 API 유스케이스가 아직 없어 이메일 가입 사용자는 로그인 플로우를 끝까지 쓸 수 없습니다.
- 이 서비스가 사용하는 auth 공통 라이브러리의 패키지는 `com.msaauth`입니다. msa-platform의 `com.msaplatform` 동명 라이브러리와 바이너리 호환되지 않습니다.
