# social-service
소셜 게시물과 사용자 반응, 해시태그 데이터를 소유하는 서비스입니다.

## 책임
- **일반 피드** 게시물(`post`)과 좋아요·댓글·공유 (`post_like`, `comment`, `comment_like`, `post_share`)
- 해시태그 관리
- 트렌딩 및 연관 태그 처리

## 담당하지 않는 것 / 서비스 경계
- 사용자 프로필과 팔로우 관계는 `user-service`가 담당합니다.
- OOTD 본문·이미지·**OOTD 좋아요/댓글**은 `fashion-service` (`ootd`, `ootd_like`, `ootd_comment`, BOUNDARY-02).
- 통합 활동 읽기 모델은 `activity-feed-service`가 담당합니다.

## 반응 경계 (BOUNDARY-02)

- 이 서비스의 반응 원장은 **`post_id` / `comment_id` 기준**입니다.
- `ootd_id` 반응 테이블은 **없음** — fashion-service API·DB만 사용합니다.
- SOCIAL-01/02 패턴(원장 + 트리거 카운터)은 post/comment에만 적용됩니다.

## 기술 정보
| 항목 | 값 |
|---|---|
| 포트 | `8088` |
| DB | PostgreSQL `postgres-social` (`socialdb`, 로컬 `5437`) |
| Gradle 모듈 경로 | `:services:social-service` |

## 주요 연동 및 이벤트
- 모든 도메인 이벤트를 `activity-feed-service`가 구독한다는 설계만 문서화되어 있습니다.
- social-service 고유의 구체적인 발행·구독 이벤트와 실제 서비스 연동은 미정입니다.

## 반응 원장 (DB 감사 SOCIAL-01 반영)
- `comment.likes_count` / `post.share_count`만 있고 원장이 없으면 재집계·중복 반응
  방지가 불가능합니다. `comment_like`, `post_share`를 Source of Truth로 추가했습니다.
- 사용자당 대상 1회: `UNIQUE(comment_id, user_id)`, `UNIQUE(post_id, user_id)`.
- 카운터는 DB 트리거가 INSERT/DELETE와 같은 트랜잭션에서 원자 증감합니다
  (`post_like` → `likes_count`도 동일 패턴으로 맞춤).
- 애플리케이션은 원장 행만 INSERT/DELETE하고 카운터를 직접 갱신하면 안 됩니다.

## Soft-delete · 자식 정합성 (DB 감사 SOCIAL-02 반영)
- `post`/`comment`에 `deleted_at`과 status↔deleted_at CHECK를 둡니다. 삭제는 하드 DELETE
  대신 `status=DELETED` soft-delete입니다.
- 대댓글은 `UNIQUE(id, post_id)` + `FOREIGN KEY (parent_comment_id, post_id)
  REFERENCES comment(id, post_id)`로 **부모가 같은 게시물**에만 속하도록 강제합니다.
- `comments_count`는 `status=ACTIVE` 댓글만 집계합니다(soft-delete 시 -1).
- 삭제된 게시물에는 좋아요·공유·댓글 INSERT를, 삭제된 댓글에는 대댓글·좋아요 INSERT를
  BEFORE 트리거가 거부합니다.

## 해시태그 집계 (Low O6)

- `hashtag_usage_hourly.unique_users_count`는 시간대별 근사 집계입니다. 정밀 distinct 원장 없이는 완벽하지 않음을 스키마 COMMENT에 명시했습니다.

## 실행 방법
```bash
cd msa-platform
./gradlew :services:social-service:bootRun
```

## 현재 구현 상태
현재는 **스켈레톤**입니다.
- 구현: 애플리케이션 부트스트랩, `/hello`, PostgreSQL·Flyway·Kafka 기본 설정, `post`, `post_like`, `comment`, `comment_like`, `post_share`, `hashtag`, `post_hashtag`, `hashtag_usage_hourly`, `hashtag_co_occurrence`, `outbox_events`, `processed_events` 테이블 migration
- 미구현: 게시물·반응·해시태그 Entity·Repository·API와 비즈니스 로직, 트렌딩 계산, 이벤트 처리
