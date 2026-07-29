-- ==============================================================
-- user-service 최종 초기 스키마
--
-- ERD: user_profile, follow_relation, user_suggestion
-- 참고: ERD의 user_outbox_events 는 공통 outbox_events 로 대체
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
-- 1. user_profile — 사용자 공개 프로필
--    account_id 는 auth-service.account.id 논리 참조 (DB-per-service, FK 없음)
--
-- [AUTH-04] status 동기화:
--   auth 의 AccountSuspended 소비 시 status = 'SUSPENDED'.
--   정지된 프로필은 팔로우·공개 활동 API 에서 거부해야 한다.
--   AccountEmailVerified 는 email_verified 컬럼에 반영 (로그인 가능 여부와
--   별개로, 프로필 완성/뱃지 등에 사용).
--
-- [USER-01] AccountRegistered 에는 nickname 이 없다 (auth 는 공개 프로필을
--   소유하지 않음). 소비 시 충돌 없는 임시 닉네임을 넣어 NOT NULL UNIQUE 를
--   만족시킨다.
--   규칙: nickname = 'u' || replace(account_id::text, '-', '')
--         예) account_id=a1b2... → u + 32hex = 33자 (VARCHAR(50) 이내)
--   account_id 가 UNIQUE 이므로 임시 닉네임도 자동으로 UNIQUE.
--   사용자가 닉네임을 바꾸면 nickname_customized = TRUE 로 두고
--   위 형식 제약을 해제한다 (nullable 정책 대신 항상 표시 가능한 값 유지).
-- --------------------------------------------------------------
CREATE TABLE user_profile (
    id                  BIGSERIAL       PRIMARY KEY,
    account_id          UUID            NOT NULL,
    nickname            VARCHAR(50)     NOT NULL,
    -- FALSE: 시스템 임시 닉네임(USER-01 규칙). TRUE: 사용자가 설정한 닉네임
    nickname_customized BOOLEAN         NOT NULL DEFAULT FALSE,
    avatar_url          VARCHAR(500),
    -- 논리 참조: media-service.media_asset.id (avatar 미설정 시 NULL)
    avatar_media_asset_id BIGINT,
    bio                 TEXT,
    -- auth.account.email_verified 미러 (AccountEmailVerified 로 갱신)
    email_verified      BOOLEAN         NOT NULL DEFAULT FALSE,
    -- 비정규화 카운터 (팔로우/게시 이벤트 반영)
    follower_count      INT             NOT NULL DEFAULT 0,
    following_count     INT             NOT NULL DEFAULT 0,
    post_count          INT             NOT NULL DEFAULT 0,
    -- [BOUNDARY-01] 등급·점수 계산 원본은 recommendation.influencer_metric.
    --   여기는 BFF 노출용 스냅샷. InfluencerTierUpdated 소비 시 갱신.
    influencer_tier     VARCHAR(20),                -- MICRO, MID, MACRO, MEGA
    influencer_score    DECIMAL(10, 2)  NOT NULL DEFAULT 0,
    influencer_tier_synced_at TIMESTAMPTZ,
    -- auth.account.status 미러 (AccountSuspended 등으로 갱신)
    status              VARCHAR(20)     NOT NULL DEFAULT 'ACTIVE',
    created_at          TIMESTAMPTZ       NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ       NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_user_profile_account_id UNIQUE (account_id),
    CONSTRAINT uq_user_profile_nickname UNIQUE (nickname),
    CONSTRAINT chk_user_profile_nickname_length CHECK (
        char_length(nickname) BETWEEN 2 AND 50
    ),
    -- 임시 닉네임은 account_id 파생식과 일치해야 함 (USER-01)
    CONSTRAINT chk_user_profile_provisional_nickname CHECK (
        nickname_customized = TRUE
        OR nickname = ('u' || replace(account_id::text, '-', ''))
    ),
    CONSTRAINT chk_user_profile_follower_count CHECK (follower_count >= 0),
    CONSTRAINT chk_user_profile_following_count CHECK (following_count >= 0),
    CONSTRAINT chk_user_profile_post_count CHECK (post_count >= 0),
    CONSTRAINT chk_user_profile_influencer_score CHECK (influencer_score >= 0),
    CONSTRAINT chk_user_profile_influencer_tier CHECK (
        influencer_tier IS NULL
        OR influencer_tier IN ('MICRO', 'MID', 'MACRO', 'MEGA')
    ),
    CONSTRAINT chk_user_profile_status CHECK (
        status IN ('ACTIVE', 'INACTIVE', 'SUSPENDED', 'DELETED')
    )
);

COMMENT ON TABLE user_profile IS
    '사용자 공개 프로필. auth.account 와 1:1 논리 매핑. status/email_verified 는 auth 이벤트 미러(AUTH-04)';
COMMENT ON COLUMN user_profile.account_id IS
    'auth.account.id 논리 참조. DB-per-service 경계로 FK 없음';
COMMENT ON COLUMN user_profile.nickname IS
    '표시 닉네임. 가입 직후는 u{accountId32hex} 임시값(USER-01). UNIQUE';
COMMENT ON COLUMN user_profile.nickname_customized IS
    'FALSE=시스템 임시 닉네임, TRUE=사용자 설정. 임시일 때 provisional CHECK 적용';
COMMENT ON COLUMN user_profile.avatar_media_asset_id IS
    '논리 참조: media-service.media_asset.id. 설정 시 media_usage(AVATAR) + avatar_url 스냅샷 (MEDIA-01)';
COMMENT ON COLUMN user_profile.email_verified IS
    'auth.account.email_verified 미러. AccountEmailVerified 소비 시 true';
COMMENT ON COLUMN user_profile.follower_count IS '팔로워 수 (비정규화 카운터)';
COMMENT ON COLUMN user_profile.following_count IS '팔로잉 수 (비정규화 카운터)';
COMMENT ON COLUMN user_profile.post_count IS '게시물 수 (비정규화 카운터)';
COMMENT ON COLUMN user_profile.influencer_tier IS
    'recommendation.influencer_metric.tier 미러 (BOUNDARY-01). MICRO/MID/MACRO/MEGA';
COMMENT ON COLUMN user_profile.influencer_score IS
    'recommendation.influencer_metric.influence_score 미러 (표시용 스냅샷)';
COMMENT ON COLUMN user_profile.influencer_tier_synced_at IS
    'InfluencerTierUpdated(또는 동등 이벤트) 마지막 반영 시각';
COMMENT ON COLUMN user_profile.status IS
    '프로필 상태: ACTIVE, INACTIVE, SUSPENDED, DELETED. SUSPENDED 는 AccountSuspended 반영';

-- account_id / nickname 은 UNIQUE 로 조회 지원. 추가 조회 인덱스:
CREATE INDEX idx_user_profile_status_created
    ON user_profile (status, created_at DESC);

CREATE INDEX idx_user_profile_influencer_score
    ON user_profile (influencer_score DESC)
    WHERE status = 'ACTIVE';

-- 아직 닉네임을 안 바꾼 사용자 (온보딩 리마인더 등)
CREATE INDEX idx_user_profile_pending_nickname
    ON user_profile (created_at)
    WHERE nickname_customized = FALSE;

-- --------------------------------------------------------------
-- 2. follow_relation — 팔로우 관계
-- --------------------------------------------------------------
CREATE TABLE follow_relation (
    id              BIGSERIAL   PRIMARY KEY,
    follower_id     BIGINT      NOT NULL,
    followee_id     BIGINT      NOT NULL,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_follow_relation_pair UNIQUE (follower_id, followee_id),
    CONSTRAINT chk_follow_relation_not_self CHECK (follower_id <> followee_id),
    CONSTRAINT fk_follow_relation_follower
        FOREIGN KEY (follower_id) REFERENCES user_profile (id),
    CONSTRAINT fk_follow_relation_followee
        FOREIGN KEY (followee_id) REFERENCES user_profile (id)
);

COMMENT ON TABLE follow_relation IS '사용자 간 팔로우 관계 (follower → followee)';
COMMENT ON COLUMN follow_relation.follower_id IS '팔로우를 건 사용자 (user_profile.id)';
COMMENT ON COLUMN follow_relation.followee_id IS '팔로우 대상 사용자 (user_profile.id)';

-- 팔로워 목록 조회: 특정 followee 의 팔로워
CREATE INDEX idx_follow_relation_followee_created
    ON follow_relation (followee_id, created_at DESC);

-- [LOW] 팔로잉 목록( follower 기준 최신순). UNIQUE(follower_id, followee_id) 접두만으로는 정렬 비용 큼
CREATE INDEX idx_follow_relation_follower_created
    ON follow_relation (follower_id, created_at DESC);

-- follower 기준 조회는 UNIQUE(follower_id, followee_id) 로 커버


-- --------------------------------------------------------------
-- [USER-02] 팔로우 카운터 동시성
--
-- 원본(Source of Truth)은 follow_relation 이고,
-- user_profile.follower_count / following_count 는 파생 캐시다.
--
-- 애플리케이션이 "SELECT 후 +1 UPDATE" 방식으로 갱신하면 동시
-- follow/unfollow 에서 lost update 로 카운터가 실제 관계 수와 어긋난다.
-- 순수 파생 데이터이므로 DB 트리거로 원장 변경(INSERT/DELETE)과 같은
-- 트랜잭션에서 원자 증감시킨다. 애플리케이션은 follow_relation 만
-- INSERT/DELETE 하면 되고 카운터를 직접 만질 필요가 없다.
--
-- 데드락 방지: A→B 와 B→A 팔로우가 동시에 일어나면 두 트랜잭션이
-- 프로필 행 잠금을 서로 반대 순서로 얻어 데드락이 날 수 있다.
-- 항상 user_profile.id 가 작은 쪽부터 갱신해 잠금 순서를 통일한다.
--
-- 검증/복구: 드리프트가 의심되면 reconcile_follow_counters() 로
-- follow_relation 기준 재집계한다 (주기 배치로 돌려도 됨).
-- --------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_follow_relation_counters()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    delta       INT;
    v_follower  BIGINT;   -- following_count 증감 대상
    v_followee  BIGINT;   -- follower_count 증감 대상
    v_first     BIGINT;
    v_second    BIGINT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        delta := 1;
        v_follower := NEW.follower_id;
        v_followee := NEW.followee_id;
    ELSE  -- DELETE (unfollow)
        delta := -1;
        v_follower := OLD.follower_id;
        v_followee := OLD.followee_id;
    END IF;

    -- 잠금 순서 통일 (id 오름차순) → 상호 팔로우 동시 처리 시 데드락 방지
    v_first  := LEAST(v_follower, v_followee);
    v_second := GREATEST(v_follower, v_followee);

    -- CASE 로 각 행에 맞는 컬럼만 증감 (한 행이 follower 이자 followee 일 수는
    -- 없음 — chk_follow_relation_not_self 가 보장)
    UPDATE user_profile SET
        following_count = following_count + CASE WHEN id = v_follower THEN delta ELSE 0 END,
        follower_count  = follower_count  + CASE WHEN id = v_followee THEN delta ELSE 0 END,
        updated_at      = NOW()
    WHERE id = v_first;

    UPDATE user_profile SET
        following_count = following_count + CASE WHEN id = v_follower THEN delta ELSE 0 END,
        follower_count  = follower_count  + CASE WHEN id = v_followee THEN delta ELSE 0 END,
        updated_at      = NOW()
    WHERE id = v_second;

    RETURN NULL;  -- AFTER 트리거 반환값은 무시됨
END;
$$;

COMMENT ON FUNCTION fn_follow_relation_counters() IS
    'follow_relation 변경 시 user_profile 카운터 원자 증감 (USER-02). 잠금은 id 오름차순';

CREATE TRIGGER trg_follow_relation_counters
    AFTER INSERT OR DELETE ON follow_relation
    FOR EACH ROW
    EXECUTE FUNCTION fn_follow_relation_counters();

-- 재집계(복구/검증)용. 반환값 = 보정된 프로필 행 수
CREATE OR REPLACE FUNCTION reconcile_follow_counters()
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    fixed INT;
BEGIN
    UPDATE user_profile p SET
        follower_count  = agg.followers,
        following_count = agg.followings,
        updated_at      = NOW()
    FROM (
        SELECT pr.id,
               COALESCE(f1.cnt, 0) AS followers,
               COALESCE(f2.cnt, 0) AS followings
        FROM user_profile pr
        LEFT JOIN (SELECT followee_id, COUNT(*) cnt FROM follow_relation GROUP BY followee_id) f1
               ON f1.followee_id = pr.id
        LEFT JOIN (SELECT follower_id, COUNT(*) cnt FROM follow_relation GROUP BY follower_id) f2
               ON f2.follower_id = pr.id
    ) agg
    WHERE agg.id = p.id
      AND (p.follower_count <> agg.followers OR p.following_count <> agg.followings);

    GET DIAGNOSTICS fixed = ROW_COUNT;
    RETURN fixed;
END;
$$;

COMMENT ON FUNCTION reconcile_follow_counters() IS
    'follow_relation 기준 카운터 재집계. 드리프트 복구/주기 검증용 (USER-02)';


-- --------------------------------------------------------------
-- 3. user_suggestion — 추천 팔로우 후보
-- --------------------------------------------------------------
CREATE TABLE user_suggestion (
    user_id             BIGINT          NOT NULL,
    suggested_user_id   BIGINT          NOT NULL,
    suggestion_reason   VARCHAR(50),                -- COMMON_FOLLOWERS, SIMILAR_INTEREST
    score               DECIMAL(10, 4),
    calculated_at       TIMESTAMPTZ,

    CONSTRAINT pk_user_suggestion PRIMARY KEY (user_id, suggested_user_id),
    CONSTRAINT chk_user_suggestion_not_self CHECK (user_id <> suggested_user_id),
    CONSTRAINT chk_user_suggestion_score CHECK (score IS NULL OR score >= 0),
    CONSTRAINT fk_user_suggestion_user
        FOREIGN KEY (user_id) REFERENCES user_profile (id),
    CONSTRAINT fk_user_suggestion_suggested
        FOREIGN KEY (suggested_user_id) REFERENCES user_profile (id)
);

COMMENT ON TABLE user_suggestion IS '팔로우 추천 후보 (배치/실시간 계산 결과)';
COMMENT ON COLUMN user_suggestion.user_id IS '추천을 받을 사용자 (user_profile.id)';
COMMENT ON COLUMN user_suggestion.suggested_user_id IS '추천 대상 사용자 (user_profile.id)';
COMMENT ON COLUMN user_suggestion.suggestion_reason IS
    '추천 사유: COMMON_FOLLOWERS, SIMILAR_INTEREST 등';
COMMENT ON COLUMN user_suggestion.score IS '추천 점수 (높을수록 우선)';
COMMENT ON COLUMN user_suggestion.calculated_at IS '추천 점수 계산 시각';

-- 사용자별 상위 추천 조회
CREATE INDEX idx_user_suggestion_user_score
    ON user_suggestion (user_id, score DESC NULLS LAST);
