package com.msaauth.auth.adapter.out.persistence;

import com.msaauth.auth.adapter.out.persistence.entity.AccountEntity;
import com.msaauth.auth.adapter.out.persistence.mapper.AccountMapper;
import com.msaauth.auth.adapter.out.persistence.repository.AccountJpaRepository;
import com.msaauth.auth.application.port.out.AccountRepository;
import com.msaauth.auth.domain.model.Account;
import com.msaauth.auth.domain.model.Email;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.Optional;
import java.util.UUID;

/**
 * AccountRepository 인터페이스 구현 (아웃바운드 어댑터).
 */
@Component
@RequiredArgsConstructor
public class AccountPersistenceAdapter implements AccountRepository {

    private final AccountJpaRepository jpaRepository;
    private final AccountMapper mapper;

    @Override
    public Account save(Account account) {
        AccountEntity entity = jpaRepository.findById(account.getId())
                .orElseGet(() -> mapper.toEntity(account));

        if (entity.getId() != null && jpaRepository.existsById(entity.getId())) {
            entity.update(
                    account.getPasswordHash() != null ? account.getPasswordHash().value() : null,
                    account.getStatus().name(),
                    account.isEmailVerified(),
                    account.getLastLoginAt()
            );
        } else {
            entity = mapper.toEntity(account);
        }
        return mapper.toDomain(jpaRepository.save(entity));
    }

    @Override
    public Optional<Account> findById(UUID id) {
        return jpaRepository.findById(id).map(mapper::toDomain);
    }

    @Override
    public Optional<Account> findByEmail(Email email) {
        return jpaRepository.findByEmail(email.value()).map(mapper::toDomain);
    }

    @Override
    public boolean existsByEmail(Email email) {
        return jpaRepository.existsByEmail(email.value());
    }
}
