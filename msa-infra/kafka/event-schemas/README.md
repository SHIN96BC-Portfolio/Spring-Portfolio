# Event Schemas

각 도메인의 이벤트 스키마 정의.

## 구조

```
event-schemas/
├── auth/           ← msa-auth가 발행하는 이벤트
├── user/           ← msa-platform user-service가 발행
├── point/          ← msa-platform point-service가 발행
├── commerce/       ← msa-platform commerce-service가 발행
└── ...
```

## 등록된 스키마 (V1)

| 파일 | eventType |
|------|-----------|
| auth/AccountRegistered.json | AccountRegistered |
| auth/AccountEmailVerified.json | AccountEmailVerified |
| auth/AccountSuspended.json | AccountSuspended |
| user/UserProfileCreated.json | UserProfileCreated |
| user/UserFollowed.json | UserFollowed |
| point/PointEarned.json | PointEarned |
| commerce/OrderCreated.json | OrderCreated |
| commerce/OrderPaid.json | OrderPaid |
| commerce/ProductViewed.json | ProductViewed |
| commerce/ProductPriceChanged.json | ProductPriceChanged |
| commerce/CartAbandoned.json | CartAbandoned |
| commerce/RepurchaseTimingPredicted.json | RepurchaseTimingPredicted |
| recommendation/InfluencerTierUpdated.json | InfluencerTierUpdated |

추가 commerce·notification 이벤트는 구현 단계에서 동일 envelope 규칙으로 확장합니다.

## 소유권

각 도메인의 이벤트 스키마는 **해당 도메인 서비스가 소유**합니다.
이 폴더는 **통합 카탈로그** 역할을 합니다.

## 이벤트 공통 구조

```json
{
  "eventId": "string (UUID)",
  "eventType": "string",
  "eventVersion": "integer",
  "occurredAt": "string (ISO 8601)",
  "traceId": "string",
  "data": {
    // 도메인별 페이로드
  }
}
```

## 버저닝

- 필드 추가: OK (backward compatible)
- 필드 제거: X
- 필드 의미 변경: X
- 큰 변경 필요 시: EventNameV2로 신규 타입 발행
