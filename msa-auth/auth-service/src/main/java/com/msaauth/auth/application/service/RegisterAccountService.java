package com.msaauth.auth.application.service;

import com.msaauth.auth.application.port.in.RegisterAccountUseCase;
import com.msaauth.auth.application.port.out.AccountRepository;
import com.msaauth.auth.application.port.out.EventPublisher;
import com.msaauth.auth.domain.exception.EmailAlreadyExistsException;
import com.msaauth.auth.domain.model.Account;
import com.msaauth.auth.domain.model.Email;
import com.msaauth.auth.domain.model.HashedPassword;
import com.msaauth.auth.domain.model.RegistrationSource;
import com.msaauth.auth.domain.service.PasswordHasher;
import com.msaauth.common.event.DomainEvent;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;

@Service
@RequiredArgsConstructor
public class RegisterAccountService implements RegisterAccountUseCase {

    private final AccountRepository accountRepository;
    private final PasswordHasher passwordHasher;
    private final EventPublisher eventPublisher;

    @Override
    @Transactional
    public Result register(Command command) {
        Email email = new Email(command.email());

        // 도메인 규칙: 이메일 중복 방지
        if (accountRepository.existsByEmail(email)) {
            throw new EmailAlreadyExistsException(command.email());
        }

        // 비밀번호 해시
        HashedPassword hashed = passwordHasher.hash(command.password());

        // 도메인 모델로 계정 생성
        Account account = Account.register(email, hashed, RegistrationSource.EMAIL);

        // 저장
        Account saved = accountRepository.save(account);

        // 도메인 이벤트 발행 (Outbox)
        eventPublisher.publishAll(saved.pullDomainEvents().stream()
                .map(e -> (DomainEvent) e)
                .toList());

        return new Result(saved.getId(), saved.getEmail().value());
    }
}
