# common-auth-client

msa-auth가 발급한 HMAC JWT를 서비스 내부에서 로컬 검증합니다.

## 제공 기능과 API

- `AuthTokenVerifier`: `${msa.auth.jwt-secret}`로 검증 키를 구성합니다.
- `verify(token)`: 서명·만료를 검증한 뒤 `VerifiedToken(accountId, email, expiresAt)`을 반환합니다.

## 사용

```kotlin
implementation(project(":libs:common-auth-client"))
```

설정 예:

```yaml
msa:
  auth:
    jwt-secret: ${JWT_SECRET}
```

## 의존 관계

Spring Web과 JJWT 0.12.3에 의존하며 다른 사내 라이브러리에는 의존하지 않습니다.

## 주의사항과 한계

- auth-service의 현재 설정 키는 `msa.jwt.secret`인 반면 이 라이브러리는 `msa.auth.jwt-secret`을 읽습니다. 같은 비밀 값을 별도로 매핑해야 합니다.
- 대칭키 공유 방식만 구현되어 있습니다. 원격 `/internal/verify-token` 검증과 JWKS/비대칭키 검증은 주석에만 언급되어 있고 구현되지 않았습니다.
- 토큰의 `typ`, issuer, audience는 검사하지 않으며 검증 실패 예외를 애플리케이션 예외로 변환하지 않습니다.
- `@Component` 스캔 범위에 이 패키지가 포함되어야 bean이 등록됩니다.
