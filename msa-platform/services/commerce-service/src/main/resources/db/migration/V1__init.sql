-- ==============================================================
-- commerce-service 최종 초기 스키마
--
-- ERD: product_category, product, product_variant, inventory,
--      inventory_reservation,
--      product_price_history, orders, order_item, payment,
--      wishlist, cart_item, product_purchase_pattern,
--      commerce_saga_step_history
--
-- 참고:
--   - ERD commerce_outbox_events 는 공통 outbox_events 로 대체
--   - Saga Orchestrator 는 common-saga JPA(SagaInstance)와 맞추어
--     saga_instances 테이블을 사용 (ERD의 commerce_saga_instances/status 미사용)
--   - money BIGINT 컬럼은 최소 화폐 단위(원/센트 등)
--   - inventory.reserved_qty 는 빠른 재고 조회용 집계이며,
--     inventory_reservation 이 Saga별 예약의 원본 원장(Source of Truth)
-- ==============================================================

-- [COMMON-03] 시각 컬럼은 TIMESTAMPTZ(UTC). 앱·JDBC·PostgreSQL 세션 timezone=UTC 권장.

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Outbox 패턴 (필수)
-- [COMMON-02] outbox_events.id = DomainEvent.eventId. DEFAULT gen_random_uuid() 금지.
CREATE TABLE outbox_events (
    id              UUID PRIMARY KEY,
    aggregate_type  VARCHAR(50) NOT NULL,
    aggregate_id    VARCHAR(100) NOT NULL,
    event_type      VARCHAR(100) NOT NULL,
    event_version   INT NOT NULL DEFAULT 1,
    payload         JSONB NOT NULL,
    trace_id        VARCHAR(100),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    published_at    TIMESTAMPTZ,

    CONSTRAINT chk_outbox_events_payload_event_id CHECK (
        payload ? 'eventId'
        AND payload->>'eventId' = id::text
    )
);

COMMENT ON TABLE outbox_events IS
    'Transactional outbox. id 는 DomainEvent.eventId 와 동일 (COMMON-02)';
COMMENT ON COLUMN outbox_events.id IS
    'Kafka message key · processed_events.event_id 와 동일 UUID';
COMMENT ON COLUMN outbox_events.payload IS
    'DomainEvent JSON envelope. 최상위 eventId 가 id 와 일치 (CHECK)';

CREATE INDEX idx_outbox_unpublished
  ON outbox_events(created_at)
  WHERE published_at IS NULL;

-- [LOW-O6] published 행 보관·purge 스윕용 (대량 outbox 운영 시).
CREATE INDEX idx_outbox_published_purge
  ON outbox_events (published_at)
  WHERE published_at IS NOT NULL;

-- Idempotency (Consumer 멱등성 - Kafka 구독하는 서비스만)
-- [COMMON-01] event_id 단독 PK 는 동일 DB 의 서로 다른 consumer group 이
--   같은 이벤트를 처리하지 못하게 한다. (event_id, consumer_group) 복합 PK.
CREATE TABLE processed_events (
    event_id        UUID NOT NULL,
    consumer_group  VARCHAR(100) NOT NULL,
    processed_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_processed_events PRIMARY KEY (event_id, consumer_group)
);

COMMENT ON TABLE processed_events IS
    'Kafka 소비 멱등 원장. PK (event_id, consumer_group) — 그룹별 1회 처리 (COMMON-01)';
COMMENT ON COLUMN processed_events.event_id IS
    'DomainEvent.eventId (Kafka 메시지와 동일 값 권장)';
COMMENT ON COLUMN processed_events.consumer_group IS
    'Kafka consumer group id (예: spring.kafka.consumer.group-id)';


-- --------------------------------------------------------------
-- 1. product_category — 상품 카테고리 (계층)
-- --------------------------------------------------------------
CREATE TABLE product_category (
    id              BIGSERIAL       PRIMARY KEY,
    parent_id       BIGINT,
    name            VARCHAR(100)    NOT NULL,
    path            VARCHAR(500),                   -- 예: fashion/women/dress
    display_order   INT,

    CONSTRAINT fk_product_category_parent
        FOREIGN KEY (parent_id) REFERENCES product_category (id)
);

COMMENT ON TABLE product_category IS '상품 카테고리 계층 구조';
COMMENT ON COLUMN product_category.parent_id IS '상위 카테고리 (자기 참조). NULL이면 루트';
COMMENT ON COLUMN product_category.path IS '카테고리 경로 스냅샷/슬러그. 예: fashion/women/dress';
COMMENT ON COLUMN product_category.display_order IS '동일 부모 내 표시 순서';

-- [LOW-A16] path 슬러그 중복 방지 (NULL 은 미할당 허용)
CREATE UNIQUE INDEX uq_product_category_path
    ON product_category (path)
    WHERE path IS NOT NULL;

CREATE INDEX idx_product_category_parent_order
    ON product_category (parent_id, display_order);


-- --------------------------------------------------------------
-- 2. product — 상품
-- --------------------------------------------------------------
CREATE TABLE product (
    id                  BIGSERIAL       PRIMARY KEY,
    brand_id            BIGINT,                     -- fashion.brand.id 논리 참조
    category_id         BIGINT,
    name                VARCHAR(200)    NOT NULL,
    description         TEXT,
    tags                JSONB,                      -- 알고리즘 태그
    color_codes         JSONB,
    view_count          BIGINT          NOT NULL DEFAULT 0,
    purchase_count      BIGINT          NOT NULL DEFAULT 0,
    wishlist_count      BIGINT          NOT NULL DEFAULT 0,
    status              VARCHAR(20)     NOT NULL DEFAULT 'ACTIVE',
    created_at          TIMESTAMPTZ       NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ       NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_product_category
        FOREIGN KEY (category_id) REFERENCES product_category (id),
    CONSTRAINT chk_product_view_count CHECK (view_count >= 0),
    CONSTRAINT chk_product_purchase_count CHECK (purchase_count >= 0),
    CONSTRAINT chk_product_wishlist_count CHECK (wishlist_count >= 0),
    CONSTRAINT chk_product_status CHECK (
        status IN ('ACTIVE', 'INACTIVE', 'SOLD_OUT', 'DISCONTINUED')
    )
);

COMMENT ON TABLE product IS '판매 상품 마스터';
COMMENT ON COLUMN product.brand_id IS
    'fashion.brand.id 논리 참조. DB-per-service 경계로 FK 없음';
COMMENT ON COLUMN product.category_id IS '소속 카테고리 (product_category.id)';
COMMENT ON COLUMN product.tags IS '알고리즘용 태그 JSON. 예: ["dress","summer","casual"]';
COMMENT ON COLUMN product.color_codes IS '색상 코드 JSON';
COMMENT ON COLUMN product.view_count IS '조회 수 (비정규화 카운터)';
COMMENT ON COLUMN product.purchase_count IS '구매 수 (비정규화 카운터)';
COMMENT ON COLUMN product.wishlist_count IS '위시리스트 담기 수 (비정규화 카운터)';
COMMENT ON COLUMN product.status IS '상품 상태: ACTIVE, INACTIVE, SOLD_OUT, DISCONTINUED';

CREATE INDEX idx_product_category_status_created
    ON product (category_id, status, created_at DESC);

CREATE INDEX idx_product_brand_id
    ON product (brand_id)
    WHERE brand_id IS NOT NULL;

CREATE INDEX idx_product_status_created
    ON product (status, created_at DESC);


-- --------------------------------------------------------------
-- 3. product_variant — SKU / 옵션 단위
-- --------------------------------------------------------------
CREATE TABLE product_variant (
    id              BIGSERIAL       PRIMARY KEY,
    product_id      BIGINT          NOT NULL,
    sku             VARCHAR(50)     NOT NULL,
    size            VARCHAR(20),
    color           VARCHAR(30),
    price           BIGINT          NOT NULL,
    -- [LOW-A16] SKU 단위 판매 중단 (상품 product.status 와 독립)
    status          VARCHAR(20)     NOT NULL DEFAULT 'ACTIVE',
    created_at      TIMESTAMPTZ       NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_product_variant_sku UNIQUE (sku),
    CONSTRAINT fk_product_variant_product
        FOREIGN KEY (product_id) REFERENCES product (id),
    CONSTRAINT chk_product_variant_price CHECK (price >= 0),
    CONSTRAINT chk_product_variant_status CHECK (
        status IN ('ACTIVE', 'INACTIVE', 'DISCONTINUED')
    )
);

COMMENT ON TABLE product_variant IS '상품 옵션(SKU) 단위. 사이즈/색상/가격';
COMMENT ON COLUMN product_variant.product_id IS '소속 상품 (product.id)';
COMMENT ON COLUMN product_variant.sku IS '재고관리 단위 SKU (유일)';
COMMENT ON COLUMN product_variant.price IS
    '판매 가격. 최소 화폐 단위(원/센트 등) BIGINT';
COMMENT ON COLUMN product_variant.status IS
    'SKU 상태: ACTIVE, INACTIVE, DISCONTINUED (LOW-A16)';

CREATE INDEX idx_product_variant_product
    ON product_variant (product_id);


-- --------------------------------------------------------------
-- 4. inventory — 재고 (낙관적 락)
-- --------------------------------------------------------------
CREATE TABLE inventory (
    id              BIGSERIAL       PRIMARY KEY,
    variant_id      BIGINT          NOT NULL,
    available_qty   INT             NOT NULL DEFAULT 0,
    reserved_qty    INT             NOT NULL DEFAULT 0,
    version         INT             NOT NULL DEFAULT 0,   -- Optimistic lock
    updated_at      TIMESTAMPTZ       NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_inventory_variant UNIQUE (variant_id),
    CONSTRAINT fk_inventory_variant
        FOREIGN KEY (variant_id) REFERENCES product_variant (id),
    CONSTRAINT chk_inventory_available_qty CHECK (available_qty >= 0),
    CONSTRAINT chk_inventory_reserved_qty CHECK (reserved_qty >= 0)
);

COMMENT ON TABLE inventory IS 'SKU별 재고. available=판매가능, reserved=사가 예약';
COMMENT ON COLUMN inventory.variant_id IS '재고 대상 SKU (product_variant.id)';
COMMENT ON COLUMN inventory.available_qty IS '판매 가능 수량';
COMMENT ON COLUMN inventory.reserved_qty IS
    '활성(RESERVED) 예약 수량 합계 캐시. 원본은 inventory_reservation';
COMMENT ON COLUMN inventory.version IS '낙관적 락 버전';


-- --------------------------------------------------------------
-- 5. inventory_reservation — Saga별 재고 예약 원장
--
-- [COM-01] reserved_qty 집계만으로는 어느 Saga가 얼마를 예약했는지
-- 알 수 없으므로 실패 보상·중복 요청·시간 만료를 안전하게 처리할 수 없다.
-- 이 테이블을 예약의 원본 원장으로 두고 inventory.reserved_qty는 조회 성능을
-- 위한 집계로 유지한다.
--
-- 예약 생성 트랜잭션의 권장 순서:
--   1) INSERT ... ON CONFLICT (saga_id, variant_id) DO NOTHING
--      → 같은 Saga 재시도에 대한 멱등성 확보
--   2) 새 행이 삽입된 경우에만 inventory를 원자적으로 갱신:
--      UPDATE inventory
--         SET available_qty = available_qty - :quantity,
--             reserved_qty  = reserved_qty  + :quantity,
--             version       = version + 1,
--             updated_at    = NOW()
--       WHERE variant_id = :variantId
--         AND available_qty >= :quantity;
--   두 작업은 반드시 같은 DB 트랜잭션에서 수행하고 UPDATE 영향 행이
--   0건이면 전체를 롤백해야 과판매를 막을 수 있다.
--
-- 상태 전이:
--   RESERVED → CONFIRMED : 결제 완료. reserved_qty만 감소(실재고 판매 확정)
--   RESERVED → RELEASED  : Saga 보상. reserved_qty 감소 + available_qty 복원
--   RESERVED → EXPIRED   : 만료 스윕. RELEASED와 동일하게 가용 재고 복원
-- 종결 상태는 다시 변경하지 않으며 애플리케이션이 조건부 UPDATE
-- (WHERE status = 'RESERVED')로 전이를 원자적으로 보장한다.
-- --------------------------------------------------------------
CREATE TABLE inventory_reservation (
    id              BIGSERIAL       PRIMARY KEY,
    saga_id         UUID            NOT NULL,
    variant_id      BIGINT          NOT NULL,
    quantity        INT             NOT NULL,
    status          VARCHAR(20)     NOT NULL DEFAULT 'RESERVED',
    expires_at      TIMESTAMPTZ       NOT NULL,
    created_at      TIMESTAMPTZ       NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ       NOT NULL DEFAULT NOW(),
    resolved_at     TIMESTAMPTZ,

    CONSTRAINT uq_inventory_reservation_saga_variant
        UNIQUE (saga_id, variant_id),
    CONSTRAINT fk_inventory_reservation_variant
        FOREIGN KEY (variant_id) REFERENCES product_variant (id),
    CONSTRAINT chk_inventory_reservation_quantity CHECK (quantity > 0),
    CONSTRAINT chk_inventory_reservation_status CHECK (
        status IN ('RESERVED', 'CONFIRMED', 'RELEASED', 'EXPIRED')
    ),
    -- 활성 예약은 아직 종결 시각이 없어야 하고, 종결 상태는 반드시 있어야 함
    CONSTRAINT chk_inventory_reservation_resolved CHECK (
        (status = 'RESERVED' AND resolved_at IS NULL)
        OR (status <> 'RESERVED' AND resolved_at IS NOT NULL)
    ),
    CONSTRAINT chk_inventory_reservation_expiry CHECK (
        expires_at > created_at
    )
);

COMMENT ON TABLE inventory_reservation IS
    'Saga별 SKU 재고 예약 원장. inventory.reserved_qty 집계의 원본';
COMMENT ON COLUMN inventory_reservation.saga_id IS
    'saga_instances.saga_id 논리 참조. 테이블 생성 순환을 피하고 이력 보존을 위해 FK 없음';
COMMENT ON COLUMN inventory_reservation.variant_id IS
    '예약 대상 SKU (product_variant.id)';
COMMENT ON COLUMN inventory_reservation.quantity IS '예약 수량(양수)';
COMMENT ON COLUMN inventory_reservation.status IS
    '예약 상태: RESERVED, CONFIRMED, RELEASED, EXPIRED';
COMMENT ON COLUMN inventory_reservation.expires_at IS
    'RESERVED 상태 자동 해제 기준 시각';
COMMENT ON COLUMN inventory_reservation.resolved_at IS
    'CONFIRMED/RELEASED/EXPIRED 종결 시각. 활성 예약이면 NULL';

-- 만료 스위퍼가 아직 활성인 예약만 만료 임박 순으로 조회
CREATE INDEX idx_inventory_reservation_expiring
    ON inventory_reservation (expires_at)
    WHERE status = 'RESERVED';

-- SKU별 활성 예약 합계 검증 및 운영 추적
CREATE INDEX idx_inventory_reservation_variant_active
    ON inventory_reservation (variant_id)
    WHERE status = 'RESERVED';


-- --------------------------------------------------------------
-- 6. product_price_history — 가격 이력 (가격 하락 알림용)
-- --------------------------------------------------------------
CREATE TABLE product_price_history (
    id              BIGSERIAL       PRIMARY KEY,
    variant_id      BIGINT          NOT NULL,
    price           BIGINT          NOT NULL,
    effective_from  TIMESTAMPTZ       NOT NULL,
    effective_to    TIMESTAMPTZ,
    changed_by      VARCHAR(50),
    created_at      TIMESTAMPTZ       NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_product_price_history_variant
        FOREIGN KEY (variant_id) REFERENCES product_variant (id),
    CONSTRAINT chk_product_price_history_price CHECK (price >= 0),
    CONSTRAINT chk_product_price_history_period CHECK (
        effective_to IS NULL OR effective_to > effective_from
    )
);

COMMENT ON TABLE product_price_history IS 'SKU 가격 변경 이력. 가격 하락 알림 입력';
COMMENT ON COLUMN product_price_history.variant_id IS '대상 SKU (product_variant.id)';
COMMENT ON COLUMN product_price_history.price IS
    '적용 가격. 최소 화폐 단위(원/센트 등) BIGINT';
COMMENT ON COLUMN product_price_history.effective_from IS '가격 적용 시작 시각';
COMMENT ON COLUMN product_price_history.effective_to IS
    '가격 적용 종료 시각. NULL이면 현재 유효';
COMMENT ON COLUMN product_price_history.changed_by IS '변경 주체(관리자/시스템)';

CREATE INDEX idx_product_price_history_variant_from
    ON product_price_history (variant_id, effective_from DESC);

-- [COM-03] 현재 유효 가격(effective_to IS NULL)은 SKU당 1건.
--   일반 인덱스였을 때는 가격 변경 트랜잭션이 "기존 행 마감(UPDATE) →
--   새 행 INSERT" 순서를 지키지 않으면 현재가가 2건 이상 생겨
--   조회마다 다른 가격이 나올 수 있었다. UNIQUE 로 승격해 DB 가 차단하고,
--   조회 인덱스 역할은 그대로 유지한다.
CREATE UNIQUE INDEX uq_product_price_history_current
    ON product_price_history (variant_id)
    WHERE effective_to IS NULL;


-- --------------------------------------------------------------
-- 7. orders — 주문
--
-- [COM-02] 불변식 보강:
--   1) 금액 정합: final_amount = total_amount - discount_amount - point_used.
--      개별 >= 0 CHECK 만으로는 "합계가 안 맞는 주문"이 저장될 수 있어
--      등식 자체를 DB 에서 강제한다 (>=0 CHECK 들과 결합하면
--      discount + point_used <= total 도 자동 보장).
--   2) 주문 생성 멱등: idempotency_key UNIQUE.
--      클라이언트(BFF)가 주문서 화면 진입 시 발급한 키를 제출하고,
--      네트워크 재시도/더블클릭이 같은 키로 오면 두 번째 INSERT 가
--      UNIQUE 위반 → 기존 주문을 반환한다.
--   3) Saga 연결: saga_id (nullable). 주문 1건 = 사가 최대 1건.
--      FK/UNIQUE 는 saga_instances 정의 뒤에 ALTER 로 추가 (아래 13번 참고).
--   4) 상태-시각 정합: paid_at/shipped_at/completed_at 은 해당 상태에
--      도달했을 때만 값이 있어야 한다.
-- --------------------------------------------------------------
CREATE TABLE orders (
    id                      BIGSERIAL       PRIMARY KEY,
    -- [COM-02] 주문 생성 멱등 키 (BFF/클라이언트 발급 UUID 문자열)
    idempotency_key         VARCHAR(100)    NOT NULL,
    user_id                 UUID            NOT NULL,   -- auth.account.id 논리 참조
    user_nickname_snapshot  VARCHAR(50),
    total_amount            BIGINT          NOT NULL,
    discount_amount         BIGINT          NOT NULL DEFAULT 0,
    point_used              BIGINT          NOT NULL DEFAULT 0,
    final_amount            BIGINT          NOT NULL,
    status                  VARCHAR(20)     NOT NULL,   -- PENDING, PAID, SHIPPED, COMPLETED, CANCELLED
    -- [COM-02] 이 주문을 처리하는 사가 (saga_instances.saga_id, ALTER 로 FK)
    saga_id                 UUID,
    referral_type           VARCHAR(30),                -- ORGANIC, RECOMMENDATION, OOTD_TAG, AD
    referral_source_id      VARCHAR(100),
    created_at              TIMESTAMPTZ       NOT NULL DEFAULT NOW(),
    paid_at                 TIMESTAMPTZ,
    shipped_at              TIMESTAMPTZ,
    completed_at            TIMESTAMPTZ,

    CONSTRAINT uq_orders_idempotency UNIQUE (idempotency_key),
    CONSTRAINT chk_orders_total_amount CHECK (total_amount >= 0),
    CONSTRAINT chk_orders_discount_amount CHECK (discount_amount >= 0),
    CONSTRAINT chk_orders_point_used CHECK (point_used >= 0),
    CONSTRAINT chk_orders_final_amount CHECK (final_amount >= 0),
    -- [COM-02] 금액 등식. 어긋난 합계는 저장 자체가 불가능
    CONSTRAINT chk_orders_amount_equation CHECK (
        final_amount = total_amount - discount_amount - point_used
    ),
    CONSTRAINT chk_orders_status CHECK (
        status IN ('PENDING', 'PAID', 'SHIPPED', 'COMPLETED', 'CANCELLED')
    ),
    -- [COM-02] 상태-시각 정합. 도달한 상태의 시각만 존재
    --   PENDING/CANCELLED: 결제 전 취소 가능 → paid_at 규칙에서 CANCELLED 제외
    CONSTRAINT chk_orders_paid_at CHECK (
        (status IN ('PAID', 'SHIPPED', 'COMPLETED') AND paid_at IS NOT NULL)
        OR (status = 'PENDING' AND paid_at IS NULL)
        OR (status = 'CANCELLED')
    ),
    CONSTRAINT chk_orders_shipped_at CHECK (
        (status IN ('SHIPPED', 'COMPLETED')) = (shipped_at IS NOT NULL)
    ),
    CONSTRAINT chk_orders_completed_at CHECK (
        (status = 'COMPLETED') = (completed_at IS NOT NULL)
    ),
    -- [LOW-A16] 유입 유형 오타 방지
    CONSTRAINT chk_orders_referral_type CHECK (
        referral_type IS NULL
        OR referral_type IN ('ORGANIC', 'RECOMMENDATION', 'OOTD_TAG', 'AD')
    )
);

COMMENT ON TABLE orders IS
    '주문 헤더. 금액은 최소 화폐 단위 BIGINT. 금액 등식·멱등 키·상태 시각을 DB 가 강제(COM-02)';
COMMENT ON COLUMN orders.idempotency_key IS
    '주문 생성 멱등 키. 클라이언트 발급, 재시도 시 동일 키 재제출 → UNIQUE 로 중복 주문 차단';
COMMENT ON COLUMN orders.user_id IS
    'auth.account.id 논리 참조. DB-per-service 경계로 FK 없음';
COMMENT ON COLUMN orders.user_nickname_snapshot IS '주문 시점 닉네임 스냅샷';
COMMENT ON COLUMN orders.total_amount IS
    '상품 합계 금액. 최소 화폐 단위(원/센트 등) BIGINT';
COMMENT ON COLUMN orders.discount_amount IS
    '할인 금액. 최소 화폐 단위(원/센트 등) BIGINT';
COMMENT ON COLUMN orders.point_used IS
    '사용 포인트(금액 환산). 최소 화폐/포인트 단위 BIGINT. point-service 결과 스냅샷';
COMMENT ON COLUMN orders.final_amount IS
    '최종 결제 금액 = total - discount - point_used (CHECK 강제)';
COMMENT ON COLUMN orders.status IS
    '주문 상태: PENDING, PAID, SHIPPED, COMPLETED, CANCELLED';
COMMENT ON COLUMN orders.saga_id IS
    '이 주문을 처리하는 사가 (saga_instances.saga_id). 주문당 최대 1건, FK 는 파일 하단 ALTER';
COMMENT ON COLUMN orders.referral_type IS
    '유입 유형: ORGANIC, RECOMMENDATION, OOTD_TAG, AD';
COMMENT ON COLUMN orders.referral_source_id IS
    '유입 소스 ID 논리 참조 (referral_type 별 외부 리소스). FK 없음';

CREATE INDEX idx_orders_user_created
    ON orders (user_id, created_at DESC);

CREATE INDEX idx_orders_status_created
    ON orders (status, created_at DESC);


-- --------------------------------------------------------------
-- 8. order_item — 주문 라인
--    product_id / variant_id 는 주문 스냅샷 보존을 위해 FK 생략
-- --------------------------------------------------------------
CREATE TABLE order_item (
    id                      BIGSERIAL       PRIMARY KEY,
    order_id                BIGINT          NOT NULL,
    variant_id              BIGINT          NOT NULL,
    product_id              BIGINT          NOT NULL,
    product_name_snapshot   VARCHAR(200),
    quantity                INT             NOT NULL,
    price_snapshot          BIGINT          NOT NULL,

    CONSTRAINT fk_order_item_order
        FOREIGN KEY (order_id) REFERENCES orders (id),
    CONSTRAINT chk_order_item_quantity CHECK (quantity > 0),
    CONSTRAINT chk_order_item_price_snapshot CHECK (price_snapshot >= 0)
);

COMMENT ON TABLE order_item IS '주문 라인 아이템. 상품명/가격은 스냅샷 보관';
COMMENT ON COLUMN order_item.order_id IS '소속 주문 (orders.id)';
COMMENT ON COLUMN order_item.variant_id IS
    'product_variant.id 논리 참조. 주문 이력 보존을 위해 FK 없음';
COMMENT ON COLUMN order_item.product_id IS
    'product.id 논리 참조. 주문 이력 보존을 위해 FK 없음';
COMMENT ON COLUMN order_item.product_name_snapshot IS '주문 시점 상품명 스냅샷';
COMMENT ON COLUMN order_item.quantity IS '주문 수량';
COMMENT ON COLUMN order_item.price_snapshot IS
    '주문 시점 단가. 최소 화폐 단위(원/센트 등) BIGINT';

CREATE INDEX idx_order_item_order
    ON order_item (order_id);

CREATE INDEX idx_order_item_product
    ON order_item (product_id);

CREATE INDEX idx_order_item_variant
    ON order_item (variant_id);


-- --------------------------------------------------------------
-- 9. payment — 결제 시도 이력 (attempt ledger)
--
-- [COM-03] 기존 UNIQUE(order_id) 는 "주문당 결제 1행" 이라
--   실패 후 재결제 시 이전 시도를 UPDATE 로 덮어야 했다 → PG 분쟁·정산
--   대사 때 필요한 실패 이력이 사라진다.
--   결제는 시도(attempt)마다 INSERT 하는 append-only 이력으로 바꾸고,
--   대신 부분 UNIQUE 두 개로 비즈니스 불변식을 유지한다:
--     1) 진행 중(PENDING/AUTHORIZED) 시도는 주문당 1건
--        → 동시 재결제(더블 클릭, 워커 경합) 차단
--     2) 성공(CAPTURED) 결제는 주문당 1건
--        → 이중 청구 차단 (REFUNDED 로 전이하면 해제되어 재결제 가능)
--   attempt_no 는 (order_id, attempt_no) UNIQUE 로 시도 순서를 고정한다.
-- --------------------------------------------------------------
CREATE TABLE payment (
    id                      BIGSERIAL       PRIMARY KEY,
    order_id                BIGINT          NOT NULL,
    -- 주문 내 결제 시도 순번 (1부터). 애플리케이션이 MAX+1 로 발급
    attempt_no              INT             NOT NULL DEFAULT 1,
    method                  VARCHAR(20)     NOT NULL,   -- CARD, BANK_TRANSFER, POINT_ONLY
    amount                  BIGINT          NOT NULL,
    status                  VARCHAR(20)     NOT NULL,
    external_payment_id     VARCHAR(100),
    failure_reason          TEXT,
    created_at              TIMESTAMPTZ       NOT NULL DEFAULT NOW(),
    paid_at                 TIMESTAMPTZ,
    refunded_at             TIMESTAMPTZ,

    CONSTRAINT uq_payment_order_attempt UNIQUE (order_id, attempt_no),
    CONSTRAINT fk_payment_order
        FOREIGN KEY (order_id) REFERENCES orders (id),
    CONSTRAINT chk_payment_attempt_no CHECK (attempt_no >= 1),
    CONSTRAINT chk_payment_amount CHECK (amount >= 0),
    CONSTRAINT chk_payment_method CHECK (
        method IN ('CARD', 'BANK_TRANSFER', 'POINT_ONLY')
    ),
    CONSTRAINT chk_payment_status CHECK (
        status IN ('PENDING', 'AUTHORIZED', 'CAPTURED', 'FAILED', 'REFUNDED', 'CANCELLED')
    ),
    -- 상태-시각 정합: 결제 완료 이후에만 paid_at, 환불 시에만 refunded_at
    CONSTRAINT chk_payment_paid_at CHECK (
        (status IN ('CAPTURED', 'REFUNDED')) = (paid_at IS NOT NULL)
    ),
    CONSTRAINT chk_payment_refunded_at CHECK (
        (status = 'REFUNDED') = (refunded_at IS NOT NULL)
    ),
    -- 실패 사유는 실패/취소 시도에만
    CONSTRAINT chk_payment_failure_reason CHECK (
        failure_reason IS NULL OR status IN ('FAILED', 'CANCELLED')
    )
);

COMMENT ON TABLE payment IS
    '결제 시도 이력(append-only). 진행 중 1건·성공 1건은 부분 UNIQUE 로 강제(COM-03)';
COMMENT ON COLUMN payment.order_id IS '대상 주문 (orders.id)';
COMMENT ON COLUMN payment.attempt_no IS '주문 내 시도 순번 (1부터, 주문별 UNIQUE)';
COMMENT ON COLUMN payment.method IS '결제 수단: CARD, BANK_TRANSFER, POINT_ONLY';
COMMENT ON COLUMN payment.amount IS
    '결제 금액. 최소 화폐 단위(원/센트 등) BIGINT. CAPTURED 시 orders.final_amount 와 일치해야 함 (LOW-A16, 앱 검증)';
COMMENT ON COLUMN payment.status IS
    '결제 상태: PENDING, AUTHORIZED, CAPTURED, FAILED, REFUNDED, CANCELLED';
COMMENT ON COLUMN payment.external_payment_id IS 'PG사 결제 ID';
COMMENT ON COLUMN payment.failure_reason IS 'FAILED/CANCELLED 사유 (PG 응답 코드 등)';

-- [COM-03] 진행 중 시도는 주문당 1건 (동시 재결제 차단)
CREATE UNIQUE INDEX uq_payment_order_in_progress
    ON payment (order_id)
    WHERE status IN ('PENDING', 'AUTHORIZED');

-- [COM-03] 성공 결제는 주문당 1건 (이중 청구 차단)
CREATE UNIQUE INDEX uq_payment_order_captured
    ON payment (order_id)
    WHERE status = 'CAPTURED';

CREATE UNIQUE INDEX uq_payment_external_payment_id
    ON payment (external_payment_id)
    WHERE external_payment_id IS NOT NULL;

-- 주문별 결제 이력 조회
CREATE INDEX idx_payment_order_created
    ON payment (order_id, created_at DESC);

-- [LOW-A16] 정산·대사: 성공/환불 결제를 상태·시각으로 스윕
CREATE INDEX idx_payment_status_paid_at
    ON payment (status, paid_at DESC)
    WHERE paid_at IS NOT NULL;


-- --------------------------------------------------------------
-- 10. wishlist — 위시리스트
-- --------------------------------------------------------------
CREATE TABLE wishlist (
    id                      BIGSERIAL       PRIMARY KEY,
    user_id                 UUID            NOT NULL,   -- auth.account.id 논리 참조
    product_id              BIGINT          NOT NULL,
    notify_on_price_drop    BOOLEAN         NOT NULL DEFAULT TRUE,
    notify_on_restock       BOOLEAN         NOT NULL DEFAULT TRUE,
    target_price            BIGINT,                     -- 이 가격 이하 시 알림
    added_at                TIMESTAMPTZ       NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_wishlist_user_product UNIQUE (user_id, product_id),
    CONSTRAINT fk_wishlist_product
        FOREIGN KEY (product_id) REFERENCES product (id),
    CONSTRAINT chk_wishlist_target_price CHECK (
        target_price IS NULL OR target_price >= 0
    )
);

COMMENT ON TABLE wishlist IS '사용자 위시리스트 및 가격/재입고 알림 설정';
COMMENT ON COLUMN wishlist.user_id IS
    'auth.account.id 논리 참조. DB-per-service 경계로 FK 없음';
COMMENT ON COLUMN wishlist.product_id IS '관심 상품 (product.id)';
COMMENT ON COLUMN wishlist.notify_on_price_drop IS '가격 하락 알림 여부';
COMMENT ON COLUMN wishlist.notify_on_restock IS '재입고 알림 여부';
COMMENT ON COLUMN wishlist.target_price IS
    '목표 가격. 최소 화폐 단위(원/센트 등) BIGINT. 이하이면 알림';

CREATE INDEX idx_wishlist_price_drop
    ON wishlist (product_id)
    WHERE notify_on_price_drop = TRUE;

CREATE INDEX idx_wishlist_restock
    ON wishlist (product_id)
    WHERE notify_on_restock = TRUE;


-- --------------------------------------------------------------
-- 11. cart_item — 장바구니
-- --------------------------------------------------------------
CREATE TABLE cart_item (
    id                      BIGSERIAL       PRIMARY KEY,
    user_id                 UUID            NOT NULL,   -- auth.account.id 논리 참조
    variant_id              BIGINT          NOT NULL,
    quantity                INT             NOT NULL,
    added_at                TIMESTAMPTZ       NOT NULL DEFAULT NOW(),
    abandoned_notified_at   TIMESTAMPTZ,                  -- 마지막 이탈 알림 시각

    CONSTRAINT uq_cart_item_user_variant UNIQUE (user_id, variant_id),
    CONSTRAINT fk_cart_item_variant
        FOREIGN KEY (variant_id) REFERENCES product_variant (id),
    CONSTRAINT chk_cart_item_quantity CHECK (quantity > 0)
);

COMMENT ON TABLE cart_item IS '장바구니 아이템';
COMMENT ON COLUMN cart_item.user_id IS
    'auth.account.id 논리 참조. DB-per-service 경계로 FK 없음';
COMMENT ON COLUMN cart_item.variant_id IS '담은 SKU (product_variant.id)';
COMMENT ON COLUMN cart_item.quantity IS '담은 수량';
COMMENT ON COLUMN cart_item.abandoned_notified_at IS '장바구니 이탈 알림을 보낸 마지막 시각';

CREATE INDEX idx_cart_item_user_added
    ON cart_item (user_id, added_at DESC);

-- 이탈 알림 대상 조회
CREATE INDEX idx_cart_item_abandoned_candidates
    ON cart_item (added_at)
    WHERE abandoned_notified_at IS NULL;


-- --------------------------------------------------------------
-- 12. product_purchase_pattern — 재구매 예측 입력
-- --------------------------------------------------------------
CREATE TABLE product_purchase_pattern (
    user_id                     UUID            NOT NULL,   -- auth.account.id 논리 참조
    product_id                  BIGINT          NOT NULL,
    purchase_count              INT             NOT NULL DEFAULT 0,
    first_purchased_at          TIMESTAMPTZ,
    last_purchased_at           TIMESTAMPTZ,
    avg_purchase_interval_days  INT,                        -- 평균 구매 간격(일)
    predicted_next_purchase_at  TIMESTAMPTZ,
    confidence_score            DECIMAL(3, 2),              -- 0.0 ~ 1.0
    last_notified_at            TIMESTAMPTZ,
    updated_at                  TIMESTAMPTZ       NOT NULL DEFAULT NOW(),

    CONSTRAINT pk_product_purchase_pattern PRIMARY KEY (user_id, product_id),
    CONSTRAINT fk_product_purchase_pattern_product
        FOREIGN KEY (product_id) REFERENCES product (id),
    CONSTRAINT chk_product_purchase_pattern_count CHECK (purchase_count >= 0),
    CONSTRAINT chk_product_purchase_pattern_interval CHECK (
        avg_purchase_interval_days IS NULL OR avg_purchase_interval_days >= 0
    ),
    CONSTRAINT chk_product_purchase_pattern_confidence CHECK (
        confidence_score IS NULL
        OR (confidence_score >= 0 AND confidence_score <= 1)
    ),
    -- [LOW-A16] 구매 이력 시각 정합
    CONSTRAINT chk_product_purchase_pattern_dates CHECK (
        first_purchased_at IS NULL
        OR last_purchased_at IS NULL
        OR first_purchased_at <= last_purchased_at
    )
);

COMMENT ON TABLE product_purchase_pattern IS '재구매 리마인더 알고리즘 입력 데이터';
COMMENT ON COLUMN product_purchase_pattern.user_id IS
    'auth.account.id 논리 참조. DB-per-service 경계로 FK 없음';
COMMENT ON COLUMN product_purchase_pattern.product_id IS '구매 패턴 대상 상품 (product.id)';
COMMENT ON COLUMN product_purchase_pattern.purchase_count IS '누적 구매 횟수';
COMMENT ON COLUMN product_purchase_pattern.avg_purchase_interval_days IS
    '평균 구매 간격(일)';
COMMENT ON COLUMN product_purchase_pattern.predicted_next_purchase_at IS
    '예측 다음 구매 시각';
COMMENT ON COLUMN product_purchase_pattern.confidence_score IS
    '예측 신뢰도 0.0~1.0';

CREATE INDEX idx_product_purchase_pattern_predicted
    ON product_purchase_pattern (predicted_next_purchase_at)
    WHERE predicted_next_purchase_at IS NOT NULL;


-- --------------------------------------------------------------
-- 13. saga_instances — Saga Orchestrator 상태
--     common-saga SagaInstance JPA 와 컬럼/테이블명 일치
--     (ERD commerce_saga_instances 대체, status → state)
--
-- [COM-04] version (낙관적 락):
--   참여자 reply 가 동시에 도착하면 두 워커가 같은 saga 행을 읽고
--   current_step/state/payload 를 서로 덮어쓸 수 있다 (lost update).
--   version 컬럼 + JPA @Version 으로 UPDATE ... WHERE version = ?
--   영향을 0행이면 재조회·재시도한다.
-- --------------------------------------------------------------
CREATE TABLE saga_instances (
    saga_id         UUID            PRIMARY KEY,
    saga_type       VARCHAR(50)     NOT NULL,
    current_step    VARCHAR(50),
    state           VARCHAR(20)     NOT NULL,           -- SagaState enum
    payload         JSONB           NOT NULL,
    version         INT             NOT NULL DEFAULT 0, -- Optimistic lock (COM-04)
    created_at      TIMESTAMPTZ       NOT NULL,
    updated_at      TIMESTAMPTZ       NOT NULL,

    CONSTRAINT chk_saga_instances_state CHECK (
        state IN ('STARTED', 'IN_PROGRESS', 'COMPLETED', 'COMPENSATING', 'FAILED')
    ),
    CONSTRAINT chk_saga_instances_version CHECK (version >= 0)
);

COMMENT ON TABLE saga_instances IS
    'Saga Orchestrator 상태. common-saga SagaInstance 엔티티 매핑. version 으로 동시 reply 덮어쓰기 방지(COM-04)';
COMMENT ON COLUMN saga_instances.saga_id IS '사가 인스턴스 ID (UUID)';
COMMENT ON COLUMN saga_instances.saga_type IS '사가 유형 (예: ORDER_PAYMENT)';
COMMENT ON COLUMN saga_instances.current_step IS '현재 실행 단계명';
COMMENT ON COLUMN saga_instances.state IS
    '사가 상태: STARTED, IN_PROGRESS, COMPLETED, COMPENSATING, FAILED';
COMMENT ON COLUMN saga_instances.payload IS '사가 컨텍스트 JSON';
COMMENT ON COLUMN saga_instances.version IS
    '낙관적 락 버전. JPA @Version. 동시 reply 시 OptimisticLockException → 재시도';

CREATE INDEX idx_saga_instances_type_state
    ON saga_instances (saga_type, state);

CREATE INDEX idx_saga_instances_updated
    ON saga_instances (updated_at);

-- [COM-02] orders ↔ saga 연결 마무리 (saga_instances 정의 후 ALTER)
--   주문 흐름: 주문 INSERT → 사가 시작 → orders.saga_id UPDATE.
--   같은 DB 이므로 FK 로 무결성을 강제하고, 부분 UNIQUE 로
--   "사가 1건 = 주문 1건" 을 보장한다 (다른 주문이 같은 사가를 가리킬 수 없음).
ALTER TABLE orders
    ADD CONSTRAINT fk_orders_saga
        FOREIGN KEY (saga_id) REFERENCES saga_instances (saga_id);

CREATE UNIQUE INDEX uq_orders_saga
    ON orders (saga_id)
    WHERE saga_id IS NOT NULL;


-- --------------------------------------------------------------
-- 14. commerce_saga_step_history — 사가 단계 실행 이력
--
-- [COM-04] 스텝 멱등성:
--   같은 단계가 Kafka reply 재소비·워커 경합으로 두 번 실행되면
--   참여자(재고 예약, 포인트 예약 등)에 중복 명령이 나간다.
--   1) (saga_id, step_name, attempt_no) UNIQUE — 시도 원장 (재시도는 attempt+1)
--   2) 부분 UNIQUE (saga_id, step_name) WHERE status IN ('STARTED','SUCCEEDED')
--      — 진행 중·성공한 단계는 중복 INSERT 불가.
--        FAILED 후 재시도는 새 attempt 행으로 STARTED 가능.
--        COMPENSATED/SKIPPED 는 성공 경로와 공존할 수 있어 제외.
-- --------------------------------------------------------------
CREATE TABLE commerce_saga_step_history (
    id                  UUID            PRIMARY KEY,
    saga_id             UUID            NOT NULL,
    step_name           VARCHAR(50)     NOT NULL,
    attempt_no          INT             NOT NULL DEFAULT 1,
    status              VARCHAR(20)     NOT NULL,
    request_payload     JSONB,
    response_payload    JSONB,
    executed_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ       NOT NULL DEFAULT NOW(),

    CONSTRAINT fk_commerce_saga_step_history_saga
        FOREIGN KEY (saga_id) REFERENCES saga_instances (saga_id),
    CONSTRAINT uq_commerce_saga_step_attempt
        UNIQUE (saga_id, step_name, attempt_no),
    CONSTRAINT chk_commerce_saga_step_history_status CHECK (
        status IN ('STARTED', 'SUCCEEDED', 'FAILED', 'COMPENSATED', 'SKIPPED')
    ),
    CONSTRAINT chk_commerce_saga_step_attempt_no CHECK (attempt_no >= 1)
);

COMMENT ON TABLE commerce_saga_step_history IS
    '사가 단계별 실행/보상 이력. attempt UNIQUE + 진행/성공 부분 UNIQUE 로 중복 실행 차단(COM-04)';
COMMENT ON COLUMN commerce_saga_step_history.saga_id IS
    '소속 사가 (saga_instances.saga_id)';
COMMENT ON COLUMN commerce_saga_step_history.step_name IS '단계 이름';
COMMENT ON COLUMN commerce_saga_step_history.attempt_no IS
    '단계 내 시도 순번 (1부터). FAILED 후 재시도 시 +1';
COMMENT ON COLUMN commerce_saga_step_history.status IS
    '단계 상태: STARTED, SUCCEEDED, FAILED, COMPENSATED, SKIPPED';
COMMENT ON COLUMN commerce_saga_step_history.request_payload IS '단계 요청 페이로드';
COMMENT ON COLUMN commerce_saga_step_history.response_payload IS '단계 응답 페이로드';
COMMENT ON COLUMN commerce_saga_step_history.executed_at IS '단계 실행(완료) 시각';

-- [COM-04] 같은 단계의 진행 중·성공 행은 사가당 1건 (중복 실행 차단)
CREATE UNIQUE INDEX uq_commerce_saga_step_active
    ON commerce_saga_step_history (saga_id, step_name)
    WHERE status IN ('STARTED', 'SUCCEEDED');

CREATE INDEX idx_commerce_saga_step_history_saga_executed
    ON commerce_saga_step_history (saga_id, executed_at);
