# OAuth 2.0 Provider Guide

## 개요

msa-auth를 Identity Provider로 사용하는 방법 (Tier 2 구현 예정).

## 클라이언트 등록

관리자가 새 OAuth 클라이언트를 등록:

```bash
POST /admin/oauth/clients
Content-Type: application/json

{
  "name": "협력 서비스 X",
  "redirect_uris": ["https://client.example.com/callback"],
  "allowed_scopes": ["read:profile", "read:email"]
}

응답:
{
  "clientId": "abc-123-...",
  "clientSecret": "generated-secret-do-not-share"
}
```

## Authorization Code Flow

### 1. 사용자를 msa-auth로 리다이렉트

```
GET /oauth/authorize?
  response_type=code
  &client_id=abc-123-...
  &redirect_uri=https://client.example.com/callback
  &scope=read:profile
  &state=random-csrf-token
```

### 2. 사용자 로그인 후 코드 발급

msa-auth가 redirect_uri로 리다이렉트:
```
https://client.example.com/callback?code=AUTH_CODE&state=random-csrf-token
```

### 3. 클라이언트가 코드를 토큰으로 교환

```
POST /oauth/token
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code
&code=AUTH_CODE
&redirect_uri=https://client.example.com/callback
&client_id=abc-123-...
&client_secret=generated-secret

응답:
{
  "access_token": "eyJhbGciOi...",
  "refresh_token": "eyJhbGciOi...",
  "token_type": "Bearer",
  "expires_in": 3600
}
```

### 4. UserInfo 조회

```
GET /oauth/userinfo
Authorization: Bearer eyJhbGciOi...

응답:
{
  "sub": "account-uuid",
  "email": "user@example.com"
}
```

## msa-platform이 사용하는 방식

msa-platform이 msa-auth의 OAuth 클라이언트로 등록:

```
clientId: msa-platform
allowed_scopes: ["read:profile", "read:email", "write:profile"]
```

- msa-platform의 user-service가 신규 계정 정보 필요 시 UserInfo 호출
- edge-gateway가 토큰 검증 시 `/internal/verify-token` 호출

자세한 구현: Tier 2에서 진행.
