package com.msaplatform.common.outbox;

import jakarta.persistence.*;
import lombok.AccessLevel;
import lombok.Getter;
import lombok.NoArgsConstructor;
import org.hibernate.annotations.JdbcTypeCode;
import org.hibernate.type.SqlTypes;

import java.time.Instant;
import java.util.UUID;

@Entity
@Table(name = "outbox_events")
@Getter
@NoArgsConstructor(access = AccessLevel.PROTECTED)
public class OutboxEvent {
    @Id @Column(columnDefinition = "uuid")
    private UUID id;

    @Column(nullable = false, length = 50) private String aggregateType;
    @Column(nullable = false, length = 100) private String aggregateId;
    @Column(nullable = false, length = 100) private String eventType;
    @Column(nullable = false) private Integer eventVersion;

    @Column(columnDefinition = "jsonb", nullable = false)
    @JdbcTypeCode(SqlTypes.JSON)
    private String payload;

    @Column(length = 100) private String traceId;
    @Column(nullable = false) private Instant createdAt;
    @Column private Instant publishedAt;

    public static OutboxEvent create(UUID eventId,
                                     String aggregateType, String aggregateId,
                                     String eventType, int version, String payloadJson, String traceId) {
        OutboxEvent e = new OutboxEvent();
        e.id = eventId;
        e.aggregateType = aggregateType;
        e.aggregateId = aggregateId;
        e.eventType = eventType;
        e.eventVersion = version;
        e.payload = payloadJson;
        e.traceId = traceId;
        e.createdAt = Instant.now();
        return e;
    }

    public void markPublished() { this.publishedAt = Instant.now(); }
    public boolean isPublished() { return publishedAt != null; }
}
