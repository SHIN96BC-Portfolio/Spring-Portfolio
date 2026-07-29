# MSA Portfolio Project

> 모노레포로 관리하는 MSA 포트폴리오 프로젝트 (Jenkins로 서비스별 CI/CD 배포)

## 레포 구성

```
[Infrastructure Layer]
msa-infra/          공유 인프라 (Kafka, Redis, 관찰 가능성)
    ↑
[Identity Layer]
msa-auth/           OAuth 2.0 Identity Provider
    ↑
[Application Layer]
msa-platform/       13개 비즈니스 도메인 서비스
```

Git은 **단일 모노레포**로 관리하고, 폴더 경계(`msa-infra` / `msa-auth` / `msa-platform`)와 path 기반 파이프라인으로 서비스별 빌드·배포를 분리합니다.

## 각 레이어 README

- [msa-infra](./msa-infra/README.md) - 공유 인프라
- [msa-auth](./msa-auth/README.md) - Identity Provider
- [msa-platform](./msa-platform/README.md) - 메인 애플리케이션

## IntelliJ 초기 설정 (Gradle)

단일 창에서 모노레포 전체를 관리합니다. **Gradle 루트는 2개만** 등록하면 됩니다.

1. IntelliJ에서 이 레포 루트(`be-service-portfolio`)를 연다.
2. 우측 **Gradle** 툴 윈도우 → **+ (Link Gradle Project)**
3. 아래 2개만 추가한다.

| 등록 | 선택 파일 | 자동 로드 |
|------|-----------|-----------|
| `msa-auth` | `msa-auth/build.gradle.kts` | `auth-service` + `libs/*` |
| `msa-platform` | `msa-platform/build.gradle.kts` | 서비스 13개 + `libs/*` |

- `msa-infra`는 Gradle이 아니므로 등록하지 않는다. (Docker Compose / Kafka 설정은 같은 창에서 열어 보면 됨)
- `auth-service`, `user-service` 등 하위 `build.gradle.kts`는 **수동 등록하지 않는다.** (`settings.gradle.kts`가 로드)

루트에 `build.gradle`이 없어서 **Gradle 창이 안 보이면**:

1. `View` → `Tool Windows` → `Gradle`
   (또는 `⇧⌘A` / `Ctrl+Shift+A` → `Gradle` 검색)
2. 그래도 없으면 `msa-auth/build.gradle.kts`를 우클릭 → `Link Gradle Project`
3. 같은 방식으로 `msa-platform/build.gradle.kts`도 Link

```
be-service-portfolio/          ← IntelliJ로 이 폴더 오픈
├── msa-infra/                 ← 등록 X
├── msa-auth/                  ← ⭐ build.gradle.kts 등록
│   └── auth-service/          ← 자동 로드
└── msa-platform/              ← ⭐ build.gradle.kts 등록
    └── services/*/            ← 자동 로드
```

## 실행 순서

**반드시 이 순서**로 실행하세요.

### DB 한 번에

```bash
cd scripts && ./db up
./scripts/db down
./scripts/db reset
```

Windows CMD: `scripts\db.cmd up`  
Windows PowerShell: `.\scripts\db.cmd up` (또는 Git Bash에서 `./scripts/db up`)

[scripts/README.md](./scripts/README.md)

자세한 내용: [scripts/README.md](./scripts/README.md)

### 수동 (기존 방식)

```bash
# 1. 인프라 먼저
cd msa-infra/docker
docker compose up -d

# 2. msa-auth
cd ../../msa-auth/docker
docker compose up -d          # postgres-auth (+ V1 init on first volume)
cd ..
./gradlew :auth-service:bootRun   # 또는 IntelliJ로 실행

# 3. msa-platform
cd ../msa-platform/docker
docker compose up -d          # PostgreSQL × 9, MongoDB (+ V1 init on first volume)
cd ..
./gradlew build
# 각 서비스는 IntelliJ로 실행
```

## Week 0 진행 가이드

[Week 0 Day-by-Day 가이드](./WEEK-0-GUIDE.md) 참고.

---

## Git 전략 (모노레포)

| 항목 | 규칙 |
|------|------|
| 레포 | 단일 모노레포 (`be-service-portfolio`) |
| 브랜치 모델 | Trunk-Based — `main` + short-lived feature |
| 배포 단위 | 서비스별 (path 변경 감지 → Jenkins 잡) |
| 이미지 태그 | `<service>:<git-sha>` (`main`만 `:latest` 선택) |

- `main`만 배포 가능 상태로 유지합니다.
- long-lived `develop` / GitFlow는 사용하지 않습니다.
- 모노레포를 멀티레포처럼 **Git을 나눠 관리하려 하지 않습니다.** (폴더 경계 + CI path trigger로 배포만 분리)

### Scope (브랜치/커밋에 사용)

| Scope | 경로 |
|-------|------|
| `infra` | `msa-infra/**` |
| `auth-service` | `msa-auth/auth-service/**`, `msa-auth/libs/**` |
| `edge-gateway` | `msa-platform/services/edge-gateway/**` |
| `user-bff` | `msa-platform/services/user-bff/**` |
| `admin-bff` | `msa-platform/services/admin-bff/**` |
| `user-service` | `msa-platform/services/user-service/**` |
| `commerce-service` | `msa-platform/services/commerce-service/**` |
| `point-service` | `msa-platform/services/point-service/**` |
| `fashion-service` | `msa-platform/services/fashion-service/**` |
| `social-service` | `msa-platform/services/social-service/**` |
| `recommendation-service` | `msa-platform/services/recommendation-service/**` |
| `activity-feed-service` | `msa-platform/services/activity-feed-service/**` |
| `notification-service` | `msa-platform/services/notification-service/**` |
| `media-service` | `msa-platform/services/media-service/**` |
| `content-service` | `msa-platform/services/content-service/**` |
| `platform-libs` | `msa-platform/libs/**` |
| `auth-libs` | `msa-auth/libs/**` |

---

## Git Hooks (로컬)

Node/Husky 없이 **shell Git hook**으로 커밋 메시지·브랜치 이름을 검사합니다.

```bash
# 클론 후 한 번 실행
./scripts/install-git-hooks.sh
```

| Hook | 검사 |
|------|------|
| `commit-msg` | `[type/scope/name] subject` |
| `pre-push` | `type/scope/name/#issueNo` (`main` 허용) |

훅 스크립트는 버전 관리되는 `.githooks/`에 두고, `git config core.hooksPath .githooks`로 연결합니다.
(`--no-verify`로 우회 가능하므로, 최종 강제력은 CI에 두는 것을 권장합니다.)

---

## Commit & Branch Pattern

### type

| type | 설명 |
|------|------|
| `feat` | 기능 개발 |
| `hotfix` | 버그 수정 (긴급/운영 반영) |
| `docs` | 문서 관련 수정 |
| `style` | 코드 포맷팅 관련 |
| `refactor` | 리팩토링 |
| `chore` | package/env 등 잡무 |
| `build` | 빌드 관련 설정 수정 |
| `deploy` | CI/CD, Helm, Docker |
| `revert` | 원복 |
| `test` | 테스트 |

### Branch Name

```
type/scope/name/#issueNo
```

예:

```
feat/auth-service/john/#123
hotfix/user-service/john/#200
deploy/infra/john/#125
chore/platform-libs/john/#126
```

### Commit Message

```
[type/scope/name] subject

markdown (본문)
```

예:

```
[feat/auth-service/john] JWT refresh 만료 처리

- refresh token 만료 시 401 반환
- auth-service 단위 테스트 추가
```

### Issues Description

```markdown
## ☄️ 이슈 설명
1. 로그인 시 오류 발생
   - ... 자세한 설명 작성 ...
```

### PR Description

```markdown
## ✨ 작업 개요

1. 로그인 오류 발생 시 메시지 노출 문제 해결
2. 인코딩 설정을 UTF-8로 변경하여 특수문자 깨짐 방지

## 📦 영향 범위

- msa-auth/auth-service
- (공통) msa-auth/libs/common-kafka

## 🚀 배포 대상

- [ ] auth-service
- [ ] (libs 변경 시) 관련 서비스 재배포

## 🔧 변경 사항

1. `LoginService`의 예외 메시지 처리 수정
2. `.editorconfig`에 charset 명시
3. `build.gradle`에서 `fileEncoding` 명시

## 🧪 테스트 방법

1. 잘못된 아이디/비밀번호로 로그인 시도
2. 에러 메시지가 정상 노출되는지 확인
3. 브라우저에서 한글 파일명 다운로드 시 깨지지 않는지 확인

## 📎 관련 이슈

Closes #123
Fixes #98
```

> `Closes` / `Fixes`는 merge 시 이슈를 자동으로 닫습니다.

---

## 모노레포 관리 주의사항

모노레포는 **멀티레포처럼 레포를 나누는 구조가 아닙니다.**  
Git은 하나이고, **변경 범위(어느 서비스/libs를 건드렸는지)** 를 잘 나누는 것이 핵심입니다.

### 반드시 지킬 규칙

1. **한 PR = 한 서비스(또는 infra / libs 한 덩어리)**  
   여러 서비스를 한 PR에 섞지 않습니다.
2. **커밋/푸시 전 `git status` / `git diff --name-only`로 범위 확인**  
   의도하지 않은 다른 서비스 파일이 포함되지 않았는지 확인합니다.
3. **브랜치·커밋에 `scope`(서비스명)를 명시**  
   영향 범위가 이름만 봐도 보이도록 합니다.
4. **`libs/**` 수정 시 영향 서비스를 PR에 명시**  
   공통 라이브러리 변경은 해당 Gradle 루트의 여러 서비스를 재배포할 수 있습니다.
5. **PR에 `영향 범위` / `배포 대상` 섹션을 채운다**

### 자주 하는 실수

| 실수 | 예방 |
|------|------|
| `user-service` 작업인데 `commerce-service` 파일도 수정됨 | PR 전 path 목록 확인 |
| `libs` 수정 후 한 서비스만 배포했다고 생각함 | `libs` 변경 = fan-out(관련 서비스 재배포) 인지 |
| 거대 PR (서비스 여러 개 동시) | 브랜치를 서비스별로 분리 |
| 커밋 메시지에 범위가 없음 | `[feat/user-service/john]` 형식 사용 |

### CI/CD와의 관계 (Jenkins)

- PR: 변경된 path에 해당하는 서비스만 **build / test**
- `main` merge: 변경된 서비스만 **Docker build → push → deploy**
- path 예시:
  - `msa-auth/auth-service/**`, `msa-auth/libs/**` → `auth-service`
  - `msa-platform/services/<name>/**`, `msa-platform/libs/**` → 해당 서비스
  - `msa-infra/**` → infra 검증/배포
- 사람이 “조심”만 하는 것이 아니라, **path trigger + PR 템플릿**으로 실수를 줄입니다.

### 한 줄 요약

> Git은 하나로 단순하게 두고, 배포/리뷰 단위만 서비스별로 쪼갠다.  
> 개발자는 **다른 서비스 변경을 섞지 않기**에 집중하고, 나머지는 CI path 감지가 맡는다.
