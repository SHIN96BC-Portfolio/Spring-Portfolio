package com.msaauth.auth.domain.event;

import com.msaauth.common.event.DomainEvent;

import java.util.UUID;

/**
 * 계정 정지 이벤트.
 *
 * <p>[AUTH-04] auth 가 계정을 정지하면 user/point 등 소비자가 로컬 상태를
 * {@code SUSPENDED} 로 맞춰 활동을 막아야 한다. DB-per-service 이므로 FK 로
 * 상태를 공유할 수 없고, 이 이벤트가 유일한 동기화 수단이다.</p>
 *
 * <p>envelope 는 {@link AccountRegistered} 와 동일하다 ({@code data} 안 payload).</p>
 */
public class AccountSuspended extends DomainEvent {

    private final UUID accountId;
    private final String reason;

    public AccountSuspended(UUID accountId, String reason) {
        super("AccountSuspended");
        this.accountId = accountId;
        this.reason = reason;
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
        return new Data(accountId, reason);
    }

    /**
     * @param reason 정지 사유 코드/설명. 예: ADMIN, ABUSE, CHARGEBACK. null 허용.
     */
    public record Data(UUID accountId, String reason) {
    }
}
