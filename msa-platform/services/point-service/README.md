# point-service
포인트 적립·사용과 잔액 원장을 소유하고 주문 Saga에 참여하는 서비스입니다.

## 책임
- 포인트 적립과 사용
- 포인트 잔액 및 이력 관리
- 포인트 주문 Saga 참여

## 담당하지 않는 것 / 서비스 경계
- 주문·결제와 Saga 오케스트레이션은 `commerce-service`가 담당합니다.
- 계정 생성과 인증은 별도 `msa-auth`가 담당합니다.
- 포인트 관련 알림 발송은 `notification-service`가 담당합니다.

## 기술 정보
| 항목 | 값 |
|---|---|
| 포트 | `8086` |
| DB | PostgreSQL `postgres-point` (`pointdb`, 로컬 `5435`) |
| Gradle 모듈 경로 | `:services:point-service` |

## 주요 연동 및 이벤트
- 설계 문서상 `AccountRegistered`와 `OrderPaid` 이벤트를 구독합니다.
- `AccountSuspended` 구독 시 `point_account.status=SUSPENDED`로 적립·사용·예약을 거부합니다 (AUTH-04, 소비 코드 미구현).
- 설계 문서상 `commerce-service`가 주도하는 포인트 주문 Saga의 참여자입니다.
- 현재 실제 이벤트 소비자와 Saga 처리 코드는 없습니다.

## 데이터 모델 핵심 설계 (DB 감사 POINT-01/02, AUTH-04 반영)
- **원장 멱등**: `point_transaction`에 `(type, source_type, source_id)` 부분 UNIQUE 인덱스가 있어,
  같은 출처 이벤트(예: 동일 주문의 `OrderPaid`)가 재소비되어도 중복 적립·차감이 DB에서 차단됩니다.
  `processed_events`(컨슈머 단 멱등)와 별개의 2차 방어선입니다.
- **예약 멱등**: `point_reservation.saga_id` UNIQUE — 사가당 예약 1건만 허용됩니다.
- **만료 lot 모델**: 별도 lot 테이블 없이 `EARNED` 원장 행이 적립 lot을 겸합니다.
  `remaining_amount`가 lot 잔여량이며, 사용/만료 시 FIFO(만료 임박 순)로 차감합니다.
  `remaining_amount`는 이 테이블에서 유일하게 UPDATE되는 컬럼입니다.
- **계정 상태 (AUTH-04)**: `point_account.status` (`ACTIVE`/`SUSPENDED`/`CLOSED`).
  정지 시 잔액은 보존하고 활동만 차단합니다.
- **ADJUSTED (Low O9)**: 관리자 조정은 `type=ADJUSTED`로 기록. 음수 조정이 필요하면 `SPENT` 또는 별도 `source_type`으로 문서화하고, `(type, source_type, source_id)` 멱등 인덱스는 `source_id IS NOT NULL`인 행만 대상입니다.

## 실행 방법
```bash
cd msa-platform
./gradlew :services:point-service:bootRun
```

## 현재 구현 상태
현재는 **스켈레톤**입니다.
- 구현: 애플리케이션 부트스트랩, `/hello`, PostgreSQL·Flyway·Kafka·Saga 기본 의존성, `point_account`, `point_transaction`, `point_reservation`, `point_earning_rule`, `outbox_events`, `processed_events` 테이블 migration
- 미구현: 포인트 원장·잔액 Entity·Repository·API와 비즈니스 로직, 이벤트 소비, Saga 보상·멱등 처리
