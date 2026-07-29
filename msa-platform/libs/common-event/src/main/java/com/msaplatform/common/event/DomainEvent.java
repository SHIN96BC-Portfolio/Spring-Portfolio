package com.msaplatform.common.event;

import com.fasterxml.jackson.annotation.JsonIgnore;
import lombok.Getter;

import java.time.Instant;
import java.util.UUID;

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

    @JsonIgnore
    public abstract String partitionKey();

    @JsonIgnore
    public abstract String aggregateType();

    @JsonIgnore
    public abstract String aggregateId();
}
