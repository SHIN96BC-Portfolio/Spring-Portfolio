-- ==============================================================
-- recommendation-service 초기 스키마
--
-- 행동 이벤트·관심사 프로필·동시 출현·추천 캐시·실험·인플루언서 지표
--
-- 설계 원칙:
--   - Database-per-Service: 모든 user/product/OOTD/post/brand/hashtag ID 는
--     외부 서비스 논리 참조이므로 FK 금지, COMMENT 로 설명
--   - 같은 서비스 내 FK 만 생성 (experiment → assignment)
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
-- 1. user_behavior_event — 원본 행동 이벤트
--
-- [REC-01] Kafka 재소비·HTTP 재시도 시 동일 행동이 N번 적재되면
--   interest_profile·co_occurrence 집계가 왜곡된다.
--   source_event_id = DomainEvent.eventId (Kafka) 또는 클라이언트가
--   Idempotency-Key 로 고정한 UUID (HTTP 수집). UNIQUE 로 원장 멱등.
--   processed_events 와 병행: 커밋 전 장애에도 INSERT UNIQUE 가 2차 방어.
--
-- 운영 참고: 월별 RANGE 파티셔닝 검토.
--   PostgreSQL 파티션 테이블의 UNIQUE/PK 는 partition key 를 포함해야 하므로
--   id BIGSERIAL PK 단독 유지와 occurred_at 파티션은 충돌한다.
--   파티션 도입 시 PK 를 (id, occurred_at) 등으로 재설계하고,
--   source_event_id UNIQUE 는 (source_event_id, occurred_at) 등으로 재정의할 것.
--   현재는 일반 테이블로 생성한다.
-- ==============================================================
CREATE TABLE user_behavior_event (
    id              BIGSERIAL PRIMARY KEY,
    -- Kafka DomainEvent.eventId 또는 HTTP Idempotency-Key (UUID)
    source_event_id UUID NOT NULL,
    user_id         UUID NOT NULL,
    event_type      VARCHAR(50) NOT NULL,               -- PRODUCT_VIEWED, OOTD_VIEWED 등
    target_type     VARCHAR(30) NOT NULL,               -- PRODUCT, OOTD, POST, BRAND, HASHTAG
    target_id       VARCHAR(100) NOT NULL,
    session_id      UUID,
    referrer_type   VARCHAR(30),                        -- ORGANIC, RECOMMENDATION, SEARCH
    referrer_id     VARCHAR(100),
    metadata        JSONB,
    occurred_at     TIMESTAMPTZ NOT NULL,
    received_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_user_behavior_event_source_event_id UNIQUE (source_event_id)
);

COMMENT ON TABLE user_behavior_event IS
    '추천 학습용 원본 행동 이벤트. source_event_id UNIQUE 로 수집 멱등 (REC-01)';
COMMENT ON COLUMN user_behavior_event.source_event_id IS
    '수집 멱등 키. Kafka: DomainEvent.eventId. HTTP: 클라이언트 Idempotency-Key(UUID). UNIQUE';
COMMENT ON COLUMN user_behavior_event.user_id IS 'Logical reference to auth.account.id; no FK because of database-per-service boundary';
COMMENT ON COLUMN user_behavior_event.event_type IS '행동 유형. 예: PRODUCT_VIEWED, OOTD_VIEWED, POST_LIKED';
COMMENT ON COLUMN user_behavior_event.target_type IS '대상 타입: PRODUCT, OOTD, POST, BRAND, HASHTAG';
COMMENT ON COLUMN user_behavior_event.target_id IS 'Logical reference to target_type 별 외부 리소스 ID; no FK because of database-per-service boundary';
COMMENT ON COLUMN user_behavior_event.referrer_type IS '유입 경로: ORGANIC, RECOMMENDATION, SEARCH';
COMMENT ON COLUMN user_behavior_event.occurred_at IS '클라이언트/원천 시스템에서 발생한 시각';
COMMENT ON COLUMN user_behavior_event.received_at IS 'recommendation-service 가 수신한 시각';

CREATE INDEX idx_ube_user_occurred
    ON user_behavior_event (user_id, occurred_at DESC);

CREATE INDEX idx_ube_target_occurred
    ON user_behavior_event (target_type, target_id, occurred_at DESC);

CREATE INDEX idx_ube_event_occurred
    ON user_behavior_event (event_type, occurred_at DESC);

CREATE INDEX idx_ube_occurred
    ON user_behavior_event (occurred_at);

-- ==============================================================
-- 2. user_interest_profile — 사용자 관심사 집계 프로필
-- ==============================================================
CREATE TABLE user_interest_profile (
    user_id                         UUID PRIMARY KEY,
    interest_scores                 JSONB,              -- 예: {"fashion": 0.85, "tech": 0.42}
    favorite_brands                 JSONB,
    favorite_categories             JSONB,
    favorite_hashtags               JSONB,
    favorite_style_tags             JSONB,
    price_range_min                 BIGINT,
    price_range_max                 BIGINT,
    price_range_preferred           BIGINT,
    most_active_hour                INT,
    most_active_day_of_week         INT,
    avg_session_duration_seconds    INT,
    persona                         VARCHAR(50),        -- ML 분류 결과
    last_calculated_at              TIMESTAMPTZ,
    version                         INT NOT NULL DEFAULT 0,

    CONSTRAINT ck_uip_price_range
        CHECK (
            price_range_min IS NULL
            OR price_range_max IS NULL
            OR price_range_min <= price_range_max
        ),
    CONSTRAINT ck_uip_price_min CHECK (price_range_min IS NULL OR price_range_min >= 0),
    CONSTRAINT ck_uip_price_max CHECK (price_range_max IS NULL OR price_range_max >= 0),
    CONSTRAINT ck_uip_price_preferred CHECK (price_range_preferred IS NULL OR price_range_preferred >= 0),
    CONSTRAINT ck_uip_most_active_hour
        CHECK (most_active_hour IS NULL OR (most_active_hour >= 0 AND most_active_hour <= 23)),
    CONSTRAINT ck_uip_most_active_dow
        CHECK (most_active_day_of_week IS NULL OR (most_active_day_of_week >= 0 AND most_active_day_of_week <= 6)),
    CONSTRAINT ck_uip_avg_session
        CHECK (avg_session_duration_seconds IS NULL OR avg_session_duration_seconds >= 0),
    CONSTRAINT ck_uip_version CHECK (version >= 0)
);

COMMENT ON TABLE user_interest_profile IS '행동 이벤트로부터 집계한 사용자 관심사 프로필';
COMMENT ON COLUMN user_interest_profile.user_id IS 'Logical reference to auth.account.id; no FK because of database-per-service boundary';
COMMENT ON COLUMN user_interest_profile.interest_scores IS '카테고리별 관심 점수. 예: {"fashion": 0.85, "tech": 0.42}';
COMMENT ON COLUMN user_interest_profile.favorite_brands IS '선호 브랜드 ID/점수 JSON (fashion.brand 논리 참조)';
COMMENT ON COLUMN user_interest_profile.favorite_categories IS '선호 카테고리 ID/점수 JSON (commerce.product_category 논리 참조)';
COMMENT ON COLUMN user_interest_profile.price_range_min IS '선호 가격대 하한 (최소 화폐 단위, BIGINT)';
COMMENT ON COLUMN user_interest_profile.price_range_max IS '선호 가격대 상한 (최소 화폐 단위, BIGINT)';
COMMENT ON COLUMN user_interest_profile.price_range_preferred IS '선호 가격대 중앙값 (최소 화폐 단위, BIGINT)';
COMMENT ON COLUMN user_interest_profile.most_active_hour IS '가장 활발한 시각 (0~23)';
COMMENT ON COLUMN user_interest_profile.most_active_day_of_week IS '가장 활발한 요일 (0=일 ~ 6=토)';
COMMENT ON COLUMN user_interest_profile.persona IS 'ML 분류 페르소나 라벨';
COMMENT ON COLUMN user_interest_profile.version IS '프로필 재계산 optimistic locking 버전';

-- ==============================================================
-- 3. product_co_occurrence — 상품 동시 출현
-- ==============================================================
CREATE TABLE product_co_occurrence (
    product_id          BIGINT NOT NULL,
    co_product_id       BIGINT NOT NULL,
    co_type             VARCHAR(30) NOT NULL,           -- VIEWED_TOGETHER, BOUGHT_TOGETHER, TAGGED_TOGETHER
    co_count            INT NOT NULL DEFAULT 0,
    confidence          DECIMAL(5, 4),
    last_calculated_at  TIMESTAMPTZ,

    CONSTRAINT pk_product_co_occurrence PRIMARY KEY (product_id, co_product_id, co_type),
    CONSTRAINT ck_product_co_not_self CHECK (product_id <> co_product_id),
    CONSTRAINT ck_product_co_count CHECK (co_count >= 0),
    CONSTRAINT ck_product_co_confidence
        CHECK (confidence IS NULL OR (confidence >= 0 AND confidence <= 1)),
    CONSTRAINT ck_product_co_type
        CHECK (co_type IN ('VIEWED_TOGETHER', 'BOUGHT_TOGETHER', 'TAGGED_TOGETHER'))
);

COMMENT ON TABLE product_co_occurrence IS '상품 연관 추천용 동시 출현 집계';
COMMENT ON COLUMN product_co_occurrence.product_id IS 'Logical reference to commerce.product.id; no FK because of database-per-service boundary';
COMMENT ON COLUMN product_co_occurrence.co_product_id IS 'Logical reference to commerce.product.id (연관 상품); no FK because of database-per-service boundary';
COMMENT ON COLUMN product_co_occurrence.co_type IS 'VIEWED_TOGETHER, BOUGHT_TOGETHER, TAGGED_TOGETHER';
COMMENT ON COLUMN product_co_occurrence.confidence IS '연관 신뢰도 (0~1)';

CREATE INDEX idx_product_co_rank
    ON product_co_occurrence (product_id, co_type, confidence DESC NULLS LAST);

-- ==============================================================
-- 4. ootd_co_occurrence — OOTD 동시 출현
-- ==============================================================
CREATE TABLE ootd_co_occurrence (
    ootd_id             BIGINT NOT NULL,
    co_ootd_id          BIGINT NOT NULL,
    co_type             VARCHAR(30) NOT NULL,
    co_count            INT NOT NULL DEFAULT 0,
    last_calculated_at  TIMESTAMPTZ,

    CONSTRAINT pk_ootd_co_occurrence PRIMARY KEY (ootd_id, co_ootd_id, co_type),
    CONSTRAINT ck_ootd_co_not_self CHECK (ootd_id <> co_ootd_id),
    CONSTRAINT ck_ootd_co_count CHECK (co_count >= 0)
);

COMMENT ON TABLE ootd_co_occurrence IS 'OOTD 연관 추천용 동시 출현 집계';
COMMENT ON COLUMN ootd_co_occurrence.ootd_id IS 'Logical reference to fashion.ootd.id; no FK because of database-per-service boundary';
COMMENT ON COLUMN ootd_co_occurrence.co_ootd_id IS 'Logical reference to fashion.ootd.id (연관 OOTD); no FK because of database-per-service boundary';

CREATE INDEX idx_ootd_co_rank
    ON ootd_co_occurrence (ootd_id, co_type, co_count DESC);

-- ==============================================================
-- 5. recommendation_experiment — A/B 실험 정의
-- (user_recommendation_cache FK 를 위해 캐시보다 먼저 생성)
-- ==============================================================
CREATE TABLE recommendation_experiment (
    id                  BIGSERIAL PRIMARY KEY,
    experiment_name     VARCHAR(100) NOT NULL,
    description         TEXT,
    variant_a           VARCHAR(50),
    variant_b           VARCHAR(50),
    traffic_split       DECIMAL(3, 2),                  -- 0.50 = 50:50 (A 비율)
    status              VARCHAR(20),                    -- DRAFT, RUNNING, COMPLETED
    starts_at           TIMESTAMPTZ,
    ends_at             TIMESTAMPTZ,

    CONSTRAINT uq_recommendation_experiment_name UNIQUE (experiment_name),
    CONSTRAINT ck_recommendation_experiment_traffic
        CHECK (traffic_split IS NULL OR (traffic_split >= 0 AND traffic_split <= 1)),
    CONSTRAINT ck_recommendation_experiment_status
        CHECK (status IS NULL OR status IN ('DRAFT', 'RUNNING', 'COMPLETED')),
    CONSTRAINT ck_recommendation_experiment_period
        CHECK (ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at)
);

COMMENT ON TABLE recommendation_experiment IS '추천 알고리즘 A/B 실험 정의';
COMMENT ON COLUMN recommendation_experiment.traffic_split IS 'variant_a 트래픽 비율 (0~1). 0.50 = 50:50';
COMMENT ON COLUMN recommendation_experiment.status IS 'DRAFT, RUNNING, COMPLETED';

CREATE INDEX idx_recommendation_experiment_status_period
    ON recommendation_experiment (status, starts_at, ends_at);

-- ==============================================================
-- 6. user_experiment_assignment — 사용자 실험 배정
-- ==============================================================
CREATE TABLE user_experiment_assignment (
    user_id         UUID NOT NULL,
    experiment_id   BIGINT NOT NULL,
    variant         VARCHAR(50) NOT NULL,
    assigned_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_user_experiment_assignment PRIMARY KEY (user_id, experiment_id),
    CONSTRAINT fk_user_experiment_assignment_experiment
        FOREIGN KEY (experiment_id) REFERENCES recommendation_experiment(id)
);

COMMENT ON TABLE user_experiment_assignment IS '사용자에게 배정된 실험 variant';
COMMENT ON COLUMN user_experiment_assignment.user_id IS 'Logical reference to auth.account.id; no FK because of database-per-service boundary';
COMMENT ON COLUMN user_experiment_assignment.experiment_id IS '내부 FK → recommendation_experiment.id';

CREATE INDEX idx_user_experiment_assignment_exp_variant
    ON user_experiment_assignment (experiment_id, variant);

-- ==============================================================
-- 7. user_recommendation_cache — 사용자별 추천 결과 캐시
--
-- [REC-02] 실험군 A/B 가 동일 (user, type, context) 키를 공유하면
--   마지막 쓰기가 이전 variant 결과를 덮어 실험 배정과 응답이 어긋난다.
--   experiment_id + variant 를 캐시 슬롯에 포함한다.
--   실험 미참여(프로덕션 기본 알고리즘): experiment_id·variant 모두 NULL.
--
-- target_context 가 NULL 일 수 있음 → COALESCE 로 unique 정규화.
-- ==============================================================
CREATE TABLE user_recommendation_cache (
    id                      BIGSERIAL PRIMARY KEY,
    user_id                 UUID NOT NULL,
    recommendation_type     VARCHAR(50) NOT NULL,       -- HOME_FEED, RELATED_PRODUCTS, FOR_YOU_OOTD
    target_context          VARCHAR(100),               -- 예: related_products 의 product_id
    -- 실험 슬라이스. NULL,NULL = 실험 외 기본 캐시
    experiment_id           BIGINT,
    variant                 VARCHAR(50),
    items                   JSONB NOT NULL,
    algorithm_version       VARCHAR(20),
    generated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at              TIMESTAMPTZ NOT NULL,

    CONSTRAINT fk_user_recommendation_cache_experiment
        FOREIGN KEY (experiment_id) REFERENCES recommendation_experiment (id),
    CONSTRAINT ck_user_recommendation_cache_experiment_pair CHECK (
        (experiment_id IS NULL AND variant IS NULL)
        OR (experiment_id IS NOT NULL AND variant IS NOT NULL)
    ),
    -- [LOW-RC-6] 만료 시각이 생성 시각보다 앞서면 TTL/조회가 깨진다.
    CONSTRAINT ck_user_recommendation_cache_expires CHECK (
        expires_at >= generated_at
    )
);

COMMENT ON TABLE user_recommendation_cache IS
    '사용자별 추천 캐시. 실험 variant 별 슬롯 분리 (REC-02)';
COMMENT ON COLUMN user_recommendation_cache.user_id IS
    'Logical reference to auth.account.id; no FK because of database-per-service boundary';
COMMENT ON COLUMN user_recommendation_cache.recommendation_type IS
    'HOME_FEED, RELATED_PRODUCTS, FOR_YOU_OOTD 등';
COMMENT ON COLUMN user_recommendation_cache.target_context IS
    '컨텍스트 키 (예: related product_id). NULL 가능';
COMMENT ON COLUMN user_recommendation_cache.experiment_id IS
    '실험 캐시 슬롯. user_experiment_assignment 와 동일 experiment_id (REC-02)';
COMMENT ON COLUMN user_recommendation_cache.variant IS
    '실험 배정 variant 라벨. assignment.variant 와 일치해야 함 (REC-02)';
COMMENT ON COLUMN user_recommendation_cache.items IS '추천 아이템 목록 JSON';

CREATE UNIQUE INDEX uq_user_recommendation_cache_slot
    ON user_recommendation_cache (
        user_id,
        recommendation_type,
        COALESCE(target_context, ''),
        COALESCE(experiment_id::text, ''),
        COALESCE(variant, '')
    );

CREATE INDEX idx_user_recommendation_cache_expires
    ON user_recommendation_cache (expires_at);

-- [LOW-RC-6] uq_user_recommendation_cache_slot 의 (user_id, recommendation_type, …) 접두로
--   user_id + recommendation_type 조회를 이미 커버하므로 중복 인덱스 제거.

CREATE INDEX idx_user_recommendation_cache_experiment
    ON user_recommendation_cache (experiment_id, variant)
    WHERE experiment_id IS NOT NULL;

-- ==============================================================
-- 8. influencer_metric — 인플루언서 영향력 지표 (계산 원본, BOUNDARY-01)
--
-- tier·influence_score 의 단일 소스. user_profile 은 InfluencerTierUpdated 로
--   표시용 스냅샷만 미러한다 (BFF 는 user 조회 우선).
-- ==============================================================
CREATE TABLE influencer_metric (
    user_id                 UUID PRIMARY KEY,
    follower_growth_rate    DECIMAL(10, 4),
    avg_engagement_rate     DECIMAL(10, 4),
    avg_ootd_likes          DECIMAL(10, 2),
    avg_post_likes          DECIMAL(10, 2),
    domain_influence        JSONB,                      -- 예: {"fashion": 0.92, "lifestyle": 0.45}
    influence_score         DECIMAL(10, 4),
    tier                    VARCHAR(20),                -- MICRO, MID, MACRO, MEGA
    last_calculated_at      TIMESTAMPTZ,

    CONSTRAINT ck_influencer_avg_engagement
        CHECK (avg_engagement_rate IS NULL OR avg_engagement_rate >= 0),
    CONSTRAINT ck_influencer_avg_ootd_likes
        CHECK (avg_ootd_likes IS NULL OR avg_ootd_likes >= 0),
    CONSTRAINT ck_influencer_avg_post_likes
        CHECK (avg_post_likes IS NULL OR avg_post_likes >= 0),
    CONSTRAINT ck_influencer_score
        CHECK (influence_score IS NULL OR influence_score >= 0),
    CONSTRAINT ck_influencer_tier
        CHECK (tier IS NULL OR tier IN ('MICRO', 'MID', 'MACRO', 'MEGA'))
);

COMMENT ON TABLE influencer_metric IS
    '인플루언서 영향력·등급 계산 원본 (BOUNDARY-01). user_profile 은 스냅샷만 보유';
COMMENT ON COLUMN influencer_metric.user_id IS 'Logical reference to auth.account.id (또는 user_profile); no FK because of database-per-service boundary';
COMMENT ON COLUMN influencer_metric.domain_influence IS '도메인별 영향력. 예: {"fashion": 0.92, "lifestyle": 0.45}';
COMMENT ON COLUMN influencer_metric.tier IS 'MICRO, MID, MACRO, MEGA';

CREATE INDEX idx_influencer_metric_score
    ON influencer_metric (influence_score DESC NULLS LAST);

CREATE INDEX idx_influencer_metric_tier_score
    ON influencer_metric (tier, influence_score DESC NULLS LAST)
    WHERE tier IS NOT NULL;
