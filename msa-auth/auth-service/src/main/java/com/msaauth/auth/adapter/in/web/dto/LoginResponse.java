package com.msaauth.auth.adapter.in.web.dto;

import java.util.UUID;

public record LoginResponse(
        UUID accountId,
        String accessToken,
        String refreshToken,
        long expiresIn
) {}
