-- ==============================================================
-- point-service 최종 초기 스키마
--
-- ERD: point_type, point_account, point_transaction, point_reservation,
--      point_cashout_request, point_earning_rule
--
-- 참고:
--   - ERD point_outbox_events 는 공통 outbox_events 로 대체
--   - point-service 는 Saga Participant 이므로 saga_instances 를 만들지 않음
--   - saga_id 컬럼은 commerce-service saga_instances.saga_id 논리 참조 (FK 없음)
--   - point BIGINT 컬럼은 최소 포인트/화폐 단위
--   - 공용 지갑(계정 1개) + 유형별 lot (POINT-03)
--
-- 멱등성 설계 (DB 아키텍처 감사 POINT-01/02 반영):
--   1) 원장 멱등: point_transaction 에 (type, source_type, source_id)
--      부분 UNIQUE 인덱스. 이벤트 재소비/재시도 시 중복 적립·차감 차단.
--   2) 예약 멱등: point_reservation.saga_id UNIQUE (사가당 예약 1건).
--   3) 만료 lot: EARNED 거래 행이 적립 lot 을 겸함.
--      remaining_amount 로 잔여량을 추적하고 소진/만료 처리.
--   4) 출금 홀드 멱등: point_cashout_request.idempotency_key UNIQUE.
--
-- [POINT-03] 포인트 유형:
--   point_type 마스터(유상/이벤트/리뷰/가입 등) + EARNED lot 에 point_type_code.
--   is_cashable / is_refundable / spend_priority 는 유형 정책.
--
-- [POINT-04] 사용·예약·출금 시 lot 선택 (애플리케이션):
--   ORDER BY expires_at ASC NULLS LAST, spend_priority ASC, lot.id ASC
--   → 만료 임박 우선, 동률이면 무상(낮은 priority) → 유상.
--   DB 는 정책값만 보관하고, 정렬·차감은 사용 시점에 수행.
--
-- [POINT-05] 출금(캐시아웃):
--   is_cashable = TRUE lot 만 대상. point_cashout_request 로 HOLDING 구간 잠금.
--   가용 = balance - Σ(RESERVED 예약) - Σ(HOLDING 출금).
-- ==============================================================

-- [COMMON-03] 시각 컬럼은 TIMESTAMPTZ(UTC). 앱·JDBC·PostgreSQL 세션 timezone=UTC 권장.

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Outbox 패턴 (필수)
-- [COMMON-02] outbox_events.id = DomainEvent.eventId. DEFAULT gen_random_uuid() 금지.
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

-- Idempotency (Consumer 멱등성 - Kafka 구독하는 서비스만)
-- [COMMON-01] event_id 단독 PK 는 동일 DB 의 서로 다른 consumer group 이
--   같은 이벤트를 처리하지 못하게 한다. (event_id, consumer_group) 복합 PK.
CREATE TABLE processed_events (
    event_id        UUID NOT NULL,
    consumer_group  VARCHAR(100) NOT NULL,
    processed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_processed_events PRIMARY KEY (event_id, consumer_group)
);

COMMENT ON TABLE processed_events IS
    'Kafka 소비 멱등 원장. PK (event_id, consumer_group) — 그룹별 1회 처리 (COMMON-01)';
COMMENT ON COLUMN processed_events.event_id IS
    'DomainEvent.eventId (Kafka 메시지와 동일 값 권장)';
COMMENT ON COLUMN processed_events.consumer_group IS
    'Kafka consumer group id (예: spring.kafka.consumer.group-id)';


-- --------------------------------------------------------------
-- 0. point_type — 포인트 유형 마스터 (POINT-03)
-- --------------------------------------------------------------
CREATE TABLE point_type (
    code                    VARCHAR(30)     PRIMARY KEY,
    name                    VARCHAR(100)    NOT NULL,
    description             VARCHAR(200),
    -- 출금(캐시아웃) 가능 여부
    is_cashable             BOOLEAN         NOT NULL DEFAULT FALSE,
    -- 주문 취소·환불 시 해당 유형 적립분 환급(복구) 가능 여부
    is_refundable           BOOLEAN         NOT NULL DEFAULT FALSE,
    -- 사용 시 동률(만료일 동일·무기한) 내 우선순위. 작을수록 먼저 사용 (무상 < 유상)
    spend_priority          INT             NOT NULL DEFAULT 100,
    -- 적립 시 기본 만료일수. NULL 이면 기본 무기한 (개별 lot expires_at 로 override)
    default_expire_days     INT,
    active                  BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_point_type_spend_priority CHECK (spend_priority >= 0),
    CONSTRAINT chk_point_type_default_expire_days CHECK (
        default_expire_days IS NULL OR default_expire_days > 0
    )
);

COMMENT ON TABLE point_type IS
    '포인트 유형 마스터. 유상/이벤트/리뷰/가입 등 정책 (POINT-03)';
COMMENT ON COLUMN point_type.code IS
    '유형 코드. 예: PAID, EVENT, REVIEW, SIGNUP, INFLUENCER';
COMMENT ON COLUMN point_type.is_cashable IS
    'TRUE 이면 캐시아웃 대상 lot. 출금 홀드는 이 유형만 선택 (POINT-05)';
COMMENT ON COLUMN point_type.is_refundable IS
    'TRUE 이면 주문 취소 시 해당 적립 lot 환급(복구) 가능';
COMMENT ON COLUMN point_type.spend_priority IS
    '사용 시 정렬 2차 키. 1차는 expires_at. 작을수록 우선 (POINT-04)';
COMMENT ON COLUMN point_type.default_expire_days IS
    '적립 시 기본 만료 일수. NULL=무기한 기본. lot.expires_at 이 최종';

CREATE INDEX idx_point_type_active_priority
    ON point_type (active, spend_priority);

-- 시드: 실서비스에서 흔한 유형 (정책은 운영 중 조정 가능)
INSERT INTO point_type (code, name, description, is_cashable, is_refundable, spend_priority, default_expire_days) VALUES
    ('SIGNUP',      '가입 보너스',     '회원가입 지급. 무상·비출금',           FALSE, FALSE, 10, 365),
    ('EVENT',       '이벤트',          '프로모션·이벤트 무상 포인트',         FALSE, FALSE, 20, 90),
    ('REVIEW',      '리뷰/활동',       '리뷰·OOTD 등 활동 보상',             FALSE, FALSE, 20, 180),
    ('INFLUENCER',  '인플루언서',      '인플루언서·크리에이터 보상',         FALSE, FALSE, 25, 365),
    ('PAID',        '유상/구매적립',   '결제 적립. 출금·주문취소 환급 가능', TRUE,  TRUE,  100, 1825);


-- --------------------------------------------------------------
-- 1. point_account — 사용자 포인트 계정 (공용 지갑 1개)
--
-- [AUTH-04] status:
--   AccountRegistered 로 계정 생성 시 ACTIVE.
--   AccountSuspended 소비 시 SUSPENDED → 적립/사용/예약/출금 API 거부.
--   잔액은 보존하고 활동만 막는다 (정지 해제 시 재개 가능하도록).
-- --------------------------------------------------------------
CREATE TABLE point_account (
    id              BIGSERIAL       PRIMARY KEY,
    user_id         UUID            NOT NULL,           -- auth.account.id 논리 참조
    balance         BIGINT          NOT NULL DEFAULT 0,
    total_earned    BIGINT          NOT NULL DEFAULT 0,
    total_spent     BIGINT          NOT NULL DEFAULT 0,
    version         INT             NOT NULL DEFAULT 0, -- Optimistic lock
    tier            VARCHAR(20)     NOT NULL DEFAULT 'BRONZE',
    status          VARCHAR(20)     NOT NULL DEFAULT 'ACTIVE',
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_point_account_user UNIQUE (user_id),
    CONSTRAINT chk_point_account_balance CHECK (balance >= 0),
    CONSTRAINT chk_point_account_total_earned CHECK (total_earned >= 0),
    CONSTRAINT chk_point_account_total_spent CHECK (total_spent >= 0),
    CONSTRAINT chk_point_account_tier CHECK (
        tier IN ('BRONZE', 'SILVER', 'GOLD', 'PLATINUM')
    ),
    CONSTRAINT chk_point_account_status CHECK (
        status IN ('ACTIVE', 'SUSPENDED', 'CLOSED')
    )
);

COMMENT ON TABLE point_account IS
    '사용자별 공용 포인트 계정 (총잔액/누적/티어). 유형별 잔여는 EARNED lot 합산';
COMMENT ON COLUMN point_account.user_id IS
    'auth.account.id 논리 참조. DB-per-service 경계로 FK 없음';
COMMENT ON COLUMN point_account.balance IS
    '총 잔액(유형 합). 가용=balance-활성예약-HOLDING출금 (앱 계산, POINT-05)';
COMMENT ON COLUMN point_account.total_earned IS
    '누적 적립액. 최소 포인트 단위 BIGINT';
COMMENT ON COLUMN point_account.total_spent IS
    '누적 사용액. 최소 포인트 단위 BIGINT';
COMMENT ON COLUMN point_account.version IS '낙관적 락 버전';
COMMENT ON COLUMN point_account.tier IS '회원 티어: BRONZE, SILVER, GOLD, PLATINUM';
COMMENT ON COLUMN point_account.status IS
    'ACTIVE | SUSPENDED | CLOSED. SUSPENDED 시 적립·사용·예약·출금 거부, 잔액 보존';

CREATE INDEX idx_point_account_tier
    ON point_account (tier);

CREATE INDEX idx_point_account_status
    ON point_account (status)
    WHERE status <> 'ACTIVE';


-- --------------------------------------------------------------
-- 2. point_transaction — 포인트 변경 원장 (Event Sourcing 스타일)
--
-- EARNED 행 = 적립 lot. point_type_code 필수.
-- 사용/예약/출금 lot 선택: POINT-04 (만료 임박 → spend_priority).
-- --------------------------------------------------------------
CREATE TABLE point_transaction (
    id                  BIGSERIAL       PRIMARY KEY,
    account_id          BIGINT          NOT NULL,
    type                VARCHAR(20)     NOT NULL,   -- EARNED, SPENT, RESERVED, RELEASED, EXPIRED, ADJUSTED
    -- EARNED 필수. SPENT/EXPIRED 등도 감사·유형별 집계용으로 권장
    point_type_code     VARCHAR(30),
    amount              BIGINT          NOT NULL,   -- 항상 양수, 방향은 type 으로 구분
    remaining_amount    BIGINT,                     -- EARNED lot 잔여량 (EARNED 만 사용, 그 외 NULL)
    balance_after       BIGINT          NOT NULL,
    source_type         VARCHAR(30)     NOT NULL,   -- ORDER, SIGNUP_BONUS, OOTD_LIKE, INFLUENCER_BONUS, CASHOUT
    source_id           VARCHAR(100),
    saga_id             UUID,                       -- commerce saga 논리 참조
    description         VARCHAR(200),
    expires_at          TIMESTAMPTZ,                -- 적립 포인트 만료 시각 (EARNED lot 만)
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_point_transaction_account
        FOREIGN KEY (account_id) REFERENCES point_account (id),
    CONSTRAINT fk_point_transaction_point_type
        FOREIGN KEY (point_type_code) REFERENCES point_type (code),
    CONSTRAINT chk_point_transaction_amount CHECK (amount > 0),
    CONSTRAINT chk_point_transaction_balance_after CHECK (balance_after >= 0),
    CONSTRAINT chk_point_transaction_type CHECK (
        type IN ('EARNED', 'SPENT', 'RESERVED', 'RELEASED', 'EXPIRED', 'ADJUSTED')
    ),
    -- lot: EARNED 는 유형 필수 + remaining 범위
    CONSTRAINT chk_point_transaction_earned_type CHECK (
        (type = 'EARNED' AND point_type_code IS NOT NULL)
        OR (type <> 'EARNED')
    ),
    CONSTRAINT chk_point_transaction_remaining CHECK (
        (type = 'EARNED' AND remaining_amount IS NOT NULL
             AND remaining_amount >= 0 AND remaining_amount <= amount)
        OR (type <> 'EARNED' AND remaining_amount IS NULL)
    ),
    CONSTRAINT chk_point_transaction_expires_scope CHECK (
        expires_at IS NULL OR type = 'EARNED'
    )
);

COMMENT ON TABLE point_transaction IS
    '포인트 변경 원장. EARNED 행은 유형별 적립 lot (POINT-03). remaining_amount 만 UPDATE 허용';
COMMENT ON COLUMN point_transaction.account_id IS '대상 포인트 계정 (point_account.id)';
COMMENT ON COLUMN point_transaction.type IS
    '변동 유형: EARNED, SPENT, RESERVED, RELEASED, EXPIRED, ADJUSTED';
COMMENT ON COLUMN point_transaction.point_type_code IS
    '포인트 유형. EARNED 필수. FK → point_type.code';
COMMENT ON COLUMN point_transaction.amount IS
    '변동량(항상 양수). 최소 포인트 단위 BIGINT. 방향은 type 으로 구분';
COMMENT ON COLUMN point_transaction.remaining_amount IS
    'EARNED lot 잔여량. 소진/만료/출금홀드 시 차감. EARNED 외 type 은 NULL';
COMMENT ON COLUMN point_transaction.balance_after IS
    '이 거래 반영 후 총잔액. 최소 포인트 단위 BIGINT';
COMMENT ON COLUMN point_transaction.source_type IS
    '발생 출처: ORDER, SIGNUP_BONUS, OOTD_LIKE, INFLUENCER_BONUS, CASHOUT 등';
COMMENT ON COLUMN point_transaction.source_id IS
    '출처 리소스 ID 논리 참조 (source_type 별). FK 없음';
COMMENT ON COLUMN point_transaction.saga_id IS
    'commerce-service saga_instances.saga_id 논리 참조. Participant 이므로 FK 없음';
COMMENT ON COLUMN point_transaction.expires_at IS '적립 포인트 만료 시각 (EARNED lot 만)';

CREATE INDEX idx_point_transaction_account_created
    ON point_transaction (account_id, created_at DESC);

CREATE UNIQUE INDEX uq_point_transaction_idempotency
    ON point_transaction (type, source_type, source_id)
    WHERE source_id IS NOT NULL;

CREATE INDEX idx_point_transaction_saga
    ON point_transaction (saga_id)
    WHERE saga_id IS NOT NULL;

-- 만료 스윕
CREATE INDEX idx_point_transaction_expiring_lots
    ON point_transaction (expires_at)
    WHERE type = 'EARNED' AND expires_at IS NOT NULL AND remaining_amount > 0;

-- 사용/예약 lot 후보: 계정·유형별 잔여 lot
CREATE INDEX idx_point_transaction_spendable_lots
    ON point_transaction (account_id, point_type_code, expires_at, id)
    WHERE type = 'EARNED' AND remaining_amount > 0;


-- --------------------------------------------------------------
-- 3. point_reservation — 사가 임시 포인트 예약
--    lot 선택은 POINT-04 와 동일(사용 시점에 정렬). 금액만 잠금.
-- --------------------------------------------------------------
CREATE TABLE point_reservation (
    id              BIGSERIAL       PRIMARY KEY,
    account_id      BIGINT          NOT NULL,
    amount          BIGINT          NOT NULL,
    saga_id         UUID            NOT NULL,           -- commerce saga 논리 참조
    status          VARCHAR(20)     NOT NULL,           -- RESERVED, CONFIRMED, RELEASED, EXPIRED
    expires_at      TIMESTAMPTZ     NOT NULL,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_point_reservation_saga UNIQUE (saga_id),
    CONSTRAINT fk_point_reservation_account
        FOREIGN KEY (account_id) REFERENCES point_account (id),
    CONSTRAINT chk_point_reservation_amount CHECK (amount > 0),
    CONSTRAINT chk_point_reservation_status CHECK (
        status IN ('RESERVED', 'CONFIRMED', 'RELEASED', 'EXPIRED')
    )
);

COMMENT ON TABLE point_reservation IS
    '주문 사가 진행 중 임시 포인트 예약 (Participant 보상 가능). lot 선택은 POINT-04';
COMMENT ON COLUMN point_reservation.account_id IS '예약 대상 계정 (point_account.id)';
COMMENT ON COLUMN point_reservation.amount IS
    '예약 금액. 최소 포인트 단위 BIGINT';
COMMENT ON COLUMN point_reservation.saga_id IS
    'commerce-service saga_instances.saga_id 논리 참조. Participant 이므로 FK 없음. 사가당 1건';
COMMENT ON COLUMN point_reservation.status IS
    '예약 상태: RESERVED, CONFIRMED, RELEASED, EXPIRED';
COMMENT ON COLUMN point_reservation.expires_at IS '예약 만료 시각';

CREATE INDEX idx_point_reservation_expires_reserved
    ON point_reservation (expires_at)
    WHERE status = 'RESERVED';

CREATE INDEX idx_point_reservation_account_status
    ON point_reservation (account_id, status);


-- --------------------------------------------------------------
-- 4. point_cashout_request — 출금(캐시아웃) 홀드 (POINT-05)
--    is_cashable lot 만 대상. HOLDING 동안 가용 잔액에서 제외.
-- --------------------------------------------------------------
CREATE TABLE point_cashout_request (
    id                  BIGSERIAL       PRIMARY KEY,
    account_id          BIGINT          NOT NULL,
    amount              BIGINT          NOT NULL,
    -- REQUESTED → HOLDING → PAID | CANCELLED | FAILED
    status              VARCHAR(20)     NOT NULL,
    idempotency_key     VARCHAR(200)    NOT NULL,
    hold_expires_at     TIMESTAMPTZ,
    paid_at             TIMESTAMPTZ,
    failure_reason      VARCHAR(500),
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_point_cashout_idempotency UNIQUE (idempotency_key),
    CONSTRAINT fk_point_cashout_account
        FOREIGN KEY (account_id) REFERENCES point_account (id),
    CONSTRAINT chk_point_cashout_amount CHECK (amount > 0),
    CONSTRAINT chk_point_cashout_status CHECK (
        status IN ('REQUESTED', 'HOLDING', 'PAID', 'CANCELLED', 'FAILED')
    ),
    CONSTRAINT chk_point_cashout_paid_at CHECK (
        (status = 'PAID' AND paid_at IS NOT NULL)
        OR (status <> 'PAID' AND paid_at IS NULL)
    )
);

COMMENT ON TABLE point_cashout_request IS
    '캐시아웃 요청·홀드. is_cashable lot 만 사용 (POINT-05)';
COMMENT ON COLUMN point_cashout_request.account_id IS '출금 대상 계정';
COMMENT ON COLUMN point_cashout_request.amount IS '출금 요청 금액. 최소 포인트 단위';
COMMENT ON COLUMN point_cashout_request.status IS
    'REQUESTED, HOLDING, PAID, CANCELLED, FAILED. HOLDING 시 가용에서 차감';
COMMENT ON COLUMN point_cashout_request.idempotency_key IS '출금 요청 멱등 키';
COMMENT ON COLUMN point_cashout_request.hold_expires_at IS '홀드 만료. 초과 시 앱이 CANCELLED 처리';

CREATE INDEX idx_point_cashout_account_status
    ON point_cashout_request (account_id, status);

CREATE INDEX idx_point_cashout_holding_expires
    ON point_cashout_request (hold_expires_at)
    WHERE status = 'HOLDING';


-- --------------------------------------------------------------
-- 5. point_earning_rule — 적립 규칙 (지급 유형 지정)
-- --------------------------------------------------------------
CREATE TABLE point_earning_rule (
    id              BIGSERIAL       PRIMARY KEY,
    rule_code       VARCHAR(50)     NOT NULL,           -- ORDER_1_PERCENT, SIGNUP_BONUS
    description     VARCHAR(200),
    -- 이 규칙으로 적립 시 부여할 포인트 유형
    point_type_code VARCHAR(30)     NOT NULL,
    earn_rate       DECIMAL(5, 4),                      -- 0.01 = 1%
    fixed_amount    BIGINT,
    max_per_day     BIGINT,
    active          BOOLEAN         NOT NULL DEFAULT TRUE,
    starts_at       TIMESTAMPTZ,
    ends_at         TIMESTAMPTZ,

    CONSTRAINT uq_point_earning_rule_code UNIQUE (rule_code),
    CONSTRAINT fk_point_earning_rule_point_type
        FOREIGN KEY (point_type_code) REFERENCES point_type (code),
    CONSTRAINT chk_point_earning_rule_earn_rate CHECK (
        earn_rate IS NULL OR (earn_rate >= 0 AND earn_rate <= 1)
    ),
    CONSTRAINT chk_point_earning_rule_fixed_amount CHECK (
        fixed_amount IS NULL OR fixed_amount >= 0
    ),
    CONSTRAINT chk_point_earning_rule_max_per_day CHECK (
        max_per_day IS NULL OR max_per_day >= 0
    ),
    CONSTRAINT chk_point_earning_rule_period CHECK (
        ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at
    ),
    CONSTRAINT chk_point_earning_rule_has_amount CHECK (
        earn_rate IS NOT NULL OR fixed_amount IS NOT NULL
    )
);

COMMENT ON TABLE point_earning_rule IS
    '포인트 적립 규칙. point_type_code 로 지급 유형 지정 (POINT-03)';
COMMENT ON COLUMN point_earning_rule.rule_code IS
    '규칙 코드. 예: ORDER_1_PERCENT, SIGNUP_BONUS';
COMMENT ON COLUMN point_earning_rule.point_type_code IS
    '적립 lot 에 부여할 유형. FK → point_type.code';
COMMENT ON COLUMN point_earning_rule.earn_rate IS
    '적립 비율. 0.01 = 1%. NULL이면 fixed_amount 사용';
COMMENT ON COLUMN point_earning_rule.fixed_amount IS
    '고정 적립액. 최소 포인트 단위 BIGINT';
COMMENT ON COLUMN point_earning_rule.max_per_day IS
    '일일 최대 적립. 최소 포인트 단위 BIGINT';
COMMENT ON COLUMN point_earning_rule.active IS '규칙 활성 여부';
COMMENT ON COLUMN point_earning_rule.starts_at IS '규칙 적용 시작';
COMMENT ON COLUMN point_earning_rule.ends_at IS '규칙 적용 종료';

CREATE INDEX idx_point_earning_rule_active_period
    ON point_earning_rule (active, starts_at, ends_at);

CREATE INDEX idx_point_earning_rule_point_type
    ON point_earning_rule (point_type_code)
    WHERE active;
