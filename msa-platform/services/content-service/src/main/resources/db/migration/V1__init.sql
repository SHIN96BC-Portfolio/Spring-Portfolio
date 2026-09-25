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
-- [CMS-04] site_key: FE 앱(사이트) 구분.
--   PORTFOLIO | COMMERCE | FASHION | SOCIAL.
--   앱별 GNB·배너·섹션 분리 및 향후 사이트별 DB 이관 키.
-- ==============================================================

-- GNB / 내비게이션 메뉴 (계층 구조)
CREATE TABLE navigation_menu (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    site_key        VARCHAR(30) NOT NULL DEFAULT 'PORTFOLIO',
    parent_id       UUID REFERENCES navigation_menu(id),
    name            VARCHAR(100) NOT NULL,
    link_url        VARCHAR(500),
    display_order   INT NOT NULL DEFAULT 0,
    locale          VARCHAR(10) NOT NULL DEFAULT 'ko',
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    starts_at       TIMESTAMPTZ,
    ends_at         TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_navigation_menu_site_key CHECK (
        site_key IN ('PORTFOLIO', 'COMMERCE', 'FASHION', 'SOCIAL')
    )
);

CREATE INDEX idx_navigation_menu_parent ON navigation_menu(parent_id);

COMMENT ON TABLE navigation_menu IS 'GNB/내비게이션 메뉴 (계층 구조, parent_id 자기참조, site_key 별)';
COMMENT ON COLUMN navigation_menu.site_key IS
    'FE 앱/사이트 코드: PORTFOLIO, COMMERCE, FASHION, SOCIAL (CMS-04)';
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
    site_key        VARCHAR(30) NOT NULL DEFAULT 'PORTFOLIO',
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
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_banner_site_key CHECK (
        site_key IN ('PORTFOLIO', 'COMMERCE', 'FASHION', 'SOCIAL')
    )
);

CREATE INDEX idx_banner_slot ON banner(site_key, slot, display_order);

COMMENT ON TABLE banner IS '홈/이벤트 등 슬롯별 배너 (site_key 별)';
COMMENT ON COLUMN banner.site_key IS
    'FE 앱/사이트 코드: PORTFOLIO, COMMERCE, FASHION, SOCIAL (CMS-04)';
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
    site_key            VARCHAR(30) NOT NULL DEFAULT 'PORTFOLIO',
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

    CONSTRAINT uq_static_page_site_slug_locale UNIQUE (site_key, slug, locale),
    CONSTRAINT uq_static_page_site_page_key_locale UNIQUE (site_key, page_key, locale),
    CONSTRAINT chk_static_page_site_key CHECK (
        site_key IN ('PORTFOLIO', 'COMMERCE', 'FASHION', 'SOCIAL')
    ),
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
    '정적 CMS 페이지. draft=미리보기, published=공개 (CMS-01). site_key 별 (CMS-04)';
COMMENT ON COLUMN static_page.site_key IS
    'FE 앱/사이트 코드: PORTFOLIO, COMMERCE, FASHION, SOCIAL (CMS-04)';
COMMENT ON COLUMN static_page.slug IS 'URL 경로 식별자. site_key·locale 과 함께 UNIQUE. 예: about, terms';
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
    site_key                        VARCHAR(30) NOT NULL DEFAULT 'PORTFOLIO',
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

    CONSTRAINT uq_home_section_site_page_section_locale
        UNIQUE (site_key, page_key, section_key, locale),
    CONSTRAINT uq_home_section_site_page_display_order_locale
        UNIQUE (site_key, page_key, display_order, locale),
    CONSTRAINT chk_home_section_site_key CHECK (
        site_key IN ('PORTFOLIO', 'COMMERCE', 'FASHION', 'SOCIAL')
    ),
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
            'CUSTOM',
            'RESUME_PROJECT'
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
    '페이지별 CMS 섹션 슬롯. site_key·page_key·section_key·section_type (CMS-01/02/04)';
COMMENT ON COLUMN home_section.site_key IS
    'FE 앱/사이트 코드: PORTFOLIO, COMMERCE, FASHION, SOCIAL (CMS-04)';
COMMENT ON COLUMN home_section.page_key IS
    '페이지 스코프. HOME, ABOUT, CAREER, PROJECTS — FE·Admin 공통 코드';
COMMENT ON COLUMN home_section.section_key IS
    'site_key·page_key·locale 내 고유 슬롯 ID. 예: hero, project-grid';
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
    '콘텐츠 언어 코드 (ko, en, ja). site_key·page_key·section_key 와 함께 UNIQUE';

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

-- 활성 메뉴: site·locale·부모별 정렬
CREATE INDEX idx_navigation_menu_site_locale_parent_active_order
    ON navigation_menu (site_key, locale, parent_id, display_order)
    WHERE is_active;

-- 활성 배너: site·locale·슬롯별 정렬
CREATE INDEX idx_banner_slot_site_locale_active_order
    ON banner (site_key, locale, slot, display_order)
    WHERE is_active;

-- 게시된 정적 페이지: site·locale별 최신 게시순
CREATE INDEX idx_static_page_site_locale_published_at
    ON static_page (site_key, locale, published_at DESC)
    WHERE is_published;

-- 활성 섹션: site·locale·페이지별·게시 스냅샷 있는 행
CREATE INDEX idx_home_section_site_locale_page_active_order
    ON home_section (site_key, locale, page_key, display_order)
    WHERE is_active AND published_config IS NOT NULL;

CREATE INDEX idx_home_section_site_locale_page_type_active_order
    ON home_section (site_key, locale, page_key, section_type, display_order)
    WHERE is_active AND published_config IS NOT NULL;

-- ==============================================================
-- CAREER page seed (ko) — mirrors FE portfolio-career-sections.ko.ts
--   RESUME_PROJECT configSchemaVersion 2: scopeTags · overview · cases(AS-IS → TO-BE) · employer
-- ==============================================================

INSERT INTO home_section (
    id, site_key, page_key, section_key, section_type, locale,
    draft_title, draft_config, draft_config_schema_version,
    published_title, published_config, published_config_schema_version,
    version, published_at, display_order, is_active
) VALUES (
    'a1000001-0000-4000-8000-000000000001'::uuid, 'PORTFOLIO', 'CAREER', 'intro', 'MARKDOWN', 'ko',
    '경력기술서 — 신병철 (프론트엔드 개발자)', '{"body":"5년차 프론트엔드 개발자로, 레거시 서비스의 차세대 재구축과 End-to-End 신규 개발을 모두 수행해왔습니다. 대규모 리팩터링·성능 최적화·풀스택 대응에 강점이 있고, 전환을 안전하게 만드는 테스트·품질 체계와 AI 에이전트 컨텍스트·검증 하네스까지 직접 구축해왔습니다. 아래는 프로젝트별 주요 사례를 **AS-IS → TO-BE** 관점으로 정리한 내용입니다."}', 1,
    '경력기술서 — 신병철 (프론트엔드 개발자)', '{"body":"5년차 프론트엔드 개발자로, 레거시 서비스의 차세대 재구축과 End-to-End 신규 개발을 모두 수행해왔습니다. 대규모 리팩터링·성능 최적화·풀스택 대응에 강점이 있고, 전환을 안전하게 만드는 테스트·품질 체계와 AI 에이전트 컨텍스트·검증 하네스까지 직접 구축해왔습니다. 아래는 프로젝트별 주요 사례를 **AS-IS → TO-BE** 관점으로 정리한 내용입니다."}', 1,
    1, NOW(), 0, TRUE
);
INSERT INTO home_section (
    id, site_key, page_key, section_key, section_type, locale,
    draft_title, draft_config, draft_config_schema_version,
    published_title, published_config, published_config_schema_version,
    version, published_at, display_order, is_active
) VALUES (
    'a1000001-0000-4000-8000-000000000002'::uuid, 'PORTFOLIO', 'CAREER', 'project-travel-platform-nextgen', 'RESUME_PROJECT', 'ko',
    'M사 B2C/B2B 여행 플랫폼 차세대 재구축', '{"projectId":"travel-platform-nextgen","title":"M사 B2C/B2B 여행 플랫폼 차세대 재구축","company":"(주) YRISM","period":"2024.08 – 재직중","role":"프론트엔드 개발","links":[],"scopeTags":["FE 3명 → 5명","PL과 아키텍처 공동 설계"],"cases":[{"title":"레거시 서비스 안정화","asIs":"인수 시점 결제·뒤로가기(라우팅) 등 핵심 플로우가 정상 동작하지 않을 만큼 불안정","approach":"정상 동작하지 않던 핵심 플로우를 하나씩 진단·수정하며 추가 개발 건과 병행 처리","toBe":"`이슈 400건+` 처리 · 결제 실패·비정상 라우팅 해소로 운영 가능한 상태로 전환"},{"title":"차세대 핵심 도메인 재구축","asIs":"as-is B2C/B2B 서비스를 운영하면서 PC·MO 핵심 도메인을 전면 재구축해야 하는 상황. as-is에 없던 보안 요구사항 존재","approach":"항공(Topas 연동 예약·조회·결제 플로우 재설계), 투어패스(Klook 연동, 탐색·옵션 선택·예약 UX 개선), 호텔(검색·필터·상세·예약 이관), 프로모션·할인조건·쿠폰(복잡한 할인 규칙을 FE에서 안정적으로 처리하는 구조), B2B 예약·관리 화면, 인증(로그인·세션·권한) 재설계. 암·복호화 모듈 신규 도입. 전환 기간 중 as-is B2C PC/MO 운영·추가 개발 병행","toBe":"B2C·B2B PC/MO 핵심 도메인 차세대 전환 · 전환 기간에도 as-is 서비스 안정 운영 유지"},{"title":"멀티테넌트 운영 구조 설계","asIs":"B2C 본 사이트, 기능 기반은 같고 상품·일부 커스텀만 다른 BP 약 150개, 대리점별로 화면·기능이 전부 다른 풀커스텀 ONBP 약 150개(증가 중)를 모두 PC·MO로 한정된 인원이 운영. APP은 웹뷰 기반이라 화면·기능은 FE 영역이지만 앱 셸은 외부 업체가 관리해, 이슈마다 원인이 웹뷰인지 앱인지부터 판별","approach":"BP — 도메인별 init 시 사이트 정보를 로드하고 API 요청 헤더에 사이트 컨텍스트를 주입하는 원소스 멀티사이트. ONBP — Turborepo 모노레포에서 공통 컴포넌트 분리 + 사이트별 빌드 파이프라인으로 커스텀·공통 영역 격리, 도메인별 config로 커스텀 요소 체계화, yarn→pnpm 전환","toBe":"`300개+` 사이트를 단일 코드베이스로 운영 · 사이트가 늘어도 코드베이스·운영 비용이 따라 늘지 않는 구조"},{"title":"코드 구조 개선 — 공통화·FSD·FE Model","asIs":"props drilling이 심하고 동일 컴포넌트가 페이지마다 중복되어 한 번 수정에 여러 파일을 반복 수정, 디버깅 지연. 필터·예약·alert·popup 로직 산재, 하드코딩 문자열. BE API 스펙 변경에 FE가 과도하게 종속","approach":"FSD 아키텍처 도입. 중복 컴포넌트를 차세대 재구축과 병행해 점진 공통화, 산재 로직을 공통 모듈로 추출, 하드코딩 상수화. FE Model 레이어 + Mapper 패턴으로 BE API Model 직접 의존 제거","toBe":"동일 수정 `4파일 → 1파일` · BE 스펙 변경 영향을 도메인 단위로 격리 · 사이드이펙트·휴먼 에러 발생 지점 감소"},{"title":"UI 시스템 교체","asIs":"무리하게 적용된 antd의 글로벌 스타일 충돌로 UI 깨짐·CSS 애니메이션 버벅임. react-print는 대용량 페이지에서 인쇄 화면이 수십 초 지연, react-date는 버그 다발","approach":"antd를 점진 제거하고 전용 UI 라이브러리(Core UI) 구축, playground로 컴포넌트 단위 검증 환경 마련. iframe 기반 인쇄 자체 구현, react-day-picker로 교체","toBe":"디자인 일관성 확보·스타일 사이드이펙트 근본 해소 · 인쇄 지연(수십 초) 해소 · 날짜 선택 UX 안정화"},{"title":"Next.js 12→15·상태관리 무중단 전환","asIs":"Next.js 12 + RTK Query·Redux 기반. 운영 중인 대규모 서비스라 일괄 전환 불가","approach":"도메인·페이지 단위 점진 마이그레이션(App Router·React 19 대응). RTK Query→TanStack Query, Redux→Zustand를 병행 운영하며 전환. 버전업 과정에서 남아 있던 Babel 설정이 SWC 컴파일 경로를 비활성화하고 있던 것을 발견해 제거","toBe":"서비스 중단 없이 메이저 버전업·상태관리 전환 완료 · Babel 제거로 빌드·dev 서버 기동 시간 단축"},{"title":"배포 파이프라인·빌드 재설계","asIs":"B2C 단일 8개 파이프라인 체계, 빌드~배포 30분 이상. 동작 없이 빌드 시간만 늘리는 설정, 잘못 설정된 캐시, 불필요한 체크 스텝·중복 `yarn install`. Docker 내부 빌드(Yarn workspaces)","approach":"*(직접)* 오케스트레이터 파이프라인으로 B2C·BP·ONBP × 4환경 20개+ 체계 분리·선택 배포, standby 파이프라인 신규 구성. Turbo prune + 호스트 pnpm/turbo 빌드 + Docker 패키징 분리, buildx registry 캐시, Turborepo·Next 빌드 캐시 정상화. Helm 차트 작성·고도화(topologySpreadConstraints, readinessProbe, CPU/메모리 HPA), `kubectl rollout status` 배포 검증. *(인프라팀 협업)* Azure AKS → Azure Local ARC 전환, active/standby failover 재해 복구, Akamai CDN, 인프라 보안, Pod 운영·모니터링, 서버 로그 분석","decision":"구축기의 릴리스 트레인·통합 브랜치 방식이 오픈 후 잦은 핫픽스·긴급 배포에 맞지 않는다고 보고, 유연한 수동 배포 전략으로 전환을 제안·적용","toBe":"빌드~배포 `30분+ → 12~15분` (약 50~60% 단축) · 파이프라인 `8개 → 20개+`로 서비스·환경 단위 선택 배포"},{"title":"페이지 로딩 최적화","asIs":"불필요한 API 중복 호출·중복 로딩, 반복 실행되는 useEffect","approach":"페이지 성격에 맞춰 SSG/SSR 조합, TanStack Query 캐싱, 불필요한 useEffect 정리","toBe":"가장 느리던 페이지 로딩 `약 1/3` 수준 (Lighthouse 모바일 기준)"},{"title":"테스트·품질 체계","asIs":"공통 컴포넌트 통합과 메이저 버전업을 병행하는데, 변경이 어느 사이트에 영향을 주는지 확인할 수단 부재. 테스트 자동화 전담 인력 없이 QA가 직접 접속해 수작업으로 확인하는 구조","approach":"Vitest 3 멀티 프로젝트(도메인 패키지, B2C/ONBP 공통 패키지) + React Testing Library로 HTTP 클라이언트·암복호화·결제/예약 유틸·커스텀 훅 검증, 패키지별 선택 실행. Playwright E2E를 운영 환경(legacy API)·dev 환경(FE Server/BFF)과 시트·도메인(B2C·BP·ONBP PC/MO) 단위로 원격 실행 — 실 SSO 연동·BFF probe로 실제 경로 검증, 실행·리포트용 Testbed UI 직접 구축. Husky pre-commit(Biome + 변경 연관 Vitest)·pre-push(빌드·타입체크·전체 테스트). OpenAPI 스펙에서 Zod/TypeBox 생성","toBe":"공통화·버전업 회귀를 커밋·푸시 단계에서 차단 · BE 스펙 변경의 FE 영향 지점을 컴파일 타임에 노출"},{"title":"AI 에이전트 컨텍스트·하네스 엔지니어링","asIs":"모노레포 규모가 커지며 AI 에이전트가 레이어 경계를 넘거나 컨벤션을 벗어난 코드를 반복 생성 — 사람이 리뷰에서 잡는 구조","approach":"*(컨텍스트)* 루트 AGENTS.md를 단일 소스로 Cursor·Claude·Gemini·Codex 진입점을 통일해 도구별 규칙 문서가 갈라지지 않게 구성. 패키지별 AGENTS.md로 API 계약·브라우저 어댑터·HTTP 통신 본체 역할과 B2C↔ONBP 교차 import 금지를 작업 경로별 주입. 사람용 가이드와 Cursor Skill·path-scoped Rule을 분리 — TS/TSX 편집 시에만 #region·Named Export·Biome·이벤트 규칙을 주입하고 레거시 일괄 리팩터는 범위에서 제외. *(검증 하네스)* 에이전트 산출물도 사람과 같은 Husky 품질 게이트(Biome·변경 연관 Vitest, 빌드·타입체크·전체 테스트)를 통과해야 반영되도록 구성. Playwright 시나리오 메타데이터로 registry 자동 생성·CLI/Testbed UI 실행, 실패 원인·수정 옵션·재검증 절차를 문서로 남겨 후속 에이전트 작업에 연결","toBe":"생성 시점(컨텍스트)과 커밋·푸시 시점(검증 하네스) 두 단계에서 아키텍처 위반·회귀 차단 · 신규 인원도 구조 파악 전부터 경계 안에서 작업"},{"title":"팀 작업 기준 수립","asIs":"문서·온보딩 부재로 신규 인력의 프로젝트 파악 지연","approach":"PL과 함께 FSD 아키텍처·FE Model+Mapper 패턴·컴포넌트 공통화 기준·브랜치·배포 규칙을 정의·문서화, 문서 자동화 도구 도입. 리드 부재 시 일정 조정·이슈 배분·기술 의사결정 대행","toBe":"아키텍처·작업 기준을 팀 공통 문서로 정립 · 문서 자동화로 프로젝트 구조·배포 규칙 파악 경로 마련"}],"techStack":["Next.js 12→15","TypeScript","Turborepo","pnpm","FSD","TanStack Query","Zustand","Redux","RTK Query","axios","Tailwind CSS","Vitest","React Testing Library","Playwright","Biome","Husky","Zod","Azure DevOps","ACR","Helm","Kubernetes","Docker"],"employer":{"period":"2024.08 – 재직중","detail":"웹개발팀 · 시스템 운영 매니저(사내 직급) · Frontend Developer"}}', 2,
    'M사 B2C/B2B 여행 플랫폼 차세대 재구축', '{"projectId":"travel-platform-nextgen","title":"M사 B2C/B2B 여행 플랫폼 차세대 재구축","company":"(주) YRISM","period":"2024.08 – 재직중","role":"프론트엔드 개발","links":[],"scopeTags":["FE 3명 → 5명","PL과 아키텍처 공동 설계"],"cases":[{"title":"레거시 서비스 안정화","asIs":"인수 시점 결제·뒤로가기(라우팅) 등 핵심 플로우가 정상 동작하지 않을 만큼 불안정","approach":"정상 동작하지 않던 핵심 플로우를 하나씩 진단·수정하며 추가 개발 건과 병행 처리","toBe":"`이슈 400건+` 처리 · 결제 실패·비정상 라우팅 해소로 운영 가능한 상태로 전환"},{"title":"차세대 핵심 도메인 재구축","asIs":"as-is B2C/B2B 서비스를 운영하면서 PC·MO 핵심 도메인을 전면 재구축해야 하는 상황. as-is에 없던 보안 요구사항 존재","approach":"항공(Topas 연동 예약·조회·결제 플로우 재설계), 투어패스(Klook 연동, 탐색·옵션 선택·예약 UX 개선), 호텔(검색·필터·상세·예약 이관), 프로모션·할인조건·쿠폰(복잡한 할인 규칙을 FE에서 안정적으로 처리하는 구조), B2B 예약·관리 화면, 인증(로그인·세션·권한) 재설계. 암·복호화 모듈 신규 도입. 전환 기간 중 as-is B2C PC/MO 운영·추가 개발 병행","toBe":"B2C·B2B PC/MO 핵심 도메인 차세대 전환 · 전환 기간에도 as-is 서비스 안정 운영 유지"},{"title":"멀티테넌트 운영 구조 설계","asIs":"B2C 본 사이트, 기능 기반은 같고 상품·일부 커스텀만 다른 BP 약 150개, 대리점별로 화면·기능이 전부 다른 풀커스텀 ONBP 약 150개(증가 중)를 모두 PC·MO로 한정된 인원이 운영. APP은 웹뷰 기반이라 화면·기능은 FE 영역이지만 앱 셸은 외부 업체가 관리해, 이슈마다 원인이 웹뷰인지 앱인지부터 판별","approach":"BP — 도메인별 init 시 사이트 정보를 로드하고 API 요청 헤더에 사이트 컨텍스트를 주입하는 원소스 멀티사이트. ONBP — Turborepo 모노레포에서 공통 컴포넌트 분리 + 사이트별 빌드 파이프라인으로 커스텀·공통 영역 격리, 도메인별 config로 커스텀 요소 체계화, yarn→pnpm 전환","toBe":"`300개+` 사이트를 단일 코드베이스로 운영 · 사이트가 늘어도 코드베이스·운영 비용이 따라 늘지 않는 구조"},{"title":"코드 구조 개선 — 공통화·FSD·FE Model","asIs":"props drilling이 심하고 동일 컴포넌트가 페이지마다 중복되어 한 번 수정에 여러 파일을 반복 수정, 디버깅 지연. 필터·예약·alert·popup 로직 산재, 하드코딩 문자열. BE API 스펙 변경에 FE가 과도하게 종속","approach":"FSD 아키텍처 도입. 중복 컴포넌트를 차세대 재구축과 병행해 점진 공통화, 산재 로직을 공통 모듈로 추출, 하드코딩 상수화. FE Model 레이어 + Mapper 패턴으로 BE API Model 직접 의존 제거","toBe":"동일 수정 `4파일 → 1파일` · BE 스펙 변경 영향을 도메인 단위로 격리 · 사이드이펙트·휴먼 에러 발생 지점 감소"},{"title":"UI 시스템 교체","asIs":"무리하게 적용된 antd의 글로벌 스타일 충돌로 UI 깨짐·CSS 애니메이션 버벅임. react-print는 대용량 페이지에서 인쇄 화면이 수십 초 지연, react-date는 버그 다발","approach":"antd를 점진 제거하고 전용 UI 라이브러리(Core UI) 구축, playground로 컴포넌트 단위 검증 환경 마련. iframe 기반 인쇄 자체 구현, react-day-picker로 교체","toBe":"디자인 일관성 확보·스타일 사이드이펙트 근본 해소 · 인쇄 지연(수십 초) 해소 · 날짜 선택 UX 안정화"},{"title":"Next.js 12→15·상태관리 무중단 전환","asIs":"Next.js 12 + RTK Query·Redux 기반. 운영 중인 대규모 서비스라 일괄 전환 불가","approach":"도메인·페이지 단위 점진 마이그레이션(App Router·React 19 대응). RTK Query→TanStack Query, Redux→Zustand를 병행 운영하며 전환. 버전업 과정에서 남아 있던 Babel 설정이 SWC 컴파일 경로를 비활성화하고 있던 것을 발견해 제거","toBe":"서비스 중단 없이 메이저 버전업·상태관리 전환 완료 · Babel 제거로 빌드·dev 서버 기동 시간 단축"},{"title":"배포 파이프라인·빌드 재설계","asIs":"B2C 단일 8개 파이프라인 체계, 빌드~배포 30분 이상. 동작 없이 빌드 시간만 늘리는 설정, 잘못 설정된 캐시, 불필요한 체크 스텝·중복 `yarn install`. Docker 내부 빌드(Yarn workspaces)","approach":"*(직접)* 오케스트레이터 파이프라인으로 B2C·BP·ONBP × 4환경 20개+ 체계 분리·선택 배포, standby 파이프라인 신규 구성. Turbo prune + 호스트 pnpm/turbo 빌드 + Docker 패키징 분리, buildx registry 캐시, Turborepo·Next 빌드 캐시 정상화. Helm 차트 작성·고도화(topologySpreadConstraints, readinessProbe, CPU/메모리 HPA), `kubectl rollout status` 배포 검증. *(인프라팀 협업)* Azure AKS → Azure Local ARC 전환, active/standby failover 재해 복구, Akamai CDN, 인프라 보안, Pod 운영·모니터링, 서버 로그 분석","decision":"구축기의 릴리스 트레인·통합 브랜치 방식이 오픈 후 잦은 핫픽스·긴급 배포에 맞지 않는다고 보고, 유연한 수동 배포 전략으로 전환을 제안·적용","toBe":"빌드~배포 `30분+ → 12~15분` (약 50~60% 단축) · 파이프라인 `8개 → 20개+`로 서비스·환경 단위 선택 배포"},{"title":"페이지 로딩 최적화","asIs":"불필요한 API 중복 호출·중복 로딩, 반복 실행되는 useEffect","approach":"페이지 성격에 맞춰 SSG/SSR 조합, TanStack Query 캐싱, 불필요한 useEffect 정리","toBe":"가장 느리던 페이지 로딩 `약 1/3` 수준 (Lighthouse 모바일 기준)"},{"title":"테스트·품질 체계","asIs":"공통 컴포넌트 통합과 메이저 버전업을 병행하는데, 변경이 어느 사이트에 영향을 주는지 확인할 수단 부재. 테스트 자동화 전담 인력 없이 QA가 직접 접속해 수작업으로 확인하는 구조","approach":"Vitest 3 멀티 프로젝트(도메인 패키지, B2C/ONBP 공통 패키지) + React Testing Library로 HTTP 클라이언트·암복호화·결제/예약 유틸·커스텀 훅 검증, 패키지별 선택 실행. Playwright E2E를 운영 환경(legacy API)·dev 환경(FE Server/BFF)과 시트·도메인(B2C·BP·ONBP PC/MO) 단위로 원격 실행 — 실 SSO 연동·BFF probe로 실제 경로 검증, 실행·리포트용 Testbed UI 직접 구축. Husky pre-commit(Biome + 변경 연관 Vitest)·pre-push(빌드·타입체크·전체 테스트). OpenAPI 스펙에서 Zod/TypeBox 생성","toBe":"공통화·버전업 회귀를 커밋·푸시 단계에서 차단 · BE 스펙 변경의 FE 영향 지점을 컴파일 타임에 노출"},{"title":"AI 에이전트 컨텍스트·하네스 엔지니어링","asIs":"모노레포 규모가 커지며 AI 에이전트가 레이어 경계를 넘거나 컨벤션을 벗어난 코드를 반복 생성 — 사람이 리뷰에서 잡는 구조","approach":"*(컨텍스트)* 루트 AGENTS.md를 단일 소스로 Cursor·Claude·Gemini·Codex 진입점을 통일해 도구별 규칙 문서가 갈라지지 않게 구성. 패키지별 AGENTS.md로 API 계약·브라우저 어댑터·HTTP 통신 본체 역할과 B2C↔ONBP 교차 import 금지를 작업 경로별 주입. 사람용 가이드와 Cursor Skill·path-scoped Rule을 분리 — TS/TSX 편집 시에만 #region·Named Export·Biome·이벤트 규칙을 주입하고 레거시 일괄 리팩터는 범위에서 제외. *(검증 하네스)* 에이전트 산출물도 사람과 같은 Husky 품질 게이트(Biome·변경 연관 Vitest, 빌드·타입체크·전체 테스트)를 통과해야 반영되도록 구성. Playwright 시나리오 메타데이터로 registry 자동 생성·CLI/Testbed UI 실행, 실패 원인·수정 옵션·재검증 절차를 문서로 남겨 후속 에이전트 작업에 연결","toBe":"생성 시점(컨텍스트)과 커밋·푸시 시점(검증 하네스) 두 단계에서 아키텍처 위반·회귀 차단 · 신규 인원도 구조 파악 전부터 경계 안에서 작업"},{"title":"팀 작업 기준 수립","asIs":"문서·온보딩 부재로 신규 인력의 프로젝트 파악 지연","approach":"PL과 함께 FSD 아키텍처·FE Model+Mapper 패턴·컴포넌트 공통화 기준·브랜치·배포 규칙을 정의·문서화, 문서 자동화 도구 도입. 리드 부재 시 일정 조정·이슈 배분·기술 의사결정 대행","toBe":"아키텍처·작업 기준을 팀 공통 문서로 정립 · 문서 자동화로 프로젝트 구조·배포 규칙 파악 경로 마련"}],"techStack":["Next.js 12→15","TypeScript","Turborepo","pnpm","FSD","TanStack Query","Zustand","Redux","RTK Query","axios","Tailwind CSS","Vitest","React Testing Library","Playwright","Biome","Husky","Zod","Azure DevOps","ACR","Helm","Kubernetes","Docker"],"employer":{"period":"2024.08 – 재직중","detail":"웹개발팀 · 시스템 운영 매니저(사내 직급) · Frontend Developer"}}', 2,
    1, NOW(), 1, TRUE
);
INSERT INTO home_section (
    id, site_key, page_key, section_key, section_type, locale,
    draft_title, draft_config, draft_config_schema_version,
    published_title, published_config, published_config_schema_version,
    version, published_at, display_order, is_active
) VALUES (
    'a1000001-0000-4000-8000-000000000003'::uuid, 'PORTFOLIO', 'CAREER', 'project-visa-center', 'RESUME_PROJECT', 'ko',
    'V사 해외 비자센터 웹 서비스 신규 구축', '{"projectId":"visa-center","title":"V사 해외 비자센터 웹 서비스 신규 구축","company":"(주) YRISM","period":"2025.02 – 2025.03","role":"프론트엔드 개발","links":[],"scopeTags":["FE 단독"],"overview":"중국 청도 비자센터의 비자 신청·안내 웹 서비스를 신규 구축. Next.js 15 App Router·Zustand·TanStack Query 기반 화면·API 연동, Tailwind CSS 4 반응형 UI, 한국어 페이지 구성, Azure 배포","techStack":["Next.js 15","TypeScript","Zustand","TanStack Query","axios","Tailwind CSS 4","Azure"],"employer":{"period":"2024.08 – 재직중","detail":"웹개발팀 · 시스템 운영 매니저(사내 직급) · Frontend Developer"}}', 2,
    'V사 해외 비자센터 웹 서비스 신규 구축', '{"projectId":"visa-center","title":"V사 해외 비자센터 웹 서비스 신규 구축","company":"(주) YRISM","period":"2025.02 – 2025.03","role":"프론트엔드 개발","links":[],"scopeTags":["FE 단독"],"overview":"중국 청도 비자센터의 비자 신청·안내 웹 서비스를 신규 구축. Next.js 15 App Router·Zustand·TanStack Query 기반 화면·API 연동, Tailwind CSS 4 반응형 UI, 한국어 페이지 구성, Azure 배포","techStack":["Next.js 15","TypeScript","Zustand","TanStack Query","axios","Tailwind CSS 4","Azure"],"employer":{"period":"2024.08 – 재직중","detail":"웹개발팀 · 시스템 운영 매니저(사내 직급) · Frontend Developer"}}', 2,
    1, NOW(), 2, TRUE
);
INSERT INTO home_section (
    id, site_key, page_key, section_key, section_type, locale,
    draft_title, draft_config, draft_config_schema_version,
    published_title, published_config, published_config_schema_version,
    version, published_at, display_order, is_active
) VALUES (
    'a1000001-0000-4000-8000-000000000004'::uuid, 'PORTFOLIO', 'CAREER', 'project-commerce-backoffice', 'RESUME_PROJECT', 'ko',
    '필리핀 커머스·배달 플랫폼 백오피스 (자사 서비스)', '{"projectId":"commerce-backoffice","title":"필리핀 커머스·배달 플랫폼 백오피스 (자사 서비스)","company":"(주) Pinetechsoft","period":"2024.02 – 2024.05","role":"프론트엔드 개발","links":[],"scopeTags":["Mall Admin 1인 개발"],"cases":[{"title":"Mall 백오피스 신규 구축","asIs":"플랫폼에 상품 판매(Mall) 기능이 추가되며 관리 백오피스 필요","approach":"구조 설계·공통 컴포넌트·REST API 연동을 단독 수행. Firebase Authentication 관리자 로그인, 상품 CRUD·옵션 자동 생성(쉼표 입력)·검색·상세, 카테고리 Drag & Drop·순서 변경, 이벤트별 상품 무한스크롤 선택, 배달비·리뷰(댓글·숨김)·주문 검색·처리, i18n","toBe":"Mall 백오피스 단독 구축 완료"},{"title":"배달비 정책 확장 (Food·Store)","asIs":"운영 중인 Food·Store 백오피스에 배달비 정책(기본·거리별, 점주·고객 부담 비율) 기능 추가 요구","approach":"기본·거리별 배달비 설정 UI·API 연동, 점주/고객/부분 점주 부담 복합 정책 UI, react-hook-form + Zod 폼 검증, 기존 JWT 디코딩·암호화 인증 흐름 연동, Food와 분리된 Store 도메인 요구사항 반영. Food Admin 버그 수정·기능 보완 병행","toBe":"Food·Store 백오피스에 서비스별 배달비 정책 반영"}],"techStack":["Next.js","TypeScript","Zustand","Jotai","TanStack Query","MUI","react-hook-form","Zod","Firebase","AWS Amplify"],"employer":{"period":"2023.10 – 2024.05","detail":"개발1팀 · 연구원 · Frontend Developer"}}', 2,
    '필리핀 커머스·배달 플랫폼 백오피스 (자사 서비스)', '{"projectId":"commerce-backoffice","title":"필리핀 커머스·배달 플랫폼 백오피스 (자사 서비스)","company":"(주) Pinetechsoft","period":"2024.02 – 2024.05","role":"프론트엔드 개발","links":[],"scopeTags":["Mall Admin 1인 개발"],"cases":[{"title":"Mall 백오피스 신규 구축","asIs":"플랫폼에 상품 판매(Mall) 기능이 추가되며 관리 백오피스 필요","approach":"구조 설계·공통 컴포넌트·REST API 연동을 단독 수행. Firebase Authentication 관리자 로그인, 상품 CRUD·옵션 자동 생성(쉼표 입력)·검색·상세, 카테고리 Drag & Drop·순서 변경, 이벤트별 상품 무한스크롤 선택, 배달비·리뷰(댓글·숨김)·주문 검색·처리, i18n","toBe":"Mall 백오피스 단독 구축 완료"},{"title":"배달비 정책 확장 (Food·Store)","asIs":"운영 중인 Food·Store 백오피스에 배달비 정책(기본·거리별, 점주·고객 부담 비율) 기능 추가 요구","approach":"기본·거리별 배달비 설정 UI·API 연동, 점주/고객/부분 점주 부담 복합 정책 UI, react-hook-form + Zod 폼 검증, 기존 JWT 디코딩·암호화 인증 흐름 연동, Food와 분리된 Store 도메인 요구사항 반영. Food Admin 버그 수정·기능 보완 병행","toBe":"Food·Store 백오피스에 서비스별 배달비 정책 반영"}],"techStack":["Next.js","TypeScript","Zustand","Jotai","TanStack Query","MUI","react-hook-form","Zod","Firebase","AWS Amplify"],"employer":{"period":"2023.10 – 2024.05","detail":"개발1팀 · 연구원 · Frontend Developer"}}', 2,
    1, NOW(), 3, TRUE
);
INSERT INTO home_section (
    id, site_key, page_key, section_key, section_type, locale,
    draft_title, draft_config, draft_config_schema_version,
    published_title, published_config, published_config_schema_version,
    version, published_at, display_order, is_active
) VALUES (
    'a1000001-0000-4000-8000-000000000005'::uuid, 'PORTFOLIO', 'CAREER', 'project-vet-reservation', 'RESUME_PROJECT', 'ko',
    '필리핀 동물병원 예약 플랫폼 (자사 서비스)', '{"projectId":"vet-reservation","title":"필리핀 동물병원 예약 플랫폼 (자사 서비스)","company":"(주) Pinetechsoft","period":"2023.10 – 2024.02","role":"프론트엔드 개발","links":[],"scopeTags":["1인 개발","Admin · 예약 Web App · 소개 사이트"],"cases":[{"title":"오프라인 예약의 온라인 전환","asIs":"오프라인 중심의 동물병원 예약","approach":"예약 Web App — 예약 생성·조회·취소, 펫 최대 10마리 관리, Web/iOS/Android FCM 푸시. 병원용 Admin — 예약 불가일 캘린더, 예약 확정/취소 시 사용자 푸시, 사용자 조회·검색, 가입·탈퇴 현황 대시보드","toBe":"예약 Web App과 병원 Admin을 1인 구축해 온라인 예약으로 전환"},{"title":"로그인 시스템 전면 개편","asIs":"이메일·SNS 계정 통합으로 요구사항이 바뀌어 로그인 프로세스를 대폭 수정해야 했고 사이드이펙트 다수 발생","approach":"Firebase를 활용해 FE 주도로 로그인 시스템을 전면 개편 — Firebase Email + Google/Facebook/Apple/Kakao 통합 로그인(NextAuth)","toBe":"이메일·SNS 계정 통합 로그인 체계로 전환"},{"title":"푸시 오발송 방지","asIs":"기존 FCM 토큰 관리 구조로는 잘못된 사용자에게 푸시가 발송될 수 있는 문제","approach":"FCM 토큰을 기기별로 관리하는 구조로 개선","toBe":"잘못된 사용자에게 푸시가 발송되는 문제 방지"},{"title":"소개 사이트 슬라이더 버그","asIs":"Swiper가 뷰포트 리사이즈 시 이미지를 잘못 노출하는 버그","approach":"라이브러리를 제거하고 fade in/out 전환을 직접 구현. 모바일·태블릿 반응형, Google Map 병원 위치, 공지사항 목록·상세","toBe":"슬라이더 버그 해소 · 모바일 중심 소개 사이트 구축"}],"techStack":["Next.js","TypeScript","Jotai","MUI","Firebase","NextAuth","react-hook-form","Yup","AWS Amplify","Vercel"],"employer":{"period":"2023.10 – 2024.05","detail":"개발1팀 · 연구원 · Frontend Developer"}}', 2,
    '필리핀 동물병원 예약 플랫폼 (자사 서비스)', '{"projectId":"vet-reservation","title":"필리핀 동물병원 예약 플랫폼 (자사 서비스)","company":"(주) Pinetechsoft","period":"2023.10 – 2024.02","role":"프론트엔드 개발","links":[],"scopeTags":["1인 개발","Admin · 예약 Web App · 소개 사이트"],"cases":[{"title":"오프라인 예약의 온라인 전환","asIs":"오프라인 중심의 동물병원 예약","approach":"예약 Web App — 예약 생성·조회·취소, 펫 최대 10마리 관리, Web/iOS/Android FCM 푸시. 병원용 Admin — 예약 불가일 캘린더, 예약 확정/취소 시 사용자 푸시, 사용자 조회·검색, 가입·탈퇴 현황 대시보드","toBe":"예약 Web App과 병원 Admin을 1인 구축해 온라인 예약으로 전환"},{"title":"로그인 시스템 전면 개편","asIs":"이메일·SNS 계정 통합으로 요구사항이 바뀌어 로그인 프로세스를 대폭 수정해야 했고 사이드이펙트 다수 발생","approach":"Firebase를 활용해 FE 주도로 로그인 시스템을 전면 개편 — Firebase Email + Google/Facebook/Apple/Kakao 통합 로그인(NextAuth)","toBe":"이메일·SNS 계정 통합 로그인 체계로 전환"},{"title":"푸시 오발송 방지","asIs":"기존 FCM 토큰 관리 구조로는 잘못된 사용자에게 푸시가 발송될 수 있는 문제","approach":"FCM 토큰을 기기별로 관리하는 구조로 개선","toBe":"잘못된 사용자에게 푸시가 발송되는 문제 방지"},{"title":"소개 사이트 슬라이더 버그","asIs":"Swiper가 뷰포트 리사이즈 시 이미지를 잘못 노출하는 버그","approach":"라이브러리를 제거하고 fade in/out 전환을 직접 구현. 모바일·태블릿 반응형, Google Map 병원 위치, 공지사항 목록·상세","toBe":"슬라이더 버그 해소 · 모바일 중심 소개 사이트 구축"}],"techStack":["Next.js","TypeScript","Jotai","MUI","Firebase","NextAuth","react-hook-form","Yup","AWS Amplify","Vercel"],"employer":{"period":"2023.10 – 2024.05","detail":"개발1팀 · 연구원 · Frontend Developer"}}', 2,
    1, NOW(), 4, TRUE
);
INSERT INTO home_section (
    id, site_key, page_key, section_key, section_type, locale,
    draft_title, draft_config, draft_config_schema_version,
    published_title, published_config, published_config_schema_version,
    version, published_at, display_order, is_active
) VALUES (
    'a1000001-0000-4000-8000-000000000007'::uuid, 'PORTFOLIO', 'CAREER', 'project-patrol-app', 'RESUME_PROJECT', 'ko',
    '반려견 순찰 활동 iOS 앱', '{"projectId":"patrol-app","title":"반려견 순찰 활동 iOS 앱","company":"(주) ER Solution","period":"2023.08","role":"iOS 개발","links":[],"scopeTags":["1인 개발"],"overview":"기존 반려견 관리 Web App에 실시간 순찰(산책) 기능을 추가하고 iOS 네이티브 앱으로 전환. Naver Map 실시간 이동 경로·시간·거리, 촬영 사진 위치 마커, 순찰 종료 시 지도 캡처(순찰일지)","cases":[{"title":"강제 종료 후 순찰 이어하기","asIs":"앱을 강제 종료해도 순찰을 이어갈 수 있어야 한다는 요구 추가. 경과 시간은 스톱워치 방식으로 계산하는 구조","approach":"프로젝트 구조를 수정하고 경과 시간을 (현재 시간 − 시작 시간 + 누적 시간)으로 계산하도록 변경","toBe":"앱 강제 종료 후에도 이전 순찰 이어하기"}],"techStack":["Swift","SwiftUI","Realm DB"],"employer":{"period":"2022.07 – 2023.09","detail":"개발1팀 · 연구원 · Full Stack Developer"}}', 2,
    '반려견 순찰 활동 iOS 앱', '{"projectId":"patrol-app","title":"반려견 순찰 활동 iOS 앱","company":"(주) ER Solution","period":"2023.08","role":"iOS 개발","links":[],"scopeTags":["1인 개발"],"overview":"기존 반려견 관리 Web App에 실시간 순찰(산책) 기능을 추가하고 iOS 네이티브 앱으로 전환. Naver Map 실시간 이동 경로·시간·거리, 촬영 사진 위치 마커, 순찰 종료 시 지도 캡처(순찰일지)","cases":[{"title":"강제 종료 후 순찰 이어하기","asIs":"앱을 강제 종료해도 순찰을 이어갈 수 있어야 한다는 요구 추가. 경과 시간은 스톱워치 방식으로 계산하는 구조","approach":"프로젝트 구조를 수정하고 경과 시간을 (현재 시간 − 시작 시간 + 누적 시간)으로 계산하도록 변경","toBe":"앱 강제 종료 후에도 이전 순찰 이어하기"}],"techStack":["Swift","SwiftUI","Realm DB"],"employer":{"period":"2022.07 – 2023.09","detail":"개발1팀 · 연구원 · Full Stack Developer"}}', 2,
    1, NOW(), 5, TRUE
);
INSERT INTO home_section (
    id, site_key, page_key, section_key, section_type, locale,
    draft_title, draft_config, draft_config_schema_version,
    published_title, published_config, published_config_schema_version,
    version, published_at, display_order, is_active
) VALUES (
    'a1000001-0000-4000-8000-000000000008'::uuid, 'PORTFOLIO', 'CAREER', 'project-emission-dashboard', 'RESUME_PROJECT', 'ko',
    '대기오염 배출량 조회·시각화 시스템', '{"projectId":"emission-dashboard","title":"대기오염 배출량 조회·시각화 시스템","company":"(주) ER Solution","period":"2023.06 – 2023.07","role":"풀스택 개발","links":[],"scopeTags":["FE·BE·DB 단독"],"overview":"도로·지역·시간 단위 미세먼지 배출량 조회·시각화 서비스. Recharts 통계·v-world-map 지도, 조회·필터, 엑셀 업로드, Nest.js REST API·MariaDB 스키마·Swagger, AWS EC2 + Docker + Nginx + PM2 배포","cases":[{"title":"대용량 테이블 조회 성능","asIs":"1.4억 건 이상 테이블 조회에 4~6분 소요","approach":"인덱스 최적화 및 통계 테이블 설계로 조회 병목을 구조적으로 해소","toBe":"조회 `4~6분 → 5초 이내` (복잡 join 시 10초 이내, `약 50배+`)"},{"title":"차트 재렌더링 이슈","asIs":"Recharts 재렌더링 시 애니메이션이 반복되는 문제","approach":"useMemo + React.memo로 불필요한 재렌더링 차단","toBe":"재렌더링 애니메이션 이슈 해소"}],"techStack":["React(Vite)","Nest.js","TypeScript","MariaDB","TanStack Query","Recoil","Docker","AWS EC2","Nginx"],"employer":{"period":"2022.07 – 2023.09","detail":"개발1팀 · 연구원 · Full Stack Developer"}}', 2,
    '대기오염 배출량 조회·시각화 시스템', '{"projectId":"emission-dashboard","title":"대기오염 배출량 조회·시각화 시스템","company":"(주) ER Solution","period":"2023.06 – 2023.07","role":"풀스택 개발","links":[],"scopeTags":["FE·BE·DB 단독"],"overview":"도로·지역·시간 단위 미세먼지 배출량 조회·시각화 서비스. Recharts 통계·v-world-map 지도, 조회·필터, 엑셀 업로드, Nest.js REST API·MariaDB 스키마·Swagger, AWS EC2 + Docker + Nginx + PM2 배포","cases":[{"title":"대용량 테이블 조회 성능","asIs":"1.4억 건 이상 테이블 조회에 4~6분 소요","approach":"인덱스 최적화 및 통계 테이블 설계로 조회 병목을 구조적으로 해소","toBe":"조회 `4~6분 → 5초 이내` (복잡 join 시 10초 이내, `약 50배+`)"},{"title":"차트 재렌더링 이슈","asIs":"Recharts 재렌더링 시 애니메이션이 반복되는 문제","approach":"useMemo + React.memo로 불필요한 재렌더링 차단","toBe":"재렌더링 애니메이션 이슈 해소"}],"techStack":["React(Vite)","Nest.js","TypeScript","MariaDB","TanStack Query","Recoil","Docker","AWS EC2","Nginx"],"employer":{"period":"2022.07 – 2023.09","detail":"개발1팀 · 연구원 · Full Stack Developer"}}', 2,
    1, NOW(), 6, TRUE
);
INSERT INTO home_section (
    id, site_key, page_key, section_key, section_type, locale,
    draft_title, draft_config, draft_config_schema_version,
    published_title, published_config, published_config_schema_version,
    version, published_at, display_order, is_active
) VALUES (
    'a1000001-0000-4000-8000-000000000009'::uuid, 'PORTFOLIO', 'CAREER', 'project-kiosk-app', 'RESUME_PROJECT', 'ko',
    'E사 레미콘 입고관리 키오스크 앱', '{"projectId":"kiosk-app","title":"E사 레미콘 입고관리 키오스크 앱","company":"(주) ER Solution","period":"2023.05 – 2023.06","role":"프론트엔드 개발","links":[],"scopeTags":["1인 개발"],"overview":"레미콘 차량 운전자가 키오스크에서 송장을 촬영하면 입고 정보를 안내하는 Android 키오스크 앱 신규 개발. 외부 USB 카메라 연동·송장 업로드, 입고 안내 화면, 일정 시간 무입력 시 메인 화면 자동 복귀, 자동 로그인","cases":[{"title":"키오스크 렌더링 성능","asIs":"React 재렌더링으로 성능 저하","approach":"useCallback + React.memo로 렌더링 최적화","toBe":"재렌더링으로 인한 성능 저하 해소"}],"techStack":["React Native","TypeScript","Redux","TanStack Query"],"employer":{"period":"2022.07 – 2023.09","detail":"개발1팀 · 연구원 · Full Stack Developer"}}', 2,
    'E사 레미콘 입고관리 키오스크 앱', '{"projectId":"kiosk-app","title":"E사 레미콘 입고관리 키오스크 앱","company":"(주) ER Solution","period":"2023.05 – 2023.06","role":"프론트엔드 개발","links":[],"scopeTags":["1인 개발"],"overview":"레미콘 차량 운전자가 키오스크에서 송장을 촬영하면 입고 정보를 안내하는 Android 키오스크 앱 신규 개발. 외부 USB 카메라 연동·송장 업로드, 입고 안내 화면, 일정 시간 무입력 시 메인 화면 자동 복귀, 자동 로그인","cases":[{"title":"키오스크 렌더링 성능","asIs":"React 재렌더링으로 성능 저하","approach":"useCallback + React.memo로 렌더링 최적화","toBe":"재렌더링으로 인한 성능 저하 해소"}],"techStack":["React Native","TypeScript","Redux","TanStack Query"],"employer":{"period":"2022.07 – 2023.09","detail":"개발1팀 · 연구원 · Full Stack Developer"}}', 2,
    1, NOW(), 7, TRUE
);
INSERT INTO home_section (
    id, site_key, page_key, section_key, section_type, locale,
    draft_title, draft_config, draft_config_schema_version,
    published_title, published_config, published_config_schema_version,
    version, published_at, display_order, is_active
) VALUES (
    'a1000001-0000-4000-8000-000000000010'::uuid, 'PORTFOLIO', 'CAREER', 'project-eco-driving-cms', 'RESUME_PROJECT', 'ko',
    'J시 시내버스 경제운전 관리 CMS', '{"projectId":"eco-driving-cms","title":"J시 시내버스 경제운전 관리 CMS","company":"(주) ER Solution","period":"2023.03 – 2023.04","role":"풀스택 개발","links":[],"scopeTags":["FE·BE·DB 단독"],"cases":[{"title":"경제운전 지표 관리 시스템 구축","asIs":"운수사 관리자가 버스 운행 데이터로 급가속·급감속 등 경제운전 지표를 확인할 CMS 필요","approach":"급가속·급감속·급진로변경·급회전 횟수 Chart.js 시각화, 관리자·운영자 역할 기반 권한과 운수사별 데이터 접근 제어, 복수 버스·노선 멀티 셀렉트. Java Spring + eGovFrame REST API, MariaDB 설계, AWS EC2/RDS 배포","toBe":"프론트·백엔드·DB·배포 단독 구축"}],"techStack":["JSP","jQuery","Java","Spring","eGovFrame","MariaDB","Docker","AWS EC2/RDS"],"employer":{"period":"2022.07 – 2023.09","detail":"개발1팀 · 연구원 · Full Stack Developer"}}', 2,
    'J시 시내버스 경제운전 관리 CMS', '{"projectId":"eco-driving-cms","title":"J시 시내버스 경제운전 관리 CMS","company":"(주) ER Solution","period":"2023.03 – 2023.04","role":"풀스택 개발","links":[],"scopeTags":["FE·BE·DB 단독"],"cases":[{"title":"경제운전 지표 관리 시스템 구축","asIs":"운수사 관리자가 버스 운행 데이터로 급가속·급감속 등 경제운전 지표를 확인할 CMS 필요","approach":"급가속·급감속·급진로변경·급회전 횟수 Chart.js 시각화, 관리자·운영자 역할 기반 권한과 운수사별 데이터 접근 제어, 복수 버스·노선 멀티 셀렉트. Java Spring + eGovFrame REST API, MariaDB 설계, AWS EC2/RDS 배포","toBe":"프론트·백엔드·DB·배포 단독 구축"}],"techStack":["JSP","jQuery","Java","Spring","eGovFrame","MariaDB","Docker","AWS EC2/RDS"],"employer":{"period":"2022.07 – 2023.09","detail":"개발1팀 · 연구원 · Full Stack Developer"}}', 2,
    1, NOW(), 8, TRUE
);
INSERT INTO home_section (
    id, site_key, page_key, section_key, section_type, locale,
    draft_title, draft_config, draft_config_schema_version,
    published_title, published_config, published_config_schema_version,
    version, published_at, display_order, is_active
) VALUES (
    'a1000001-0000-4000-8000-000000000011'::uuid, 'PORTFOLIO', 'CAREER', 'project-distribution-platform', 'RESUME_PROJECT', 'ko',
    'D사 유통관리 플랫폼·B2C 쇼핑몰', '{"projectId":"distribution-platform","title":"D사 유통관리 플랫폼·B2C 쇼핑몰","company":"(주) ER Solution","period":"2022.10 – 2023.06","role":"프론트엔드 개발","links":[],"scopeTags":["FE 메인","유통관리 100% · 쇼핑몰 60%"],"overview":"B2B·B2C 유통관리 Web App과, 여기서 소싱한 상품을 판매하는 B2C 쇼핑몰을 신규 개발. 기획·디자인 미팅부터 참여해 요구사항 문서 정리, 프론트엔드 구조 설계·공통 컴포넌트, Editor.js 상품 에디터, Intersection Observer + React Query 무한스크롤, Atomic Design·Git Flow 도입","cases":[{"title":"중첩 팝업 UX 개선","asIs":"팝업이 4~5개 중첩되는 기획","approach":"팝업을 1~2개로 줄이고 상세는 페이지 전환으로 바꾸도록 제안","toBe":"중첩 팝업 `4~5개 → 1~2개`"}],"techStack":["React(CRA)","JavaScript","Redux","React Router","React Query","Nginx"],"employer":{"period":"2022.07 – 2023.09","detail":"개발1팀 · 연구원 · Full Stack Developer"}}', 2,
    'D사 유통관리 플랫폼·B2C 쇼핑몰', '{"projectId":"distribution-platform","title":"D사 유통관리 플랫폼·B2C 쇼핑몰","company":"(주) ER Solution","period":"2022.10 – 2023.06","role":"프론트엔드 개발","links":[],"scopeTags":["FE 메인","유통관리 100% · 쇼핑몰 60%"],"overview":"B2B·B2C 유통관리 Web App과, 여기서 소싱한 상품을 판매하는 B2C 쇼핑몰을 신규 개발. 기획·디자인 미팅부터 참여해 요구사항 문서 정리, 프론트엔드 구조 설계·공통 컴포넌트, Editor.js 상품 에디터, Intersection Observer + React Query 무한스크롤, Atomic Design·Git Flow 도입","cases":[{"title":"중첩 팝업 UX 개선","asIs":"팝업이 4~5개 중첩되는 기획","approach":"팝업을 1~2개로 줄이고 상세는 페이지 전환으로 바꾸도록 제안","toBe":"중첩 팝업 `4~5개 → 1~2개`"}],"techStack":["React(CRA)","JavaScript","Redux","React Router","React Query","Nginx"],"employer":{"period":"2022.07 – 2023.09","detail":"개발1팀 · 연구원 · Full Stack Developer"}}', 2,
    1, NOW(), 9, TRUE
);
INSERT INTO home_section (
    id, site_key, page_key, section_key, section_type, locale,
    draft_title, draft_config, draft_config_schema_version,
    published_title, published_config, published_config_schema_version,
    version, published_at, display_order, is_active
) VALUES (
    'a1000001-0000-4000-8000-000000000012'::uuid, 'PORTFOLIO', 'CAREER', 'project-public-site-maintenance', 'RESUME_PROJECT', 'ko',
    'I공사 공식 사이트 유지보수', '{"projectId":"public-site-maintenance","title":"I공사 공식 사이트 유지보수","company":"(주) ER Solution","period":"2022.09 – 2023.09","role":"유지보수","links":[],"scopeTags":["유지보수 담당","재직 기간 병행"],"cases":[{"title":"웹접근성 인증·보안 점검 대응","asIs":"공공기관 웹접근성(WA) 인증심사와 모의해킹 점검 대응 필요","approach":"웹접근성 기준 대응, 모의해킹 결과에 따른 보안 취약점 패치·강화, JSP·Spring 레거시 페이지 구조 파악·개선. 기능 추가·수정·장애 대응 병행","toBe":"`WA 인증 통과` · 보안 취약점 해소"}],"techStack":["JSP","jQuery","Java","Spring","eGovFrame","Oracle"],"employer":{"period":"2022.07 – 2023.09","detail":"개발1팀 · 연구원 · Full Stack Developer"}}', 2,
    'I공사 공식 사이트 유지보수', '{"projectId":"public-site-maintenance","title":"I공사 공식 사이트 유지보수","company":"(주) ER Solution","period":"2022.09 – 2023.09","role":"유지보수","links":[],"scopeTags":["유지보수 담당","재직 기간 병행"],"cases":[{"title":"웹접근성 인증·보안 점검 대응","asIs":"공공기관 웹접근성(WA) 인증심사와 모의해킹 점검 대응 필요","approach":"웹접근성 기준 대응, 모의해킹 결과에 따른 보안 취약점 패치·강화, JSP·Spring 레거시 페이지 구조 파악·개선. 기능 추가·수정·장애 대응 병행","toBe":"`WA 인증 통과` · 보안 취약점 해소"}],"techStack":["JSP","jQuery","Java","Spring","eGovFrame","Oracle"],"employer":{"period":"2022.07 – 2023.09","detail":"개발1팀 · 연구원 · Full Stack Developer"}}', 2,
    1, NOW(), 10, TRUE
);
INSERT INTO home_section (
    id, site_key, page_key, section_key, section_type, locale,
    draft_title, draft_config, draft_config_schema_version,
    published_title, published_config, published_config_schema_version,
    version, published_at, display_order, is_active
) VALUES (
    'a1000001-0000-4000-8000-000000000013'::uuid, 'PORTFOLIO', 'CAREER', 'project-cms-site', 'RESUME_PROJECT', 'ko',
    'S사 사용자 사이트·관리자 CMS', '{"projectId":"cms-site","title":"S사 사용자 사이트·관리자 CMS","company":"(주) ER Solution","period":"2022.07 – 2022.09","role":"풀스택 개발","links":[],"scopeTags":["풀스택"],"overview":"사용자 사이트(JSP)와 관리자 CMS(React) 신규 구축. DB·프로젝트 구조 설계, Q&A 게시판(MVC), CMS에서 사용자 사이트 메뉴를 DB 기반으로 동적 관리, Container-Presenter 패턴·메뉴별 권한 관리, Spring Boot REST API·MySQL, AWS EC2/RDS 배포","techStack":["React","Redux","Material UI","JSP","jQuery","Java","Spring Boot","MySQL","AWS"],"employer":{"period":"2022.07 – 2023.09","detail":"개발1팀 · 연구원 · Full Stack Developer"}}', 2,
    'S사 사용자 사이트·관리자 CMS', '{"projectId":"cms-site","title":"S사 사용자 사이트·관리자 CMS","company":"(주) ER Solution","period":"2022.07 – 2022.09","role":"풀스택 개발","links":[],"scopeTags":["풀스택"],"overview":"사용자 사이트(JSP)와 관리자 CMS(React) 신규 구축. DB·프로젝트 구조 설계, Q&A 게시판(MVC), CMS에서 사용자 사이트 메뉴를 DB 기반으로 동적 관리, Container-Presenter 패턴·메뉴별 권한 관리, Spring Boot REST API·MySQL, AWS EC2/RDS 배포","techStack":["React","Redux","Material UI","JSP","jQuery","Java","Spring Boot","MySQL","AWS"],"employer":{"period":"2022.07 – 2023.09","detail":"개발1팀 · 연구원 · Full Stack Developer"}}', 2,
    1, NOW(), 11, TRUE
);
INSERT INTO home_section (
    id, site_key, page_key, section_key, section_type, locale,
    draft_title, draft_config, draft_config_schema_version,
    published_title, published_config, published_config_schema_version,
    version, published_at, display_order, is_active
) VALUES (
    'a1000001-0000-4000-8000-000000000006'::uuid, 'PORTFOLIO', 'CAREER', 'strengths', 'MARKDOWN', 'ko',
    '강점 요약', '{"body":"- **레거시 → 차세대 전환**을 무중단으로 수행하는 대규모 리팩터링 역량\n- **성능 병목을 구조적으로 진단·해결**하는 최적화 역량 (50배 개선 사례)\n- **FE 배포 파이프라인·Helm 차트를 직접 설계·구축**하는 배포·운영 역량\n- **테스트·품질 게이트를 계층으로 설계**해 대규모 전환의 회귀를 차단하는 안정성 역량\n- **AI 에이전트의 컨텍스트와 검증 하네스를 설계**해 아키텍처 경계를 지키게 하는 역량\n- 프론트·백·모바일·인프라를 아우르며 기획부터 배포까지 **End-to-End로 완성**하는 풀스택 오너십"}', 1,
    '강점 요약', '{"body":"- **레거시 → 차세대 전환**을 무중단으로 수행하는 대규모 리팩터링 역량\n- **성능 병목을 구조적으로 진단·해결**하는 최적화 역량 (50배 개선 사례)\n- **FE 배포 파이프라인·Helm 차트를 직접 설계·구축**하는 배포·운영 역량\n- **테스트·품질 게이트를 계층으로 설계**해 대규모 전환의 회귀를 차단하는 안정성 역량\n- **AI 에이전트의 컨텍스트와 검증 하네스를 설계**해 아키텍처 경계를 지키게 하는 역량\n- 프론트·백·모바일·인프라를 아우르며 기획부터 배포까지 **End-to-End로 완성**하는 풀스택 오너십"}', 1,
    1, NOW(), 12, TRUE
);

-- ==============================================================
-- GNB navigation_menu seed — mirrors FE portfolio-navigation.*.ts
-- ==============================================================

INSERT INTO navigation_menu (id, site_key, parent_id, name, link_url, display_order, locale, is_active) VALUES
    ('b1000001-0000-4000-8000-000000000001'::uuid, 'PORTFOLIO', NULL, '홈', '/', 0, 'ko', TRUE),
    ('b1000001-0000-4000-8000-000000000002'::uuid, 'PORTFOLIO', NULL, '경력기술서', '/resume', 1, 'ko', TRUE),
    ('b1000001-0000-4000-8000-000000000003'::uuid, 'PORTFOLIO', NULL, 'Home', '/', 0, 'en', TRUE),
    ('b1000001-0000-4000-8000-000000000004'::uuid, 'PORTFOLIO', NULL, 'Resume', '/resume', 1, 'en', TRUE),
    ('b1000001-0000-4000-8000-000000000005'::uuid, 'PORTFOLIO', NULL, 'ホーム', '/', 0, 'ja', TRUE),
    ('b1000001-0000-4000-8000-000000000006'::uuid, 'PORTFOLIO', NULL, '職務経歴書', '/resume', 1, 'ja', TRUE);
