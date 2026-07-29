package com.msaauth.auth.domain.event;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class AccountRegisteredSerializationTest {

    private final ObjectMapper objectMapper = new ObjectMapper()
            .registerModule(new JavaTimeModule());

    @Test
    void serializesCommonMetadataAndDomainDataAsEnvelope() throws Exception {
        // Given: auth-service가 발행할 계정 등록 도메인 이벤트
        UUID accountId = UUID.randomUUID();
        AccountRegistered event =
                new AccountRegistered(accountId, "user@example.com", "EMAIL");

        // When: OutboxEventPublisher와 동일하게 Jackson으로 직렬화
        JsonNode json = objectMapper.readTree(objectMapper.writeValueAsString(event));

        // Then: 이벤트 추적/버저닝에 필요한 공통 메타데이터는 최상위에 존재
        assertThat(json.path("eventId").asText()).isNotBlank();
        assertThat(json.path("eventType").asText()).isEqualTo("AccountRegistered");
        assertThat(json.path("eventVersion").asInt()).isEqualTo(1);
        assertThat(json.path("occurredAt").asText()).isNotBlank();
        assertThat(json.path("traceId").asText()).isNotBlank();

        // 도메인 필드는 최상위로 새어 나오지 않아야 소비 DTO/JSON Schema와 계약이 유지된다.
        assertThat(json.has("accountId")).isFalse();
        assertThat(json.has("email")).isFalse();
        assertThat(json.has("registeredVia")).isFalse();

        // 도메인 payload는 data envelope 아래에서만 제공
        JsonNode data = json.path("data");
        assertThat(data.path("accountId").asText()).isEqualTo(accountId.toString());
        assertThat(data.path("email").asText()).isEqualTo("user@example.com");
        assertThat(data.path("registeredVia").asText()).isEqualTo("EMAIL");
    }
}
