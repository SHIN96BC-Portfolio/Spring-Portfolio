package com.msaauth.auth.application.port.in;

import java.util.UUID;

public interface LoginUseCase {
    Result login(Command command);

    record Command(String email, String password, String deviceInfo, String ipAddress) {}
    record Result(UUID accountId, String accessToken, String refreshToken, long expiresIn) {}
}
