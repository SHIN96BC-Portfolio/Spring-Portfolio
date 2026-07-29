package com.msaauth.auth.infrastructure;

import com.msaauth.auth.domain.service.TokenGenerator;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import javax.crypto.SecretKey;
import java.time.Instant;
import java.util.Date;
import java.util.UUID;

/**
 * JWT 토큰 생성 구현 (인프라).
 */
@Component
public class JwtTokenGenerator implements TokenGenerator {

    private final SecretKey key;
    private final long accessExpirySeconds;
    private final long refreshExpirySeconds;

    public JwtTokenGenerator(
            @Value("${msa.jwt.secret}") String secret,
            @Value("${msa.jwt.access-expiry-seconds:3600}") long accessExpirySeconds,
            @Value("${msa.jwt.refresh-expiry-seconds:2592000}") long refreshExpirySeconds  // 30 days
    ) {
        this.key = Keys.hmacShaKeyFor(secret.getBytes());
        this.accessExpirySeconds = accessExpirySeconds;
        this.refreshExpirySeconds = refreshExpirySeconds;
    }

    @Override
    public AccessTokenPair generateTokens(UUID accountId, String email) {
        Instant now = Instant.now();

        String access = Jwts.builder()
                .subject(accountId.toString())
                .claim("email", email)
                .claim("typ", "access")
                .issuedAt(Date.from(now))
                .expiration(Date.from(now.plusSeconds(accessExpirySeconds)))
                .signWith(key)
                .compact();

        String refresh = Jwts.builder()
                .subject(accountId.toString())
                .claim("typ", "refresh")
                .issuedAt(Date.from(now))
                .expiration(Date.from(now.plusSeconds(refreshExpirySeconds)))
                .signWith(key)
                .compact();

        return new AccessTokenPair(access, refresh, accessExpirySeconds);
    }
}
