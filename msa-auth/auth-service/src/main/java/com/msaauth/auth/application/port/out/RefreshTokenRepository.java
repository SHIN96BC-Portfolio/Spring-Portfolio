package com.msaauth.auth.application.port.out;

import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

/**
 * refresh_token 저장소 포트.
 *
 * <p>[AUTH-03] Refresh Token Rotation 을 전제로 한다.
 * <ul>
 *   <li>최초 로그인 시 저장되는 토큰은 새 family 를 시작한다
 *       (DB 가 {@code family_id DEFAULT gen_random_uuid()} 로 자동 생성).</li>
 *   <li>refresh 시에는 기존 토큰을 ROTATED 로 폐기하고 같은 family 로
 *       새 토큰을 저장한 뒤 {@code replaced_by} 를 연결한다.</li>
 *   <li>{@code replacedBy != null} 인 토큰이 다시 제시되면 탈취 재사용이므로
 *       {@link #revokeFamily} 로 family 전체를 폐기해야 한다.</li>
 * </ul></p>
 */
public interface RefreshTokenRepository {
    void save(UUID accountId, String tokenHash, String deviceInfo, String ipAddress, Instant expiresAt);
    Optional<StoredToken> findByTokenHash(String tokenHash);
    void revoke(String tokenHash, String reason);

    /** 재사용 탐지 시 같은 로그인 계열의 토큰을 일괄 폐기한다. */
    void revokeFamily(UUID familyId, String reason);

    /**
     * @param revokedAt  NULL 이면 유효한 토큰
     * @param replacedBy 이 토큰을 대체한 토큰 id. 값이 있는데 다시 사용되면 재사용 공격
     */
    record StoredToken(
            Long id,
            UUID accountId,
            String tokenHash,
            UUID familyId,
            Long replacedBy,
            Instant expiresAt,
            Instant revokedAt
    ) {}
}
