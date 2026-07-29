package com.msaauth.auth.adapter.out.persistence;

import com.msaauth.auth.adapter.out.persistence.entity.RefreshTokenEntity;
import com.msaauth.auth.adapter.out.persistence.repository.RefreshTokenJpaRepository;
import com.msaauth.auth.application.port.out.RefreshTokenRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

/**
 * RefreshTokenRepository JPA 구현.
 * 로그인 시 저장·조회·폐기를 담당한다. rotation(replaced_by)은 refresh 유스케이스 추가 시 확장.
 */
@Component
@RequiredArgsConstructor
public class RefreshTokenPersistenceAdapter implements RefreshTokenRepository {

    private final RefreshTokenJpaRepository jpaRepository;

    @Override
    public void save(UUID accountId, String tokenHash, String deviceInfo, String ipAddress, Instant expiresAt) {
        RefreshTokenEntity entity = new RefreshTokenEntity(
                accountId,
                tokenHash,
                UUID.randomUUID(),
                deviceInfo,
                ipAddress,
                expiresAt,
                Instant.now()
        );
        jpaRepository.save(entity);
    }

    @Override
    public Optional<StoredToken> findByTokenHash(String tokenHash) {
        return jpaRepository.findByTokenHash(tokenHash).map(this::toStored);
    }

    @Override
    @Transactional
    public void revoke(String tokenHash, String reason) {
        jpaRepository.findByTokenHash(tokenHash).ifPresent(entity -> {
            if (entity.getRevokedAt() == null) {
                entity.revoke(reason, Instant.now());
            }
        });
    }

    @Override
    @Transactional
    public void revokeFamily(UUID familyId, String reason) {
        Instant now = Instant.now();
        for (RefreshTokenEntity entity : jpaRepository.findByFamilyId(familyId)) {
            if (entity.getRevokedAt() == null) {
                entity.revoke(reason, now);
            }
        }
    }

    private StoredToken toStored(RefreshTokenEntity entity) {
        return new StoredToken(
                entity.getId(),
                entity.getAccountId(),
                entity.getTokenHash(),
                entity.getFamilyId(),
                entity.getReplacedBy(),
                entity.getExpiresAt(),
                entity.getRevokedAt()
        );
    }
}
