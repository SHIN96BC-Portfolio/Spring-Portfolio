package com.msaauth.auth.domain.model;

import com.msaauth.auth.domain.event.AccountEmailVerified;
import com.msaauth.auth.domain.event.AccountRegistered;
import com.msaauth.auth.domain.event.AccountSuspended;
import com.msaauth.auth.domain.service.PasswordHasher;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * [AUTH-04] 로그인 정책과 상태 전파 이벤트 발행 계약.
 */
class AccountAuth04PolicyTest {

    private static final PasswordHasher NOOP_HASHER = new PasswordHasher() {
        @Override
        public HashedPassword hash(String raw) {
            return new HashedPassword(raw);
        }

        @Override
        public boolean matches(String raw, HashedPassword hashed) {
            return raw.equals(hashed.value());
        }
    };

    @Test
    void emailSignup_cannotLoginUntilVerified() {
        // Given: 이메일 가입 (미인증)
        Account account = Account.register(
                new Email("user@example.com"),
                NOOP_HASHER.hash("password1"),
                RegistrationSource.EMAIL
        );

        // Then: ACTIVE 이지만 미인증 → 로그인 불가
        assertFalse(account.canLogin());
        assertEquals(1, account.pullDomainEvents().size()); // AccountRegistered only
    }

    @Test
    void verifyEmail_emitsEvent_andAllowsLogin() {
        Account account = Account.register(
                new Email("user@example.com"),
                NOOP_HASHER.hash("password1"),
                RegistrationSource.EMAIL
        );
        account.pullDomainEvents(); // clear register event

        // When
        account.verifyEmail();

        // Then
        assertTrue(account.canLogin());
        var events = account.pullDomainEvents();
        assertEquals(1, events.size());
        assertInstanceOf(AccountEmailVerified.class, events.getFirst());

        // 재호출은 no-op
        account.verifyEmail();
        assertTrue(account.pullDomainEvents().isEmpty());
    }

    @Test
    void suspend_emitsEvent_andBlocksLogin() {
        Account account = Account.registerViaOAuth(
                new Email("oauth@example.com"),
                RegistrationSource.KAKAO
        );
        account.pullDomainEvents();
        assertTrue(account.canLogin());

        // When
        account.suspend("ABUSE");

        // Then
        assertFalse(account.canLogin());
        var events = account.pullDomainEvents();
        assertEquals(1, events.size());
        AccountSuspended suspended = assertInstanceOf(AccountSuspended.class, events.getFirst());
        assertEquals("ABUSE", suspended.eventData().reason());

        // 재정지 no-op
        account.suspend("ADMIN");
        assertTrue(account.pullDomainEvents().isEmpty());
    }

    @Test
    void oauthRegister_emitsRegisteredAndVerified() {
        Account account = Account.registerViaOAuth(
                new Email("oauth@example.com"),
                RegistrationSource.KAKAO
        );

        assertTrue(account.canLogin());
        var events = account.pullDomainEvents();
        assertEquals(2, events.size());
        assertInstanceOf(AccountRegistered.class, events.get(0));
        assertInstanceOf(AccountEmailVerified.class, events.get(1));
    }
}
