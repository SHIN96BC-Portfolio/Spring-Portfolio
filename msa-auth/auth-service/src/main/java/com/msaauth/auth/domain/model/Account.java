package com.msaauth.auth.domain.model;

import com.msaauth.auth.domain.event.AccountEmailVerified;
import com.msaauth.auth.domain.event.AccountRegistered;
import com.msaauth.auth.domain.event.AccountSuspended;
import com.msaauth.auth.domain.exception.InvalidCredentialsException;
import com.msaauth.auth.domain.service.PasswordHasher;
import lombok.Builder;
import lombok.Getter;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/**
 * 순수 도메인 모델. Spring/JPA 아무것도 모름.
 *
 * <p>비즈니스 규칙 ([AUTH-04]):
 * <ul>
 *   <li>로그인은 {@code status=ACTIVE} 이고 {@code emailVerified=true} 여야 한다.
 *       미인증 ACTIVE 계정은 가입 직후 상태이며 로그인 불가.</li>
 *   <li>정지({@link #suspend}) / 이메일 인증({@link #verifyEmail}) 은
 *       각각 {@code AccountSuspended} / {@code AccountEmailVerified} 를 발행해
 *       user·point 등 소비자가 로컬 상태를 맞추게 한다.</li>
 *   <li>비밀번호 없는 계정 = OAuth-only 유저 (OAuth 가입 시 emailVerified=true).</li>
 * </ul></p>
 */
@Getter
public class Account {

    private final UUID id;
    private final Email email;
    private HashedPassword passwordHash;   // nullable (OAuth-only)
    private AccountStatus status;
    private boolean emailVerified;
    private Instant lastLoginAt;
    private final Instant createdAt;
    private Instant updatedAt;

    // 발생한 도메인 이벤트 (Aggregate에서 수집)
    private final transient List<Object> domainEvents = new ArrayList<>();

    @Builder
    private Account(UUID id, Email email, HashedPassword passwordHash,
                    AccountStatus status, boolean emailVerified,
                    Instant lastLoginAt, Instant createdAt, Instant updatedAt) {
        this.id = id;
        this.email = email;
        this.passwordHash = passwordHash;
        this.status = status;
        this.emailVerified = emailVerified;
        this.lastLoginAt = lastLoginAt;
        this.createdAt = createdAt;
        this.updatedAt = updatedAt;
    }

    /**
     * 새 계정 생성 (이메일 회원가입).
     */
    public static Account register(Email email, HashedPassword passwordHash, RegistrationSource source) {
        Instant now = Instant.now();
        Account account = Account.builder()
                .id(UUID.randomUUID())
                .email(email)
                .passwordHash(passwordHash)
                .status(AccountStatus.ACTIVE)
                .emailVerified(false)
                .createdAt(now)
                .updatedAt(now)
                .build();
        account.domainEvents.add(new AccountRegistered(
                account.id,
                account.email.value(),
                source.name()
        ));
        return account;
    }

    /**
     * OAuth-only 계정 생성 (카카오 로그인 등).
     */
    public static Account registerViaOAuth(Email email, RegistrationSource source) {
        Instant now = Instant.now();
        Account account = Account.builder()
                .id(UUID.randomUUID())
                .email(email)
                .passwordHash(null)
                .status(AccountStatus.ACTIVE)
                .emailVerified(true)  // OAuth로 검증됨
                .createdAt(now)
                .updatedAt(now)
                .build();
        account.domainEvents.add(new AccountRegistered(
                account.id,
                account.email.value(),
                source.name()
        ));
        // OAuth 는 가입 시점에 이미 인증됨 → 소비자가 emailVerified 를 맞출 수 있게 발행
        account.domainEvents.add(new AccountEmailVerified(
                account.id,
                account.email.value()
        ));
        return account;
    }

    /**
     * 로그인 시 비밀번호 검증.
     */
    public void verifyPassword(String rawPassword, PasswordHasher hasher) {
        if (passwordHash == null) {
            throw new InvalidCredentialsException("This account uses OAuth login");
        }
        if (!hasher.matches(rawPassword, passwordHash)) {
            throw new InvalidCredentialsException("Invalid password");
        }
    }

    public void markLoggedIn() {
        this.lastLoginAt = Instant.now();
        this.updatedAt = Instant.now();
    }

    /**
     * 이메일 인증 완료. 이미 인증된 경우 no-op (이벤트 재발행 없음).
     */
    public void verifyEmail() {
        if (this.emailVerified) {
            return;
        }
        this.emailVerified = true;
        this.updatedAt = Instant.now();
        this.domainEvents.add(new AccountEmailVerified(this.id, this.email.value()));
    }

    /**
     * 계정 정지. 이미 정지된 경우 no-op.
     *
     * @param reason 정지 사유 코드 (ADMIN, ABUSE 등). 이벤트 payload 로 전달
     */
    public void suspend(String reason) {
        if (this.status == AccountStatus.SUSPENDED) {
            return;
        }
        this.status = AccountStatus.SUSPENDED;
        this.updatedAt = Instant.now();
        this.domainEvents.add(new AccountSuspended(this.id, reason));
    }

    /**
     * 로그인 가능 여부.
     * ACTIVE 이면서 이메일 인증이 끝난 계정만 허용한다 ([AUTH-04]).
     */
    public boolean canLogin() {
        return status == AccountStatus.ACTIVE && emailVerified;
    }

    public List<Object> pullDomainEvents() {
        List<Object> events = new ArrayList<>(domainEvents);
        domainEvents.clear();
        return events;
    }
}
