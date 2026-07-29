package com.msaauth.auth.adapter.out.event;

import com.msaauth.auth.application.port.out.EventPublisher;
import com.msaauth.common.event.DomainEvent;
import com.msaauth.common.outbox.OutboxEventPublisher;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.List;

/**
 * EventPublisher 포트 구현 = Outbox에 저장.
 * common-outbox의 OutboxEventPublisher를 감쌈.
 */
@Component
@RequiredArgsConstructor
public class OutboxEventPublisherAdapter implements EventPublisher {

    private final OutboxEventPublisher outboxEventPublisher;

    @Override
    public void publish(DomainEvent event) {
        outboxEventPublisher.publish(event);
    }

    @Override
    public void publishAll(List<DomainEvent> events) {
        events.forEach(outboxEventPublisher::publish);
    }
}
