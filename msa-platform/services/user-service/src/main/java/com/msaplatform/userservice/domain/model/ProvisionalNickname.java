package com.msaplatform.userservice.domain.model;

import java.util.Locale;
import java.util.UUID;

/**
 * AccountRegistered 소비 시 쓰는 임시 닉네임 규칙 ([USER-01]).
 *
 * <p>auth 이벤트에는 nickname 이 없다. user-service 가 공개 프로필을 소유하므로
 * 여기서 충돌 없는 표시명을 만든다. DB CHECK
 * {@code nickname = 'u' || replace(account_id::text, '-', '')}
 * 와 동일한 식이어야 한다.</p>
 *
 * <p>사용자가 닉네임을 바꾸면 {@code nickname_customized=true} 로 두고
 * 이 규칙을 더 이상 적용하지 않는다.</p>
 */
public final class ProvisionalNickname {

    private ProvisionalNickname() {
    }

    /**
     * @return {@code u} + accountId 하이픈 제거 소문자 hex (33자)
     */
    public static String fromAccountId(UUID accountId) {
        if (accountId == null) {
            throw new IllegalArgumentException("accountId must not be null");
        }
        return "u" + accountId.toString().replace("-", "").toLowerCase(Locale.ROOT);
    }

    /** 주어진 닉네임이 해당 계정의 시스템 임시값인지 여부. */
    public static boolean matches(UUID accountId, String nickname) {
        return fromAccountId(accountId).equals(nickname);
    }
}
