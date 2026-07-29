package com.msaauth.common.event;

import com.fasterxml.jackson.annotation.JsonIgnore;
import com.fasterxml.jackson.annotation.JsonProperty;
import lombok.Getter;

import java.time.Instant;
import java.util.UUID;

/**
 * 모든 도메인 이벤트의 부모.
 *
 * <p>외부 이벤트는 공통 메타데이터와 도메인 payload를 분리한 다음 계약을 사용한다.</p>
 * <pre>
 * {
 *   "eventId": "...",
 *   "eventType": "AccountRegistered",
 *   "eventVersion": 1,
 *   "occurredAt": "...",
 *   "traceId": "...",
 *   "data": { ... }
 * }
 * </pre>
 *
 * <p>{@code data} envelope를 강제하는 이유는 발행 서비스의 Java 필드 배치가 바뀌어도
 * Kafka 소비 DTO와 JSON Schema가 동일한 외부 계약을 유지하도록 하기 위함이다.</p>
 *
 * 사용:
 * <pre>
 * public class AccountRegistered extends DomainEvent {
 *     public AccountRegistered(UUID accountId, ...) {
 *         super("AccountRegistered");
 *     }
 *
 *     public Data eventData() {
 *         return new Data(accountId, ...);
 *     }
 * }
 * </pre>
 */
@Getter
public abstract class DomainEvent {
    private final String eventId;
    private final String eventType;
    private final Instant occurredAt;
    private final int eventVersion;
    private final String traceId;

    protected DomainEvent(String eventType) {
        this(eventType, 1);
    }

    protected DomainEvent(String eventType, int version) {
        this.eventId = UUID.randomUUID().toString();
        this.eventType = eventType;
        this.occurredAt = Instant.now();
        this.eventVersion = version;
        this.traceId = TraceContext.currentTraceId();
    }

    /**
     * Kafka 파티션 키 (하위 클래스에서 오버라이드)
     */
    @JsonIgnore
    public abstract String partitionKey();

    /**
     * Aggregate 타입 (예: "Account", "Order")
     */
    @JsonIgnore
    public abstract String aggregateType();

    /**
     * Aggregate ID (예: accountId)
     */
    @JsonIgnore
    public abstract String aggregateId();

    /**
     * 외부 이벤트 계약의 도메인별 payload.
     *
     * 공통 메타데이터와 도메인 데이터를 분리해 모든 이벤트를
     * { eventId, eventType, eventVersion, occurredAt, traceId, data } 형태로 직렬화한다.
     */
    @JsonProperty("data")
    public abstract Object eventData();
}
