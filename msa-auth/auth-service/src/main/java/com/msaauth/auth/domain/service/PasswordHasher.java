package com.msaauth.auth.domain.service;

import com.msaauth.auth.domain.model.HashedPassword;

/**
 * 비밀번호 해시 인터페이스.
 * 도메인이 정의하고, 인프라(BCrypt 등)가 구현.
 */
public interface PasswordHasher {
    HashedPassword hash(String rawPassword);
    boolean matches(String rawPassword, HashedPassword hashed);
}
