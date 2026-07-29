package com.msaauth.common.outbox;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

/**
 * Outbox에 저장된 이벤트를 주기적으로 Kafka로 발행.
 * 
 * 매 1초마다 실행.
 * SKIP LOCKED로 다중 인스턴스 안전.
 */
@Slf4j
@Component
@RequiredArgsConstructor
public class OutboxPollingPublisher {

    private final OutboxEventRepository repository;
    private final KafkaTemplate<String, String> kafkaTemplate;

    @Value("${msa.outbox.batch-size:100}")
    private int batchSize;

    @Value("${msa.outbox.topic-prefix:}")
    private String topicPrefix;

    @Scheduled(fixedDelayString = "${msa.outbox.polling-interval:1000}")
    @Transactional
    public void publishPendingEvents() {
        List<OutboxEvent> events = repository.findUnpublishedWithLock(batchSize);
        if (events.isEmpty()) return;

        log.debug("Publishing {} outbox events", events.size());

        for (OutboxEvent evt : events) {
            String topic = topicFor(evt);
            try {
                // COMMON-02: Kafka record key = DomainEvent.eventId (= outbox row id)
                kafkaTemplate.send(topic, evt.getId().toString(), evt.getPayload()).get();
                evt.markPublished();
            } catch (Exception e) {
                log.error("Failed to publish event {} to topic {}", evt.getId(), topic, e);
                // 다음 폴링에서 재시도됨
            }
        }
    }

    /**
     * 이벤트 → 토픽 매핑.
     * aggregateType 기반으로 <domain>.events 토픽 결정.
     * 
     * 오버라이드하려면 이 클래스를 상속하거나, application.yml의 msa.outbox.topic-prefix 활용.
     */
    protected String topicFor(OutboxEvent event) {
        // Account → auth.events
        // OAuthClient → auth.events
        // 서비스별로 커스터마이즈 가능
        String prefix = topicPrefix.isEmpty() ? inferDomain(event.getAggregateType()) : topicPrefix;
        return prefix + ".events";
    }

    private String inferDomain(String aggregateType) {
        return switch (aggregateType) {
            case "Account", "OAuthClient", "OAuthAuthorization" -> "auth";
            case "UserProfile", "FollowRelation" -> "user";
            case "Order", "Product", "Cart", "Wishlist" -> "commerce";
            case "OOTD", "Brand" -> "fashion";
            case "Post", "Hashtag" -> "social";
            case "PointAccount" -> "point";
            default -> "unknown";
        };
    }
}
