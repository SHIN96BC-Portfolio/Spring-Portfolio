# msa-auth Architecture

## 헥사고날 아키텍처 (Ports & Adapters)

```
┌─────────────────────────────────────────────────┐
│  Adapter (외부 세계)                             │
│                                                  │
│  ┌────────────┐              ┌──────────────┐  │
│  │  Web API   │              │  Persistence │  │
│  │(Controller)│              │  (JPA)       │  │
│  └─────┬──────┘              └──────▲───────┘  │
│        │                            │           │
│  ┌─────▼────────────────────────────┴───────┐  │
│  │  Application (유스케이스)                │  │
│  │                                          │  │
│  │  ┌────────────┐     ┌────────────────┐  │  │
│  │  │  Port In   │     │   Port Out     │  │  │
│  │  │(UseCase IF)│     │(Repository IF) │  │  │
│  │  └─────┬──────┘     └────────▲───────┘  │  │
│  │        │                     │          │  │
│  │  ┌─────▼─────────────────────┴──────┐   │  │
│  │  │      Service (구현)              │   │  │
│  │  └──────────────┬───────────────────┘   │  │
│  └─────────────────┼─────────────────────────┘  │
│                    │                             │
│  ┌─────────────────▼─────────────────────┐      │
│  │      Domain (순수)                    │      │
│  │  - Account, OAuthClient (모델)        │      │
│  │  - AccountRegistered (이벤트)         │      │
│  │  - 비즈니스 규칙                       │      │
│  └───────────────────────────────────────┘      │
└─────────────────────────────────────────────────┘
```

## 원칙

1. **도메인은 순수하다**: Spring, JPA, HTTP 아무것도 모름
2. **의존성은 안쪽으로**: Adapter → Application → Domain
3. **인터페이스로 격리**: Port를 통해서만 통신

## 폴더 매핑

| 폴더 | 역할 |
|------|------|
| `domain/model/` | Account, OAuthClient 등 순수 도메인 |
| `domain/event/` | AccountRegistered 등 도메인 이벤트 |
| `domain/exception/` | 도메인 예외 |
| `domain/service/` | 순수 도메인 서비스 (인터페이스) |
| `application/port/in/` | 유스케이스 인터페이스 |
| `application/port/out/` | 아웃바운드 인터페이스 (Repo, EventPublisher) |
| `application/service/` | 유스케이스 구현 |
| `adapter/in/web/` | REST 컨트롤러 |
| `adapter/out/persistence/` | JPA 어댑터 |
| `adapter/out/kafka/` | Kafka 이벤트 발행 |
| `adapter/out/external/` | 외부 API (카카오 OAuth 등) |
| `infrastructure/` | BCrypt, JWT 유틸 |
| `config/` | Spring 설정 |

## OAuth 2.0 Provider 컨셉

msa-auth는 OAuth 2.0 표준을 구현한 Identity Provider입니다.

### 지원 Flow (Tier 2)

- Authorization Code Flow (기본)
- Refresh Token Flow

### 엔드포인트

- `POST /api/auth/signup` - 회원가입 (자체)
- `POST /api/auth/login` - 로그인 (자체)
- `POST /api/auth/refresh` - 토큰 갱신
- `GET /oauth/authorize` - OAuth Authorization
- `POST /oauth/token` - OAuth Token 발급
- `GET /oauth/userinfo` - UserInfo
- `POST /internal/verify-token` - JWT 검증 (다른 서비스가 호출)
