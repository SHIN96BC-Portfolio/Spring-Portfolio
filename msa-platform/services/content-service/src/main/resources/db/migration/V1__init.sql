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

-- ==============================================================
-- CAREER page seed (ko) — mirrors FE portfolio-career-sections.ko.ts
-- ==============================================================

INSERT INTO home_section (
    id, page_key, section_key, section_type, locale,
    draft_title, draft_config, draft_config_schema_version,
    published_title, published_config, published_config_schema_version,
    version, published_at, display_order, is_active
) VALUES (
    'a1000001-0000-4000-8000-000000000001'::uuid, 'CAREER', 'intro', 'MARKDOWN', 'ko',
    '경력기술서 — 신병철 (프론트엔드 개발자)', '{"body":"5년차 프론트엔드 개발자로, 레거시 서비스의 차세대 재구축과 End-to-End 신규 개발을 모두 수행해왔습니다. 대규모 리팩터링·성능 최적화·풀스택 대응에 강점이 있으며, 아래는 대표 프로젝트를 **문제 → 해결 → 성과** 관점으로 정리한 내용입니다."}'::jsonb, 1,
    '경력기술서 — 신병철 (프론트엔드 개발자)', '{"body":"5년차 프론트엔드 개발자로, 레거시 서비스의 차세대 재구축과 End-to-End 신규 개발을 모두 수행해왔습니다. 대규모 리팩터링·성능 최적화·풀스택 대응에 강점이 있으며, 아래는 대표 프로젝트를 **문제 → 해결 → 성과** 관점으로 정리한 내용입니다."}'::jsonb, 1,
    1, NOW(), 0, TRUE
);
INSERT INTO home_section (
    id, page_key, section_key, section_type, locale,
    draft_title, draft_config, draft_config_schema_version,
    published_title, published_config, published_config_schema_version,
    version, published_at, display_order, is_active
) VALUES (
    'a1000001-0000-4000-8000-000000000002'::uuid, 'CAREER', 'project-modetour-nextgen', 'RESUME_PROJECT', 'ko',
    '모두투어 B2C/B2B 여행 플랫폼 차세대 재구축', '{"projectId":"modetour-nextgen","orderLabel":"1","title":"모두투어 B2C/B2B 여행 플랫폼 차세대 재구축","company":"와이리즘","period":"2024.08 ~ 재직중","role":"프론트엔드 개발","links":[{"label":"modetour.com","url":"https://www.modetour.com"},{"label":"elpis.modetour.co.kr","url":"https://elpis.modetour.co.kr"},{"label":"go.modetour.co.kr","url":"https://go.modetour.co.kr"},{"label":"gentlemonster.modetour.com","url":"https://gentlemonster.modetour.com"},{"label":"homeplus1.modetour.co.kr","url":"https://homeplus1.modetour.co.kr"}],"problem":"운영 중인 as-is 서비스를 유지하면서, 동시에 차세대 프론트엔드를 전면 재구축해야 하는 과제. 인수 시점의 서비스는 결제·뒤로가기(라우팅) 등 핵심 기능이 정상 동작하지 않을 만큼 버그가 많고 불안정한 상태였음. 또한 코드 구조상 props 드릴링이 심하고 공통화가 되어 있지 않아, 동일 컴포넌트가 페이지마다 중복 존재해 한 번 수정할 때 여러 파일을 반복 수정해야 했고 디버깅에도 많은 시간이 소요됨. 한정된 인원으로 300개이상의 BP/ONBP 사이트를 효율적으로 운영할 구조도 필요했음.","workSections":[{"title":"1) 서비스 안정화 (레거시 버그 대응)","items":["추가 개발건과 결제 실패·비정상 라우팅 등 critical 버그를 포함해 **300건 이상의 이슈를 처리**하며 서비스를 정상 궤도로 안정화","정상 동작하지 않던 핵심 플로우를 하나씩 진단·수정해 서비스 신뢰성 확보"]},{"title":"2) 아키텍처·구조 개선","items":["**원소스 멀티사이트 구조 설계** — 도메인별 사이트 정보를 로드하고 API 헤더에 사이트 컨텍스트를 주입해, 단일 코드베이스로 300개이상의 사이트를 운영하는 구조 구현","**Turborepo 모노레포 전환** — 300개이상의 BP/ONBP 도메인 통합 관리, 도메인별 config 분리, yarn→pnpm 전환, 사이트별 빌드 파이프라인 구성","**공통 컴포넌트화 + props 드릴링 해소** — 페이지마다 중복되던 컴포넌트를 공통 컴포넌트로 통합. 동일 수정 시 4개 파일 → 1개 파일로 작업 범위를 줄여 유지보수·디버깅 시간을 단축하고 사이드 이펙트와 휴먼 에러 발생 지점 감소","**FSD 아키텍처 도입**, FE Model + Mapper 패턴으로 BE API 변경 영향도 최소화"]},{"title":"3) 성능 최적화","items":["**페이지 로딩 최적화** — SSG/SSR을 상황에 맞게 조합하고 TanStack Query 캐싱으로 불필요한 API 중복 호출·중복 로딩 제거, 불필요하게 반복 실행되던 useEffect 정리. 로딩이 가장 오래 걸리던 페이지 기준 약 15초 → 5초 수준으로 단축","**빌드~배포 시간 단축** — 기존 파이프라인의 비효율을 진단·제거. 설정만 되어 있고 실제로는 동작하지 않고 빌드 시간만 늘어나게 만드는 불필요한 코드들을 제거, 잘못 설정되어 정상적으로 동작하지 않던 캐시 설정을 Turborepo·Next 빌드 캐시를 도입하여 정상 적용하고, 불필요한 체크 스텝과 중복 실행되던 `yarn install`을 제거. 빌드 큐·캐시를 정비해 빌드~배포 30분+ → 12~15분 (약 50~60% 단축)"]},{"title":"4) UI·기술 부채 개선","items":["**자체 UI 라이브러리 구축** — 무리하게 적용된 antd로 인한 CSS 애니메이션 버벅임을 해소하기 위해 antd를 점진 제거하고 모두투어 전용 UI 라이브러리 구축, react-print·react-date 등 문제 라이브러리 자체 구현·교체","**Next.js 12→15 메이저 버전업** — App Router·React 19 대응 포함 점진적 마이그레이션을 서비스 무중단으로 수행","RTK Query→TanStack Query·Redux→Zustand 무중단 점진 전환, 페이지별 중복 로직 공통화, 하드코딩 상수화"]},{"title":"5) 팀 생산성·협업","items":["**AI 개발 워크플로우 팀 표준화** — Cursor Agent 규칙 및 Claude Code·Gemini CLI 가이드를 도입해 팀 공통 작업 방식과 온보딩 프로세스를 문서화"]}],"outcomes":["결제·라우팅 등 핵심 장애를 해소하고 **300건+ 이슈를 처리**해 불안정하던 레거시를 안정 궤도로 전환","300개 이상의 사이트를 **단일 코드베이스·단일 모노레포**로 운영·배포하는 체계 확립","**배포 시간 약 50~60% 단축**, 주요 페이지 로딩 대폭 개선으로 개발 생산성·사용자 경험 동시 향상","메이저 버전업·상태관리 전환을 **서비스 중단 없이** 완료해 안정성과 최신 기술 스택 동시 확보"],"extraSections":[{"title":"CI/CD·인프라 재설계 (인프라팀과 협업)","body":"차세대 전환에 맞춰 배포 파이프라인과 인프라를 전면 재설계하는 작업에 참여했습니다.","items":["**파이프라인 체계 재설계** — B2C 단일 서비스 기준 8개 파이프라인을, B2C·BP·ONBP × 4환경(dev/stg/prd/stby) 20개+ 체계로 분리. `pipeline-deploys.yml` 오케스트레이터를 통해 원하는 서비스·환경만 선택 배포하는 구조 구성","**빌드 방식 개선** — Docker 내부 빌드(Yarn workspaces)에서 Turbo prune + 호스트 pnpm/turbo 빌드 + Docker 패키징 분리 구조로 전환, buildx registry 캐시 도입으로 빌드 시간 단축","**배포 인프라 전환** — Azure AKS에서 Azure Local ARC(Connected K8s) 프록시 방식으로 전환, `kubectl rollout status` 기반 배포 검증 추가로 배포 안정성 확보","**DR·페일오버 대응** — standby 파이프라인을 신규 구성해 failover(active/standby) 기반 재해 복구 체계 마련","**Helm 차트 고도화** — topologySpreadConstraints(노드 분산), readinessProbe(`/api/health`), CPU/메모리 기반 HPA 오토스케일 적용","**배포 전략 전환 판단** — 차세대 구축기의 릴리스 트레인·통합 브랜치 방식에서, 오픈 후 잦은 핫픽스·긴급 배포에 대응하기 위한 유연한 수동 배포 전략으로 전환"]}],"techStack":["Next.js 12→15","TypeScript","Turborepo","pnpm","FSD","TanStack Query","Zustand","Redux","RTK Query","axios","Tailwind CSS","Azure DevOps","ACR","Helm","Kubernetes","Docker","Git"]}'::jsonb, 1,
    '모두투어 B2C/B2B 여행 플랫폼 차세대 재구축', '{"projectId":"modetour-nextgen","orderLabel":"1","title":"모두투어 B2C/B2B 여행 플랫폼 차세대 재구축","company":"와이리즘","period":"2024.08 ~ 재직중","role":"프론트엔드 개발","links":[{"label":"modetour.com","url":"https://www.modetour.com"},{"label":"elpis.modetour.co.kr","url":"https://elpis.modetour.co.kr"},{"label":"go.modetour.co.kr","url":"https://go.modetour.co.kr"},{"label":"gentlemonster.modetour.com","url":"https://gentlemonster.modetour.com"},{"label":"homeplus1.modetour.co.kr","url":"https://homeplus1.modetour.co.kr"}],"problem":"운영 중인 as-is 서비스를 유지하면서, 동시에 차세대 프론트엔드를 전면 재구축해야 하는 과제. 인수 시점의 서비스는 결제·뒤로가기(라우팅) 등 핵심 기능이 정상 동작하지 않을 만큼 버그가 많고 불안정한 상태였음. 또한 코드 구조상 props 드릴링이 심하고 공통화가 되어 있지 않아, 동일 컴포넌트가 페이지마다 중복 존재해 한 번 수정할 때 여러 파일을 반복 수정해야 했고 디버깅에도 많은 시간이 소요됨. 한정된 인원으로 300개이상의 BP/ONBP 사이트를 효율적으로 운영할 구조도 필요했음.","workSections":[{"title":"1) 서비스 안정화 (레거시 버그 대응)","items":["추가 개발건과 결제 실패·비정상 라우팅 등 critical 버그를 포함해 **300건 이상의 이슈를 처리**하며 서비스를 정상 궤도로 안정화","정상 동작하지 않던 핵심 플로우를 하나씩 진단·수정해 서비스 신뢰성 확보"]},{"title":"2) 아키텍처·구조 개선","items":["**원소스 멀티사이트 구조 설계** — 도메인별 사이트 정보를 로드하고 API 헤더에 사이트 컨텍스트를 주입해, 단일 코드베이스로 300개이상의 사이트를 운영하는 구조 구현","**Turborepo 모노레포 전환** — 300개이상의 BP/ONBP 도메인 통합 관리, 도메인별 config 분리, yarn→pnpm 전환, 사이트별 빌드 파이프라인 구성","**공통 컴포넌트화 + props 드릴링 해소** — 페이지마다 중복되던 컴포넌트를 공통 컴포넌트로 통합. 동일 수정 시 4개 파일 → 1개 파일로 작업 범위를 줄여 유지보수·디버깅 시간을 단축하고 사이드 이펙트와 휴먼 에러 발생 지점 감소","**FSD 아키텍처 도입**, FE Model + Mapper 패턴으로 BE API 변경 영향도 최소화"]},{"title":"3) 성능 최적화","items":["**페이지 로딩 최적화** — SSG/SSR을 상황에 맞게 조합하고 TanStack Query 캐싱으로 불필요한 API 중복 호출·중복 로딩 제거, 불필요하게 반복 실행되던 useEffect 정리. 로딩이 가장 오래 걸리던 페이지 기준 약 15초 → 5초 수준으로 단축","**빌드~배포 시간 단축** — 기존 파이프라인의 비효율을 진단·제거. 설정만 되어 있고 실제로는 동작하지 않고 빌드 시간만 늘어나게 만드는 불필요한 코드들을 제거, 잘못 설정되어 정상적으로 동작하지 않던 캐시 설정을 Turborepo·Next 빌드 캐시를 도입하여 정상 적용하고, 불필요한 체크 스텝과 중복 실행되던 `yarn install`을 제거. 빌드 큐·캐시를 정비해 빌드~배포 30분+ → 12~15분 (약 50~60% 단축)"]},{"title":"4) UI·기술 부채 개선","items":["**자체 UI 라이브러리 구축** — 무리하게 적용된 antd로 인한 CSS 애니메이션 버벅임을 해소하기 위해 antd를 점진 제거하고 모두투어 전용 UI 라이브러리 구축, react-print·react-date 등 문제 라이브러리 자체 구현·교체","**Next.js 12→15 메이저 버전업** — App Router·React 19 대응 포함 점진적 마이그레이션을 서비스 무중단으로 수행","RTK Query→TanStack Query·Redux→Zustand 무중단 점진 전환, 페이지별 중복 로직 공통화, 하드코딩 상수화"]},{"title":"5) 팀 생산성·협업","items":["**AI 개발 워크플로우 팀 표준화** — Cursor Agent 규칙 및 Claude Code·Gemini CLI 가이드를 도입해 팀 공통 작업 방식과 온보딩 프로세스를 문서화"]}],"outcomes":["결제·라우팅 등 핵심 장애를 해소하고 **300건+ 이슈를 처리**해 불안정하던 레거시를 안정 궤도로 전환","300개 이상의 사이트를 **단일 코드베이스·단일 모노레포**로 운영·배포하는 체계 확립","**배포 시간 약 50~60% 단축**, 주요 페이지 로딩 대폭 개선으로 개발 생산성·사용자 경험 동시 향상","메이저 버전업·상태관리 전환을 **서비스 중단 없이** 완료해 안정성과 최신 기술 스택 동시 확보"],"extraSections":[{"title":"CI/CD·인프라 재설계 (인프라팀과 협업)","body":"차세대 전환에 맞춰 배포 파이프라인과 인프라를 전면 재설계하는 작업에 참여했습니다.","items":["**파이프라인 체계 재설계** — B2C 단일 서비스 기준 8개 파이프라인을, B2C·BP·ONBP × 4환경(dev/stg/prd/stby) 20개+ 체계로 분리. `pipeline-deploys.yml` 오케스트레이터를 통해 원하는 서비스·환경만 선택 배포하는 구조 구성","**빌드 방식 개선** — Docker 내부 빌드(Yarn workspaces)에서 Turbo prune + 호스트 pnpm/turbo 빌드 + Docker 패키징 분리 구조로 전환, buildx registry 캐시 도입으로 빌드 시간 단축","**배포 인프라 전환** — Azure AKS에서 Azure Local ARC(Connected K8s) 프록시 방식으로 전환, `kubectl rollout status` 기반 배포 검증 추가로 배포 안정성 확보","**DR·페일오버 대응** — standby 파이프라인을 신규 구성해 failover(active/standby) 기반 재해 복구 체계 마련","**Helm 차트 고도화** — topologySpreadConstraints(노드 분산), readinessProbe(`/api/health`), CPU/메모리 기반 HPA 오토스케일 적용","**배포 전략 전환 판단** — 차세대 구축기의 릴리스 트레인·통합 브랜치 방식에서, 오픈 후 잦은 핫픽스·긴급 배포에 대응하기 위한 유연한 수동 배포 전략으로 전환"]}],"techStack":["Next.js 12→15","TypeScript","Turborepo","pnpm","FSD","TanStack Query","Zustand","Redux","RTK Query","axios","Tailwind CSS","Azure DevOps","ACR","Helm","Kubernetes","Docker","Git"]}'::jsonb, 1,
    1, NOW(), 1, TRUE
);
INSERT INTO home_section (
    id, page_key, section_key, section_type, locale,
    draft_title, draft_config, draft_config_schema_version,
    published_title, published_config, published_config_schema_version,
    version, published_at, display_order, is_active
) VALUES (
    'a1000001-0000-4000-8000-000000000003'::uuid, 'CAREER', 'project-uteas', 'RESUME_PROJECT', 'ko',
    '미세먼지 배출량 조회·시각화 서비스 (UTEAS)', '{"projectId":"uteas","orderLabel":"2","title":"미세먼지 배출량 조회·시각화 서비스 (UTEAS)","company":"이알솔루션","period":"2023.06 ~ 2023.07","role":"풀스택 개발 (FE·BE·DB 단독)","links":[],"problem":"도로·지역·시간 단위 미세먼지 배출량을 조회·시각화하는 환경 모니터링 서비스 신규 개발. **1.4억 건 이상의 대용량 테이블** 조회에서 4~6분이 걸리는 심각한 성능 병목이 존재.","workSections":[{"title":"한 일","items":["FE·BE·DB 설계를 단독으로 수행","**인덱스 최적화 및 통계 테이블 설계**로 대용량 조회 병목 구조적 해소","Recharts 통계 시각화, v-world-map 지도, 엑셀 업로드 기능 구현","Nest.js API·MariaDB 스키마 설계, AWS EC2 배포"]}],"outcomes":["**1.4억 건 조회 4~6분 → 5초 이내 (약 50배 이상 개선)**","프론트·백·인프라를 단독으로 완성해 End-to-End 개발 역량 입증"],"techStack":["React(Vite)","Nest.js","TypeScript","MariaDB","TanStack Query","Docker","AWS EC2"]}'::jsonb, 1,
    '미세먼지 배출량 조회·시각화 서비스 (UTEAS)', '{"projectId":"uteas","orderLabel":"2","title":"미세먼지 배출량 조회·시각화 서비스 (UTEAS)","company":"이알솔루션","period":"2023.06 ~ 2023.07","role":"풀스택 개발 (FE·BE·DB 단독)","links":[],"problem":"도로·지역·시간 단위 미세먼지 배출량을 조회·시각화하는 환경 모니터링 서비스 신규 개발. **1.4억 건 이상의 대용량 테이블** 조회에서 4~6분이 걸리는 심각한 성능 병목이 존재.","workSections":[{"title":"한 일","items":["FE·BE·DB 설계를 단독으로 수행","**인덱스 최적화 및 통계 테이블 설계**로 대용량 조회 병목 구조적 해소","Recharts 통계 시각화, v-world-map 지도, 엑셀 업로드 기능 구현","Nest.js API·MariaDB 스키마 설계, AWS EC2 배포"]}],"outcomes":["**1.4억 건 조회 4~6분 → 5초 이내 (약 50배 이상 개선)**","프론트·백·인프라를 단독으로 완성해 End-to-End 개발 역량 입증"],"techStack":["React(Vite)","Nest.js","TypeScript","MariaDB","TanStack Query","Docker","AWS EC2"]}'::jsonb, 1,
    1, NOW(), 2, TRUE
);
INSERT INTO home_section (
    id, page_key, section_key, section_type, locale,
    draft_title, draft_config, draft_config_schema_version,
    published_title, published_config, published_config_schema_version,
    version, published_at, display_order, is_active
) VALUES (
    'a1000001-0000-4000-8000-000000000004'::uuid, 'CAREER', 'project-lhat', 'RESUME_PROJECT', 'ko',
    '필리핀 Lhat 플랫폼 백오피스·웹앱 구축', '{"projectId":"lhat","orderLabel":"3","title":"필리핀 Lhat 플랫폼 백오피스·웹앱 구축","company":"파인테크소프트","period":"2023.11 ~ 2024.05","role":"프론트엔드 개발","links":[],"problem":"여러 도메인(Mall·Food·Store·동물병원)의 백오피스와 사용자 웹앱을 신규 구축·운영했습니다.","workSections":[{"title":"주요 프로젝트","items":["**Lhat Mall Admin** — 상품 판매 기능 추가에 따른 관리자 백오피스를 구조 설계부터 API 연동까지 단독 구축. Firebase 인증, 상품·옵션·카테고리·이벤트·주문·리뷰 관리, 무한스크롤 이벤트 상품 선택, i18n 적용","**Lhat Food / Store Admin** — 기본·거리별 배달비 정책 기능 신규 추가, react-hook-form + Zod 폼 검증, 점주/고객 부담 비율 설정 UI 구현","**Zootopia (동물병원)** — 예약 관리 Admin + 온라인 예약 웹앱 구축. 예약 생성·조회·취소, 펫 최대 10마리 관리, Email·SNS 통합 로그인(NextAuth), FCM 푸시 알림 연동, 소개 사이트까지 구축"]}],"outcomes":["구조 설계부터 배포까지 **단독 오너십**으로 다수 서비스 완성","인증·결제·알림 등 핵심 도메인을 아우르는 백오피스·웹앱 개발 경험 축적"],"techStack":["Next.js","TypeScript","Zustand/Jotai","TanStack Query","MUI","Firebase","AWS Amplify","NextAuth","Zod"]}'::jsonb, 1,
    '필리핀 Lhat 플랫폼 백오피스·웹앱 구축', '{"projectId":"lhat","orderLabel":"3","title":"필리핀 Lhat 플랫폼 백오피스·웹앱 구축","company":"파인테크소프트","period":"2023.11 ~ 2024.05","role":"프론트엔드 개발","links":[],"problem":"여러 도메인(Mall·Food·Store·동물병원)의 백오피스와 사용자 웹앱을 신규 구축·운영했습니다.","workSections":[{"title":"주요 프로젝트","items":["**Lhat Mall Admin** — 상품 판매 기능 추가에 따른 관리자 백오피스를 구조 설계부터 API 연동까지 단독 구축. Firebase 인증, 상품·옵션·카테고리·이벤트·주문·리뷰 관리, 무한스크롤 이벤트 상품 선택, i18n 적용","**Lhat Food / Store Admin** — 기본·거리별 배달비 정책 기능 신규 추가, react-hook-form + Zod 폼 검증, 점주/고객 부담 비율 설정 UI 구현","**Zootopia (동물병원)** — 예약 관리 Admin + 온라인 예약 웹앱 구축. 예약 생성·조회·취소, 펫 최대 10마리 관리, Email·SNS 통합 로그인(NextAuth), FCM 푸시 알림 연동, 소개 사이트까지 구축"]}],"outcomes":["구조 설계부터 배포까지 **단독 오너십**으로 다수 서비스 완성","인증·결제·알림 등 핵심 도메인을 아우르는 백오피스·웹앱 개발 경험 축적"],"techStack":["Next.js","TypeScript","Zustand/Jotai","TanStack Query","MUI","Firebase","AWS Amplify","NextAuth","Zod"]}'::jsonb, 1,
    1, NOW(), 3, TRUE
);
INSERT INTO home_section (
    id, page_key, section_key, section_type, locale,
    draft_title, draft_config, draft_config_schema_version,
    published_title, published_config, published_config_schema_version,
    version, published_at, display_order, is_active
) VALUES (
    'a1000001-0000-4000-8000-000000000005'::uuid, 'CAREER', 'project-er-platform', 'RESUME_PROJECT', 'ko',
    '다양한 플랫폼·공공 서비스 개발', '{"projectId":"er-platform","orderLabel":"4","title":"다양한 플랫폼·공공 서비스 개발","company":"이알솔루션","period":"2022.07 ~ 2023.09","role":"풀스택 개발 연구원","links":[],"problem":"프론트엔드 주력으로 풀스택·모바일까지 폭넓게 수행했습니다.","workSections":[{"title":"주요 프로젝트","items":["**DdaPick / DdaPlace** — B2B·B2C 유통관리 웹앱 및 B2C 쇼핑몰 신규 개발. 기획 단계 참여, 프론트엔드 단독 구축, Editor.js 상품 에디터·무한스크롤·Atomic Design 패턴 도입","**전주경제운전 CMS** — 시내버스 경제운전 지표 관리 시스템. 권한 관리, Chart.js 운행 지표 시각화, Spring + eGovFrame API·MariaDB 설계·AWS 배포 (풀스택)","**유진레미콘 입고관리** — 키오스크 송장 촬영 Android 앱. 외부 카메라 연동, 키오스크 UX, React 렌더링 최적화","**반려견 순찰대** — 실시간 산책 기능 iOS 네이티브 앱 (Swift/SwiftUI), Naver Map 기반 실시간 경로·거리 표시","**인천항보안공사** — 공식 사이트 유지보수, 웹접근성(WA) 인증심사 대응·통과, 모의해킹 보안 취약점 패치"]}],"outcomes":[],"techStack":["React","Next.js","TypeScript","Redux","Java/Spring","eGovFrame","Nest.js","React Native","Swift","MariaDB","AWS"]}'::jsonb, 1,
    '다양한 플랫폼·공공 서비스 개발', '{"projectId":"er-platform","orderLabel":"4","title":"다양한 플랫폼·공공 서비스 개발","company":"이알솔루션","period":"2022.07 ~ 2023.09","role":"풀스택 개발 연구원","links":[],"problem":"프론트엔드 주력으로 풀스택·모바일까지 폭넓게 수행했습니다.","workSections":[{"title":"주요 프로젝트","items":["**DdaPick / DdaPlace** — B2B·B2C 유통관리 웹앱 및 B2C 쇼핑몰 신규 개발. 기획 단계 참여, 프론트엔드 단독 구축, Editor.js 상품 에디터·무한스크롤·Atomic Design 패턴 도입","**전주경제운전 CMS** — 시내버스 경제운전 지표 관리 시스템. 권한 관리, Chart.js 운행 지표 시각화, Spring + eGovFrame API·MariaDB 설계·AWS 배포 (풀스택)","**유진레미콘 입고관리** — 키오스크 송장 촬영 Android 앱. 외부 카메라 연동, 키오스크 UX, React 렌더링 최적화","**반려견 순찰대** — 실시간 산책 기능 iOS 네이티브 앱 (Swift/SwiftUI), Naver Map 기반 실시간 경로·거리 표시","**인천항보안공사** — 공식 사이트 유지보수, 웹접근성(WA) 인증심사 대응·통과, 모의해킹 보안 취약점 패치"]}],"outcomes":[],"techStack":["React","Next.js","TypeScript","Redux","Java/Spring","eGovFrame","Nest.js","React Native","Swift","MariaDB","AWS"]}'::jsonb, 1,
    1, NOW(), 4, TRUE
);
INSERT INTO home_section (
    id, page_key, section_key, section_type, locale,
    draft_title, draft_config, draft_config_schema_version,
    published_title, published_config, published_config_schema_version,
    version, published_at, display_order, is_active
) VALUES (
    'a1000001-0000-4000-8000-000000000006'::uuid, 'CAREER', 'strengths', 'MARKDOWN', 'ko',
    '강점 요약', '{"body":"- **레거시 → 차세대 전환**을 무중단으로 수행하는 대규모 리팩터링 역량\n- **성능 병목을 구조적으로 진단·해결**하는 최적화 역량 (50배 개선 사례)\n- **CI/CD 파이프라인·K8s 인프라 재설계**까지 다루는 배포·운영 역량\n- 기획부터 배포까지 **End-to-End로 완성**하는 풀스택 오너십\n- 프론트·백·모바일·인프라를 아우르는 넓은 기술 스펙트럼"}'::jsonb, 1,
    '강점 요약', '{"body":"- **레거시 → 차세대 전환**을 무중단으로 수행하는 대규모 리팩터링 역량\n- **성능 병목을 구조적으로 진단·해결**하는 최적화 역량 (50배 개선 사례)\n- **CI/CD 파이프라인·K8s 인프라 재설계**까지 다루는 배포·운영 역량\n- 기획부터 배포까지 **End-to-End로 완성**하는 풀스택 오너십\n- 프론트·백·모바일·인프라를 아우르는 넓은 기술 스펙트럼"}'::jsonb, 1,
    1, NOW(), 5, TRUE
);

-- ==============================================================
-- GNB navigation_menu seed — mirrors FE portfolio-navigation.*.ts
-- ==============================================================

INSERT INTO navigation_menu (id, parent_id, name, link_url, display_order, locale, is_active) VALUES
    ('b1000001-0000-4000-8000-000000000001'::uuid, NULL, '홈', '/', 0, 'ko', TRUE),
    ('b1000001-0000-4000-8000-000000000002'::uuid, NULL, '경력기술서', '/resume', 1, 'ko', TRUE),
    ('b1000001-0000-4000-8000-000000000003'::uuid, NULL, 'Home', '/', 0, 'en', TRUE),
    ('b1000001-0000-4000-8000-000000000004'::uuid, NULL, 'Resume', '/resume', 1, 'en', TRUE),
    ('b1000001-0000-4000-8000-000000000005'::uuid, NULL, 'ホーム', '/', 0, 'ja', TRUE),
    ('b1000001-0000-4000-8000-000000000006'::uuid, NULL, '職務経歴書', '/resume', 1, 'ja', TRUE);
