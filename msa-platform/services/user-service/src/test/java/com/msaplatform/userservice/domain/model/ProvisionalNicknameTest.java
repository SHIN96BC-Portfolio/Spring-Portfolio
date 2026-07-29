package com.msaplatform.userservice.domain.model;

import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * [USER-01] DB CHECK 식과 Java 파생 규칙이 일치하는지 검증.
 */
class ProvisionalNicknameTest {

    @Test
    void fromAccountId_stripsHyphens_andPrefixesU() {
        UUID id = UUID.fromString("A1B2C3D4-E5F6-7890-ABCD-EF1234567890");

        String nickname = ProvisionalNickname.fromAccountId(id);

        assertEquals("ua1b2c3d4e5f67890abcdef1234567890", nickname);
        assertEquals(33, nickname.length());
        assertTrue(ProvisionalNickname.matches(id, nickname));
    }

    @Test
    void differentAccounts_neverCollide() {
        String a = ProvisionalNickname.fromAccountId(UUID.randomUUID());
        String b = ProvisionalNickname.fromAccountId(UUID.randomUUID());
        assertFalse(a.equals(b));
    }

    @Test
    void nullAccountId_rejected() {
        assertThrows(IllegalArgumentException.class, () -> ProvisionalNickname.fromAccountId(null));
    }
}
