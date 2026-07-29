package com.msaauth.auth.domain.model;

/**
 * 해시된 비밀번호 값 객체.
 * 원본 비밀번호는 절대 저장 안 함.
 */
public record HashedPassword(String value) {
    public HashedPassword {
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException("Password hash must not be blank");
        }
    }
}
