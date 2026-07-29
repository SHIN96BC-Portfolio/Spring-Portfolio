-- ==============================================================
-- media-service 초기 스키마
--
-- ERD: media_asset, media_usage
--
-- 주의:
--   - owner_user_id, media_usage.resource_id 는 cross-service 논리 참조 (FK 금지)
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
-- 1. 미디어 자산 (S3 원본/파생 메타데이터)
--
-- [MEDIA-01] 소비 서비스는 URL만 저장하면 orphan 정리·참조 중 삭제 방지가
-- 불가능하다. 각 서비스는 media_asset.id 를 논리 참조로 함께 저장하고,
-- attach 시 media_usage 를 등록·detach 시 released_at 으로 해제한다.
-- ==============================================================
CREATE TABLE media_asset (
    id                  BIGSERIAL PRIMARY KEY,
    -- 논리 참조: auth.account.id
    owner_user_id       UUID         NOT NULL,
    original_filename   VARCHAR(255),
    -- 스토리지 오브젝트 키 (버킷 내 유일)
    s3_key              VARCHAR(500) NOT NULL,
    public_url          VARCHAR(500),
    mime_type           VARCHAR(50),
    size_bytes          BIGINT,
    width               INT,
    height              INT,
    -- 예: {"small":"...","medium":"...","large":"..."}
    thumbnail_urls      JSONB,
    status              VARCHAR(20)  NOT NULL DEFAULT 'UPLOADING',
    created_at          TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    deleted_at          TIMESTAMPTZ,

    CONSTRAINT uq_media_asset_s3_key UNIQUE (s3_key),
    CONSTRAINT chk_media_asset_size_nonneg
        CHECK (size_bytes IS NULL OR size_bytes >= 0),
    CONSTRAINT chk_media_asset_width_nonneg
        CHECK (width IS NULL OR width >= 0),
    CONSTRAINT chk_media_asset_height_nonneg
        CHECK (height IS NULL OR height >= 0),
    CONSTRAINT chk_media_asset_status CHECK (
        status IN ('UPLOADING', 'PROCESSING', 'READY', 'DELETED')
    ),
    CONSTRAINT chk_media_asset_deleted_at CHECK (
        (status = 'DELETED') = (deleted_at IS NOT NULL)
    )
);

COMMENT ON TABLE media_asset IS
    '업로드된 미디어 자산. 소비 서비스는 id+URL 스냅샷과 media_usage 등록을 함께 사용(MEDIA-01)';
COMMENT ON COLUMN media_asset.owner_user_id IS
    '논리 참조: auth.account.id (database-per-service 경계로 FK 없음)';
COMMENT ON COLUMN media_asset.s3_key IS '객체 스토리지 키. UNIQUE — 동일 키 중복 업로드 방지';
COMMENT ON COLUMN media_asset.public_url IS
    'CDN/공개 URL. 소비 서비스에 복사해 두는 스냅샷의 출처';
COMMENT ON COLUMN media_asset.thumbnail_urls IS '해상도별 썸네일 URL JSON (small/medium/large 등)';
COMMENT ON COLUMN media_asset.status IS 'UPLOADING, PROCESSING, READY, DELETED';
COMMENT ON COLUMN media_asset.deleted_at IS
    'soft-delete 시각. status=DELETED 일 때만 NOT NULL. 활성 usage 가 있으면 삭제 불가';

CREATE INDEX idx_media_asset_owner_created
    ON media_asset (owner_user_id, created_at DESC);

-- 업로드/변환 워커 대상
CREATE INDEX idx_media_asset_processing
    ON media_asset (status, created_at)
    WHERE status IN ('UPLOADING', 'PROCESSING');

-- 삭제 정리 배치
CREATE INDEX idx_media_asset_deleted
    ON media_asset (deleted_at)
    WHERE deleted_at IS NOT NULL;

-- ==============================================================
-- 2. media_usage — 미디어 사용처 등록/해제 원장
--
-- attach: INSERT (released_at NULL). READY 상태 asset 만 허용(트리거).
-- detach: UPDATE released_at = NOW() (행 보존 → 감사/재attach 이력).
-- 활성 usage 가 있는 asset 은 soft-delete 불가(트리거).
-- ==============================================================
CREATE TABLE media_usage (
    id                  BIGSERIAL PRIMARY KEY,
    asset_id            BIGINT       NOT NULL,
    -- OOTD, POST, AVATAR, PRODUCT, BRAND_LOGO, BANNER
    usage_type          VARCHAR(20)  NOT NULL,
    -- 논리 참조: usage_type 별 외부 서비스 리소스 ID
    resource_id         VARCHAR(100) NOT NULL,
    created_at          TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    released_at         TIMESTAMPTZ,

    CONSTRAINT fk_media_usage_asset
        FOREIGN KEY (asset_id) REFERENCES media_asset (id),
    CONSTRAINT chk_media_usage_type CHECK (
        usage_type IN ('OOTD', 'POST', 'AVATAR', 'PRODUCT', 'BRAND_LOGO', 'BANNER')
    )
);

COMMENT ON TABLE media_usage IS
    '미디어 attach/detach 원장. 활성(released_at NULL) usage 가 있으면 asset 삭제 차단(MEDIA-01)';
COMMENT ON COLUMN media_usage.asset_id IS '내부 FK → media_asset.id';
COMMENT ON COLUMN media_usage.usage_type IS
    'OOTD, POST, AVATAR, PRODUCT, BRAND_LOGO, BANNER — 소비 서비스 attach API 와 1:1';
COMMENT ON COLUMN media_usage.resource_id IS
    '논리 참조: usage_type 별 외부 리소스 ID (fashion/social/user/content 등, FK 없음)';
COMMENT ON COLUMN media_usage.released_at IS
    'detach 시각. NULL 이면 활성 usage. 해제 후에도 행은 보존';

-- 활성 usage 만 유일 — 같은 attach 재시도는 UNIQUE 위반으로 멱등 처리
CREATE UNIQUE INDEX uq_media_usage_active
    ON media_usage (asset_id, usage_type, resource_id)
    WHERE released_at IS NULL;

CREATE INDEX idx_media_usage_asset_active
    ON media_usage (asset_id)
    WHERE released_at IS NULL;

CREATE INDEX idx_media_usage_type_resource
    ON media_usage (usage_type, resource_id);

-- READY 가 아닌 asset 에 usage 등록 금지
CREATE OR REPLACE FUNCTION fn_media_usage_reject_not_ready()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM media_asset
        WHERE id = NEW.asset_id AND status = 'READY'
    ) THEN
        RAISE EXCEPTION 'MEDIA-01: cannot attach usage to non-READY asset %', NEW.asset_id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

-- 활성 usage 가 남아 있으면 asset soft-delete 금지
CREATE OR REPLACE FUNCTION fn_media_asset_reject_delete_with_usage()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status = 'DELETED'
       AND OLD.status IS DISTINCT FROM 'DELETED'
       AND EXISTS (
           SELECT 1 FROM media_usage
           WHERE asset_id = NEW.id AND released_at IS NULL
       ) THEN
        RAISE EXCEPTION 'MEDIA-01: cannot delete asset % with active usages', NEW.id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_media_usage_reject_not_ready
    BEFORE INSERT ON media_usage
    FOR EACH ROW
    EXECUTE FUNCTION fn_media_usage_reject_not_ready();

CREATE TRIGGER trg_media_asset_reject_delete_with_usage
    BEFORE UPDATE OF status, deleted_at ON media_asset
    FOR EACH ROW
    EXECUTE FUNCTION fn_media_asset_reject_delete_with_usage();
