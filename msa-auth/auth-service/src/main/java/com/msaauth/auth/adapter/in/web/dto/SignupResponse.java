package com.msaauth.auth.adapter.in.web.dto;

import java.util.UUID;

public record SignupResponse(UUID accountId, String email) {}
