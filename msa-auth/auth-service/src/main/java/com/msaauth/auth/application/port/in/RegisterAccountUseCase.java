package com.msaauth.auth.application.port.in;

import java.util.UUID;

public interface RegisterAccountUseCase {
    Result register(Command command);

    record Command(String email, String password) {}
    record Result(UUID accountId, String email) {}
}
