// ==============================================================
// activity-feed-service — MongoDB 초기화 스크립트
//
// 중요:
//   - 이 파일은 Flyway migration 이 아닙니다.
//   - MongoDB shell(mongosh) / 로컬·배포 초기화용 스크립트입니다.
//   - application resources 에 두어 버전 관리하되, Flyway 가 실행하지 않습니다.
//
// 사용 예:
//   mongosh "mongodb://localhost:27017/activitydb" V1__init_mongodb.js
//
// [FEED-01] 멱등성 + 타입 계약
//   1) sourceEventId: Kafka DomainEvent.eventId 를 그대로 저장.
//      unique 인덱스로 동일 이벤트 재소비 시 중복 피드 문서를 차단한다.
//      (PostgreSQL 의 processed_events 와 역할이 같다 — 읽기 모델에서는
//       문서 자체에 원본 이벤트 ID 를 심는 편이 단순하다.)
//   2) type enum: msa-infra/docs/event-catalog.md 에서 activity-feed 가
//      구독하는 이벤트 이름과 1:1 로 맞춘다 (PascalCase).
//      과거 ERD 의 SNAKE_CASE(ORDER_CREATED 등)는 카탈로그와 달라
//      컨슈머가 insert 시 validator 에 거부되거나, 반대로 잘못된 타입이
//      통과하는 문제를 낳았으므로 폐기한다.
//   계약: 1 이벤트 → 1 피드 문서(활동 주체 userId 기준).
//         팬아웃이 필요해지면 unique 를 (sourceEventId, userId) 로 확장.
//
// [FEED-02] TTL·조회 인덱스
//   - timestamp(활동 시각) 기준 TTL 은 과거 이벤트 백필 시 즉시 삭제된다.
//   - expireAt(절대 만료 시각) + TTL(expireAfterSeconds:0) 사용.
//   - 소비 시 expireAt = max(timestamp, createdAt) + 보존기간(기본 1년) 권장.
//   - 공개 범위 필터: { userId, visibility, timestamp } 복합 인덱스.
//
// [LOW-AF-5] validator: 필수 필드·type enum 은 strict, metadata 만 확장 허용.
//   additionalProperties:false 로 오타 필드 적재를 줄인다.
// ==============================================================

const dbName = typeof db !== "undefined" && db.getName ? db.getName() : "activitydb";
const targetDb = db.getSiblingDB(dbName);

print(`[activity-feed] initializing MongoDB schema on database: ${dbName}`);

const collectionName = "activities";

// event-catalog.md 기준 activity-feed 구독 이벤트 (발행 순서와 무관, 이름 고정)
const FEED_EVENT_TYPES = [
  "AccountRegistered",
  "UserProfileCreated",
  "UserFollowed",
  "OrderCreated",
  "OrderPaid",
  "PointEarned"
];

const activitiesValidator = {
  $jsonSchema: {
    bsonType: "object",
    required: [
      "sourceEventId",
      "userId",
      "type",
      "timestamp",
      "summary",
      "visibility",
      "createdAt",
      "expireAt"
    ],
    properties: {
      _id: {
        bsonType: "objectId",
        description: "MongoDB 문서 ID"
      },
      // Kafka DomainEvent.eventId — 멱등 키 (FEED-01)
      sourceEventId: {
        bsonType: "string",
        pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
        description: "원본 도메인 이벤트 ID (UUID). 재소비 중복 방지 키"
      },
      // 논리 참조: auth.account.id (문자열 UUID)
      userId: {
        bsonType: "string",
        description: "활동 주체 사용자 ID (auth.account.id 논리 참조)"
      },
      // event-catalog eventType 과 1:1 (PascalCase)
      type: {
        enum: FEED_EVENT_TYPES,
        description: "활동 유형 = 구독 이벤트 이름 (event-catalog.md)"
      },
      timestamp: {
        bsonType: "date",
        description:
          "활동 발생 시각 (피드 정렬. 과거 백필 가능 — TTL 기준으로 쓰지 않음, FEED-02)"
      },
      summary: {
        bsonType: "string",
        description: "비정규화된 요약 텍스트"
      },
      metadata: {
        bsonType: "object",
        description: "유형별 부가 필드 (주문번호, 상대 userId 등)",
        additionalProperties: true
      },
      visibility: {
        enum: ["PUBLIC", "PRIVATE", "FOLLOWERS_ONLY"],
        description: "노출 범위"
      },
      createdAt: {
        bsonType: "date",
        description: "문서 생성(수집) 시각. 백필 시에도 insert 시각"
      },
      expireAt: {
        bsonType: "date",
        description:
          "절대 만료 시각. TTL 인덱스 대상(FEED-02). 권장: max(timestamp,createdAt)+1년"
      },
      indexedAt: {
        bsonType: ["date", "null"],
        description: "검색/보조 인덱스 반영 시각 (선택)"
      }
    },
    additionalProperties: false
  }
};

const existing = targetDb.getCollectionNames().includes(collectionName);
if (!existing) {
  targetDb.createCollection(collectionName, {
    validator: activitiesValidator,
    validationLevel: "moderate",
    validationAction: "error"
  });
  print(`[activity-feed] created collection: ${collectionName}`);
} else {
  // 이미 있으면 validator 만 갱신 (로컬 재실행 안전)
  targetDb.runCommand({
    collMod: collectionName,
    validator: activitiesValidator,
    validationLevel: "moderate",
    validationAction: "error"
  });
  print(`[activity-feed] updated validator on existing collection: ${collectionName}`);
}

const activities = targetDb.getCollection(collectionName);

// --------------------------------------------------------------
// 인덱스
//   0) 멱등: { sourceEventId: 1 } unique  — FEED-01
//   1) 사용자 타임라인: { userId: 1, timestamp: -1 }
//   2) 유형 필터: { userId: 1, type: 1, timestamp: -1 }
//   3) 노출 범위 필터: { userId: 1, visibility: 1, timestamp: -1 } — FEED-02
//   4) TTL: { expireAt: 1 } expireAfterSeconds: 0 — FEED-02
// --------------------------------------------------------------

const FEED_RETENTION_SECONDS = 31536000; // 1년 (문서화·앱 기본값 참고용)

// 동일 Kafka 이벤트 재소비 시 DuplicateKey → 애플리케이션은 no-op 처리
activities.createIndex(
  { sourceEventId: 1 },
  {
    name: "uq_activities_source_event_id",
    unique: true,
    background: true
  }
);

activities.createIndex(
  { userId: 1, timestamp: -1 },
  { name: "idx_activities_user_timestamp", background: true }
);

activities.createIndex(
  { userId: 1, type: 1, timestamp: -1 },
  { name: "idx_activities_user_type_timestamp", background: true }
);

activities.createIndex(
  { userId: 1, visibility: 1, timestamp: -1 },
  { name: "idx_activities_user_visibility_timestamp", background: true }
);

// TTL: expireAt 시각이 지나면 삭제 (백필 시 timestamp 가 과거여도 expireAt 으로 보존 기간 제어)
activities.createIndex(
  { expireAt: 1 },
  {
    name: "idx_activities_expire_at_ttl",
    expireAfterSeconds: 0,
    background: true
  }
);

// 레거시 TTL 인덱스 제거 (timestamp 기준 — FEED-02 에서 폐기)
try {
  activities.dropIndex("idx_activities_timestamp_ttl");
  print("[activity-feed] dropped legacy TTL index idx_activities_timestamp_ttl");
} catch (e) {
  // 최초 기동 등 인덱스 없음
}

print(
  `[activity-feed] indexes ensured (1 unique + 3 compound + 1 TTL on expireAt); retention hint ${FEED_RETENTION_SECONDS}s`
);
print(`[activity-feed] allowed types: ${FEED_EVENT_TYPES.join(", ")}`);
print("[activity-feed] MongoDB init complete");
