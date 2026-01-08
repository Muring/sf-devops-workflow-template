# Salesforce CI/CD (GitHub Actions)

Salesforce(SFDX) 프로젝트를 GitHub Actions로 배포/검증하는 CI/CD 파이프라인이다.
운영(Production)은 **태그 기반 승인 + Validate → Quick Deploy** 전략으로 배포 시간을 단축하고, Sandbox는 **자주 자동 배포**되도록 구성했다.

---

## 목표

* **Sandbox**

  * `main` 반영 시 자동 배포
  * 빠른 피드백을 위해 기본적으로 테스트를 스킵(NoTestRun)

* **Production**

  * `prod-rc-*` 태그: 운영 Org에 **Validate** 수행(테스트 포함)
  * `prod-*` 태그: Validate 결과(Job ID)를 이용해 **Quick Deploy**
  * GitHub **Environment 보호 규칙**으로 `prod-*` 태그만 운영 배포 가능하도록 제한

* **보안**

  * JWT 기반 인증(`sf org login jwt`)
  * `.github/workflows/**` 변경은 CODEOWNERS + 브랜치 보호로 변조 방지

---

## 저장소 구조

```text
.
├─ force-app/                       # Salesforce metadata
├─ .github/
│  ├─ workflows/
│  │  ├─ pr-validate.yml             # PR 검증(Validate)
│  │  ├─ deploy-sandbox.yml          # main → sandbox 자동 배포
│  │  ├─ prod-validate.yml           # prod-rc-* → production validate
│  │  └─ prod-deploy.yml             # prod-* → production quick deploy
│  └─ CODEOWNERS                     # 워크플로 변경 보호
└─ README.md
```

---

## 사전 준비

### 1) Salesforce Org 준비

* Sandbox Org 1개
* Production Org 1개

각 Org에 **Connected App**을 생성하고, JWT 인증을 위한 설정을 한다.

> Sandbox와 Production의 Connected App **Consumer Key(Client Id)는 서로 다르게 발급**된다.
> 다만 동일한 인증서(공개키)를 두 Org의 Connected App에 등록하는 방식은 가능하다.

### 2) GitHub Environments 생성

Repository Settings → **Environments**에서 아래 2개 환경을 만든다.

* `sandbox`
* `production`

---

## Secrets 설정 (Environment Secrets)

각 Environment에 동일한 키 이름으로 Secrets를 저장한다.
(즉, 워크플로에서는 `secrets.SF_CLIENT_ID`처럼 **이름이 통일**된다.)

### 공통 키(환경마다 값만 다름)

| Key               | 설명                                                                            |
| ----------------- | ----------------------------------------------------------------------------- |
| `SF_CLIENT_ID`    | Connected App Consumer Key(Client Id)                                         |
| `SF_USERNAME`     | 배포용 Salesforce Username                                                       |
| `SF_INSTANCE_URL` | Sandbox: `https://test.salesforce.com` / Prod: `https://login.salesforce.com` |
| `SF_JWT_KEY`      | JWT private key(문자열 전체)                                                       |

> `SF_JWT_KEY`는 보통 줄바꿈 포함 텍스트이므로, GitHub Secrets에 그대로 저장한다.

---

## GitHub Environment 보호 규칙(Production 필수)

`production` Environment에서 다음을 설정한다.

### Deployment branches and tags

* **Selected branches and tags**로 설정
* 허용 규칙 추가

  * Branch: `main`
  * Tag: `prod-*`
  * Tag: `prod-rc-*` (Validate 태그도 production 환경 사용하므로 포함)

이 설정이 없으면, `environment: production`을 사용하는 Job이 태그 실행 시 다음과 같은 에러로 차단될 수 있다.

* `Tag "..." is not allowed to deploy to production due to environment protection rules.`

---

## 워크플로 동작 방식

### 1) PR 검증 (PR → main)

* 트리거: `pull_request` (base: `main`)
* 동작: sandbox에 인증 후 `sf project deploy validate` 수행(테스트 포함)

파일: `.github/workflows/pr-validate.yml`

---

### 2) Sandbox 자동 배포 (main push)

* 트리거: `push` (branch: `main`)
* 동작: sandbox에 `sf project deploy start` 수행
* 기본값: `--test-level NoTestRun`

파일: `.github/workflows/deploy-sandbox.yml`

---

### 3) Production 배포 (태그 기반 승인)

운영 배포는 **2단계 태그**로 수행한다.

#### (1) Validate 태그: `prod-rc-YYYY.MM.DD-SS`

* 트리거: 태그 push(`prod-rc-*`)
* 동작:

  * Production에 Validate 수행(테스트 포함)
  * 결과 JSON에서 **Validated Deploy Job ID**를 추출
  * GitHub Release(해당 rc 태그)의 body에 `ValidatedDeployId: <JOB_ID>` 형태로 저장

파일: `.github/workflows/prod-validate.yml`

#### (2) Deploy 태그: `prod-YYYY.MM.DD-SS`

* 트리거: 태그 push(`prod-*`)
* 동작:

  * 동일 커밋에 찍힌 `prod-rc-*` 태그를 찾음
  * RC Release body에서 `ValidatedDeployId`를 읽음
  * `sf project deploy quick --job-id <JOB_ID>`로 Quick Deploy 수행
  * GitHub Release 생성 시 `--generate-notes`로 릴리즈 노트 자동 생성 + 배포 메타 정보 기록

파일: `.github/workflows/prod-deploy.yml`

---

## 태그 네이밍 규칙

### 권장 규칙

* Validate(검증): `prod-rc-YYYY.MM.DD-SS`
* Deploy(실배포): `prod-YYYY.MM.DD-SS`

예시:

* `prod-rc-2026.01.07-06`
* `prod-2026.01.07-06`

> `SS`는 동일 날짜 내 재시도/재배포를 위한 시퀀스이다.

---

## 운영 배포 절차(실제 실행 방법)

### 1) Validate 수행(업무시간 권장)

```bash
git checkout main
git pull

git tag -a prod-rc-2026.01.07-06 -m "Production validate"
git push origin prod-rc-2026.01.07-06
```

* GitHub Actions에서 `prod-validate.yml`이 실행된다.
* RC 태그 Release body에 `ValidatedDeployId: ...`가 기록된다.

### 2) Quick Deploy 수행(배포 시간대 권장)

```bash
git checkout main
git pull

git tag -a prod-2026.01.07-06 -m "Production release"
git push origin prod-2026.01.07-06
```

* GitHub Actions에서 `prod-deploy.yml`이 실행된다.
* 동일 커밋의 RC 태그를 찾고, Job ID로 Quick Deploy를 수행한다.

---

## 워크플로 변조 방지 (CODEOWNERS + Branch Protection)

### 1) CODEOWNERS 파일 생성

아래 위치 중 하나에 `CODEOWNERS` 파일을 둔다.

* `/CODEOWNERS`
* `/.github/CODEOWNERS`  ✅ (권장)
* `/docs/CODEOWNERS`

예시: `/.github/CODEOWNERS`

```txt
/.github/workflows/  @Muring @muring3
/.github/CODEOWNERS  @Muring @muring3
```

### 2) main 브랜치 보호 설정(권장)

Repository Settings → Branches → main 보호 규칙에서 아래를 활성화한다.

* Require a pull request before merging
* Require approvals (최소 1명)
* **Require review from Code Owners**
* Require status checks to pass (PR Validate)
* (가능하면) Restrict who can push to matching branches

---

## 트러블슈팅

### `Parsing --instance-url Expected a valid url but received:`

* 원인: `SF_INSTANCE_URL`이 빈 값으로 전달됨(Secrets 미주입)
* 해결:

  * Job에 `environment: production` / `environment: sandbox`가 선언되어 있는지 확인
  * 해당 Environment에 `SF_INSTANCE_URL`이 존재하는지 확인
  * 값에 공백/따옴표가 섞이지 않았는지 확인

### `Tag "...” is not allowed to deploy to production due to environment protection rules.`

* 원인: production Environment의 “허용된 태그 패턴”에 현재 태그가 포함되지 않음
* 해결:

  * `prod-*`, `prod-rc-*`가 모두 허용되도록 Deployment branches and tags를 설정

---

## 참고

* Salesforce CLI: `sf org login jwt`, `sf project deploy validate`, `sf project deploy quick`
* GitHub Environments: secrets 및 tag/branch 기반 배포 제한
* GitHub CODEOWNERS + branch protection: 워크플로 변경 승인 강제

---