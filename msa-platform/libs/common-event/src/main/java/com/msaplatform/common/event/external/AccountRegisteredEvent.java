package com.msaplatform.common.event.external;

/**
 * msa-auth가 발행하는 AccountRegistered 이벤트 (외부 이벤트).
 * 
 * Kafka로부터 역직렬화되는 클래스.
 * 발행 소유권은 msa-auth에 있고, 여기는 구독 클라이언트용.
 */
public record AccountRegisteredEvent(
    String eventId,
    String eventType,
    java.time.Instant occurredAt,
    int eventVersion,
    String traceId,
    Data data
) {
    public record Data(
        String accountId,
        String email,
        String registeredVia
    ) {}
}
