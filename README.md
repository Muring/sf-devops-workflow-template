# Salesforce CI/CD (develop → main)

**Sandbox 자동 배포 + Production Validate → Quick Deploy + Release 자동 생성**

이 저장소는 Salesforce(SFDX) 프로젝트를 GitHub Actions 기반으로 운영한다.
개발 속도와 운영 안정성을 동시에 확보하기 위해 다음 전략을 사용한다.

* **Sandbox**: `develop` 브랜치 push 시 자동 배포(테스트 스킵)
* **Production**: `develop → main` PR에서 **Validate(테스트 포함)** 수행
* **Production 배포**: PR merge로 `main`에 반영되면 **Quick Deploy**로 빠르게 반영
* **Release**: Production Quick Deploy가 성공하면 `release-*` 태그와 GitHub Release를 자동 생성


## 목차

* [전체 흐름](#전체-흐름)
* [브랜치 전략](#브랜치-전략)
* [워크플로 파일](#워크플로-파일)
* [필수 설정](#필수-설정)

  * [Salesforce Connected App(JWT)](#salesforce-connected-appjwt)
  * [GitHub Environments & Secrets](#github-environments--secrets)
  * [Repository 설정 권장](#repository-설정-권장)
* [운영 사용 방법](#운영-사용-방법)
* [트러블슈팅](#트러블슈팅)
* [보안/운영 팁](#보안운영-팁)


## 전체 흐름

### 1) develop → Sandbox 자동 배포

* 트리거: `push` to `develop`
* 대상: Sandbox Org
* 테스트: `NoTestRun`

### 2) PR(develop → main) → Production Validate

* 트리거: `pull_request` to `main`
* 대상: Production Org
* 테스트: `RunLocalTests`
* 결과: Validate 결과의 **Job ID(ValidatedDeployId)**를 PR 코멘트로 기록

### 3) main merge → Production Quick Deploy

* 트리거: `push` to `main` (PR merge로 발생)
* 동작:

  1. 현재 커밋과 연결된 PR을 조회
  2. PR 코멘트에서 `ValidatedDeployId`를 읽음
  3. `sf project deploy quick`로 운영 반영

### 4) Quick Deploy 성공 → Release 자동 생성

* Production Quick Deploy 성공 시점에만:

  * `release-YYYY.MM.DD-SS` 태그 생성 및 push
  * GitHub Release 자동 생성(릴리즈 노트 자동 생성)


## 브랜치 전략

* `develop`: 개발/통합 브랜치이다. 변경이 잦으므로 Sandbox 자동 배포로 빠르게 피드백을 받는다.
* `main`: 운영 반영 브랜치이다. `develop → main` PR로만 반영한다.

권장 GitHub 브랜치 보호:

* `main` 직접 push 금지(PR 필수)
* 필수 상태 체크: PR Validate 워크플로 통과 필수
* PR 승인(Approvals) 조건 적용(팀 정책)


## 워크플로 파일

### 1) Sandbox 자동 배포

* 파일: `.github/workflows/deploy-sandbox.yml`
* 트리거: `push` to `develop`
* 환경: `environment: sandbox`

### 2) PR Production Validate

* 파일: `.github/workflows/pr-validate-production.yml`
* 트리거: `pull_request` to `main`
* 환경: `environment: production-validate`
* PR 코멘트 예시:

```text
ValidatedDeployId: 0AfXXXXXXXXXXXX
HeadSHA: abcdef1234...
Note: This id will be used for sf project deploy quick on main merge.
```

### 3) Production Quick Deploy + Release

* 파일: `.github/workflows/quick-deploy-production.yml`
* 트리거: `push` to `main`
* 환경: `environment: production`
* 포함 기능:

  * 운영 배포 권한자 allowlist Gate
  * Quick Deploy 성공 시 `release-*` 태그 & GitHub Release 자동 생성


## 필수 설정

### Salesforce Connected App(JWT)

Sandbox와 Production 각각에 Connected App을 생성한다.
일반적으로 Sandbox/Production의 Consumer Key는 서로 다르다.

필수 항목:

* Consumer Key(Client ID)
* JWT 인증용 Private Key(Repository에는 커밋하지 않음)
* Integration User(배포용 사용자) 생성 및 권한 부여


### GitHub Environments & Secrets

다음 3개 Environment를 사용한다.

* `sandbox`
* `production-validate`
* `production`

각 Environment에 아래 Secrets를 저장한다(키 이름 동일 권장).

| Secret Key        | 설명                                                         |
| ----------------- | ---------------------------------------------------------- |
| `SF_CLIENT_ID`    | Connected App Consumer Key                                 |
| `SF_USERNAME`     | 배포용 사용자 Username                                           |
| `SF_INSTANCE_URL` | 로그인 URL (`https://test.salesforce.com` 또는 My Domain URL 등) |
| `SF_JWT_KEY`      | JWT private key 내용(멀티라인)                                   |

> 워크플로에서 Environment secrets를 읽으려면 job에 `environment: <name>` 선언이 필요하다.


### Repository 설정 권장

#### 1) Actions 권한

Release 태그 생성 및 GitHub Release 생성을 위해 다음이 필요하다.

* 워크플로에 `permissions: contents: write`
* Repository Settings에서 GitHub Actions의 `GITHUB_TOKEN`이 read-only인 경우 read/write로 변경

#### 2) 브랜치 보호(main)

* Require a pull request before merging
* Require status checks to pass
* Require approvals (팀 정책)


## 운영 사용 방법

### 1) 개발/테스트(Sandbox)

1. `develop` 브랜치에 커밋 push
2. GitHub Actions가 Sandbox에 자동 배포
3. Sandbox에서 기능 확인

### 2) 운영 반영(Production)

1. `develop` → `main` PR 생성
2. PR Validate(Production Validate)가 실행되어 테스트 포함 검증 수행
3. Validate 성공 후 PR 승인 및 merge
4. `main`에 push가 발생하며 Production Quick Deploy 실행
5. 성공 시 `release-*` 태그 + GitHub Release가 자동 생성


## 트러블슈팅

### 1) Quick Deploy가 “PR을 못 찾는다”

* main에 직접 push했거나, 커밋이 PR merge로 생성되지 않은 경우이다.
* 운영 정책상 main 직접 push를 막는 것이 권장이다.

### 2) Quick Deploy가 “ValidatedDeployId를 못 찾는다”

* PR Validate 워크플로가 실행되지 않았거나 실패했을 가능성이 높다.
* PR 코멘트가 삭제되었거나, 코멘트 형식이 바뀐 경우에도 발생한다.

### 3) Tag push / Release 생성이 실패한다

* `permissions: contents: write` 누락
* Repository Actions 토큰 권한이 read-only
* 브랜치/태그 보호 정책과 충돌


## 보안/운영 팁

* JWT private key는 절대 저장소에 커밋하지 않는다.
* 배포용 사용자는 최소 권한 원칙을 적용한다.
* `.github/workflows/**` 변경은 CODEOWNERS + 브랜치 보호로 보호하는 구성이 권장된다.
* 운영 배포 권한자(allowlist)는 최소화한다.


## 참고

* Salesforce CLI를 사용하여 `deploy validate`로 검증한 결과(Job ID)를 `deploy quick`에서 재사용한다.
* Release는 “운영 반영 성공 기록”으로 취급한다. Quick Deploy 성공 시점에만 생성된다.
