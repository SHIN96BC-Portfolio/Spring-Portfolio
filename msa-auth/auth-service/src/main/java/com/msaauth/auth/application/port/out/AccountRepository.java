package com.msaauth.auth.application.port.out;

import com.msaauth.auth.domain.model.Account;
import com.msaauth.auth.domain.model.Email;

import java.util.Optional;
import java.util.UUID;

/**
 * 도메인이 정의하는 저장소 인터페이스.
 * 실제 구현은 adapter/out/persistence에서.
 */
public interface AccountRepository {
    Account save(Account account);
    Optional<Account> findById(UUID id);
    Optional<Account> findByEmail(Email email);
    boolean existsByEmail(Email email);
}
