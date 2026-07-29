-- ==============================================================
-- fashion-service 초기 스키마
--
-- 브랜드·OOTD·상품 태그·좋아요·댓글
--
-- 설계 원칙:
--   - Database-per-Service: cross-service ID 는 FK 없이 COMMENT 로 논리 참조
--   - 같은 서비스 내 FK 만 생성
-- [BOUNDARY-02] OOTD 좋아요·댓글(ootd_like, ootd_comment)은 fashion 소유.
--   social 의 post/comment/post_like 는 일반 피드 전용 — OOTD 반응 API 는 fashion 만.
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
-- 1. brand — 패션 브랜드 마스터
-- ==============================================================
CREATE TABLE brand (
    id              BIGSERIAL PRIMARY KEY,
    name            VARCHAR(100) NOT NULL,
    description     TEXT,
    logo_url        VARCHAR(500),                       -- media-service 가 생성한 URL snapshot
    verified        BOOLEAN NOT NULL DEFAULT FALSE,
    follower_count  INT NOT NULL DEFAULT 0,
    ootd_count      INT NOT NULL DEFAULT 0,
    -- [LOW-O2] commerce.product.brand_id 논리 참조 — hard delete 대신 DEPRECATED
    status          VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_brand_name UNIQUE (name),
    CONSTRAINT ck_brand_follower_count CHECK (follower_count >= 0),
    CONSTRAINT ck_brand_ootd_count CHECK (ootd_count >= 0),
    CONSTRAINT ck_brand_status CHECK (status IN ('ACTIVE', 'DEPRECATED'))
);

COMMENT ON TABLE brand IS '패션 브랜드 마스터. commerce.product.brand_id 가 논리 참조함';
COMMENT ON COLUMN brand.logo_url IS 'media-service 가 생성한 로고 URL snapshot (cross-service FK 없음)';
COMMENT ON COLUMN brand.follower_count IS
    '비정규화 팔로워 수. 원본은 brand_follow (트리거 원자 증감, FASHION-01)';
COMMENT ON COLUMN brand.ootd_count IS
    '비정규화 ACTIVE OOTD 연관 수. 원본은 ootd_brand (트리거, FASHION-01)';
COMMENT ON COLUMN brand.status IS
    'ACTIVE | DEPRECATED. 삭제 대신 비활성화해 commerce 논리 참조 고아 방지 (LOW-O2)';

-- ==============================================================
-- 2. brand_follow — 브랜드 팔로우
-- ==============================================================
CREATE TABLE brand_follow (
    id              BIGSERIAL PRIMARY KEY,
    user_id         UUID NOT NULL,
    brand_id        BIGINT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_brand_follow_user_brand UNIQUE (user_id, brand_id),
    CONSTRAINT fk_brand_follow_brand
        FOREIGN KEY (brand_id) REFERENCES brand(id)
);

COMMENT ON TABLE brand_follow IS '사용자가 브랜드를 팔로우하는 관계';
COMMENT ON COLUMN brand_follow.user_id IS 'Logical reference to auth.account.id; no FK because of database-per-service boundary';
COMMENT ON COLUMN brand_follow.brand_id IS '내부 FK → brand.id';

CREATE INDEX idx_brand_follow_brand_created
    ON brand_follow (brand_id, created_at DESC);

-- [LOW-O3] 사용자별 팔로우 브랜드 목록(최신순). UNIQUE(user_id, brand_id) 접두만으로는 비효율적일 수 있음.
CREATE INDEX idx_brand_follow_user_created
    ON brand_follow (user_id, created_at DESC);

-- brand_follow → brand.follower_count (FASHION-01)
CREATE OR REPLACE FUNCTION fn_brand_follow_counters()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE brand
        SET follower_count = follower_count + 1,
            updated_at = NOW()
        WHERE id = NEW.brand_id;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE brand
        SET follower_count = follower_count - 1,
            updated_at = NOW()
        WHERE id = OLD.brand_id;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_brand_follow_counters
    AFTER INSERT OR DELETE ON brand_follow
    FOR EACH ROW
    EXECUTE FUNCTION fn_brand_follow_counters();

-- ==============================================================
-- 3. ootd — Outfit Of The Day 게시물
-- ==============================================================
CREATE TABLE ootd (
    id                  BIGSERIAL PRIMARY KEY,
    author_id           UUID NOT NULL,
    title               VARCHAR(200) NOT NULL,
    description         TEXT,
    style_tags          JSONB,                          -- 예: ["casual","street","minimal"]
    season              VARCHAR(20),                    -- SPRING, SUMMER, FALL, WINTER
    likes_count         INT NOT NULL DEFAULT 0,
    view_count          BIGINT NOT NULL DEFAULT 0,
    comment_count       INT NOT NULL DEFAULT 0,
    engagement_score    DECIMAL(10, 4) NOT NULL DEFAULT 0,  -- 추천/피드용 알고리즘 점수
    status              VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    -- [SOCIAL-02] soft-delete 시각. status=DELETED 와 쌍
    deleted_at          TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT ck_ootd_likes_count CHECK (likes_count >= 0),
    CONSTRAINT ck_ootd_view_count CHECK (view_count >= 0),
    CONSTRAINT ck_ootd_comment_count CHECK (comment_count >= 0),
    CONSTRAINT ck_ootd_engagement_score CHECK (engagement_score >= 0),
    CONSTRAINT ck_ootd_status CHECK (status IN ('ACTIVE', 'HIDDEN', 'DELETED')),
    -- [LOW-O4] season 코드 정규화 (NULL 허용)
    CONSTRAINT ck_ootd_season CHECK (
        season IS NULL OR season IN ('SPRING', 'SUMMER', 'FALL', 'WINTER')
    ),
    CONSTRAINT ck_ootd_deleted_at CHECK (
        (status = 'DELETED') = (deleted_at IS NOT NULL)
    )
);

COMMENT ON TABLE ootd IS 'OOTD(Outfit Of The Day) 게시물. recommendation/social 이 논리 참조할 수 있음';
COMMENT ON COLUMN ootd.author_id IS 'Logical reference to auth.account.id; no FK because of database-per-service boundary';
COMMENT ON COLUMN ootd.style_tags IS
    '임시 JSON 태그 캐시. 정규 style_tag N:M 은 관리 UI 도입 시 추가 예정 (FASHION-01)';
COMMENT ON COLUMN ootd.season IS '시즌 코드: SPRING, SUMMER, FALL, WINTER';
COMMENT ON COLUMN ootd.engagement_score IS '알고리즘용 참여 점수 (좋아요/조회/댓글 기반)';
COMMENT ON COLUMN ootd.likes_count IS '비정규화 좋아요 수 (ootd_like 집계)';
COMMENT ON COLUMN ootd.comment_count IS
    '비정규화 활성 댓글 수. status=ACTIVE 댓글만 집계 (SOCIAL-02)';
COMMENT ON COLUMN ootd.deleted_at IS
    'soft-delete 시각. status=DELETED 일 때만 NOT NULL (SOCIAL-02)';

CREATE INDEX idx_ootd_author_created
    ON ootd (author_id, created_at DESC);

CREATE INDEX idx_ootd_status_engagement
    ON ootd (status, engagement_score DESC);

CREATE INDEX idx_ootd_active_engagement
    ON ootd (engagement_score DESC, created_at DESC)
    WHERE status = 'ACTIVE';

-- ==============================================================
-- 3b. ootd_brand — OOTD ↔ 브랜드 연관 (FASHION-01)
--
-- brand.ootd_count 의 원장. ACTIVE OOTD 연결만 집계(soft-delete 시 감소).
-- 앱은 ootd_brand 만 INSERT/DELETE — brand.ootd_count 직접 갱신 금지.
-- ==============================================================
CREATE TABLE ootd_brand (
    ootd_id         BIGINT NOT NULL,
    brand_id        BIGINT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_ootd_brand PRIMARY KEY (ootd_id, brand_id),
    CONSTRAINT fk_ootd_brand_ootd
        FOREIGN KEY (ootd_id) REFERENCES ootd (id),
    CONSTRAINT fk_ootd_brand_brand
        FOREIGN KEY (brand_id) REFERENCES brand (id)
);

COMMENT ON TABLE ootd_brand IS
    'OOTD 에 태그된 브랜드. brand.ootd_count 집계 원본 (FASHION-01)';
COMMENT ON COLUMN ootd_brand.ootd_id IS '내부 FK → ootd.id';
COMMENT ON COLUMN ootd_brand.brand_id IS '내부 FK → brand.id';

CREATE INDEX idx_ootd_brand_brand
    ON ootd_brand (brand_id, created_at DESC);

-- ==============================================================
-- 4. ootd_image — OOTD 이미지
-- ==============================================================
CREATE TABLE ootd_image (
    id              BIGSERIAL PRIMARY KEY,
    ootd_id         BIGINT NOT NULL,
    -- 논리 참조: media-service.media_asset.id (cross-service FK 없음)
    media_asset_id  BIGINT NOT NULL,
    image_url       VARCHAR(500) NOT NULL,
    display_order   INT NOT NULL,

    CONSTRAINT fk_ootd_image_ootd
        FOREIGN KEY (ootd_id) REFERENCES ootd(id),
    CONSTRAINT uq_ootd_image_order UNIQUE (ootd_id, display_order),
    CONSTRAINT ck_ootd_image_display_order CHECK (display_order >= 0)
);

COMMENT ON TABLE ootd_image IS 'OOTD 에 첨부된 이미지 목록 (MEDIA-01: asset id + URL 스냅샷)';
COMMENT ON COLUMN ootd_image.media_asset_id IS
    '논리 참조: media-service.media_asset.id. attach 시 media_usage(OOTD) 필수';
COMMENT ON COLUMN ootd_image.image_url IS
    'attach 시점 public_url 스냅샷 (media-service 가 발급한 URL)';
COMMENT ON COLUMN ootd_image.display_order IS '동일 OOTD 내 노출 순서 (0부터)';

CREATE INDEX idx_ootd_image_ootd
    ON ootd_image (ootd_id, display_order);

-- ==============================================================
-- 5. product_tag — OOTD 이미지 위 상품 태그 (Fashion → Commerce 협업)
-- ==============================================================
CREATE TABLE product_tag (
    id              BIGSERIAL PRIMARY KEY,
    ootd_id         BIGINT NOT NULL,
    product_id      BIGINT NOT NULL,
    image_id        BIGINT,
    position_x      DECIMAL(5, 2),                      -- 이미지 가로 좌표 (0~100 %)
    position_y      DECIMAL(5, 2),                      -- 이미지 세로 좌표 (0~100 %)
    click_count     INT NOT NULL DEFAULT 0,
    purchase_count  INT NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_product_tag_ootd
        FOREIGN KEY (ootd_id) REFERENCES ootd(id),
    CONSTRAINT fk_product_tag_image
        FOREIGN KEY (image_id) REFERENCES ootd_image(id),
    CONSTRAINT ck_product_tag_position_x
        CHECK (position_x IS NULL OR (position_x >= 0 AND position_x <= 100)),
    CONSTRAINT ck_product_tag_position_y
        CHECK (position_y IS NULL OR (position_y >= 0 AND position_y <= 100)),
    CONSTRAINT ck_product_tag_click_count CHECK (click_count >= 0),
    CONSTRAINT ck_product_tag_purchase_count CHECK (purchase_count >= 0)
);

COMMENT ON TABLE product_tag IS 'OOTD 이미지 위에 붙는 상품 태그. Fashion → Commerce cross-domain 협업';
COMMENT ON COLUMN product_tag.product_id IS 'Logical reference to commerce.product.id; no FK because of database-per-service boundary';
COMMENT ON COLUMN product_tag.image_id IS '내부 FK → ootd_image.id (어느 이미지에 태그가 붙는지)';
COMMENT ON COLUMN product_tag.position_x IS '이미지 가로 위치 백분율 (0~100)';
COMMENT ON COLUMN product_tag.position_y IS '이미지 세로 위치 백분율 (0~100)';

CREATE INDEX idx_product_tag_ootd
    ON product_tag (ootd_id);

CREATE INDEX idx_product_tag_product
    ON product_tag (product_id);

CREATE INDEX idx_product_tag_image
    ON product_tag (image_id)
    WHERE image_id IS NOT NULL;

-- ==============================================================
-- 6. ootd_like — OOTD 좋아요 (BOUNDARY-02: fashion 전용, social.post_like 와 분리)
-- ==============================================================
CREATE TABLE ootd_like (
    id              BIGSERIAL PRIMARY KEY,
    ootd_id         BIGINT NOT NULL,
    user_id         UUID NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_ootd_like_ootd_user UNIQUE (ootd_id, user_id),
    CONSTRAINT fk_ootd_like_ootd
        FOREIGN KEY (ootd_id) REFERENCES ootd(id)
);

COMMENT ON TABLE ootd_like IS
    'OOTD 좋아요 원장 (BOUNDARY-02). social.post_like 와 별개 — fashion API 만';
COMMENT ON COLUMN ootd_like.user_id IS 'Logical reference to auth.account.id; no FK because of database-per-service boundary';

CREATE INDEX idx_ootd_like_user_created
    ON ootd_like (user_id, created_at DESC);

-- ==============================================================
-- 7. ootd_comment — OOTD 댓글 (BOUNDARY-02: fashion 전용, 대댓글 지원)
--
-- [SOCIAL-02] social.comment 와 동일 계약:
--   soft-delete(status/deleted_at) + 부모는 같은 ootd_id 만 허용하는 복합 FK.
-- ==============================================================
CREATE TABLE ootd_comment (
    id                  BIGSERIAL PRIMARY KEY,
    ootd_id             BIGINT NOT NULL,
    author_id           UUID NOT NULL,
    parent_comment_id   BIGINT,
    content             TEXT NOT NULL,
    status              VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    deleted_at          TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_ootd_comment_id_ootd UNIQUE (id, ootd_id),
    CONSTRAINT fk_ootd_comment_ootd
        FOREIGN KEY (ootd_id) REFERENCES ootd(id),
    CONSTRAINT fk_ootd_comment_parent_same_ootd
        FOREIGN KEY (parent_comment_id, ootd_id)
            REFERENCES ootd_comment (id, ootd_id),
    CONSTRAINT ck_ootd_comment_not_self
        CHECK (parent_comment_id IS NULL OR parent_comment_id <> id),
    CONSTRAINT ck_ootd_comment_status CHECK (
        status IN ('ACTIVE', 'HIDDEN', 'DELETED')
    ),
    CONSTRAINT ck_ootd_comment_deleted_at CHECK (
        (status = 'DELETED') = (deleted_at IS NOT NULL)
    )
);

COMMENT ON TABLE ootd_comment IS
    'OOTD 댓글 원장 (BOUNDARY-02). social.comment 는 post 전용';
COMMENT ON COLUMN ootd_comment.author_id IS
    'Logical reference to auth.account.id; no FK because of database-per-service boundary';
COMMENT ON COLUMN ootd_comment.parent_comment_id IS
    '부모 댓글. 복합 FK 로 같은 ootd_id 강제. NULL 이면 최상위';
COMMENT ON COLUMN ootd_comment.status IS 'ACTIVE, HIDDEN, DELETED';
COMMENT ON COLUMN ootd_comment.deleted_at IS
    'soft-delete 시각. status=DELETED 일 때만 NOT NULL';

CREATE INDEX idx_ootd_comment_ootd_created
    ON ootd_comment (ootd_id, created_at)
    WHERE status = 'ACTIVE';

CREATE INDEX idx_ootd_comment_parent
    ON ootd_comment (parent_comment_id)
    WHERE parent_comment_id IS NOT NULL;

CREATE INDEX idx_ootd_comment_author_created
    ON ootd_comment (author_id, created_at DESC);

-- [SOCIAL-02] ACTIVE 댓글만 ootd.comment_count 반영
CREATE OR REPLACE FUNCTION fn_ootd_comment_counters()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status = 'ACTIVE' THEN
            UPDATE ootd SET comment_count = comment_count + 1 WHERE id = NEW.ootd_id;
        END IF;
        RETURN NULL;
    ELSIF TG_OP = 'UPDATE' THEN
        IF OLD.status = 'ACTIVE' AND NEW.status IS DISTINCT FROM 'ACTIVE' THEN
            UPDATE ootd SET comment_count = comment_count - 1 WHERE id = OLD.ootd_id;
        ELSIF OLD.status IS DISTINCT FROM 'ACTIVE' AND NEW.status = 'ACTIVE' THEN
            UPDATE ootd SET comment_count = comment_count + 1 WHERE id = NEW.ootd_id;
        END IF;
        RETURN NULL;
    ELSE
        IF OLD.status = 'ACTIVE' THEN
            UPDATE ootd SET comment_count = comment_count - 1 WHERE id = OLD.ootd_id;
        END IF;
        RETURN NULL;
    END IF;
END;
$$;

CREATE TRIGGER trg_ootd_comment_counters
    AFTER INSERT OR UPDATE OF status OR DELETE ON ootd_comment
    FOR EACH ROW
    EXECUTE FUNCTION fn_ootd_comment_counters();

CREATE OR REPLACE FUNCTION fn_reject_on_deleted_ootd()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM ootd WHERE id = NEW.ootd_id AND status = 'DELETED') THEN
        RAISE EXCEPTION 'SOCIAL-02: cannot react to deleted ootd %', NEW.ootd_id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_reject_ootd_comment_on_deleted()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM ootd WHERE id = NEW.ootd_id AND status = 'DELETED') THEN
        RAISE EXCEPTION 'SOCIAL-02: cannot comment on deleted ootd %', NEW.ootd_id
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.parent_comment_id IS NOT NULL
       AND EXISTS (
           SELECT 1 FROM ootd_comment
           WHERE id = NEW.parent_comment_id AND status = 'DELETED'
       ) THEN
        RAISE EXCEPTION 'SOCIAL-02: cannot reply to deleted ootd comment %', NEW.parent_comment_id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_ootd_like_reject_deleted
    BEFORE INSERT ON ootd_like
    FOR EACH ROW
    EXECUTE FUNCTION fn_reject_on_deleted_ootd();

CREATE TRIGGER trg_ootd_comment_reject_deleted
    BEFORE INSERT ON ootd_comment
    FOR EACH ROW
    EXECUTE FUNCTION fn_reject_ootd_comment_on_deleted();

-- [FASHION-01] ootd_brand ↔ brand.ootd_count
CREATE OR REPLACE FUNCTION fn_ootd_brand_counters()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_brand_id BIGINT;
    v_ootd_id  BIGINT;
    v_active   BOOLEAN;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_brand_id := NEW.brand_id;
        v_ootd_id := NEW.ootd_id;
        SELECT (status = 'ACTIVE') INTO v_active FROM ootd WHERE id = v_ootd_id;
        IF v_active THEN
            UPDATE brand
            SET ootd_count = ootd_count + 1, updated_at = NOW()
            WHERE id = v_brand_id;
        END IF;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        v_brand_id := OLD.brand_id;
        v_ootd_id := OLD.ootd_id;
        SELECT (status = 'ACTIVE') INTO v_active FROM ootd WHERE id = v_ootd_id;
        IF v_active THEN
            UPDATE brand
            SET ootd_count = ootd_count - 1, updated_at = NOW()
            WHERE id = v_brand_id;
        END IF;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION fn_ootd_status_brand_counters()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
        RETURN NEW;
    END IF;
    IF OLD.status = 'ACTIVE' AND NEW.status IS DISTINCT FROM 'ACTIVE' THEN
        UPDATE brand b
        SET ootd_count = b.ootd_count - 1,
            updated_at = NOW()
        FROM ootd_brand ob
        WHERE ob.ootd_id = NEW.id AND ob.brand_id = b.id;
    ELSIF OLD.status IS DISTINCT FROM 'ACTIVE' AND NEW.status = 'ACTIVE' THEN
        UPDATE brand b
        SET ootd_count = b.ootd_count + 1,
            updated_at = NOW()
        FROM ootd_brand ob
        WHERE ob.ootd_id = NEW.id AND ob.brand_id = b.id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION reconcile_brand_ootd_counters()
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    fixed INT;
BEGIN
    UPDATE brand b
    SET ootd_count = agg.cnt,
        updated_at = NOW()
    FROM (
        SELECT b2.id AS brand_id,
               COALESCE(active_links.cnt, 0) AS cnt
        FROM brand b2
        LEFT JOIN (
            SELECT ob.brand_id, COUNT(*) AS cnt
            FROM ootd_brand ob
            INNER JOIN ootd o ON o.id = ob.ootd_id AND o.status = 'ACTIVE'
            GROUP BY ob.brand_id
        ) active_links ON active_links.brand_id = b2.id
    ) agg
    WHERE b.id = agg.brand_id
      AND b.ootd_count IS DISTINCT FROM agg.cnt;

    GET DIAGNOSTICS fixed = ROW_COUNT;
    RETURN fixed;
END;
$$;

COMMENT ON FUNCTION reconcile_brand_ootd_counters() IS
    'ootd_brand·ACTIVE ootd 기준으로 brand.ootd_count 재집계 (FASHION-01)';

CREATE TRIGGER trg_ootd_brand_counters
    AFTER INSERT OR DELETE ON ootd_brand
    FOR EACH ROW
    EXECUTE FUNCTION fn_ootd_brand_counters();

CREATE TRIGGER trg_ootd_status_brand_counters
    AFTER UPDATE OF status ON ootd
    FOR EACH ROW
    EXECUTE FUNCTION fn_ootd_status_brand_counters();

CREATE TRIGGER trg_ootd_brand_reject_deleted
    BEFORE INSERT ON ootd_brand
    FOR EACH ROW
    EXECUTE FUNCTION fn_reject_on_deleted_ootd();
