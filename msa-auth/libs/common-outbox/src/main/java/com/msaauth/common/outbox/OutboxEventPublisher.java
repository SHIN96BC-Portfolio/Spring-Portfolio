package com.msaauth.common.outbox;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.msaauth.common.event.DomainEvent;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

/**
 * 도메인 이벤트를 Outbox에 저장.
 *
 * 도메인 트랜잭션과 같은 트랜잭션 안에서 호출해야 함 (REQUIRED).
 * outbox_events.id 는 DomainEvent.eventId 와 동일 (COMMON-02).
 */
@Slf4j
@Service
@RequiredArgsConstructor
public class OutboxEventPublisher {

    private final OutboxEventRepository repository;
    private final ObjectMapper objectMapper;

    @Transactional(propagation = Propagation.MANDATORY)
    public void publish(DomainEvent event) {
        try {
            String payload = objectMapper.writeValueAsString(event);
            OutboxEvent outbox = OutboxEvent.create(
                    UUID.fromString(event.getEventId()),
                    event.aggregateType(),
                    event.aggregateId(),
                    event.getEventType(),
                    event.getEventVersion(),
                    payload,
                    event.getTraceId()
            );
            repository.save(outbox);
            log.debug("Outbox event saved: {} ({})", event.getEventType(), event.getEventId());
        } catch (JsonProcessingException e) {
            throw new RuntimeException("Failed to serialize event: " + event.getEventType(), e);
        }
    }
}
