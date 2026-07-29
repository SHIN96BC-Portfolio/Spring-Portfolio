# fashion-service
OOTD와 브랜드, 상품의 패션 분류·태깅 정보를 소유하는 서비스입니다.

## 책임
- OOTD 관리 (본문·이미지·상품 태그)
- OOTD **좋아요·댓글** (`ootd_like`, `ootd_comment`, BOUNDARY-02)
- 브랜드와 상품 태깅
- 스타일 태그 관리

## 담당하지 않는 것 / 서비스 경계
- 상품 판매, 주문과 재고는 `commerce-service`가 담당합니다.
- **일반 소셜 피드** 게시물·좋아요·댓글은 `social-service` (`post`, `comment`, `post_like` 등)가 담당합니다.
- OOTD 반응 API·원장은 **이 서비스만** 소유합니다. social에 OOTD 반응 테이블을 두지 않습니다.
- 개인화 추천 계산은 `recommendation-service`가 담당합니다.

## 기술 정보
| 항목 | 값 |
|---|---|
| 포트 | `8087` |
| DB | PostgreSQL `postgres-fashion` (`fashiondb`, 로컬 `5436`) |
| Gradle 모듈 경로 | `:services:fashion-service` |

## 주요 연동 및 이벤트
- 모든 도메인 이벤트를 `activity-feed-service`가 구독한다는 설계만 문서화되어 있습니다.
- fashion-service 고유의 구체적인 발행·구독 이벤트와 실제 서비스 연동은 미정입니다.

## 서비스 경계 — OOTD vs 소셜 피드 (BOUNDARY-02)

| 대상 | 소유 서비스 | DB 원장 |
|------|-------------|---------|
| OOTD 본문·이미지·태그 | fashion | `ootd`, `ootd_image`, `product_tag` |
| OOTD 좋아요·댓글 | fashion | `ootd_like`, `ootd_comment` |
| 일반 피드 게시물·반응 | social | `post`, `comment`, `post_like`, `comment_like`, `post_share` |

BFF는 OOTD 상세의 반응 API를 fashion으로, 피드 post 반응을 social로 라우팅합니다.

## 브랜드·OOTD 집계 (DB 감사 FASHION-01 반영)

- **`ootd_brand`**: OOTD ↔ 브랜드 N:M 원장. `brand.ootd_count`는 **ACTIVE** OOTD 연결만 트리거로 ±1.
- **`brand_follow`**: `brand.follower_count`도 트리거로 ±1 (앱이 카운터 직접 수정 금지).
- OOTD `status`가 ACTIVE↔비ACTIVE로 바뀌면 연결된 모든 브랜드 `ootd_count`를 일괄 조정합니다.
- 드리프트 복구: `SELECT reconcile_brand_ootd_counters();`
- `ootd.style_tags` JSONB는 임시 캐시입니다. 정규 `style_tag` 마스터·N:M은 관리 UI 도입 시 추가합니다.
- **Low O3**: `idx_brand_follow_user_created` — 사용자별 팔로우 브랜드 최신순.
- **Low O4**: `ootd.season` CHECK (`SPRING`/`SUMMER`/`FALL`/`WINTER`).
- **Low O2**: `brand.status` `ACTIVE` | `DEPRECATED` — commerce `brand_id` 논리 참조 고아 방지.

## Soft-delete · 자식 정합성 (DB 감사 SOCIAL-02 반영)
- `ootd`/`ootd_comment`에 `deleted_at`과 status↔deleted_at CHECK.
- 대댓글은 `(parent_comment_id, ootd_id) → ootd_comment(id, ootd_id)` 복합 FK로
  부모가 같은 OOTD에만 속하도록 강제합니다.
- `comment_count`는 ACTIVE 댓글만 집계. 삭제된 OOTD/댓글에 대한 반응·대댓글은 트리거가 거부합니다.

## 실행 방법
```bash
cd msa-platform
./gradlew :services:fashion-service:bootRun
```

## 현재 구현 상태
현재는 **스켈레톤**입니다.
- 구현: 애플리케이션 부트스트랩, `/hello`, PostgreSQL·Flyway·Kafka 기본 설정, `brand`, `brand_follow`, `ootd`(soft-delete), `ootd_brand`, `ootd_image`, `product_tag`, `ootd_like`, `ootd_comment`(soft-delete·복합 FK), `outbox_events`, `processed_events` 테이블 migration
- 미구현: OOTD·브랜드·상품 태그 Entity·Repository·API와 비즈니스 로직, 이벤트 처리
