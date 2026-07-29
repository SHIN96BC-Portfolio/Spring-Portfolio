# user-service
사용자 프로필, 팔로우 관계와 인플루언서 등급을 소유하는 서비스입니다.

## 책임
- 사용자 프로필 관리
- 팔로우 관계 관리
- 인플루언서 **등급·점수 표시 스냅샷** (계산은 `recommendation-service`, BOUNDARY-01)

## 담당하지 않는 것 / 서비스 경계
- 계정 인증, 토큰 발급과 인증 원장은 별도 `msa-auth`가 담당합니다.
- 사용자 화면용 데이터 조합은 `user-bff`가 담당합니다.
- 소셜 게시물과 반응은 `social-service`가 담당합니다.

## 기술 정보
| 항목 | 값 |
|---|---|
| 포트 | `8084` |
| DB | PostgreSQL `postgres-user` (`userdb`, 로컬 `5433`) |
| Gradle 모듈 경로 | `:services:user-service` |

## 주요 연동 및 이벤트
- `AccountRegistered` 구독 → 프로필 생성 (미구현).
  nickname 은 이벤트에 없음 → `ProvisionalNickname.fromAccountId(accountId)` 로
  `u{uuid32hex}` 임시값을 넣는다 (USER-01).
- `AccountEmailVerified` 구독 → `user_profile.email_verified=true` (미구현, AUTH-04).
- `AccountSuspended` 구독 → `user_profile.status=SUSPENDED`, 팔로우·공개 활동 거부 (미구현, AUTH-04).
- 현재 코드에는 실제 Kafka 소비자가 없습니다.

## 닉네임 초기화 (USER-01)
- auth는 공개 프로필을 소유하지 않으므로 `AccountRegistered`에 nickname이 없습니다.
- 가입 소비 시 `nickname = 'u' || replace(account_id::text, '-', '')`,
  `nickname_customized = false`로 INSERT합니다. `account_id` UNIQUE → 임시 닉네임도 충돌 없음.
- DB CHECK가 임시 닉네임 형식을 강제합니다. 사용자가 변경하면 `nickname_customized=true`.
- Java 규칙: `com.msaplatform.userservice.domain.model.ProvisionalNickname`

## 팔로우 카운터 동시성 (USER-02)
- 원본은 `follow_relation`이고 `follower_count`/`following_count`는 파생 캐시입니다.
- DB 트리거(`trg_follow_relation_counters`)가 INSERT/DELETE와 같은 트랜잭션에서
  카운터를 원자 증감합니다. **애플리케이션은 `follow_relation`만 INSERT/DELETE**하고
  카운터를 직접 갱신하면 안 됩니다 (이중 증감 발생).
- 상호 팔로우 동시 처리 데드락을 막기 위해 트리거는 항상 `user_profile.id`가
  작은 쪽부터 갱신합니다(잠금 순서 통일).
- 드리프트 복구·검증: `SELECT reconcile_follow_counters();` (보정 행 수 반환).

## 팔로우 조회 (Low)

- `idx_follow_relation_follower_created` — 내 팔로잉 목록 최신순.

## 상태 전파 (AUTH-04)
- `email_verified` / `status`는 auth 원본의 미러입니다. JWT가 남아 있어도
  `status=SUSPENDED`이면 쓰기 API를 거부해야 합니다.

## 인플루언서 등급 (BOUNDARY-01)
- **계산 원본**: `recommendation-service.influencer_metric` (`tier`, `influence_score`).
- **표시 스냅샷**: `user_profile.influencer_tier` / `influencer_score` / `influencer_tier_synced_at`.
- `recommendation-service`가 등급 재산정 후 `InfluencerTierUpdated` 발행 → user가 소비해 스냅샷 갱신 (미구현).
- tier 코드는 양쪽 동일: `MICRO`, `MID`, `MACRO`, `MEGA`.

## 실행 방법
```bash
cd msa-platform
./gradlew :services:user-service:bootRun
```

## 현재 구현 상태
현재는 **스켈레톤**입니다.
- 구현: 애플리케이션 부트스트랩, `/hello`, PostgreSQL·Flyway·Kafka 기본 설정, `user_profile`(임시 닉네임 규칙·email_verified·status 포함), `ProvisionalNickname`, `follow_relation`, `user_suggestion`, `outbox_events`, `processed_events` 테이블 migration
- 미구현: 프로필·팔로우·등급 Entity·Repository·API와 비즈니스 로직, auth 이벤트 소비 로직
