-- ==============================================================
-- social-service 초기 스키마
--
-- 게시물·좋아요·댓글·해시태그·트렌딩 집계
--
-- 설계 원칙:
--   - Database-per-Service: cross-service ID 는 FK 없이 COMMENT 로 논리 참조
--   - 같은 서비스 내 FK 만 생성
--   - 댓글 테이블명은 ERD 대로 comment 사용
-- [BOUNDARY-02] post·comment·post_like·comment_like·post_share 만 소유.
--   OOTD 반응(ootd_like, ootd_comment)은 fashion-service — 이 스키마에 OOTD 없음.
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
-- 1. post — 소셜 피드 게시물 (일반 post, OOTD 아님 — BOUNDARY-02)
-- ==============================================================
CREATE TABLE post (
    id                  BIGSERIAL PRIMARY KEY,
    author_id           UUID NOT NULL,
    content             TEXT NOT NULL,
    image_urls          JSONB,                          -- [MEDIA-01] 레거시 캐시; 신규는 post_image
    likes_count         INT NOT NULL DEFAULT 0,
    comments_count      INT NOT NULL DEFAULT 0,
    view_count          BIGINT NOT NULL DEFAULT 0,
    share_count         INT NOT NULL DEFAULT 0,
    engagement_score    DECIMAL(10, 4) NOT NULL DEFAULT 0,
    status              VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    -- [SOCIAL-02] soft-delete 시각. status=DELETED 와 쌍으로만 존재
    deleted_at          TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT ck_post_likes_count CHECK (likes_count >= 0),
    CONSTRAINT ck_post_comments_count CHECK (comments_count >= 0),
    CONSTRAINT ck_post_view_count CHECK (view_count >= 0),
    CONSTRAINT ck_post_share_count CHECK (share_count >= 0),
    CONSTRAINT ck_post_engagement_score CHECK (engagement_score >= 0),
    CONSTRAINT ck_post_status CHECK (status IN ('ACTIVE', 'HIDDEN', 'DELETED')),
    CONSTRAINT ck_post_deleted_at CHECK (
        (status = 'DELETED') = (deleted_at IS NOT NULL)
    )
);

COMMENT ON TABLE post IS
    '소셜 피드 게시물 (일반 post). OOTD 본문·반응은 fashion-service (BOUNDARY-02)';
COMMENT ON COLUMN post.author_id IS 'Logical reference to auth.account.id; no FK because of database-per-service boundary';
COMMENT ON COLUMN post.image_urls IS
    '레거시 URL 배열 캐시. 신규 attach 는 post_image + media_usage(POST) 사용 (MEDIA-01)';
COMMENT ON COLUMN post.engagement_score IS '알고리즘용 참여 점수 (좋아요/댓글/공유/조회 기반)';
COMMENT ON COLUMN post.likes_count IS
    '비정규화 좋아요 수. 원본은 post_like (트리거 원자 증감, SOCIAL-01)';
COMMENT ON COLUMN post.comments_count IS
    '비정규화 활성 댓글 수. status=ACTIVE 댓글만 집계 (SOCIAL-02)';
COMMENT ON COLUMN post.share_count IS
    '비정규화 공유 수. 원본은 post_share (트리거 원자 증감, SOCIAL-01)';
COMMENT ON COLUMN post.deleted_at IS
    'soft-delete 시각. status=DELETED 일 때만 NOT NULL (SOCIAL-02)';

CREATE INDEX idx_post_author_created
    ON post (author_id, created_at DESC);

CREATE INDEX idx_post_status_created
    ON post (status, created_at DESC);

CREATE INDEX idx_post_active_engagement
    ON post (engagement_score DESC, created_at DESC)
    WHERE status = 'ACTIVE';

-- ==============================================================
-- 1b. post_image — 게시물 첨부 이미지 (MEDIA-01)
--
-- attach 순서: media-service usage 등록(POST, post_id) → INSERT.
-- detach: usage released_at → DELETE 또는 soft-delete 정책은 앱 계층.
-- ==============================================================
CREATE TABLE post_image (
    id              BIGSERIAL PRIMARY KEY,
    post_id         BIGINT NOT NULL,
    -- 논리 참조: media-service.media_asset.id (cross-service FK 없음)
    media_asset_id  BIGINT NOT NULL,
    image_url       VARCHAR(500) NOT NULL,
    display_order   INT NOT NULL,

    CONSTRAINT fk_post_image_post
        FOREIGN KEY (post_id) REFERENCES post (id),
    CONSTRAINT uq_post_image_order UNIQUE (post_id, display_order),
    CONSTRAINT ck_post_image_display_order CHECK (display_order >= 0)
);

COMMENT ON TABLE post_image IS
    '게시물 이미지. media_asset_id + URL 스냅샷으로 media-service 와 연결 (MEDIA-01)';
COMMENT ON COLUMN post_image.media_asset_id IS
    '논리 참조: media-service.media_asset.id. attach 시 media_usage(POST) 필수';
COMMENT ON COLUMN post_image.image_url IS
    'attach 시점 public_url 스냅샷 (CDN 변경·삭제 후에도 피드 렌더용)';

CREATE INDEX idx_post_image_post
    ON post_image (post_id, display_order);

-- ==============================================================
-- 2. post_like — 게시물 좋아요 (원장)
-- ==============================================================
CREATE TABLE post_like (
    id              BIGSERIAL PRIMARY KEY,
    post_id         BIGINT NOT NULL,
    user_id         UUID NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_post_like_post_user UNIQUE (post_id, user_id),
    CONSTRAINT fk_post_like_post
        FOREIGN KEY (post_id) REFERENCES post(id)
);

COMMENT ON TABLE post_like IS
    '게시물 좋아요 원장. 사용자당 게시물 1회. post.likes_count 의 Source of Truth';
COMMENT ON COLUMN post_like.user_id IS
    'Logical reference to auth.account.id; no FK because of database-per-service boundary';

CREATE INDEX idx_post_like_user_created
    ON post_like (user_id, created_at DESC);

-- [SOCIAL-01] post_like → post.likes_count 원자 증감 (USER-02 와 동일 패턴)
CREATE OR REPLACE FUNCTION fn_post_like_counters()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE post SET likes_count = likes_count + 1
        WHERE id = NEW.post_id;
        RETURN NULL;
    ELSE
        UPDATE post SET likes_count = likes_count - 1
        WHERE id = OLD.post_id;
        RETURN NULL;
    END IF;
END;
$$;

COMMENT ON FUNCTION fn_post_like_counters() IS
    'post_like INSERT/DELETE 시 post.likes_count 원자 증감 (SOCIAL-01)';

CREATE TRIGGER trg_post_like_counters
    AFTER INSERT OR DELETE ON post_like
    FOR EACH ROW
    EXECUTE FUNCTION fn_post_like_counters();

-- ==============================================================
-- 3. comment — 게시물 댓글 (대댓글 지원)
--    ERD 테이블명 그대로 comment 사용 (PostgreSQL 예약어는 아님)
--
-- [SOCIAL-02] soft-delete + 부모-게시물 정합:
--   1) status/deleted_at — 하드 DELETE 대신 soft-delete. 삭제 댓글은
--      comments_count 에서 제외되고 신규 좋아요/대댓글 대상이 될 수 없다.
--   2) UNIQUE(id, post_id) + FK(parent_comment_id, post_id) → comment(id, post_id)
--      — 부모 댓글이 다른 게시물에 속한 경우를 DB 가 차단한다.
--      단순 FK(parent_comment_id) 만으로는 크로스-포스트 대댓글이 가능하다.
-- ==============================================================
CREATE TABLE comment (
    id                  BIGSERIAL PRIMARY KEY,
    post_id             BIGINT NOT NULL,
    author_id           UUID NOT NULL,
    parent_comment_id   BIGINT,
    content             TEXT NOT NULL,
    likes_count         INT NOT NULL DEFAULT 0,
    status              VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    deleted_at          TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- 복합 FK 대상: 부모는 반드시 같은 post_id
    CONSTRAINT uq_comment_id_post UNIQUE (id, post_id),
    CONSTRAINT fk_comment_post
        FOREIGN KEY (post_id) REFERENCES post(id),
    CONSTRAINT fk_comment_parent_same_post
        FOREIGN KEY (parent_comment_id, post_id)
            REFERENCES comment (id, post_id),
    CONSTRAINT ck_comment_likes_count CHECK (likes_count >= 0),
    CONSTRAINT ck_comment_not_self
        CHECK (parent_comment_id IS NULL OR parent_comment_id <> id),
    CONSTRAINT ck_comment_status CHECK (
        status IN ('ACTIVE', 'HIDDEN', 'DELETED')
    ),
    CONSTRAINT ck_comment_deleted_at CHECK (
        (status = 'DELETED') = (deleted_at IS NOT NULL)
    )
);

COMMENT ON TABLE comment IS
    '게시물 댓글. soft-delete + 부모는 같은 post 만 허용 (SOCIAL-02)';
COMMENT ON COLUMN comment.author_id IS
    'Logical reference to auth.account.id; no FK because of database-per-service boundary';
COMMENT ON COLUMN comment.parent_comment_id IS
    '부모 댓글. 복합 FK 로 같은 post_id 강제. NULL 이면 최상위';
COMMENT ON COLUMN comment.likes_count IS
    '비정규화 댓글 좋아요 수. 원본은 comment_like (트리거 원자 증감, SOCIAL-01)';
COMMENT ON COLUMN comment.status IS 'ACTIVE, HIDDEN, DELETED';
COMMENT ON COLUMN comment.deleted_at IS
    'soft-delete 시각. status=DELETED 일 때만 NOT NULL';

CREATE INDEX idx_comment_post_created
    ON comment (post_id, created_at)
    WHERE status = 'ACTIVE';

CREATE INDEX idx_comment_parent
    ON comment (parent_comment_id)
    WHERE parent_comment_id IS NOT NULL;

CREATE INDEX idx_comment_author_created
    ON comment (author_id, created_at DESC);

-- [SOCIAL-02] 활성 댓글만 post.comments_count 에 반영
CREATE OR REPLACE FUNCTION fn_comment_post_counters()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status = 'ACTIVE' THEN
            UPDATE post SET comments_count = comments_count + 1 WHERE id = NEW.post_id;
        END IF;
        RETURN NULL;
    ELSIF TG_OP = 'UPDATE' THEN
        IF OLD.status = 'ACTIVE' AND NEW.status IS DISTINCT FROM 'ACTIVE' THEN
            UPDATE post SET comments_count = comments_count - 1 WHERE id = OLD.post_id;
        ELSIF OLD.status IS DISTINCT FROM 'ACTIVE' AND NEW.status = 'ACTIVE' THEN
            UPDATE post SET comments_count = comments_count + 1 WHERE id = NEW.post_id;
        END IF;
        RETURN NULL;
    ELSE  -- DELETE (하드 삭제 경로, 드묾)
        IF OLD.status = 'ACTIVE' THEN
            UPDATE post SET comments_count = comments_count - 1 WHERE id = OLD.post_id;
        END IF;
        RETURN NULL;
    END IF;
END;
$$;

COMMENT ON FUNCTION fn_comment_post_counters() IS
    'ACTIVE 댓글만 post.comments_count 에 반영 (SOCIAL-02)';

CREATE TRIGGER trg_comment_post_counters
    AFTER INSERT OR UPDATE OF status OR DELETE ON comment
    FOR EACH ROW
    EXECUTE FUNCTION fn_comment_post_counters();

-- [SOCIAL-02] 삭제된 게시물에는 댓글/반응 금지, 삭제된 댓글에는 대댓글·좋아요 금지
CREATE OR REPLACE FUNCTION fn_reject_on_deleted_post()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM post WHERE id = NEW.post_id AND status = 'DELETED') THEN
        RAISE EXCEPTION 'SOCIAL-02: cannot react to deleted post %', NEW.post_id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_reject_comment_on_deleted_targets()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM post WHERE id = NEW.post_id AND status = 'DELETED') THEN
        RAISE EXCEPTION 'SOCIAL-02: cannot comment on deleted post %', NEW.post_id
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.parent_comment_id IS NOT NULL
       AND EXISTS (
           SELECT 1 FROM comment
           WHERE id = NEW.parent_comment_id AND status = 'DELETED'
       ) THEN
        RAISE EXCEPTION 'SOCIAL-02: cannot reply to deleted comment %', NEW.parent_comment_id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_reject_like_on_deleted_comment()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM comment WHERE id = NEW.comment_id AND status = 'DELETED') THEN
        RAISE EXCEPTION 'SOCIAL-02: cannot like deleted comment %', NEW.comment_id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_post_like_reject_deleted
    BEFORE INSERT ON post_like
    FOR EACH ROW
    EXECUTE FUNCTION fn_reject_on_deleted_post();

CREATE TRIGGER trg_comment_reject_deleted
    BEFORE INSERT ON comment
    FOR EACH ROW
    EXECUTE FUNCTION fn_reject_comment_on_deleted_targets();

-- comment_like / post_share 거부 트리거는 해당 테이블 생성 후 등록 (아래 4·5절)

-- ==============================================================
-- 4. comment_like — 댓글 좋아요 원장 (SOCIAL-01)
--
--   comment.likes_count 만 있고 원장이 없으면 재집계·중복 좋아요 방지가
--   불가능하다. post_like 와 동일하게 (comment_id, user_id) UNIQUE 원장을 두고
--   트리거로 카운터를 원자 증감한다.
-- ==============================================================
CREATE TABLE comment_like (
    id              BIGSERIAL PRIMARY KEY,
    comment_id      BIGINT NOT NULL,
    user_id         UUID NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_comment_like_comment_user UNIQUE (comment_id, user_id),
    CONSTRAINT fk_comment_like_comment
        FOREIGN KEY (comment_id) REFERENCES comment(id)
);

COMMENT ON TABLE comment_like IS
    '댓글 좋아요 원장. 사용자당 댓글 1회. comment.likes_count 의 Source of Truth (SOCIAL-01)';
COMMENT ON COLUMN comment_like.user_id IS
    'Logical reference to auth.account.id; no FK because of database-per-service boundary';

CREATE INDEX idx_comment_like_user_created
    ON comment_like (user_id, created_at DESC);

CREATE OR REPLACE FUNCTION fn_comment_like_counters()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE comment SET likes_count = likes_count + 1
        WHERE id = NEW.comment_id;
        RETURN NULL;
    ELSE
        UPDATE comment SET likes_count = likes_count - 1
        WHERE id = OLD.comment_id;
        RETURN NULL;
    END IF;
END;
$$;

COMMENT ON FUNCTION fn_comment_like_counters() IS
    'comment_like INSERT/DELETE 시 comment.likes_count 원자 증감 (SOCIAL-01)';

CREATE TRIGGER trg_comment_like_counters
    AFTER INSERT OR DELETE ON comment_like
    FOR EACH ROW
    EXECUTE FUNCTION fn_comment_like_counters();

CREATE TRIGGER trg_comment_like_reject_deleted
    BEFORE INSERT ON comment_like
    FOR EACH ROW
    EXECUTE FUNCTION fn_reject_like_on_deleted_comment();

-- ==============================================================
-- 5. post_share — 게시물 공유 원장 (SOCIAL-01)
--
--   post.share_count 만 있고 원장이 없으면 중복 공유 집계·재집계가 불가.
--   사용자당 게시물 1회 공유로 모델링 (UNIQUE). 채널별 재공유가 필요하면
--   UNIQUE 를 (post_id, user_id, channel) 로 확장한다.
-- ==============================================================
CREATE TABLE post_share (
    id              BIGSERIAL PRIMARY KEY,
    post_id         BIGINT NOT NULL,
    user_id         UUID NOT NULL,
    -- LINK, KAKAO, TWITTER, SYSTEM 등 (선택)
    channel         VARCHAR(30),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_post_share_post_user UNIQUE (post_id, user_id),
    CONSTRAINT fk_post_share_post
        FOREIGN KEY (post_id) REFERENCES post(id)
);

COMMENT ON TABLE post_share IS
    '게시물 공유 원장. 사용자당 게시물 1회. post.share_count 의 Source of Truth (SOCIAL-01)';
COMMENT ON COLUMN post_share.user_id IS
    'Logical reference to auth.account.id; no FK because of database-per-service boundary';
COMMENT ON COLUMN post_share.channel IS '공유 채널. 예: LINK, KAKAO, TWITTER';

CREATE INDEX idx_post_share_user_created
    ON post_share (user_id, created_at DESC);

CREATE OR REPLACE FUNCTION fn_post_share_counters()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE post SET share_count = share_count + 1
        WHERE id = NEW.post_id;
        RETURN NULL;
    ELSE
        UPDATE post SET share_count = share_count - 1
        WHERE id = OLD.post_id;
        RETURN NULL;
    END IF;
END;
$$;

COMMENT ON FUNCTION fn_post_share_counters() IS
    'post_share INSERT/DELETE 시 post.share_count 원자 증감 (SOCIAL-01)';

CREATE TRIGGER trg_post_share_counters
    AFTER INSERT OR DELETE ON post_share
    FOR EACH ROW
    EXECUTE FUNCTION fn_post_share_counters();

CREATE TRIGGER trg_post_share_reject_deleted
    BEFORE INSERT ON post_share
    FOR EACH ROW
    EXECUTE FUNCTION fn_reject_on_deleted_post();

-- ==============================================================
-- 6. hashtag — 해시태그 마스터
-- ==============================================================
CREATE TABLE hashtag (
    id                  BIGSERIAL PRIMARY KEY,
    tag                 VARCHAR(50) NOT NULL,
    normalized_tag      VARCHAR(50) NOT NULL,            -- 검색/중복 방지용 정규화 값
    category            VARCHAR(30),
    status              VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',  -- ACTIVE, BLOCKED, SPAM
    first_used_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used_at        TIMESTAMPTZ,

    CONSTRAINT uq_hashtag_tag UNIQUE (tag),
    CONSTRAINT uq_hashtag_normalized_tag UNIQUE (normalized_tag),
    CONSTRAINT ck_hashtag_status CHECK (status IN ('ACTIVE', 'BLOCKED', 'SPAM'))
);

COMMENT ON TABLE hashtag IS '해시태그 마스터. 트렌딩·연관 추천의 기준 엔티티';
COMMENT ON COLUMN hashtag.tag IS '사용자에게 보이는 원본 태그';
COMMENT ON COLUMN hashtag.normalized_tag IS '대소문자/공백 정규화 후 검색·중복 방지용 키';
COMMENT ON COLUMN hashtag.status IS 'ACTIVE, BLOCKED, SPAM';

CREATE INDEX idx_hashtag_status
    ON hashtag (status)
    WHERE status = 'ACTIVE';

-- ==============================================================
-- 7. post_hashtag — 게시물 ↔ 해시태그 N:M
-- ==============================================================
CREATE TABLE post_hashtag (
    post_id         BIGINT NOT NULL,
    hashtag_id      BIGINT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_post_hashtag PRIMARY KEY (post_id, hashtag_id),
    CONSTRAINT fk_post_hashtag_post
        FOREIGN KEY (post_id) REFERENCES post(id),
    CONSTRAINT fk_post_hashtag_hashtag
        FOREIGN KEY (hashtag_id) REFERENCES hashtag(id)
);

COMMENT ON TABLE post_hashtag IS '게시물과 해시태그의 N:M 매핑';

-- PK 가 post_id 선두이므로 해시태그별 게시물 역조회용 인덱스
CREATE INDEX idx_post_hashtag_hashtag_created
    ON post_hashtag (hashtag_id, created_at DESC);

-- ==============================================================
-- 8. hashtag_usage_hourly — 시간대별 해시태그 사용 집계 (트렌딩)
-- ==============================================================
CREATE TABLE hashtag_usage_hourly (
    hashtag_id          BIGINT NOT NULL,
    hour_bucket         TIMESTAMPTZ NOT NULL,             -- 해당 시각 구간의 시작 (시 단위)
    usage_count         INT NOT NULL DEFAULT 0,
    unique_users_count  INT NOT NULL DEFAULT 0,

    CONSTRAINT pk_hashtag_usage_hourly PRIMARY KEY (hashtag_id, hour_bucket),
    CONSTRAINT fk_hashtag_usage_hourly_hashtag
        FOREIGN KEY (hashtag_id) REFERENCES hashtag(id),
    CONSTRAINT ck_hashtag_usage_count CHECK (usage_count >= 0),
    CONSTRAINT ck_hashtag_unique_users_count CHECK (unique_users_count >= 0)
);

COMMENT ON TABLE hashtag_usage_hourly IS '트렌딩 해시태그용 시간대별 사용 집계';
COMMENT ON COLUMN hashtag_usage_hourly.hour_bucket IS '집계 구간 시작 시각 (시 단위 truncate)';
COMMENT ON COLUMN hashtag_usage_hourly.usage_count IS '해당 시간대 태그 사용 횟수';
COMMENT ON COLUMN hashtag_usage_hourly.unique_users_count IS
    '해당 시간대 고유 사용자 수(집계·근사). 정밀 distinct 원장 없이는 완벽하지 않음 (LOW-O6)';

CREATE INDEX idx_hashtag_usage_hourly_trending
    ON hashtag_usage_hourly (hour_bucket DESC, usage_count DESC);

-- ==============================================================
-- 9. hashtag_co_occurrence — 해시태그 동시 출현 (연관 추천)
-- ==============================================================
CREATE TABLE hashtag_co_occurrence (
    hashtag_id              BIGINT NOT NULL,
    related_hashtag_id      BIGINT NOT NULL,
    co_count                INT NOT NULL DEFAULT 0,
    last_calculated_at      TIMESTAMPTZ,

    CONSTRAINT pk_hashtag_co_occurrence PRIMARY KEY (hashtag_id, related_hashtag_id),
    CONSTRAINT fk_hashtag_co_occurrence_hashtag
        FOREIGN KEY (hashtag_id) REFERENCES hashtag(id),
    CONSTRAINT fk_hashtag_co_occurrence_related
        FOREIGN KEY (related_hashtag_id) REFERENCES hashtag(id),
    CONSTRAINT ck_hashtag_co_not_self CHECK (hashtag_id <> related_hashtag_id),
    CONSTRAINT ck_hashtag_co_count CHECK (co_count >= 0)
);

COMMENT ON TABLE hashtag_co_occurrence IS '관련 해시태그 추천용 동시 출현 집계';
COMMENT ON COLUMN hashtag_co_occurrence.co_count IS '두 해시태그가 함께 사용된 횟수';

CREATE INDEX idx_hashtag_co_occurrence_rank
    ON hashtag_co_occurrence (hashtag_id, co_count DESC);
