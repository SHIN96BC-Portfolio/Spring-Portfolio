# activity-feed-service
도메인 이벤트를 통합해 사용자 활동 피드용 CQRS 읽기 모델을 만드는 서비스입니다.

## 책임
- 여러 도메인의 활동 이벤트 구독
- MongoDB 기반 통합 활동 저장
- 활동 피드용 CQRS Read Model 제공

## 담당하지 않는 것 / 서비스 경계
- 원본 도메인 데이터와 쓰기 규칙은 각 도메인 서비스가 소유합니다.
- 게시물 원장은 `social-service`, 주문 원장은 `commerce-service`가 담당합니다.
- 이벤트의 비즈니스 처리를 지휘하지 않고 조회용 모델을 구성합니다.

## 기술 정보
| 항목 | 값 |
|---|---|
| 포트 | `8090` |
| DB | MongoDB `mongodb-activity` (`activitydb`, 로컬 `27017`) |
| Gradle 모듈 경로 | `:services:activity-feed-service` |

## 주요 연동 및 이벤트
- `msa-infra/docs/event-catalog.md` 기준 구독 대상:
  `AccountRegistered`, `UserProfileCreated`, `UserFollowed`,
  `OrderCreated`, `OrderPaid`, `PointEarned`
- 현재 서비스 코드에는 소비자가 없습니다.
- 별도의 발행 이벤트는 없습니다 (읽기 모델 전용).

## 피드 문서 설계 (DB 감사 FEED-01 반영)
- **멱등 키**: `sourceEventId` = Kafka `DomainEvent.eventId`(UUID).
  unique 인덱스로 동일 이벤트 재소비 시 중복 피드 문서를 차단합니다.
  계약은 **1 이벤트 → 1 피드 문서**(활동 주체 `userId` 기준)입니다.
- **type 계약**: MongoDB validator enum을 이벤트 카탈로그 이름과
  1:1(PascalCase)로 통일했습니다. 과거 ERD의 `ORDER_CREATED` 같은
  SNAKE_CASE는 카탈로그와 달라 insert 거부/오허용이 나므로 사용하지 않습니다.
- 새 피드 유형을 추가할 때는 **카탈로그에 이벤트를 먼저 등록**한 뒤
  `V1__init_mongodb.js`의 `FEED_EVENT_TYPES`와 validator를 함께 갱신합니다.

## TTL·조회 인덱스 (DB 감사 FEED-02 반영)

- **`timestamp`**: 피드 정렬용(과거 `occurredAt` 백필 가능). **TTL 키로 사용하지 않습니다.**
- **`createdAt`**: MongoDB에 문서가 들어온 시각.
- **`expireAt`**: 절대 만료 시각. TTL 인덱스(`expireAfterSeconds: 0`) 대상.
- 소비자 권장: `expireAt = max(timestamp, createdAt) + 1년` — 백필해도 수집 시점부터 보존.
- 조회: `{ userId, visibility, timestamp }` 복합 인덱스로 PUBLIC/FOLLOWERS_ONLY 필터 지원.

## Validator (Low AF-5)

- 컬렉션 validator: 루트 `additionalProperties: false` (오타 필드 차단). `metadata`만 확장 허용.

## 실행 방법
```bash
cd msa-platform
# docker-compose 최초 기동 시 MongoDB validator/index가 자동 적용됩니다.
docker compose -f docker/docker-compose.yml up -d mongodb-activity
./gradlew :services:activity-feed-service:bootRun
```

## 현재 구현 상태
현재는 **스켈레톤**입니다.
- 구현: 애플리케이션 부트스트랩, `/hello`, MongoDB·Kafka 기본 설정, `activities` 컬렉션 validator(`sourceEventId`, `expireAt` + 카탈로그 type enum)·unique 멱등·사용자/유형/visibility 조회 인덱스·`expireAt` TTL을 구성하는 MongoDB 초기화 스크립트
- 미구현: MongoDB Document·Repository, 이벤트 consumer, 피드 조회 API와 Read Model 갱신 비즈니스 로직
