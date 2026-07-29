# commerce-service
상품 탐색부터 주문·결제·재고와 재구매 분석까지 커머스 도메인을 소유하는 서비스입니다.

## 책임
- 상품, 주문, 결제와 재고 관리
- 위시리스트와 장바구니 관리
- 재구매 패턴 분석
- 포인트 주문 Saga 오케스트레이션

## 담당하지 않는 것 / 서비스 경계
- 포인트 잔액과 적립·사용 원장은 `point-service`가 담당합니다.
- 추천 모델과 개인화 결과는 `recommendation-service`가 담당합니다.
- 알림 채널 발송은 `notification-service`가 담당합니다.

## 기술 정보
| 항목 | 값 |
|---|---|
| 포트 | `8085` |
| DB | PostgreSQL `postgres-commerce` (`commercedb`, 로컬 `5434`) |
| Gradle 모듈 경로 | `:services:commerce-service` |

## 주요 연동 및 이벤트
- 설계 문서상 `OrderPaid`를 발행해 `point-service`, `notification-service`, `recommendation-service`가 구독합니다.
- 설계 문서상 `RepurchaseTimingPredicted`는 `notification-service`, `ProductViewed`는 `recommendation-service`로 전달됩니다.
- 설계 문서상 포인트 주문에서 Saga 오케스트레이터 역할을 합니다. 현재 실제 이벤트·Saga 구현은 없습니다.

## 재고 예약 설계 (DB 감사 COM-01 반영)
- `inventory_reservation`이 Saga별 SKU 예약의 원본 원장이고,
  `inventory.reserved_qty`는 빠른 조회를 위한 활성 예약 수량 집계입니다.
- `(saga_id, variant_id)` UNIQUE 제약으로 같은 Saga 요청이 재시도되어도
  동일 SKU가 중복 예약되지 않습니다.
- 예약 생성과 `inventory` 수량 변경은 반드시 하나의 DB 트랜잭션에서 처리합니다.
  `available_qty >= quantity` 조건부 UPDATE가 성공한 경우에만 예약을 확정해야
  동시 주문 시 과판매를 막을 수 있습니다.
- 예약 상태는 `RESERVED`에서 `CONFIRMED`, `RELEASED`, `EXPIRED` 중 하나로만
  종결합니다. 보상·만료 시 `reserved_qty`를 감소시키고 `available_qty`를 복원하며,
  결제 확정 시에는 `reserved_qty`만 감소시킵니다.
- 만료 스위퍼는 `status = 'RESERVED'`인 행만 부분 인덱스로 조회합니다.
  실제 조건부 상태 전이와 재고 갱신 로직은 아직 구현 전입니다.

## 주문 불변식 (DB 감사 COM-02 반영)
- **금액 등식**: `final_amount = total_amount - discount_amount - point_used`를
  CHECK로 강제합니다. 합계가 어긋난 주문은 저장 자체가 불가능합니다.
- **주문 생성 멱등**: `orders.idempotency_key` UNIQUE. BFF/클라이언트가 주문서
  진입 시 발급한 키를 제출하고, 재시도·더블클릭이 같은 키로 오면 UNIQUE 위반
  → 기존 주문을 조회해 반환합니다.
- **Saga 연결**: `orders.saga_id`는 `saga_instances` FK + 부분 UNIQUE.
  주문 1건 = 사가 최대 1건이며, 서로 다른 주문이 같은 사가를 가리킬 수 없습니다.
- **상태-시각 정합**: `paid_at`/`shipped_at`/`completed_at`은 해당 상태에
  도달했을 때만 존재하도록 CHECK로 강제합니다 (결제 전 취소는 `paid_at` 없이 허용).

## 결제·가격 불변식 (DB 감사 COM-03 반영)
- **결제 시도 이력**: `payment`는 주문당 1행이 아니라 시도(attempt)마다 INSERT하는
  append-only 이력입니다. `(order_id, attempt_no)` UNIQUE로 순번을 고정하고,
  실패 이력이 보존되어 PG 분쟁·정산 대사에 사용할 수 있습니다.
- **부분 UNIQUE 불변식**: 진행 중(`PENDING`/`AUTHORIZED`) 시도는 주문당 1건
  (동시 재결제 차단), 성공(`CAPTURED`)은 주문당 1건(이중 청구 차단).
  환불(`REFUNDED`)로 전이하면 성공 자리가 비어 재결제가 가능해집니다.
- **현재 가격 유일성**: `product_price_history`의 현재가(`effective_to IS NULL`)는
  SKU당 1건을 부분 UNIQUE로 강제합니다. 가격 변경은 "기존 행 마감 UPDATE →
  새 행 INSERT"를 한 트랜잭션으로 수행해야 합니다.

## Saga 동시성·스텝 멱등 (DB 감사 COM-04 반영)
- **사가 낙관적 락**: `saga_instances.version` + JPA `@Version`(`common-saga.SagaInstance`).
  동시 reply가 상태를 덮어쓰지 못하도록 하고, 충돌 시 재조회·재시도합니다.
- **스텝 시도 원장**: `commerce_saga_step_history`에 `attempt_no`와
  `(saga_id, step_name, attempt_no)` UNIQUE를 둡니다. FAILED 후 재시도는 attempt+1.
- **스텝 중복 실행 차단**: `(saga_id, step_name)` 부분 UNIQUE
  (`status IN ('STARTED','SUCCEEDED')`). 진행 중·성공한 단계는 재INSERT 불가.
  오케스트레이터는 스텝 시작 시 STARTED 행을 먼저 INSERT한 뒤 참여자를 호출해야 합니다.

## 운영 하드닝 (Low A16)

- `orders.referral_type` CHECK (`ORGANIC`, `RECOMMENDATION`, `OOTD_TAG`, `AD`)
- `product_category.path` partial UNIQUE
- `product_variant.status` (`ACTIVE`/`INACTIVE`/`DISCONTINUED`)
- `product_purchase_pattern`: `first_purchased_at <= last_purchased_at`
- `payment`: `idx_payment_status_paid_at` — CAPTURED/REFUNDED 대사 스윕
- CAPTURED `payment.amount` = `orders.final_amount` (앱 검증, COMMENT)

## 실행 방법
```bash
cd msa-platform
./gradlew :services:commerce-service:bootRun
```

## 현재 구현 상태
현재는 **스켈레톤**입니다.
- 구현: 애플리케이션 부트스트랩, `/hello`, PostgreSQL·Flyway·Kafka·Saga 기본 의존성, `product_category`, `product`, `product_variant`, `inventory`, `inventory_reservation`, `product_price_history`, `orders`, `order_item`, `payment`, `wishlist`, `cart_item`, `product_purchase_pattern`, `saga_instances`, `commerce_saga_step_history`, `outbox_events`, `processed_events` 테이블 migration
- 미구현: 커머스 Entity·Repository·API와 비즈니스 로직, 재구매 분석, 이벤트 발행, Saga 흐름
