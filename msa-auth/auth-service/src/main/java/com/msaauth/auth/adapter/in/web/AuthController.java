package com.msaauth.auth.adapter.in.web;

import com.msaauth.auth.adapter.in.web.dto.LoginRequest;
import com.msaauth.auth.adapter.in.web.dto.LoginResponse;
import com.msaauth.auth.adapter.in.web.dto.SignupRequest;
import com.msaauth.auth.adapter.in.web.dto.SignupResponse;
import com.msaauth.auth.application.port.in.LoginUseCase;
import com.msaauth.auth.application.port.in.RegisterAccountUseCase;
import com.msaauth.common.web.ApiResponse;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/api/auth")
@RequiredArgsConstructor
public class AuthController {

    private final RegisterAccountUseCase registerAccountUseCase;
    private final LoginUseCase loginUseCase;

    @PostMapping("/signup")
    public ResponseEntity<ApiResponse<SignupResponse>> signup(@Valid @RequestBody SignupRequest req) {
        var result = registerAccountUseCase.register(
                new RegisterAccountUseCase.Command(req.email(), req.password())
        );
        return ResponseEntity
                .status(HttpStatus.CREATED)
                .body(ApiResponse.ok(new SignupResponse(result.accountId(), result.email())));
    }

    @PostMapping("/login")
    public ResponseEntity<ApiResponse<LoginResponse>> login(
            @Valid @RequestBody LoginRequest req,
            HttpServletRequest httpRequest
    ) {
        var result = loginUseCase.login(new LoginUseCase.Command(
                req.email(),
                req.password(),
                httpRequest.getHeader("User-Agent"),
                httpRequest.getRemoteAddr()
        ));
        return ResponseEntity.ok(ApiResponse.ok(new LoginResponse(
                result.accountId(),
                result.accessToken(),
                result.refreshToken(),
                result.expiresIn()
        )));
    }
}
