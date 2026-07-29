-- ==============================================================
-- auth-service 초기 스키마
-- ==============================================================

-- UUID 함수 활성화
-- [COMMON-03] 시각 컬럼은 TIMESTAMPTZ(UTC). 앱·JDBC·PostgreSQL 세션 timezone=UTC 권장.

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ==============================================================
-- account: 계정
--
-- [AUTH-02] 이메일 대소문자 중복 방지.
--   - 애플리케이션(Email 값 객체)이 소문자로 정규화해 저장하는 것이 1차 방어,
--     DB 의 UNIQUE INDEX ON LOWER(email) 이 2차 방어.
--     정규화를 우회하는 경로(수동 INSERT, 배치 등)가 생겨도
--     User@x.com / user@x.com 이 별도 계정으로 만들어질 수 없다.
--   - citext 확장 대신 함수 인덱스를 선택: 확장 설치 없이 동작하고,
--     조회 시 WHERE LOWER(email) = ? 로 인덱스를 태울 수 있다.
-- ==============================================================
CREATE TABLE account (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email           VARCHAR(100) NOT NULL,
    password_hash   VARCHAR(255),
    status          VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    email_verified  BOOLEAN NOT NULL DEFAULT false,
    last_login_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- [AUTH-04] AccountStatus enum 과 동기. 정지/삭제는 이벤트로 전파
    CONSTRAINT chk_account_status CHECK (
        status IN ('ACTIVE', 'SUSPENDED', 'DELETED')
    )
);

COMMENT ON TABLE account IS
    '인증 계정. status/email_verified 변경은 AccountSuspended·AccountEmailVerified 로 전파(AUTH-04)';
COMMENT ON COLUMN account.email IS
    '애플리케이션에서 소문자 정규화 후 저장. 유일성은 LOWER(email) 인덱스가 보장';
COMMENT ON COLUMN account.status IS
    'ACTIVE | SUSPENDED | DELETED. SUSPENDED 시 user/point 로컬 상태도 이벤트로 맞춤';
COMMENT ON COLUMN account.email_verified IS
    'true 여야 로그인 가능(AUTH-04). OAuth 가입은 생성 시 true + AccountEmailVerified 발행';

-- 대소문자 무시 유일성. 이메일 조회 인덱스를 겸한다
-- (별도 idx_account_email 불필요 — 유일 인덱스가 조회에도 사용됨)
CREATE UNIQUE INDEX uq_account_email_lower ON account (LOWER(email));

CREATE INDEX idx_account_status ON account(status);

-- ==============================================================
-- refresh_token
--
-- [AUTH-03] Refresh Token Rotation 지원 구조.
--   - family_id: 최초 로그인 1회 = 1 family. 회전(rotation)으로 재발급된
--     토큰들은 같은 family_id 를 공유한다.
--   - replaced_by: 이 토큰을 대체한 다음 토큰의 id (rotation 체인).
--     "이미 대체된(replaced_by IS NOT NULL) 토큰이 다시 사용됨"
--     = 탈취 재사용 신호 → family 전체를 즉시 폐기(revoke)한다.
--   - revoked → revoked_at (TIMESTAMPTZ): 폐기 여부에 더해 '언제' 폐기됐는지가
--     보안 사고 조사에 필요하므로 boolean 대신 시각으로 기록. NULL = 유효.
--   - token_hash UNIQUE: 동일 토큰 중복 저장을 차단하고 조회 인덱스를 겸함.
-- ==============================================================
CREATE TABLE refresh_token (
    id              BIGSERIAL PRIMARY KEY,
    account_id      UUID NOT NULL REFERENCES account(id),
    token_hash      VARCHAR(255) NOT NULL,
    family_id       UUID NOT NULL DEFAULT gen_random_uuid(),
    replaced_by     BIGINT REFERENCES refresh_token(id),
    device_info     VARCHAR(255),
    ip_address      VARCHAR(45),
    expires_at      TIMESTAMPTZ NOT NULL,
    revoked_at      TIMESTAMPTZ,
    revoked_reason  VARCHAR(50),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_refresh_token_hash UNIQUE (token_hash),
    -- 폐기 사유는 폐기 시각과 함께만 존재
    CONSTRAINT chk_refresh_token_revoked_reason CHECK (
        revoked_reason IS NULL OR revoked_at IS NOT NULL
    )
);

COMMENT ON TABLE refresh_token IS
    'refresh token 저장(해시). rotation 체인(family_id/replaced_by)으로 탈취 재사용 탐지';
COMMENT ON COLUMN refresh_token.family_id IS
    '로그인 세션 계열. 재사용 탐지 시 같은 family 전체를 폐기';
COMMENT ON COLUMN refresh_token.replaced_by IS
    '이 토큰을 대체한 토큰 id. 값이 있는데 다시 사용되면 탈취로 간주';
COMMENT ON COLUMN refresh_token.revoked_at IS 'NULL 이면 유효. 폐기 시각 기록';
COMMENT ON COLUMN refresh_token.revoked_reason IS
    '폐기 사유: ROTATED, REUSE_DETECTED, LOGOUT, ADMIN 등';

-- 계정별 유효 토큰 조회 (전체 로그아웃, 세션 목록)
CREATE INDEX idx_refresh_token_account
  ON refresh_token(account_id)
  WHERE revoked_at IS NULL;

-- 재사용 탐지 시 family 일괄 폐기용
CREATE INDEX idx_refresh_token_family
  ON refresh_token(family_id);

-- ==============================================================
-- oauth_identity: 외부 OAuth 연결 (카카오 등)
--
-- [AUTH-01] 외부 access_token / refresh_token 컬럼을 저장하지 않는다.
--   - 이 서비스는 소셜 "로그인"에만 외부 OAuth 를 사용한다.
--     토큰은 로그인 시점에 프로필 조회용으로 한 번 쓰고 버리면 되고,
--     이후 사용자를 대신해 외부 API 를 호출할 일이 없다.
--   - 평문 저장 시 DB 유출 = 외부 계정 API 사칭 가능이라는 Critical 리스크.
--     "암호화해서 저장"보다 "아예 저장하지 않음"(저장 최소화)이 더 안전하고
--     키 관리(KMS/Vault) 부담도 없다.
--   - 향후 외부 API 연동(예: 카카오 메시지 발송)이 필요해지면
--     그때 KMS 봉투 암호화를 전제로 별도 테이블/컬럼을 추가한다.
-- ==============================================================
CREATE TABLE oauth_identity (
    id                BIGSERIAL PRIMARY KEY,
    account_id        UUID NOT NULL REFERENCES account(id),
    provider          VARCHAR(20) NOT NULL,
    provider_user_id  VARCHAR(100) NOT NULL,
    linked_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- 외부 계정 1개는 내부 계정 1개에만 연결
    CONSTRAINT uq_oauth_identity_provider_user UNIQUE (provider, provider_user_id),
    CONSTRAINT chk_oauth_identity_provider CHECK (
        provider IN ('KAKAO', 'GOOGLE', 'GITHUB')
    )
);

COMMENT ON TABLE oauth_identity IS
    '외부 OAuth 계정 연결. 외부 토큰은 저장하지 않음(로그인 시 1회 사용 후 폐기)';

CREATE INDEX idx_oauth_identity_account ON oauth_identity(account_id);

-- ==============================================================
-- auth_attempt: 인증 시도 이력
-- ==============================================================
CREATE TABLE auth_attempt (
    id              BIGSERIAL PRIMARY KEY,
    account_id      UUID,
    email           VARCHAR(100),
    success         BOOLEAN NOT NULL,
    failure_reason  VARCHAR(50),
    ip_address      VARCHAR(45),
    user_agent      VARCHAR(500),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_auth_attempt_email_time ON auth_attempt(email, created_at DESC);

-- ==============================================================
-- outbox_events: Outbox 패턴
-- [COMMON-02] id = DomainEvent.eventId (DEFAULT gen_random_uuid() 금지).
-- ==============================================================
CREATE TABLE outbox_events (
    id              UUID PRIMARY KEY,
    aggregate_type  VARCHAR(50) NOT NULL,
    aggregate_id    VARCHAR(100) NOT NULL,
    event_type      VARCHAR(100) NOT NULL,
    event_version   INT NOT NULL DEFAULT 1,
    payload         JSONB NOT NULL,
    trace_id        VARCHAR(100),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    published_at    TIMESTAMPTZ,

    CONSTRAINT chk_outbox_events_payload_event_id CHECK (
        payload ? 'eventId'
        AND payload->>'eventId' = id::text
    )
);

COMMENT ON TABLE outbox_events IS
    'Transactional outbox. id 는 DomainEvent.eventId 와 동일 (COMMON-02)';
COMMENT ON COLUMN outbox_events.id IS
    'Kafka message key · processed_events.event_id 와 동일 UUID';
COMMENT ON COLUMN outbox_events.payload IS
    'DomainEvent JSON envelope. 최상위 eventId 가 id 와 일치 (CHECK)';

CREATE INDEX idx_outbox_unpublished 
  ON outbox_events(created_at) 
  WHERE published_at IS NULL;

-- [LOW-O6] published 행 보관·purge 스윕용 (대량 outbox 운영 시).
CREATE INDEX idx_outbox_published_purge
  ON outbox_events (published_at)
  WHERE published_at IS NOT NULL;

-- ==============================================================
-- oauth_client: OAuth 2.0 Provider 클라이언트 등록 (Tier 2)
-- ==============================================================
CREATE TABLE oauth_client (
    id                  BIGSERIAL PRIMARY KEY,
    client_id           UUID UNIQUE NOT NULL DEFAULT gen_random_uuid(),
    client_secret_hash  VARCHAR(255) NOT NULL,
    name                VARCHAR(100) NOT NULL,
    description         TEXT,
    redirect_uris       JSONB NOT NULL,
    allowed_scopes      JSONB NOT NULL,
    status              VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_oauth_client_status ON oauth_client(status);

-- ==============================================================
-- oauth_authorization: 발급된 권한
--
-- [AUTH-03] Authorization Code Flow 보안 보강.
--   - PKCE(code_challenge/method): public 클라이언트(SPA/모바일)의
--     code 가로채기 공격 방어. 토큰 교환 시 code_verifier 를 검증한다.
--   - redirect_uri: 인가 요청에 사용된 URI 를 저장해 두고
--     토큰 교환 시 동일한 값인지 검증한다 (RFC 6749 §4.1.3).
--   - code_used_at: authorization code 는 1회용(RFC 6749 §4.1.2).
--     NULL 이 아닌데 다시 교환을 시도하면 code 재사용 공격으로 간주하고
--     해당 authorization 에서 발급된 토큰을 모두 폐기해야 한다.
--   - 각 hash 에 부분 UNIQUE: 같은 code/token 이 두 행에 존재할 수 없게 하고
--     해시 기반 조회 인덱스를 겸한다.
-- ==============================================================
CREATE TABLE oauth_authorization (
    id                       BIGSERIAL PRIMARY KEY,
    client_id                UUID NOT NULL REFERENCES oauth_client(client_id),
    account_id               UUID NOT NULL REFERENCES account(id),
    scopes                   JSONB NOT NULL,
    redirect_uri             VARCHAR(500) NOT NULL,
    authorization_code_hash  VARCHAR(255),
    code_challenge           VARCHAR(255),
    code_challenge_method    VARCHAR(10),
    code_expires_at          TIMESTAMPTZ,
    code_used_at             TIMESTAMPTZ,
    access_token_hash        VARCHAR(255),
    refresh_token_hash       VARCHAR(255),
    expires_at               TIMESTAMPTZ,
    revoked_at               TIMESTAMPTZ,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- S256 만 권장이지만 스펙상 plain 도 존재. 그 외 값은 차단
    CONSTRAINT chk_oauth_auth_challenge_method CHECK (
        code_challenge_method IS NULL OR code_challenge_method IN ('S256', 'plain')
    ),
    -- challenge 와 method 는 항상 쌍으로 존재
    CONSTRAINT chk_oauth_auth_pkce_pair CHECK (
        (code_challenge IS NULL) = (code_challenge_method IS NULL)
    )
);

COMMENT ON TABLE oauth_authorization IS
    'OAuth 2.0 인가/토큰 발급 기록. PKCE 와 code 1회용 검증 지원';
COMMENT ON COLUMN oauth_authorization.redirect_uri IS
    '인가 요청에 사용된 redirect_uri. 토큰 교환 시 동일 값 검증';
COMMENT ON COLUMN oauth_authorization.code_challenge IS
    'PKCE code_challenge. public 클라이언트 code 가로채기 방어';
COMMENT ON COLUMN oauth_authorization.code_expires_at IS
    'authorization code 자체의 만료 (짧게, 예: 10분)';
COMMENT ON COLUMN oauth_authorization.code_used_at IS
    'code 교환 시각. 값이 있는데 재교환 시도 = 재사용 공격 → 토큰 전체 폐기';
COMMENT ON COLUMN oauth_authorization.revoked_at IS 'NULL 이면 유효. 폐기 시각';

-- code/token 해시 유일성 + 조회 인덱스 (NULL 은 아직 발급 전이므로 제외)
CREATE UNIQUE INDEX uq_oauth_auth_code_hash
    ON oauth_authorization(authorization_code_hash)
    WHERE authorization_code_hash IS NOT NULL;
CREATE UNIQUE INDEX uq_oauth_auth_access_hash
    ON oauth_authorization(access_token_hash)
    WHERE access_token_hash IS NOT NULL;
CREATE UNIQUE INDEX uq_oauth_auth_refresh_hash
    ON oauth_authorization(refresh_token_hash)
    WHERE refresh_token_hash IS NOT NULL;

CREATE INDEX idx_oauth_auth_account ON oauth_authorization(account_id);
CREATE INDEX idx_oauth_auth_client ON oauth_authorization(client_id);
