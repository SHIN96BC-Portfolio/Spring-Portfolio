package com.msaauth.auth.application.port.out;

import com.msaauth.common.event.DomainEvent;

import java.util.List;

/**
 * 도메인 이벤트 발행 인터페이스.
 * 구현: OutboxEventPublisher (auth 내부) 또는 직접 Kafka.
 */
public interface EventPublisher {
    void publish(DomainEvent event);
    void publishAll(List<DomainEvent> events);
}
