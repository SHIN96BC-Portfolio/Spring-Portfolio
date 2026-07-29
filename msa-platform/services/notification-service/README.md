# notification-service
도메인 이벤트에 반응해 알림과 마케팅 메시지를 발송하는 서비스입니다.

## 책임
- 이메일과 웹훅 알림 발송
- 마케팅 캠페인 자동화
- 재구매, 가격 인하와 이탈 복구 알림

## 담당하지 않는 것 / 서비스 경계
- 알림의 원인이 되는 주문·사용자·추천 데이터는 각 도메인 서비스가 소유합니다.
- 재구매 시점 예측은 `commerce-service`가 담당합니다.
- 사용자 화면용 응답 조합은 `user-bff`가 담당합니다.

## 기술 정보
| 항목 | 값 |
|---|---|
| 포트 | `8091` |
| DB | PostgreSQL `postgres-notification` (`notificationdb`, 로컬 `5439`) |
| Gradle 모듈 경로 | `:services:notification-service` |

## 주요 연동 및 이벤트
- 설계 문서상 `AccountRegistered`, `OrderPaid`, `RepurchaseTimingPredicted` 이벤트를 구독합니다.
- 이메일·웹훅 공급자와의 구체적인 연동은 미정입니다.
- 현재 실제 이벤트 소비자와 발송 어댑터는 없습니다.

## 발송 멱등성 (DB 감사 NOTIF-01 반영)
- `processed_events`만으로는 **발송 성공 후 커밋 전 장애** 시 재소비로 중복 메일/웹훅이 나갑니다.
- `notification.idempotency_key` UNIQUE가 발송 단위 원장 멱등입니다.
  키 형식:
  - Kafka: `{sourceEventId}:{channel}:{templateId|NONE}:{recipientUserId}`
  - 캠페인: `campaign:{campaignId}:{channel}:{templateId|NONE}:{recipientUserId}`
- 권장 흐름: 채널 호출 **전에** PENDING 행을 INSERT → 이미 SENT면 스킵 →
  발송 후 SENT/`sent_at` 갱신 → `processed_events` 기록.
- `source_event_id`는 추적용이며, 한 이벤트가 여러 채널로 팬아웃될 수 있어
  유일 제약은 `idempotency_key`에만 둡니다.

## 캠페인·전환 (DB 감사 NOTIF-02 반영)

- **`marketing_campaign.idempotency_key` UNIQUE** — 동일 Kafka 이벤트로 캠페인이 두 번 스케줄되는 것을 막습니다.
  - 예: `{sourceEventId}:{campaign_type}:{target_user_id}:{target_resource_id|NONE}`
- **`campaign_conversion.idempotency_key` UNIQUE** — 전환(특히 PURCHASED) 재처리 시 지표가 부풀지 않습니다.
- `campaign_type` / `status` / `conversion_type` / 채널·카테고리는 PostgreSQL CHECK로 enum 고정.

## IN_APP 인박스 (Low NT-6)

- `idx_notification_in_app_inbox`: `(recipient_user_id, created_at DESC)` partial — `channel = IN_APP` 이고 `status IN (SENT, OPENED)`.

## 실행 방법
```bash
cd msa-platform
./gradlew :services:notification-service:bootRun
```

## 현재 구현 상태
현재는 **스켈레톤**입니다.
- 구현: 애플리케이션 부트스트랩, `/hello`, PostgreSQL·Flyway·Kafka 기본 설정, `notification_template`, `notification`(멱등 키 포함), `marketing_campaign`, `notification_preference`, `campaign_conversion`, `outbox_events`, `processed_events` 테이블 migration
- 미구현: 알림·캠페인 Entity·Repository·API와 비즈니스 로직, 이벤트 소비, 이메일·웹훅 발송
