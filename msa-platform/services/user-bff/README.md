# user-bff
사용자 클라이언트에 필요한 여러 도메인 데이터를 REST API로 조합하는 BFF입니다.

## 책임
- 사용자용 REST API 제공
- 여러 도메인 서비스의 응답 조합
- 홈 화면 구성 조회 시 `content-service` 데이터 활용

## 담당하지 않는 것 / 서비스 경계
- 관리자용 CMS와 GraphQL은 `admin-bff`가 담당합니다.
- 인증 원장과 토큰 발급은 별도 `msa-auth`가 담당합니다.
- 도메인 데이터의 소유와 비즈니스 규칙은 각 도메인 서비스가 담당합니다.

## 기술 정보
| 항목 | 값 |
|---|---|
| 포트 | `8081` |
| DB | 없음 |
| Gradle 모듈 경로 | `:services:user-bff` |

## 주요 연동 및 이벤트
- 설계 문서상 `content-service`를 조회해 사용자 홈 화면을 구성합니다.
- `msa-auth` 토큰 검증 URL 설정이 있습니다.
- 그 밖의 실제 HTTP 연동과 구체적인 발행·구독 이벤트는 미정입니다.

## 실행 방법
```bash
cd msa-platform
./gradlew :services:user-bff:bootRun
```

## 현재 구현 상태
현재는 **스켈레톤**입니다.
- 구현: 애플리케이션 부트스트랩, `/hello`, Actuator, 인증·Kafka 기본 설정
- 미구현: 사용자 REST API, 도메인 서비스 조합, `content-service` HTTP 조회
