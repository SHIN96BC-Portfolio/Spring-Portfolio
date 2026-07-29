-- ==============================================================
-- notification-service 초기 스키마
--
-- ERD: notification_template, notification, marketing_campaign,
--      notification_preference, campaign_conversion
--
-- 주의:
--   - 서비스 경계를 넘는 ID(user_id 등)에는 FK를 두지 않고 COMMENT로 논리 참조
--   - notification ↔ marketing_campaign 순환 FK는
--     marketing_campaign.notification_id 를 먼저 두고,
--     notification.campaign_id FK는 마지막 ALTER 로 추가
--
-- [NOTIF-01] 발송 멱등성:
--   processed_events 만으로는 "발송 성공 → 커밋 전 장애 → 재소비 → 재발송"
--   을 막을 수 없다. notification.idempotency_key UNIQUE 가 발송 단위의
--   원장 멱등 키이며, 발송 전에 INSERT 하고 이미 있으면/SENT 이면 스킵한다.
--
-- [NOTIF-02] 캠페인·전환:
--   marketing_campaign.idempotency_key 로 동일 트리거 이벤트의 중복 스케줄 방지.
--   campaign_conversion.idempotency_key 로 전환 지표 재처리 중복 방지.
--   status/channel/category 는 CHECK 로 enum 고정.
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

-- ==============================================================
-- 1. 알림 템플릿
-- ==============================================================
CREATE TABLE notification_template (
    id                  BIGSERIAL PRIMARY KEY,
    -- 비즈니스 식별자 (notification / campaign 이 참조하는 코드)
    template_id         VARCHAR(50)  NOT NULL,
    -- EMAIL, WEBHOOK, IN_APP, PUSH
    channel             VARCHAR(20)  NOT NULL,
    -- TRANSACTION, MARKETING, SOCIAL, SYSTEM
    category            VARCHAR(30),
    subject_template    VARCHAR(200),
    body_template       TEXT,
    -- 템플릿 변수 스키마/예시 (예: {"nickname":"string","orderId":"string"})
    variables           JSONB,
    active              BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ    NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_notification_template_template_id UNIQUE (template_id),
    CONSTRAINT chk_notification_template_channel CHECK (
        channel IN ('EMAIL', 'WEBHOOK', 'IN_APP', 'PUSH')
    ),
    CONSTRAINT chk_notification_template_category CHECK (
        category IS NULL
        OR category IN ('TRANSACTION', 'MARKETING', 'SOCIAL', 'SYSTEM')
    )
);

COMMENT ON TABLE notification_template IS '채널·카테고리별 알림 본문/제목 템플릿';
COMMENT ON COLUMN notification_template.template_id IS '템플릿 비즈니스 코드 (unique). notification/marketing_campaign.template_id 가 참조';
COMMENT ON COLUMN notification_template.channel IS '발송 채널: EMAIL, WEBHOOK, IN_APP, PUSH';
COMMENT ON COLUMN notification_template.category IS '알림 카테고리: TRANSACTION, MARKETING, SOCIAL, SYSTEM';
COMMENT ON COLUMN notification_template.variables IS '템플릿 치환 변수 정의(JSON)';

-- ==============================================================
-- 2. 알림 발송 이력
--    campaign_id 컬럼은 먼저 두고, FK는 순환 참조 때문에 마지막 ALTER 로 추가
--
-- [NOTIF-01] 멱등 발송 흐름 (애플리케이션 계약):
--   1) idempotency_key 로 INSERT (status=PENDING).
--      UNIQUE 위반이면 기존 행 조회 → SENT/OPENED/CLICKED 면 재발송 금지,
--      PENDING/FAILED 면 워커가 재시도(동일 행).
--   2) 채널 어댑터로 발송.
--   3) status=SENT, sent_at 갱신 후 processed_events 기록.
--   키 형식 (고정, 애플리케이션이 조립):
--     Kafka 기원:  "{sourceEventId}:{channel}:{templateOrNone}:{recipientUserId}"
--     캠페인 기원: "campaign:{campaignId}:{channel}:{templateOrNone}:{recipientUserId}"
--     template_id 가 NULL 이면 구간 값 "NONE" 사용 (키에 NULL 금지).
-- ==============================================================
CREATE TABLE notification (
    id                  BIGSERIAL PRIMARY KEY,
    -- [NOTIF-01] 발송 단위 멱등 키. 외부 채널 호출 전에 반드시 INSERT
    idempotency_key     VARCHAR(300) NOT NULL,
    -- 원본 Kafka DomainEvent.eventId (캠페인 스케줄 발송이면 NULL)
    source_event_id     UUID,
    -- 논리 참조: auth.account.id (cross-service FK 금지)
    recipient_user_id   UUID         NOT NULL,
    -- EMAIL, WEBHOOK, IN_APP, PUSH
    channel             VARCHAR(20)  NOT NULL,
    -- TRANSACTION, MARKETING, SOCIAL, SYSTEM
    category            VARCHAR(30)  NOT NULL,
    -- notification_template.template_id 참조 (nullable: 자유 형식 알림 허용)
    template_id         VARCHAR(50),
    subject             VARCHAR(200),
    content             TEXT,
    -- PENDING, SENT, FAILED, DLQ, OPENED, CLICKED
    status              VARCHAR(20)  NOT NULL,
    -- marketing_campaign.id (nullable, FK는 아래 ALTER)
    campaign_id         BIGINT,
    click_count         INT          NOT NULL DEFAULT 0,
    opened_at           TIMESTAMPTZ,
    failure_reason      TEXT,
    retry_count         INT          NOT NULL DEFAULT 0,
    sent_at             TIMESTAMPTZ,
    created_at          TIMESTAMPTZ    NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_notification_idempotency UNIQUE (idempotency_key),
    CONSTRAINT fk_notification_template
        FOREIGN KEY (template_id) REFERENCES notification_template (template_id),
    CONSTRAINT chk_notification_channel CHECK (
        channel IN ('EMAIL', 'WEBHOOK', 'IN_APP', 'PUSH')
    ),
    CONSTRAINT chk_notification_category CHECK (
        category IN ('TRANSACTION', 'MARKETING', 'SOCIAL', 'SYSTEM')
    ),
    CONSTRAINT chk_notification_status CHECK (
        status IN ('PENDING', 'SENT', 'FAILED', 'DLQ', 'OPENED', 'CLICKED')
    ),
    CONSTRAINT chk_notification_click_count_nonneg
        CHECK (click_count >= 0),
    CONSTRAINT chk_notification_retry_count_nonneg
        CHECK (retry_count >= 0),
    -- SENT 이후 열람/클릭만 허용. sent_at 은 SENT 이상에서만
    CONSTRAINT chk_notification_sent_at CHECK (
        (status IN ('PENDING', 'FAILED', 'DLQ') AND sent_at IS NULL)
        OR (status IN ('SENT', 'OPENED', 'CLICKED') AND sent_at IS NOT NULL)
    )
);

COMMENT ON TABLE notification IS
    '개별 알림 발송/열람 이력. idempotency_key 로 중복 발송 차단(NOTIF-01)';
COMMENT ON COLUMN notification.idempotency_key IS
    '발송 멱등 키. 형식: {eventId|campaign:id}:{channel}:{template|NONE}:{recipient}. UNIQUE';
COMMENT ON COLUMN notification.source_event_id IS
    'Kafka DomainEvent.eventId. 캠페인 스케줄 발송이면 NULL';
COMMENT ON COLUMN notification.recipient_user_id IS
    '논리 참조: auth.account.id (database-per-service 경계로 FK 없음)';
COMMENT ON COLUMN notification.channel IS '발송 채널: EMAIL, WEBHOOK, IN_APP, PUSH';
COMMENT ON COLUMN notification.category IS '알림 카테고리: TRANSACTION, MARKETING, SOCIAL, SYSTEM';
COMMENT ON COLUMN notification.template_id IS '내부 FK → notification_template.template_id';
COMMENT ON COLUMN notification.status IS 'PENDING, SENT, FAILED, DLQ, OPENED, CLICKED';
COMMENT ON COLUMN notification.campaign_id IS
    '내부 FK → marketing_campaign.id (순환 참조로 마지막 ALTER에서 FK 추가)';

CREATE INDEX idx_notification_recipient_created
    ON notification (recipient_user_id, created_at DESC);

-- [LOW-NT-6] IN_APP 인박스: 미읽음·읽음(SENT/OPENED)만 recipient별 최신순 조회
CREATE INDEX idx_notification_in_app_inbox
    ON notification (recipient_user_id, created_at DESC)
    WHERE channel = 'IN_APP' AND status IN ('SENT', 'OPENED');

-- 발송 워커: 재시도/대기 건 조회
CREATE INDEX idx_notification_pending_failed
    ON notification (status, created_at)
    WHERE status IN ('PENDING', 'FAILED');

CREATE INDEX idx_notification_template_id
    ON notification (template_id)
    WHERE template_id IS NOT NULL;

CREATE INDEX idx_notification_campaign_id
    ON notification (campaign_id)
    WHERE campaign_id IS NOT NULL;

-- 원본 이벤트 기준 추적 (한 이벤트가 여러 채널로 팬아웃될 수 있음)
CREATE INDEX idx_notification_source_event
    ON notification (source_event_id)
    WHERE source_event_id IS NOT NULL;

-- ==============================================================
-- 3. 마케팅 캠페인
--
-- [NOTIF-02] 스케줄 멱등: Kafka 재소비 시 동일 캠페인이 중복 INSERT 되지 않도록
--   idempotency_key UNIQUE. 형식 예:
--   "{sourceEventId}:{campaign_type}:{target_user_id}:{target_resource_id|NONE}"
-- ==============================================================
CREATE TABLE marketing_campaign (
    id                      BIGSERIAL PRIMARY KEY,
    -- [NOTIF-02] 캠페인 생성(스케줄) 멱등 키
    idempotency_key         VARCHAR(300) NOT NULL,
    -- Kafka DomainEvent.eventId (수동 스케줄이면 NULL)
    source_event_id         UUID,
    -- REPURCHASE_REMINDER, PRICE_DROP, CART_ABANDONMENT, NEW_PRODUCT, INFLUENCER_BONUS, RESTOCK_ALERT
    campaign_type           VARCHAR(50)  NOT NULL,
    -- 논리 참조: auth.account.id
    target_user_id          UUID         NOT NULL,
    -- 대상 리소스 타입 (PRODUCT, ORDER, OOTD 등)
    target_resource_type    VARCHAR(30),
    -- 논리 참조: target_resource_type 별 외부 서비스 리소스 ID
    target_resource_id      VARCHAR(100),
    template_id             VARCHAR(50),
    custom_data             JSONB,
    scheduled_at            TIMESTAMPTZ    NOT NULL,
    executed_at             TIMESTAMPTZ,
    -- SCHEDULED, EXECUTING, SENT, CANCELLED, FAILED
    status                  VARCHAR(20)  NOT NULL,
    -- 발송된 notification.id (nullable)
    notification_id         BIGINT,
    created_at              TIMESTAMPTZ    NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_marketing_campaign_idempotency UNIQUE (idempotency_key),
    CONSTRAINT fk_marketing_campaign_template
        FOREIGN KEY (template_id) REFERENCES notification_template (template_id),
    CONSTRAINT fk_marketing_campaign_notification
        FOREIGN KEY (notification_id) REFERENCES notification (id),
    CONSTRAINT chk_marketing_campaign_type CHECK (
        campaign_type IN (
            'REPURCHASE_REMINDER',
            'PRICE_DROP',
            'CART_ABANDONMENT',
            'NEW_PRODUCT',
            'INFLUENCER_BONUS',
            'RESTOCK_ALERT'
        )
    ),
    CONSTRAINT chk_marketing_campaign_status CHECK (
        status IN ('SCHEDULED', 'EXECUTING', 'SENT', 'CANCELLED', 'FAILED')
    ),
    CONSTRAINT chk_marketing_campaign_executed CHECK (
        (status <> 'SENT') OR executed_at IS NOT NULL
    )
);

COMMENT ON TABLE marketing_campaign IS
    '마케팅 캠페인 스케줄. idempotency_key 로 중복 스케줄 차단 (NOTIF-02)';
COMMENT ON COLUMN marketing_campaign.idempotency_key IS
    '스케줄 멱등 키. 예: {sourceEventId}:{campaign_type}:{userId}:{resourceId|NONE}';
COMMENT ON COLUMN marketing_campaign.source_event_id IS
    'Kafka DomainEvent.eventId. 수동 생성 캠페인이면 NULL';
COMMENT ON COLUMN marketing_campaign.campaign_type IS 'REPURCHASE_REMINDER, PRICE_DROP, CART_ABANDONMENT, NEW_PRODUCT, INFLUENCER_BONUS, RESTOCK_ALERT';
COMMENT ON COLUMN marketing_campaign.target_user_id IS '논리 참조: auth.account.id (FK 없음)';
COMMENT ON COLUMN marketing_campaign.target_resource_type IS '대상 리소스 종류 (commerce/fashion/social 등)';
COMMENT ON COLUMN marketing_campaign.target_resource_id IS '논리 참조: target_resource_type 별 외부 서비스 리소스 ID (FK 없음)';
COMMENT ON COLUMN marketing_campaign.template_id IS '내부 FK → notification_template.template_id';
COMMENT ON COLUMN marketing_campaign.status IS 'SCHEDULED, EXECUTING, SENT, CANCELLED, FAILED';
COMMENT ON COLUMN marketing_campaign.notification_id IS '내부 FK → notification.id (캠페인 실행 결과 알림, nullable)';

-- 스케줄 워커: 예정된 캠페인 조회
CREATE INDEX idx_marketing_campaign_scheduled
    ON marketing_campaign (status, scheduled_at)
    WHERE status = 'SCHEDULED';

CREATE INDEX idx_marketing_campaign_target_user
    ON marketing_campaign (target_user_id, created_at DESC);

CREATE INDEX idx_marketing_campaign_notification_id
    ON marketing_campaign (notification_id)
    WHERE notification_id IS NOT NULL;

CREATE INDEX idx_marketing_campaign_source_event
    ON marketing_campaign (source_event_id)
    WHERE source_event_id IS NOT NULL;

-- ==============================================================
-- 4. 사용자 알림 수신 설정
-- ==============================================================
CREATE TABLE notification_preference (
    -- 논리 참조: auth.account.id
    user_id                 UUID         NOT NULL,
    channel                 VARCHAR(20)  NOT NULL,
    category                VARCHAR(30)  NOT NULL,
    enabled                 BOOLEAN      NOT NULL DEFAULT TRUE,
    quiet_hours_start       TIME,
    quiet_hours_end         TIME,

    CONSTRAINT pk_notification_preference PRIMARY KEY (user_id, channel, category),
    CONSTRAINT chk_notification_preference_channel CHECK (
        channel IN ('EMAIL', 'WEBHOOK', 'IN_APP', 'PUSH')
    ),
    CONSTRAINT chk_notification_preference_category CHECK (
        category IN ('TRANSACTION', 'MARKETING', 'SOCIAL', 'SYSTEM')
    )
);

COMMENT ON TABLE notification_preference IS '사용자별 채널·카테고리 수신 동의 및 방해 금지 시간';
COMMENT ON COLUMN notification_preference.user_id IS '논리 참조: auth.account.id (FK 없음)';
COMMENT ON COLUMN notification_preference.channel IS 'EMAIL, WEBHOOK, IN_APP, PUSH';
COMMENT ON COLUMN notification_preference.category IS 'TRANSACTION, MARKETING, SOCIAL, SYSTEM';
COMMENT ON COLUMN notification_preference.quiet_hours_start IS '방해 금지 시작 시각 (로컬 시간 정책은 애플리케이션에서 해석)';
COMMENT ON COLUMN notification_preference.quiet_hours_end IS '방해 금지 종료 시각';

-- ==============================================================
-- 5. 캠페인 전환(효과 측정)
--
-- [NOTIF-02] 전환 이벤트 재처리 시 PURCHASED 등이 중복 집계되지 않도록
--   idempotency_key UNIQUE. 예: "{sourceEventId}:PURCHASED:{campaign_id}"
-- ==============================================================
CREATE TABLE campaign_conversion (
    id                  BIGSERIAL PRIMARY KEY,
    campaign_id         BIGINT       NOT NULL,
    idempotency_key     VARCHAR(300) NOT NULL,
    source_event_id     UUID,
    -- OPENED, CLICKED, PURCHASED, IGNORED
    conversion_type     VARCHAR(30)  NOT NULL,
    -- 전환 가치 (최소 화폐 단위, 예: 원). PURCHASED 등에서 사용
    conversion_value    BIGINT,
    occurred_at         TIMESTAMPTZ    NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_campaign_conversion_idempotency UNIQUE (idempotency_key),
    CONSTRAINT fk_campaign_conversion_campaign
        FOREIGN KEY (campaign_id) REFERENCES marketing_campaign (id),
    CONSTRAINT chk_campaign_conversion_type CHECK (
        conversion_type IN ('OPENED', 'CLICKED', 'PURCHASED', 'IGNORED')
    ),
    CONSTRAINT chk_campaign_conversion_value_nonneg
        CHECK (conversion_value IS NULL OR conversion_value >= 0)
);

COMMENT ON TABLE campaign_conversion IS
    '캠페인 전환 원장. idempotency_key 로 중복 집계 방지 (NOTIF-02)';
COMMENT ON COLUMN campaign_conversion.idempotency_key IS
    '전환 멱등 키. 예: {notificationId|eventId}:{conversion_type}:{campaign_id}';
COMMENT ON COLUMN campaign_conversion.source_event_id IS
    '원본 Kafka/주문 이벤트 ID (추적용, UNIQUE 는 idempotency_key)';
COMMENT ON COLUMN campaign_conversion.campaign_id IS '내부 FK → marketing_campaign.id';
COMMENT ON COLUMN campaign_conversion.conversion_type IS 'OPENED, CLICKED, PURCHASED, IGNORED';
COMMENT ON COLUMN campaign_conversion.conversion_value IS '전환 금액 등 가치. BIGINT 최소 화폐 단위(예: 원)';

CREATE INDEX idx_campaign_conversion_campaign_occurred
    ON campaign_conversion (campaign_id, occurred_at DESC);

CREATE INDEX idx_campaign_conversion_type_occurred
    ON campaign_conversion (conversion_type, occurred_at DESC)
    WHERE conversion_type IS NOT NULL;

-- ==============================================================
-- 6. 순환 FK 마무리: notification.campaign_id → marketing_campaign.id
-- ==============================================================
ALTER TABLE notification
    ADD CONSTRAINT fk_notification_campaign
        FOREIGN KEY (campaign_id) REFERENCES marketing_campaign (id);
