# DB 스크립트

## 명령

```text
db up      # 컨테이너 기동 + V1 스키마(볼륨 최초 생성 시)
db down    # 중지 (데이터 유지)
db reset   # 볼륨 삭제 후 재기동
```

`db` 가 OS를 감지해서 `unix/` 또는 `windows/` 로 분기합니다.

## 실행

`scripts` 폴더에서:

| OS | 실행 |
|----|------|
| macOS / Linux / WSL / Git Bash | `./db up` |
| Windows CMD | `db up` (`db.cmd` — CMD는 확장자 없는 파일을 못 실행해서 얇은 래퍼만 둠) |

레포 루트:

```bash
./scripts/db up
```

```bat
scripts\db.cmd up
```

## 구조

```
scripts/
├── db              # 진입점 + OS 분기
├── db.cmd          # Windows CMD 전용 래퍼 → db 또는 windows/
├── unix/           # macOS / Linux 구현
└── windows/        # Windows 구현
```

## 요구 사항

Docker Desktop, `docker compose` (V2)
