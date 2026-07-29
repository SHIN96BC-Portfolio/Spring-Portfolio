package com.msaauth.auth.domain.model;

import java.util.Locale;
import java.util.regex.Pattern;

/**
 * 이메일 값 객체.
 *
 * <p>[AUTH-02] 생성 시점에 항상 소문자로 정규화한다.
 * User@x.com 과 user@x.com 이 서로 다른 계정으로 만들어지는 것을 막기 위한
 * 1차 방어선이며, DB 의 {@code UNIQUE INDEX ON LOWER(email)} 이 2차 방어선이다.
 * 정규화가 생성자 안에 있으므로 이 타입을 거치는 모든 경로(가입/로그인/조회)가
 * 자동으로 같은 표기를 사용한다.</p>
 */
public record Email(String value) {
    private static final Pattern PATTERN = Pattern.compile(
            "^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$"
    );

    public Email {
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException("Email must not be blank");
        }
        // 검증보다 먼저 정규화 — 이후 로직/저장 전부 소문자 기준
        value = value.strip().toLowerCase(Locale.ROOT);
        if (!PATTERN.matcher(value).matches()) {
            throw new IllegalArgumentException("Invalid email format: " + value);
        }
        if (value.length() > 100) {
            throw new IllegalArgumentException("Email too long (max 100)");
        }
    }
}
