package com.msaauth.auth.domain.event;

import com.msaauth.common.event.DomainEvent;

import java.util.UUID;

/**
 * 계정 이메일 인증 완료 이벤트.
 *
 * <p>AccountRegistered와 동일한 외부 이벤트 envelope를 사용하여
 * 소비자가 이벤트 종류와 무관하게 공통 메타데이터와 data를 같은 방식으로 처리할 수 있다.</p>
 */
public class AccountEmailVerified extends DomainEvent {

    private final UUID accountId;
    private final String email;

    public AccountEmailVerified(UUID accountId, String email) {
        super("AccountEmailVerified");
        this.accountId = accountId;
        this.email = email;
    }

    @Override
    public String partitionKey() { return accountId.toString(); }

    @Override
    public String aggregateType() { return "Account"; }

    @Override
    public String aggregateId() { return accountId.toString(); }

    @Override
    public Data eventData() {
        return new Data(accountId, email);
    }

    /**
     * AccountEmailVerified 이벤트의 도메인 payload.
     */
    public record Data(UUID accountId, String email) {
    }
}
