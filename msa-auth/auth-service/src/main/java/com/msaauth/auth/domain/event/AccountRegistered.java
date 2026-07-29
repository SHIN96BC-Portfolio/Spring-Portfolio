package com.msaauth.auth.domain.event;

import com.msaauth.common.event.DomainEvent;

import java.util.UUID;

/**
 * 계정 등록 완료 이벤트.
 *
 * <p>개별 필드의 getter를 노출하지 않고 {@link #eventData()}로 묶는 이유는
 * 최상위에 accountId/email이 직렬화되는 것을 방지하고, 외부 계약의
 * {@code data} envelope 구조를 유지하기 위함이다.</p>
 */
public class AccountRegistered extends DomainEvent {

    private final UUID accountId;
    private final String email;
    private final String registeredVia;   // EMAIL, KAKAO, GOOGLE

    public AccountRegistered(UUID accountId, String email, String registeredVia) {
        super("AccountRegistered");
        this.accountId = accountId;
        this.email = email;
        this.registeredVia = registeredVia;
    }

    @Override
    public String partitionKey() {
        return accountId.toString();
    }

    @Override
    public String aggregateType() {
        return "Account";
    }

    @Override
    public String aggregateId() {
        return accountId.toString();
    }

    @Override
    public Data eventData() {
        return new Data(accountId, email, registeredVia);
    }

    /**
     * AccountRegistered 이벤트의 도메인 payload.
     * 공통 메타데이터는 {@link DomainEvent}가 최상위에 직렬화한다.
     */
    public record Data(
            UUID accountId,
            String email,
            String registeredVia
    ) {
    }
}
