# content-service
GNB, 배너, 정적 페이지와 홈 섹션 구성을 소유하는 CMS 도메인 서비스입니다.

## 책임
- GNB(내비게이션 메뉴) 관리
- 슬롯별 배너 관리
- 소개·약관 등 정적 페이지 관리
- 홈 화면 섹션과 노출 순서 관리

## 담당하지 않는 것 / 서비스 경계
- 관리자 GraphQL 진입점과 화면용 조합은 `admin-bff`가 담당합니다.
- 사용자 홈 화면용 조회 조합은 `user-bff`가 담당합니다.
- 이미지 객체 저장과 썸네일 처리는 `media-service`가 담당합니다.

## 기술 정보
| 항목 | 값 |
|---|---|
| 포트 | `8093` |
| DB | PostgreSQL `postgres-content` (`contentdb`, 로컬 `5441`) |
| Gradle 모듈 경로 | `:services:content-service` |

## 주요 연동 및 이벤트
- 설계 흐름은 `admin-bff`가 CMS를 관리하고 `user-bff`가 홈 화면 구성을 조회하는 방식입니다.
- 두 BFF와의 실제 HTTP API 연동은 아직 구현되지 않았습니다.
- 구체적인 발행·구독 이벤트는 현재 문서와 코드에서 확인되지 않아 미정입니다.

## Draft / Publish (DB 감사 CMS-01 반영)

`static_page`, `home_section`은 **draft**와 **published** payload를 분리합니다.

| API | 읽기 대상 |
|-----|-----------|
| Admin preview | `draft_title`, `draft_body` / `draft_title`, `draft_config` |
| Public (`user-bff`) | `published_*` ( `static_page`는 `is_published = true` 추가 ) |

**Publish 트랜잭션 (앱 계약)**  
1. `published_*` ← 현재 `draft_*` 복사  
2. `version = version + 1`, `published_at = NOW()`  
3. `static_page`만 `is_published = true` 설정  

초안만 수정하면 게시본은 그대로라 Admin 미리보기와 라이브 사이트를 동시에 만족합니다.

## 페이지·섹션 스코프 (DB 감사 CMS-02 반영)

**`static_page.page_key`** (optional UNIQUE): `ABOUT`, `CAREER`, `TERMS` 등 Admin/FE 고정 코드. URL은 `slug` 유지.

**`home_section`** (페이지별 섹션 슬롯):

| 컬럼 | 역할 |
|------|------|
| `site_key` | `PORTFOLIO`, `COMMERCE`, `FASHION`, `SOCIAL` |
| `page_key` | `HOME`, `ABOUT`, `CAREER`, `PROJECTS` |
| `section_key` | 페이지 내 고정 슬롯 (`hero`, `project-grid` 등) |
| `section_type` | FE 컴포넌트 (`PROJECT_GRID`, `HERO`, `MARKDOWN`, …) |
| `draft_config_schema_version` | `draft_config` JSON 계약 버전 |
| `published_config_schema_version` | publish 시 스냅샷 |

- UNIQUE `(site_key, page_key, section_key, locale)` — 슬롯 중복 방지  
- UNIQUE `(site_key, page_key, display_order, locale)` — 페이지별 순서 충돌 방지  


Publish 시 `published_config_schema_version = draft_config_schema_version` 복사.

## 운영 하드닝 (Low)

- **CM-5**: 활성 배너·내비 인덱스는 `is_active` partial만. `starts_at`/`ends_at` “지금 노출”은 소량일 때 앱 필터로 충분.
- **CM-6**: `processed_events`는 플랫폼 공통 패턴 유지. content 도메인 Kafka 구독·발행 이벤트는 카탈로그 확정 후 연결.

## 실행 방법
```bash
cd msa-platform
./gradlew :services:content-service:bootRun
```

## 현재 구현 상태
현재는 **스켈레톤**입니다.
- 구현: `navigation_menu`, `banner`, `static_page`, `home_section`, `outbox_events`, `processed_events` 테이블 migration과 V2 기간 제약·조회 인덱스·테이블/컬럼 COMMENT, 애플리케이션 부트스트랩, `/hello`, PostgreSQL·Flyway·Kafka 기본 설정
- 미구현: CMS Entity·Repository·HTTP API와 비즈니스 로직, `admin-bff` 관리 연동, `user-bff` 조회 연동, 이벤트 처리
