# recommendation-service
행동 데이터를 바탕으로 상품·OOTD 추천과 인플루언서 점수를 계산하는 서비스입니다.

## 책임
- 사용자 행동 이벤트 수집
- 상품과 OOTD 추천
- 인플루언서 스코어링·**등급(tier) 계산 원본** (BOUNDARY-01)
- A/B 테스트

## 담당하지 않는 것 / 서비스 경계
- 상품·주문 원장은 `commerce-service`가 담당합니다.
- OOTD 원본 데이터는 `fashion-service`가 담당합니다.
- 사용자 프로필과 등급 관리는 `user-service`가 담당합니다.

## 기술 정보
| 항목 | 값 |
|---|---|
| 포트 | `8089` |
| DB | PostgreSQL `postgres-recommendation` (`recommendationdb`, 로컬 `5438`) |
| Gradle 모듈 경로 | `:services:recommendation-service` |

## 주요 연동 및 이벤트
- 설계 문서상 `commerce-service`의 `OrderPaid`, `ProductViewed` 이벤트를 구독합니다.
- 모든 도메인 이벤트를 `activity-feed-service`가 구독한다는 설계가 있습니다.
- 현재 실제 Kafka 소비자와 추천 서비스 연동은 없습니다.

## 행동 이벤트 멱등성 (DB 감사 REC-01 반영)

Kafka 재전달·HTTP 재시도 시 `user_behavior_event`가 중복 적재되면 관심사 프로필과 동시출현 통계가 왜곡됩니다.

- `source_event_id` **UNIQUE**가 행동 원장의 1차 멱등 키입니다.
- **Kafka 소비**: `DomainEvent.eventId`를 그대로 `source_event_id`에 넣고 INSERT. UNIQUE 위반이면 스킵.
- **HTTP 수집**: 클라이언트가 `Idempotency-Key`(UUID)를 보내고, 동일 키로 재시도합니다.
- `processed_events`는 커밋 경계용 2차 방어입니다. 발송/집계 파이프라인과 동일한 “원장 UNIQUE + processed” 패턴을 따릅니다.

권장 흐름: `INSERT … ON CONFLICT (source_event_id) DO NOTHING` → (선택) 집계·프로필 갱신 → `processed_events` 기록.

## 추천 캐시와 A/B 실험 (DB 감사 REC-02 반영)

동일 `(user_id, recommendation_type, target_context)`만 키로 쓰면 variant A 결과가 B에 덮어씌워집니다.

- 캐시 슬롯: `user_id`, `recommendation_type`, `target_context`, **`experiment_id`**, **`variant`**
- **실험 미참여**: `experiment_id`·`variant` 모두 `NULL` (기본 알고리즘 캐시)
- **실험 참여**: `user_experiment_assignment`와 같은 `experiment_id`·`variant`로 INSERT/UPSERT
- UNIQUE: `uq_user_recommendation_cache_slot` (COALESCE로 NULL context·실험 외 슬롯 정규화)

## 운영 하드닝 (Low)

- **RC-6**: `user_recommendation_cache`에 `expires_at >= generated_at` CHECK. 중복 인덱스 `idx_user_recommendation_cache_user_type` 제거(UNIQUE 슬롯 접두로 커버).
- **RC-7**: `user_behavior_event` 월 파티션은 PK/UNIQUE와 충돌해 V1에서는 일반 테이블. 장기 보관은 retention job + `idx_ube_occurred` 유지.

## 인플루언서 등급 (BOUNDARY-01)

- `influencer_metric`이 `tier`·`influence_score`의 **단일 계산 원본**입니다.
- 등급 변경 시 `InfluencerTierUpdated`를 outbox로 발행하고, `user-service`가 `user_profile` 스냅샷을 갱신합니다 (이벤트·소비자 미구현).

## 실행 방법
```bash
cd msa-platform
./gradlew :services:recommendation-service:bootRun
```

## 현재 구현 상태
현재는 **스켈레톤**입니다.
- 구현: 애플리케이션 부트스트랩, `/hello`, PostgreSQL·Flyway·Kafka 기본 설정, `user_behavior_event`, `user_interest_profile`, `product_co_occurrence`, `ootd_co_occurrence`, `user_recommendation_cache`, `recommendation_experiment`, `user_experiment_assignment`, `influencer_metric`, `outbox_events`, `processed_events` 테이블 migration
- 미구현: 행동 수집·추천·스코어링·A/B 테스트 Entity·Repository·API와 비즈니스 로직, 이벤트 소비
