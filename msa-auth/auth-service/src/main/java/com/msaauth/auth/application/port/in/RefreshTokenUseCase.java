package com.msaauth.auth.application.port.in;

public interface RefreshTokenUseCase {
    Result refresh(Command command);

    record Command(String refreshToken) {}
    record Result(String accessToken, String refreshToken, long expiresIn) {}
}
