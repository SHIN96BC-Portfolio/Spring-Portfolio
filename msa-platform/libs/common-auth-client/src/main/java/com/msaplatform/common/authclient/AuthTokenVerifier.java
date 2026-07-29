package com.msaplatform.common.authclient;

import io.jsonwebtoken.Claims;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import javax.crypto.SecretKey;
import java.util.UUID;

/**
 * msa-auth가 발급한 JWT 토큰을 검증하는 클라이언트 라이브러리.
 * 
 * Tier 1: 대칭키 공유 방식 (심플)
 * Tier 2: msa-auth의 /internal/verify-token 호출 또는 JWKS 활용
 */
@Component
public class AuthTokenVerifier {

    private final SecretKey key;

    public AuthTokenVerifier(@Value("${msa.auth.jwt-secret}") String secret) {
        this.key = Keys.hmacShaKeyFor(secret.getBytes());
    }

    public VerifiedToken verify(String token) {
        Claims claims = Jwts.parser()
                .verifyWith(key)
                .build()
                .parseSignedClaims(token)
                .getPayload();

        return new VerifiedToken(
                UUID.fromString(claims.getSubject()),
                (String) claims.get("email"),
                claims.getExpiration().toInstant()
        );
    }

    public record VerifiedToken(UUID accountId, String email, java.time.Instant expiresAt) {}
}
