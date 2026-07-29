package com.msaauth.common.outbox;

import jakarta.persistence.*;
import lombok.AccessLevel;
import lombok.Getter;
import lombok.NoArgsConstructor;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;

import java.time.Instant;
import java.util.UUID;

/**
 * Outbox 패턴의 이벤트 저장 엔티티.
 * 
 * 도메인 트랜잭션과 같은 트랜잭션 안에서 저장되어 원자성 보장.
 * 별도 Publisher가 이걸 읽어서 Kafka로 발행.
 */
@Entity
@Table(name = "outbox_events")
@Getter
@NoArgsConstructor(access = AccessLevel.PROTECTED)
public class OutboxEvent {

    @Id
    @Column(columnDefinition = "uuid")
    private UUID id;

    @Column(nullable = false, length = 50)
    private String aggregateType;

    @Column(nullable = false, length = 100)
    private String aggregateId;

    @Column(nullable = false, length = 100)
    private String eventType;

    @Column(nullable = false)
    private Integer eventVersion;

    @Column(columnDefinition = "jsonb", nullable = false)
    @JdbcTypeCode(SqlTypes.JSON)
    private String payload;

    @Column(length = 100)
    private String traceId;

    @Column(nullable = false)
    private Instant createdAt;

    @Column
    private Instant publishedAt;

    public static OutboxEvent create(
            UUID eventId,
            String aggregateType,
            String aggregateId,
            String eventType,
            int version,
            String payloadJson,
            String traceId
    ) {
        OutboxEvent evt = new OutboxEvent();
        evt.id = eventId;
        evt.aggregateType = aggregateType;
        evt.aggregateId = aggregateId;
        evt.eventType = eventType;
        evt.eventVersion = version;
        evt.payload = payloadJson;
        evt.traceId = traceId;
        evt.createdAt = Instant.now();
        return evt;
    }

    public void markPublished() {
        this.publishedAt = Instant.now();
    }

    public boolean isPublished() {
        return publishedAt != null;
    }
}
