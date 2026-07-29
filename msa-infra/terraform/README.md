# Terraform - Cloud Infrastructure

## 목적

AWS Lightsail 및 관련 리소스를 코드로 관리.

## 사용 시점

Tier 3 (Week 12+): 클라우드 배포 시작 시.

## 계획

- Lightsail 인스턴스 2대 (API + DB)
- Object Storage 버킷
- Static IP
- 스냅샷 정책
- AWS Budgets + 자동 정지 람다

## 사용법 (구현 후)

```bash
terraform init
terraform plan
terraform apply
```
