package com.msaauth.auth.adapter.out.persistence.mapper;

import com.msaauth.auth.adapter.out.persistence.entity.AccountEntity;
import com.msaauth.auth.domain.model.Account;
import com.msaauth.auth.domain.model.AccountStatus;
import com.msaauth.auth.domain.model.Email;
import com.msaauth.auth.domain.model.HashedPassword;
import org.springframework.stereotype.Component;

/**
 * 도메인 <-> Entity 변환.
 */
@Component
public class AccountMapper {

    public AccountEntity toEntity(Account account) {
        return new AccountEntity(
                account.getId(),
                account.getEmail().value(),
                account.getPasswordHash() != null ? account.getPasswordHash().value() : null,
                account.getStatus().name(),
                account.isEmailVerified(),
                account.getLastLoginAt(),
                account.getCreatedAt(),
                account.getUpdatedAt()
        );
    }

    public Account toDomain(AccountEntity entity) {
        return Account.builder()
                .id(entity.getId())
                .email(new Email(entity.getEmail()))
                .passwordHash(entity.getPasswordHash() != null ? new HashedPassword(entity.getPasswordHash()) : null)
                .status(AccountStatus.valueOf(entity.getStatus()))
                .emailVerified(entity.isEmailVerified())
                .lastLoginAt(entity.getLastLoginAt())
                .createdAt(entity.getCreatedAt())
                .updatedAt(entity.getUpdatedAt())
                .build();
    }
}
