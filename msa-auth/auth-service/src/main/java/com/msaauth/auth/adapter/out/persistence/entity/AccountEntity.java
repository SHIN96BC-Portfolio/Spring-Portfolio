package com.msaauth.auth.adapter.out.persistence.entity;

import jakarta.persistence.*;
import lombok.AccessLevel;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.Instant;
import java.util.UUID;

/**
 * JPA 엔티티. 도메인 모델과는 별개.
 * Mapper를 통해 도메인 <-> Entity 변환.
 */
@Entity
@Table(name = "account")
@Getter
@NoArgsConstructor(access = AccessLevel.PROTECTED)
public class AccountEntity {

    @Id
    @Column(columnDefinition = "uuid")
    private UUID id;

    @Column(nullable = false, unique = true, length = 100)
    private String email;

    @Column(length = 255)
    private String passwordHash;

    @Column(nullable = false, length = 20)
    private String status;

    @Column(nullable = false)
    private boolean emailVerified;

    @Column
    private Instant lastLoginAt;

    @Column(nullable = false)
    private Instant createdAt;

    @Column(nullable = false)
    private Instant updatedAt;

    @Setter
    public static class Builder {
        // 사용 편의 위해 setter 활용
    }

    public AccountEntity(UUID id, String email, String passwordHash, String status,
                         boolean emailVerified, Instant lastLoginAt,
                         Instant createdAt, Instant updatedAt) {
        this.id = id;
        this.email = email;
        this.passwordHash = passwordHash;
        this.status = status;
        this.emailVerified = emailVerified;
        this.lastLoginAt = lastLoginAt;
        this.createdAt = createdAt;
        this.updatedAt = updatedAt;
    }

    public void update(String passwordHash, String status, boolean emailVerified, Instant lastLoginAt) {
        this.passwordHash = passwordHash;
        this.status = status;
        this.emailVerified = emailVerified;
        this.lastLoginAt = lastLoginAt;
        this.updatedAt = Instant.now();
    }
}
