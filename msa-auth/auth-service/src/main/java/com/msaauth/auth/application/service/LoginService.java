package com.msaauth.auth.application.service;

import com.msaauth.auth.application.port.in.LoginUseCase;
import com.msaauth.auth.application.port.out.AccountRepository;
import com.msaauth.auth.application.port.out.RefreshTokenRepository;
import com.msaauth.auth.domain.exception.AccountNotFoundException;
import com.msaauth.auth.domain.exception.InvalidCredentialsException;
import com.msaauth.auth.domain.model.Account;
import com.msaauth.auth.domain.model.Email;
import com.msaauth.auth.domain.service.PasswordHasher;
import com.msaauth.auth.domain.service.TokenGenerator;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.security.MessageDigest;
import java.time.Instant;

@Slf4j
@Service
@RequiredArgsConstructor
public class LoginService implements LoginUseCase {

    private final AccountRepository accountRepository;
    private final RefreshTokenRepository refreshTokenRepository;
    private final PasswordHasher passwordHasher;
    private final TokenGenerator tokenGenerator;

    @Override
    @Transactional
    public Result login(Command command) {
        Email email = new Email(command.email());

        Account account = accountRepository.findByEmail(email)
                .orElseThrow(() -> new AccountNotFoundException("Account not found: " + command.email()));

        if (!account.canLogin()) {
            throw new InvalidCredentialsException("Account is not active");
        }

        // 도메인이 비밀번호 검증
        account.verifyPassword(command.password(), passwordHasher);
        account.markLoggedIn();
        accountRepository.save(account);

        // 토큰 발급
        TokenGenerator.AccessTokenPair tokens = tokenGenerator.generateTokens(
                account.getId(),
                account.getEmail().value()
        );

        // 리프레시 토큰 저장 (해시로)
        String refreshHash = hash(tokens.refreshToken());
        refreshTokenRepository.save(
                account.getId(),
                refreshHash,
                command.deviceInfo(),
                command.ipAddress(),
                Instant.now().plusSeconds(60L * 60 * 24 * 30)  // 30일
        );

        return new Result(
                account.getId(),
                tokens.accessToken(),
                tokens.refreshToken(),
                tokens.accessExpiresInSeconds()
        );
    }

    private String hash(String token) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] bytes = md.digest(token.getBytes());
            StringBuilder sb = new StringBuilder();
            for (byte b : bytes) sb.append(String.format("%02x", b));
            return sb.toString();
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }
}
