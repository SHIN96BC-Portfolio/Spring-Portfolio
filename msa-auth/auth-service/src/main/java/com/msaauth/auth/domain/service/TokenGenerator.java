package com.msaauth.auth.domain.service;

import java.util.UUID;

/**
 * JWT 토큰 생성 인터페이스.
 */
public interface TokenGenerator {
    AccessTokenPair generateTokens(UUID accountId, String email);
    
    record AccessTokenPair(String accessToken, String refreshToken, long accessExpiresInSeconds) {}
}
