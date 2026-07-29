package com.msaplatform.common.saga;

import jakarta.persistence.*;
import lombok.AccessLevel;
import lombok.Getter;
import lombok.NoArgsConstructor;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;

import java.time.Instant;
import java.util.UUID;

/**
 * Saga Orchestrator 상태 엔티티.
 *
 * <p>[COM-04] {@link #version} 은 JPA {@code @Version} 낙관적 락이다.
 * 참여자 reply 가 동시에 도착해 두 워커가 같은 행을 읽고
 * {@link #moveTo} 로 덮어쓰는 lost update 를 막는다.
 * 충돌 시 {@code OptimisticLockException} → 재조회 후 재시도.</p>
 */
@Entity
@Table(name = "saga_instances")
@Getter
@NoArgsConstructor(access = AccessLevel.PROTECTED)
public class SagaInstance {

    @Id @Column(columnDefinition = "uuid")
    private UUID sagaId;

    @Column(nullable = false, length = 50)
    private String sagaType;

    @Column(length = 50)
    private String currentStep;

    @Column(nullable = false, length = 20)
    @Enumerated(EnumType.STRING)
    private SagaState state;

    @Column(columnDefinition = "jsonb", nullable = false)
    @JdbcTypeCode(SqlTypes.JSON)
    private String payload;

    /**
     * 낙관적 락 버전. DB {@code saga_instances.version} 과 매핑.
     * 애플리케이션이 직접 증가시키지 않는다 — JPA 가 flush 시 처리.
     */
    @Version
    @Column(nullable = false)
    private int version;

    @Column(nullable = false)
    private Instant createdAt;

    @Column(nullable = false)
    private Instant updatedAt;

    public static SagaInstance start(String sagaType, String payload) {
        SagaInstance saga = new SagaInstance();
        saga.sagaId = UUID.randomUUID();
        saga.sagaType = sagaType;
        saga.state = SagaState.STARTED;
        saga.payload = payload;
        saga.version = 0;
        saga.createdAt = Instant.now();
        saga.updatedAt = Instant.now();
        return saga;
    }

    public void moveTo(String step, SagaState newState) {
        this.currentStep = step;
        this.state = newState;
        this.updatedAt = Instant.now();
    }
}
