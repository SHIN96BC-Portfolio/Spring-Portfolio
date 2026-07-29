-- ==============================================================
-- point-service 최종 초기 스키마
--
-- ERD: point_account, point_transaction, point_reservation, point_earning_rule
--
-- 참고:
--   - ERD point_outbox_events 는 공통 outbox_events 로 대체
--   - point-service 는 Saga Participant 이므로 saga_instances 를 만들지 않음
--   - saga_id 컬럼은 commerce-service saga_instances.saga_id 논리 참조 (FK 없음)
--   - point BIGINT 컬럼은 최소 포인트/화폐 단위
--
-- 멱등성 설계 (DB 아키텍처 감사 POINT-01/02 반영):
--   1) 원장 멱등: point_transaction 에 (type, source_type, source_id)
--      부분 UNIQUE 인덱스. 이벤트 재소비/재시도 시 중복 적립·차감 차단.
--   2) 예약 멱등: point_reservation.saga_id UNIQUE (사가당 예약 1건).
--   3) 만료 lot: EARNED 거래 행이 적립 lot 을 겸함.
--      remaining_amount 로 잔여량을 추적하고 FIFO 소진/만료 처리.
--      별도 point_lot 테이블 대신 원장 재사용 — 포트폴리오 규모에서
--      테이블 수를 늘리지 않으면서 만료 정산이 가능한 최소 모델.
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
-- 1. point_account — 사용자 포인트 계정
--
-- [AUTH-04] status:
--   AccountRegistered 로 계정 생성 시 ACTIVE.
--   AccountSuspended 소비 시 SUSPENDED → 적립/사용/예약 API 거부.
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
    created_at      TIMESTAMPTZ       NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ       NOT NULL DEFAULT NOW(),

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
    '사용자별 포인트 계정 (잔액/누적/티어). status 는 auth 정지 이벤트 미러(AUTH-04)';
COMMENT ON COLUMN point_account.user_id IS
    'auth.account.id 논리 참조. DB-per-service 경계로 FK 없음';
COMMENT ON COLUMN point_account.balance IS
    '현재 사용 가능 잔액. 최소 포인트 단위 BIGINT';
COMMENT ON COLUMN point_account.total_earned IS
    '누적 적립액. 최소 포인트 단위 BIGINT';
COMMENT ON COLUMN point_account.total_spent IS
    '누적 사용액. 최소 포인트 단위 BIGINT';
COMMENT ON COLUMN point_account.version IS '낙관적 락 버전';
COMMENT ON COLUMN point_account.tier IS '회원 티어: BRONZE, SILVER, GOLD, PLATINUM';
COMMENT ON COLUMN point_account.status IS
    'ACTIVE | SUSPENDED | CLOSED. SUSPENDED 시 적립·사용·예약 거부, 잔액 보존';

CREATE INDEX idx_point_account_tier
    ON point_account (tier);

CREATE INDEX idx_point_account_status
    ON point_account (status)
    WHERE status <> 'ACTIVE';


-- --------------------------------------------------------------
-- 2. point_transaction — 포인트 변경 원장 (Event Sourcing 스타일)
--
-- 멱등성:
--   같은 출처(source_type + source_id)에 대해 같은 type 의 거래는 1건만 허용.
--   Kafka 재소비·HTTP 재시도가 겹쳐도 DB 가 중복 적립/차감을 차단한다.
--   (processed_events 는 컨슈머 단 멱등이고, 이 UNIQUE 는 원장 단 멱등 — 둘은 별개 방어선)
--
-- 만료 lot 모델:
--   EARNED 행 하나가 "적립 lot" 역할을 한다.
--   remaining_amount 는 해당 lot 에서 아직 소진되지 않은 잔여량이며,
--   SPENT/EXPIRED 처리 시 FIFO(만료 임박 순)로 lot 의 remaining_amount 를 차감한다.
--   remaining_amount 는 이 테이블에서 유일하게 UPDATE 되는 컬럼이다
--   (나머지는 append-only 유지).
-- --------------------------------------------------------------
CREATE TABLE point_transaction (
    id                  BIGSERIAL       PRIMARY KEY,
    account_id          BIGINT          NOT NULL,
    type                VARCHAR(20)     NOT NULL,   -- EARNED, SPENT, RESERVED, RELEASED, EXPIRED, ADJUSTED
    amount              BIGINT          NOT NULL,   -- 항상 양수, 방향은 type 으로 구분
    remaining_amount    BIGINT,                     -- EARNED lot 잔여량 (EARNED 만 사용, 그 외 NULL)
    balance_after       BIGINT          NOT NULL,
    source_type         VARCHAR(30)     NOT NULL,   -- ORDER, SIGNUP_BONUS, OOTD_LIKE, INFLUENCER_BONUS
    source_id           VARCHAR(100),
    saga_id             UUID,                       -- commerce saga 논리 참조
    description         VARCHAR(200),
    expires_at          TIMESTAMPTZ,                  -- 적립 포인트 만료 시각 (EARNED lot 만)
    created_at          TIMESTAMPTZ       NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_point_transaction_account
        FOREIGN KEY (account_id) REFERENCES point_account (id),
    CONSTRAINT chk_point_transaction_amount CHECK (amount > 0),
    CONSTRAINT chk_point_transaction_balance_after CHECK (balance_after >= 0),
    CONSTRAINT chk_point_transaction_type CHECK (
        type IN ('EARNED', 'SPENT', 'RESERVED', 'RELEASED', 'EXPIRED', 'ADJUSTED')
    ),
    -- lot 모델 불변식: EARNED 는 0 <= remaining <= amount, 그 외 type 은 remaining 없음
    CONSTRAINT chk_point_transaction_remaining CHECK (
        (type = 'EARNED' AND remaining_amount IS NOT NULL
             AND remaining_amount >= 0 AND remaining_amount <= amount)
        OR (type <> 'EARNED' AND remaining_amount IS NULL)
    ),
    -- 만료는 EARNED lot 에만 의미가 있음
    CONSTRAINT chk_point_transaction_expires_scope CHECK (
        expires_at IS NULL OR type = 'EARNED'
    )
);

COMMENT ON TABLE point_transaction IS
    '포인트 변경 원장. 모든 잔액 변동을 기록. EARNED 행은 적립 lot 을 겸하며 remaining_amount 만 UPDATE 허용';
COMMENT ON COLUMN point_transaction.account_id IS '대상 포인트 계정 (point_account.id)';
COMMENT ON COLUMN point_transaction.type IS
    '변동 유형: EARNED, SPENT, RESERVED, RELEASED, EXPIRED, ADJUSTED';
COMMENT ON COLUMN point_transaction.amount IS
    '변동량(항상 양수). 최소 포인트 단위 BIGINT. 방향은 type 으로 구분';
COMMENT ON COLUMN point_transaction.remaining_amount IS
    'EARNED lot 잔여량. 소진/만료 시 FIFO 로 차감. EARNED 외 type 은 NULL';
COMMENT ON COLUMN point_transaction.balance_after IS
    '이 거래 반영 후 잔액. 최소 포인트 단위 BIGINT';
COMMENT ON COLUMN point_transaction.source_type IS
    '발생 출처 유형: ORDER, SIGNUP_BONUS, OOTD_LIKE, INFLUENCER_BONUS 등';
COMMENT ON COLUMN point_transaction.source_id IS
    '출처 리소스 ID 논리 참조 (source_type 별). FK 없음';
COMMENT ON COLUMN point_transaction.saga_id IS
    'commerce-service saga_instances.saga_id 논리 참조. Participant 이므로 FK 없음';
COMMENT ON COLUMN point_transaction.expires_at IS '적립 포인트 만료 시각 (EARNED lot 만)';

CREATE INDEX idx_point_transaction_account_created
    ON point_transaction (account_id, created_at DESC);

-- 원장 단 멱등 키.
-- 같은 출처 이벤트가 재처리되어도 (type, source_type, source_id) 조합으로
-- INSERT 가 UNIQUE 위반이 되어 중복 적립/차감이 물리적으로 불가능하다.
-- source_id 가 없는 수동 조정(ADJUSTED 등)은 멱등 대상이 아니므로 부분 인덱스로 제외.
-- 예: 주문 적립(EARNED/ORDER/#123)과 주문 취소 차감(SPENT/ORDER/#123)은 공존 가능.
CREATE UNIQUE INDEX uq_point_transaction_idempotency
    ON point_transaction (type, source_type, source_id)
    WHERE source_id IS NOT NULL;

CREATE INDEX idx_point_transaction_saga
    ON point_transaction (saga_id)
    WHERE saga_id IS NOT NULL;

-- 만료 스윕: 잔여량이 남아 있는 EARNED lot 만 대상으로 만료 임박 순 조회.
-- (소진 완료 lot 은 remaining_amount = 0 이라 인덱스에서 제외됨)
CREATE INDEX idx_point_transaction_expiring_lots
    ON point_transaction (expires_at)
    WHERE type = 'EARNED' AND expires_at IS NOT NULL AND remaining_amount > 0;


-- --------------------------------------------------------------
-- 3. point_reservation — 사가 임시 포인트 예약
-- --------------------------------------------------------------
CREATE TABLE point_reservation (
    id              BIGSERIAL       PRIMARY KEY,
    account_id      BIGINT          NOT NULL,
    amount          BIGINT          NOT NULL,
    saga_id         UUID            NOT NULL,           -- commerce saga 논리 참조
    status          VARCHAR(20)     NOT NULL,           -- RESERVED, CONFIRMED, RELEASED, EXPIRED
    expires_at      TIMESTAMPTZ       NOT NULL,
    created_at      TIMESTAMPTZ       NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ       NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_point_reservation_saga UNIQUE (saga_id),
    CONSTRAINT fk_point_reservation_account
        FOREIGN KEY (account_id) REFERENCES point_account (id),
    CONSTRAINT chk_point_reservation_amount CHECK (amount > 0),
    CONSTRAINT chk_point_reservation_status CHECK (
        status IN ('RESERVED', 'CONFIRMED', 'RELEASED', 'EXPIRED')
    )
);

COMMENT ON TABLE point_reservation IS
    '주문 사가 진행 중 임시 포인트 예약 (Participant 보상 가능)';
COMMENT ON COLUMN point_reservation.account_id IS '예약 대상 계정 (point_account.id)';
COMMENT ON COLUMN point_reservation.amount IS
    '예약 금액. 최소 포인트 단위 BIGINT';
COMMENT ON COLUMN point_reservation.saga_id IS
    'commerce-service saga_instances.saga_id 논리 참조. Participant 이므로 FK 없음. 사가당 1건';
COMMENT ON COLUMN point_reservation.status IS
    '예약 상태: RESERVED, CONFIRMED, RELEASED, EXPIRED';
COMMENT ON COLUMN point_reservation.expires_at IS '예약 만료 시각';

-- 만료 스윕 대상
CREATE INDEX idx_point_reservation_expires_reserved
    ON point_reservation (expires_at)
    WHERE status = 'RESERVED';

CREATE INDEX idx_point_reservation_account_status
    ON point_reservation (account_id, status);


-- --------------------------------------------------------------
-- 4. point_earning_rule — 적립 규칙
-- --------------------------------------------------------------
CREATE TABLE point_earning_rule (
    id              BIGSERIAL       PRIMARY KEY,
    rule_code       VARCHAR(50)     NOT NULL,           -- ORDER_1_PERCENT, SIGNUP_BONUS
    description     VARCHAR(200),
    earn_rate       DECIMAL(5, 4),                      -- 0.01 = 1%
    fixed_amount    BIGINT,
    max_per_day     BIGINT,
    active          BOOLEAN         NOT NULL DEFAULT TRUE,
    starts_at       TIMESTAMPTZ,
    ends_at         TIMESTAMPTZ,

    CONSTRAINT uq_point_earning_rule_code UNIQUE (rule_code),
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

COMMENT ON TABLE point_earning_rule IS '포인트 적립 규칙 (비율/고정액/일일 한도)';
COMMENT ON COLUMN point_earning_rule.rule_code IS
    '규칙 코드. 예: ORDER_1_PERCENT, SIGNUP_BONUS';
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
