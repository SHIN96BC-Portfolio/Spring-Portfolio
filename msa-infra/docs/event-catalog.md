# 통합 이벤트 카탈로그

전체 시스템의 이벤트 발행/구독 관계 통합 문서.

## 발행자 → 구독자

| 이벤트 | 발행 (레포/서비스) | 구독 (레포/서비스) |
|--------|-------------------|-------------------|
| AccountRegistered | msa-auth | msa-platform (user, point, notification, activity-feed) |
| AccountEmailVerified | msa-auth | msa-platform (user, point, notification) |
| AccountSuspended | msa-auth | msa-platform (user, point, notification) |
| OAuthClientGranted | msa-auth | (선택) 보안 모니터링 |
| UserProfileCreated | msa-platform (user) | msa-platform (activity-feed) |
| UserFollowed | msa-platform (user) | msa-platform (notification, recommendation, activity-feed) |
| OrderCreated | msa-platform (commerce) | msa-platform (activity-feed) |
| OrderPaid | msa-platform (commerce) | msa-platform (point, notification, recommendation, activity-feed) |
| ProductViewed | msa-platform (commerce) | msa-platform (recommendation) |
| ProductPriceChanged | msa-platform (commerce) | msa-platform (notification, recommendation) |
| CartAbandoned | msa-platform (commerce) | msa-platform (notification) |
| RepurchaseTimingPredicted ⭐ | msa-platform (commerce) | msa-platform (notification) |
| PointEarned | msa-platform (point) | msa-platform (activity-feed) |
| InfluencerTierUpdated | msa-platform (recommendation) | msa-platform (user) |
| PointReserved (Saga) | msa-platform (point) | msa-platform (commerce - Orchestrator) |

## Cross-Repo 이벤트 (중요)

**msa-auth → msa-platform** 이벤트:
- AccountRegistered
- AccountEmailVerified
- AccountSuspended

이 이벤트들은 msa-auth 소유이며, msa-platform이 구독합니다.
스키마 변경 시 msa-auth가 backward compatible 원칙 준수.

### AUTH-04 상태 전파 계약

| auth 상태 변화 | 이벤트 | 소비자 반영 |
|----------------|--------|-------------|
| 이메일 인증 완료 / OAuth 가입 | `AccountEmailVerified` | `user_profile.email_verified=true`, point는 활동 허용 전제 |
| 계정 정지 | `AccountSuspended` | `user_profile.status=SUSPENDED`, `point_account.status=SUSPENDED` |
| 로그인 | (이벤트 없음, 동기 API) | `canLogin()` = ACTIVE **그리고** email_verified |

정지된 계정의 JWT가 남아 있어도 user/point는 로컬 `status`로 쓰기를 거부해야 한다
(토큰 폐기와 별개의 방어선).

### BOUNDARY-01 인플루언서 tier

| 역할 | 서비스 | 저장소 |
|------|--------|--------|
| 계산 원본 | recommendation | `influencer_metric.tier`, `influence_score` |
| 표시 스냅샷 | user | `user_profile.influencer_tier`, `influencer_score` |

`InfluencerTierUpdated` 스키마: `kafka/event-schemas/recommendation/InfluencerTierUpdated.json` (BOUNDARY-01).

### BOUNDARY-02 OOTD 반응 vs 소셜 피드

| 리소스 | 소유 서비스 | 비고 |
|--------|-------------|------|
| `ootd`, `ootd_like`, `ootd_comment` | fashion | OOTD 반응 API·DB 원장 |
| `post`, `post_like`, `comment`, … | social | 일반 피드만 |

social DB에 `ootd_*` 반응 테이블을 추가하지 않습니다. BFF 라우팅도 위 경계를 따릅니다.

## activity-feed type 계약 (FEED-01)

`activity-feed-service`의 MongoDB `activities.type`은 위 표에서
해당 서비스가 구독하는 `eventType`과 **이름이 동일**해야 합니다
(PascalCase, 예: `OrderPaid`).

구독 → type enum 목록:
`AccountRegistered`, `UserProfileCreated`, `UserFollowed`,
`OrderCreated`, `OrderPaid`, `PointEarned`

피드 문서에는 `sourceEventId`(= 원본 `eventId`)를 저장하고 unique 인덱스로
재소비 멱등성을 보장합니다. 스키마 스크립트:
`msa-platform/services/activity-feed-service/.../V1__init_mongodb.js`

### FEED-02 TTL·조회

- `timestamp`: 정렬용(과거 백필 가능). TTL 키로 쓰지 않음.
- `expireAt`: 절대 만료 시각 + MongoDB TTL (`expireAfterSeconds: 0`).
- 권장: `expireAt = max(timestamp, createdAt) + 1년`.
- 인덱스: `{ userId, visibility, timestamp }`.

## Outbox · eventId 정합 (COMMON-02)

- `outbox_events.id` = `DomainEvent.eventId` (DB DEFAULT `gen_random_uuid()` 사용 금지).
- `payload` JSON 최상위 `eventId`는 `id` 컬럼과 일치 (PostgreSQL CHECK).
- Kafka 발행 시 **record key = `eventId`**; 소비 측 `processed_events.event_id`도 동일 값.

## 이벤트 스키마

각 이벤트의 JSON Schema는 [../kafka/event-schemas/](../kafka/event-schemas/) 참고.

### LOW-O7 (플랫폼 이벤트 스키마 보강)

activity-feed·알림·추천이 구독하는 이벤트 중 스키마 파일이 없던 항목을 추가했습니다.

- `user/UserProfileCreated.json`
- `user/UserFollowed.json`
- `point/PointEarned.json`
- `commerce/OrderCreated.json`, `OrderPaid.json`, `ProductViewed.json`, `ProductPriceChanged.json`, `CartAbandoned.json`, `RepurchaseTimingPredicted.json`
- `recommendation/InfluencerTierUpdated.json`

발행 구현 전 계약 테스트(round-trip)에 사용합니다.

### LOW-O8 (PII 최소화)

`AccountRegistered.data.email`은 user/point 초기화에 편하지만 PII 노출면이 큽니다. 장기적으로는 `accountId`만 전파하고 이메일은 auth API 조회로 제한하는 방안을 검토합니다 (스키마 필드는 backward compatible 유지).
