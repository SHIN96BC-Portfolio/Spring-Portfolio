-- ==============================================================
-- content-service 초기 스키마
--
-- CMS: GNB(내비게이션), 배너, 정적 페이지, 홈 섹션 구성
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

-- Idempotency (Consumer 멱등성)
-- [COMMON-01] event_id 단독 PK 는 동일 DB 의 서로 다른 consumer group 이
--   같은 이벤트를 처리하지 못하게 한다. (event_id, consumer_group) 복합 PK.
CREATE TABLE processed_events (
    event_id        UUID NOT NULL,
    consumer_group  VARCHAR(100) NOT NULL,
    processed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_processed_events PRIMARY KEY (event_id, consumer_group)
);

COMMENT ON TABLE processed_events IS
    'Kafka 소비 멱등 원장. PK (event_id, consumer_group) — 그룹별 1회 처리 (COMMON-01). '
    'content 도메인 Kafka 구독·발행 이벤트는 카탈로그 확정 전까지 테이블만 유지 (LOW-CM-6)';
COMMENT ON COLUMN processed_events.event_id IS
    'DomainEvent.eventId (Kafka 메시지와 동일 값 권장)';
COMMENT ON COLUMN processed_events.consumer_group IS
    'Kafka consumer group id (예: spring.kafka.consumer.group-id)';

-- ==============================================================
-- CMS 도메인 테이블
--
-- [CMS-01] Admin 이 본문을 수정할 때 단일 body 를 덮으면 게시본이 사라져
--   preview API 가 불가능하다. draft_* (편집·미리보기) 와 published_*
--   (공개 API) 를 분리하고 publish 시 스냅샷 복사 + version 증가.
--
-- [CMS-02] 포트폴리오 About/Career/Projects 등 페이지별 섹션을 구분하지 않으면
--   display_order 충돌·FE 컴포넌트 매핑(PROJECT_GRID 등)이 깨진다.
--   page_key + section_key 로 슬롯을 고정하고, page_key 내 display_order 는 UNIQUE.
-- [CMS-03] locale: FE [lang] 라우트·API ?lang= 와 동일 (ko, en, ja).
--   page_key·section_key·slug 등은 locale 별로 분리 저장.
-- ==============================================================

-- GNB / 내비게이션 메뉴 (계층 구조)
CREATE TABLE navigation_menu (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    parent_id       UUID REFERENCES navigation_menu(id),
    name            VARCHAR(100) NOT NULL,
    link_url        VARCHAR(500),
    display_order   INT NOT NULL DEFAULT 0,
    locale          VARCHAR(10) NOT NULL DEFAULT 'ko',
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    starts_at       TIMESTAMPTZ,
    ends_at         TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_navigation_menu_parent ON navigation_menu(parent_id);

COMMENT ON TABLE navigation_menu IS 'GNB/내비게이션 메뉴 (계층 구조, parent_id 자기참조)';
COMMENT ON COLUMN navigation_menu.parent_id IS '상위 메뉴. NULL이면 루트. 내부 FK → navigation_menu.id';
COMMENT ON COLUMN navigation_menu.name IS '메뉴 표시명';
COMMENT ON COLUMN navigation_menu.link_url IS '이동 URL (외부/내부 경로)';
COMMENT ON COLUMN navigation_menu.display_order IS '동일 parent 내 노출 순서 (작을수록 우선)';
COMMENT ON COLUMN navigation_menu.is_active IS '활성 여부';
COMMENT ON COLUMN navigation_menu.starts_at IS '노출 시작 시각 (NULL이면 즉시)';
COMMENT ON COLUMN navigation_menu.ends_at IS '노출 종료 시각 (NULL이면 무기한)';
COMMENT ON COLUMN navigation_menu.locale IS '콘텐츠 언어 코드 (ko, en, ja). FE lang·API lang 과 동일';

-- 배너 (홈/이벤트 등 슬롯별 노출)
CREATE TABLE banner (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slot            VARCHAR(50) NOT NULL,          -- 예: HOME_MAIN, HOME_SUB
    title           VARCHAR(200) NOT NULL,
    -- 논리 참조: media-service.media_asset.id (cross-service FK 없음)
    media_asset_id  BIGINT NOT NULL,
    image_url       VARCHAR(500) NOT NULL,
    link_url        VARCHAR(500),
    display_order   INT NOT NULL DEFAULT 0,
    locale          VARCHAR(10) NOT NULL DEFAULT 'ko',
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    starts_at       TIMESTAMPTZ,
    ends_at         TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_banner_slot ON banner(slot, display_order);

COMMENT ON TABLE banner IS '홈/이벤트 등 슬롯별 배너';
COMMENT ON COLUMN banner.slot IS '배너 슬롯 코드. 예: HOME_MAIN, HOME_SUB';
COMMENT ON COLUMN banner.title IS '배너 제목';
COMMENT ON COLUMN banner.media_asset_id IS
    '논리 참조: media-service.media_asset.id. attach 시 media_usage(BANNER) 필수 (MEDIA-01)';
COMMENT ON COLUMN banner.image_url IS
    'attach 시점 public_url 스냅샷 (CDN 변경 후에도 CMS 노출용)';
COMMENT ON COLUMN banner.link_url IS '클릭 시 이동 URL';
COMMENT ON COLUMN banner.display_order IS '동일 slot 내 노출 순서';
COMMENT ON COLUMN banner.is_active IS '활성 여부';
COMMENT ON COLUMN banner.starts_at IS '노출 시작 시각';
COMMENT ON COLUMN banner.ends_at IS '노출 종료 시각';
COMMENT ON COLUMN banner.locale IS '콘텐츠 언어 코드 (ko, en, ja)';

-- 정적 페이지 (소개, 약관, FAQ 등)
CREATE TABLE static_page (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slug                VARCHAR(100) NOT NULL,
    -- Admin·FE 고정 페이지 식별 (단일 markdown 페이지). NULL 이면 slug 만 사용
    page_key            VARCHAR(50),
    locale              VARCHAR(10) NOT NULL DEFAULT 'ko',
    -- Admin 편집·preview (항상 최신 초안)
    draft_title         VARCHAR(200) NOT NULL,
    draft_body          TEXT NOT NULL,
    -- 공개 API 스냅샷 (publish 전 NULL)
    published_title     VARCHAR(200),
    published_body      TEXT,
    version             INT NOT NULL DEFAULT 0,
    is_published        BOOLEAN NOT NULL DEFAULT FALSE,
    published_at        TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_static_page_slug_locale UNIQUE (slug, locale),
    CONSTRAINT uq_static_page_page_key_locale UNIQUE (page_key, locale),
    CONSTRAINT chk_static_page_locale CHECK (locale IN ('ko', 'en', 'ja')),
    CONSTRAINT chk_static_page_page_key CHECK (
        page_key IS NULL
        OR page_key IN ('ABOUT', 'CAREER', 'TERMS', 'PRIVACY', 'FAQ')
    ),
    CONSTRAINT chk_static_page_version_nonneg
        CHECK (version >= 0),
    CONSTRAINT chk_static_page_published_version
        CHECK (NOT is_published OR version >= 1),
    CONSTRAINT chk_static_page_published_snapshot CHECK (
        NOT is_published
        OR (
            published_title IS NOT NULL
            AND published_body IS NOT NULL
            AND published_at IS NOT NULL
        )
    )
);

COMMENT ON TABLE static_page IS
    '정적 CMS 페이지. draft=미리보기, published=공개 (CMS-01)';
COMMENT ON COLUMN static_page.slug IS 'URL 경로 식별자. locale 과 함께 UNIQUE. 예: about, terms';
COMMENT ON COLUMN static_page.page_key IS
    '포트폴리오 고정 페이지 코드 (CMS-02). 예: ABOUT, CAREER. NULL 허용';
COMMENT ON COLUMN static_page.draft_title IS '편집 중 제목. Admin preview API 가 반환';
COMMENT ON COLUMN static_page.draft_body IS '편집 중 본문 (Markdown/HTML). Admin preview';
COMMENT ON COLUMN static_page.published_title IS '게시 스냅샷 제목. user/public API 전용';
COMMENT ON COLUMN static_page.published_body IS '게시 스냅샷 본문. publish 시 draft_body 복사';
COMMENT ON COLUMN static_page.version IS 'publish 할 때마다 +1. 감사·캐시 무효화용';
COMMENT ON COLUMN static_page.is_published IS 'TRUE 이면 공개 API 에 published_* 노출';
COMMENT ON COLUMN static_page.published_at IS '최근 publish 시각';
COMMENT ON COLUMN static_page.locale IS '콘텐츠 언어 코드 (ko, en, ja)';

-- 페이지별 섹션 구성 (홈·About·Career·Projects 등)
CREATE TABLE home_section (
    id                              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- HOME, ABOUT, CAREER, PROJECTS (포트폴리오 FE 라우트·Admin 스코프)
    page_key                        VARCHAR(50) NOT NULL DEFAULT 'HOME',
    -- 페이지 내 안정 슬롯 ID (Admin·FE 계약). 예: hero, project-grid
    section_key                     VARCHAR(100) NOT NULL,
    -- 렌더 컴포넌트 타입. 예: PROJECT_GRID, HERO, MARKDOWN
    section_type                    VARCHAR(50) NOT NULL,
    locale                          VARCHAR(10) NOT NULL DEFAULT 'ko',
    draft_title                     VARCHAR(200),
    draft_config                    JSONB,
    draft_config_schema_version     INT NOT NULL DEFAULT 1,
    published_title                 VARCHAR(200),
    published_config                JSONB,
    published_config_schema_version INT,
    version                         INT NOT NULL DEFAULT 0,
    published_at                    TIMESTAMPTZ,
    display_order                   INT NOT NULL DEFAULT 0,
    is_active                       BOOLEAN NOT NULL DEFAULT TRUE,
    starts_at                       TIMESTAMPTZ,
    ends_at                         TIMESTAMPTZ,
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_home_section_page_section_locale
        UNIQUE (page_key, section_key, locale),
    CONSTRAINT uq_home_section_page_display_order_locale
        UNIQUE (page_key, display_order, locale),
    CONSTRAINT chk_home_section_locale CHECK (locale IN ('ko', 'en', 'ja')),
    CONSTRAINT chk_home_section_page_key CHECK (
        page_key IN ('HOME', 'ABOUT', 'CAREER', 'PROJECTS')
    ),
    CONSTRAINT chk_home_section_type CHECK (
        section_type IN (
            'BANNER',
            'HERO',
            'MARKDOWN',
            'PROJECT_GRID',
            'RECOMMENDED_PRODUCTS',
            'FEED',
            'OOTD',
            'TIMELINE',
            'CUSTOM'
        )
    ),
    CONSTRAINT chk_home_section_display_order_nonneg
        CHECK (display_order >= 0),
    CONSTRAINT chk_home_section_version_nonneg
        CHECK (version >= 0),
    CONSTRAINT chk_home_section_draft_config_schema
        CHECK (draft_config_schema_version >= 1),
    CONSTRAINT chk_home_section_published_config_schema CHECK (
        published_config_schema_version IS NULL
        OR published_config_schema_version >= 1
    ),
    CONSTRAINT chk_home_section_published_snapshot CHECK (
        (published_title IS NULL AND published_config IS NULL AND published_at IS NULL
            AND published_config_schema_version IS NULL)
        OR (
            published_config IS NOT NULL
            AND published_at IS NOT NULL
            AND published_config_schema_version IS NOT NULL
        )
    )
);

COMMENT ON TABLE home_section IS
    '페이지별 CMS 섹션 슬롯. page_key·section_key·section_type (CMS-01/02)';
COMMENT ON COLUMN home_section.page_key IS
    '페이지 스코프. HOME, ABOUT, CAREER, PROJECTS — FE·Admin 공통 코드';
COMMENT ON COLUMN home_section.section_key IS
    'page_key·locale 내 고유 슬롯 ID. 예: hero, project-grid';
COMMENT ON COLUMN home_section.section_type IS
    'UI 컴포넌트 타입. PROJECT_GRID, HERO, MARKDOWN 등 (FE 매핑)';
COMMENT ON COLUMN home_section.draft_config_schema_version IS
    'draft_config JSON 계약 버전. 스키마 변경 시 증가 (CMS-02)';
COMMENT ON COLUMN home_section.published_config_schema_version IS
    'publish 시점 draft_config_schema_version 스냅샷';
COMMENT ON COLUMN home_section.draft_title IS '편집 중 섹션 제목 (preview)';
COMMENT ON COLUMN home_section.draft_config IS
    '편집 중 설정 JSON (노출 개수, 대상 ID 등). Admin preview';
COMMENT ON COLUMN home_section.published_title IS '게시 스냅샷 제목. user-bff 홈 조회';
COMMENT ON COLUMN home_section.published_config IS
    '게시 스냅샷 설정. publish 시 draft_config 복사';
COMMENT ON COLUMN home_section.version IS 'publish 시 +1';
COMMENT ON COLUMN home_section.published_at IS '최근 publish 시각 (NULL 이면 아직 미게시 스냅샷 없음)';
COMMENT ON COLUMN home_section.display_order IS '홈 내 섹션 노출 순서';
COMMENT ON COLUMN home_section.is_active IS '활성 여부 (스케줄·노출 on/off, draft 와 별개)';
COMMENT ON COLUMN home_section.starts_at IS '노출 시작 시각';
COMMENT ON COLUMN home_section.ends_at IS '노출 종료 시각';
COMMENT ON COLUMN home_section.locale IS
    '콘텐츠 언어 코드 (ko, en, ja). page_key·section_key 와 함께 UNIQUE';

-- ==============================================================
-- 기간 유효성 CHECK
--    ends_at 이 있으면 starts_at 보다 이후여야 함 (둘 다 NULL 허용)
-- ==============================================================

ALTER TABLE navigation_menu
    ADD CONSTRAINT chk_navigation_menu_period
        CHECK (ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at);

ALTER TABLE navigation_menu
    ADD CONSTRAINT chk_navigation_menu_locale
        CHECK (locale IN ('ko', 'en', 'ja'));

ALTER TABLE banner
    ADD CONSTRAINT chk_banner_period
        CHECK (ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at);

ALTER TABLE banner
    ADD CONSTRAINT chk_banner_locale
        CHECK (locale IN ('ko', 'en', 'ja'));

ALTER TABLE home_section
    ADD CONSTRAINT chk_home_section_period
        CHECK (ends_at IS NULL OR starts_at IS NULL OR ends_at > starts_at);

-- ==============================================================
-- 조회 패턴 인덱스
-- ==============================================================

-- 활성 메뉴: locale·부모별 정렬
CREATE INDEX idx_navigation_menu_locale_parent_active_order
    ON navigation_menu (locale, parent_id, display_order)
    WHERE is_active;

-- 활성 배너: locale·슬롯별 정렬
CREATE INDEX idx_banner_slot_locale_active_order
    ON banner (locale, slot, display_order)
    WHERE is_active;

-- 게시된 정적 페이지: locale별 최신 게시순
CREATE INDEX idx_static_page_locale_published_at
    ON static_page (locale, published_at DESC)
    WHERE is_published;

-- 활성 섹션: locale·페이지별·게시 스냅샷 있는 행
CREATE INDEX idx_home_section_locale_page_active_order
    ON home_section (locale, page_key, display_order)
    WHERE is_active AND published_config IS NOT NULL;

CREATE INDEX idx_home_section_locale_page_type_active_order
    ON home_section (locale, page_key, section_type, display_order)
    WHERE is_active AND published_config IS NOT NULL;
