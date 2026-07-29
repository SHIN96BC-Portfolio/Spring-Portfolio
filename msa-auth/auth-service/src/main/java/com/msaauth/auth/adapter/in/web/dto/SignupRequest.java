package com.msaauth.auth.adapter.in.web.dto;

import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record SignupRequest(
        @NotBlank @Email
        String email,

        @NotBlank
        @Size(min = 8, max = 100, message = "Password must be 8-100 characters")
        String password
) {}
