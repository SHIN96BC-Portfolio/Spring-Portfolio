# admin-bff
관리자 화면을 위해 도메인 서비스를 조합하는 GraphQL BFF입니다.

## 책임
- 관리자용 GraphQL API 제공: `/graphql`
- 로컬 GraphiQL 제공: `/graphiql`
- CMS 관리용 GraphQL 스키마와 조회·변경 진입점 제공

## 담당하지 않는 것 / 서비스 경계
- 사용자 클라이언트용 REST API와 화면 응답 조합은 `user-bff`가 담당합니다.
- CMS 데이터와 규칙의 소유자는 `content-service`입니다.
- 인증 원장과 토큰 발급은 별도 `msa-auth`가 담당합니다.

## 기술 정보
| 항목 | 값 |
|---|---|
| 포트 | `8082` |
| DB | 없음 |
| Gradle 모듈 경로 | `:services:admin-bff` |

## 주요 연동 및 이벤트
- `content-service` HTTP 연동이 예정되어 있으나 아직 연결되지 않았습니다.
- CMS GraphQL 스키마와 컨트롤러는 스텁입니다. 조회는 빈 목록을 반환하고 변경은 미지원 예외를 발생시킵니다.
- Kafka 설정은 있으나 구체적인 발행·구독 이벤트는 미정입니다.

## 실행 방법
```bash
cd msa-platform
./gradlew :services:admin-bff:bootRun
```

## 현재 구현 상태
현재는 **스켈레톤**입니다.
- 구현: `/graphql`, `/graphiql`, CMS 스키마, 스텁 컨트롤러, `/hello`, Actuator
- 미구현: `content-service` HTTP 클라이언트, 실제 CMS 조회·변경, DataLoader 기반 조합
