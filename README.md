# GitHub Actions 기반 Salesforce CI/CD (main < develop < feature) 운영 가이드

> 본 문서는 저장소에 포함된 3개의 GitHub Actions Workflow 파일을 기준으로, **브랜치 전략(main < develop < feature)** 과 그에 따른 **자동 검증(Validate) + Quick Deploy + (Production) Release 생성** 흐름을 상세히 설명합니다.  
> 대상 파일:
> - `.github/workflows/pr-validate-on-integration.yml`
> - `.github/workflows/deploy-sandbox.yml`
> - `.github/workflows/deploy-production.yml`

---

<details>
<summary><strong>목차 (펼치기/접기)</strong></summary>

- [1. 이 구조가 해결하려는 문제(목표)](#1-이-구조가-해결하려는-문제목표)
- [2. 브랜치 전략: main &lt; develop &lt; feature](#2-브랜치-전략-main--develop--feature)
- [3. Workflow 전체 개요(3종)](#3-workflow-전체-개요3종)
- [4. 공통 전제/준비 사항](#4-공통-전제준비-사항)
- [5. PR Validate Workflow 상세 설명 (pr-validate-on-integrationyml)](#5-pr-validate-workflow-상세-설명-pr-validate-on-integrationyml)
- [6. Sandbox Quick Deploy 상세 (deploy-sandboxyml)](#6-sandbox-quick-deploy-상세-deploy-sandboxyml)
- [7. Production Quick Deploy + Release 상세 (deploy-productionyml)](#7-production-quick-deploy--release-상세-deploy-productionyml)
- [8. “ValidatedDeployId 브릿지” 설계 의도](#8-validateddeployid-브릿지-설계-의도)
- [9. 운영 규칙/권장사항](#9-운영-규칙권장사항)
- [10. 자주 발생하는 이슈와 트러블슈팅](#10-자주-발생하는-이슈와-트러블슈팅)
- [11. 파일별 “코드 레벨” 해설(스텝 단위)](#11-파일별-코드-레벨-해설스텝-단위)
- [12. 결론: 이 구조의 장점](#12-결론-이-구조의-장점)
- [부록 A. PR 본문 템플릿 예시](#부록-a-pr-본문-템플릿-예시)
- [부록 B. 파일 원문](#부록-b-파일-원문)
- [13. 핵심 코드 스니펫 상세 해설(실제 YAML 발췌 + 설명)](#13-핵심-코드-스니펫-상세-해설실제-yaml-발췌--설명)

</details>


## 1. 이 구조가 해결하려는 문제(목표)

Salesforce 메타데이터 배포는 일반적인 애플리케이션 배포와 달리 다음의 특성이 있습니다.

- **배포(Deploy) 전에 검증(Validate)을 반드시 통과해야 하며**, 검증에서 생성되는 Deploy Job Id를 재사용하면 **Quick Deploy**가 가능함
- “검증은 통과했는데 실제 배포가 실패”하거나, “PR은 이미 merge 되었는데 deploy가 깨짐” 같은 상황이 발생하면  
  Git 히스토리(그래프)가 지저분해지고, 원인 추적/롤백도 어려워짐
- 전체 소스를 매번 배포하면 시간이 길어지고 실패 가능성이 증가하며, PR 단위로 변경된 것만 검증/배포하고 싶음
- Production 배포는 특히 **권한/승인자 게이트**가 필요하고, 배포 성공 시 **릴리즈 태그/릴리즈 노트**를 자동으로 남기고 싶음

이 Workflow 3종은 위 문제를 아래의 운영 원칙으로 해결하는 것을 목표로 합니다.

### 핵심 목표

1. **PR 단계에서 “변경분(Delta)만” 검증**하여, merge 전에 실패를 최대한 앞단에서 차단
2. merge 후에는 PR에서 생성된 **Validated Deploy Job Id**를 재사용하여 **Quick Deploy**로 빠르게 배포
3. Production 배포는 승인자만 실행 가능하도록 게이트를 두고, 성공 시 **Release Tag + GitHub Release**까지 자동 생성
4. 메타데이터 변경이 없는 PR은 **SKIPPED**로 처리하여 불필요한 배포를 하지 않음
5. 운영이 복잡해지지 않도록, 브랜치 규칙을 단순하게 유지:
   - feature → (PR) → develop → (PR) → main

---

## 2. 브랜치 전략: main < develop < feature

본 저장소는 다음과 같은 브랜치 역할을 전제로 합니다.

- **feature/***: 개발자가 기능/수정 단위로 작업하는 브랜치
- **develop**: 통합 브랜치(샌드박스 대상). feature 브랜치들이 PR로 들어오는 곳
- **main**: 프로덕션 브랜치(운영 대상). develop에서 검증된 변경만 PR로 들어오는 곳

### 권장 운영 흐름(가이드)

1. 개발자는 `feature/*` 브랜치를 생성하여 작업
2. `feature/*` → `develop` 로 Pull Request 생성
3. PR 생성 시, **PR Validate Workflow**가 자동 실행되어 Sandbox(또는 Validate 전용 Org)에 대해 배포 검증
4. 검증이 통과하면 PR 코멘트에 `ValidatedDeployId`가 남음
5. PR을 merge하여 `develop`에 반영하면, `develop push` 트리거로 **Sandbox Quick Deploy Workflow**가 실행되어 빠르게 배포
6. `develop` → `main` PR을 생성하면, 동일하게 PR Validate가 Production(또는 Production Validate Org)에 대해 검증
7. PR merge로 `main`에 반영되면, `main push` 트리거로 **Production Quick Deploy + Release Workflow**가 실행되어 배포 및 릴리즈 산출물(태그/릴리즈)이 생성

---

## 3. Workflow 전체 개요(3종)

### 3.1 PR Validate (main/develop 대상)

- 파일: `pr-validate-on-integration.yml`
- 트리거: `pull_request` (대상 브랜치: `main`, `develop`)
- 역할:
  - PR에서 변경된 메타데이터만 추출(Delta)
  - Salesforce CLI로 `sf project deploy validate` 수행
  - 결과로 생성된 **job id(ValidatedDeployId)** 를 PR 코멘트로 남김  
    → 이후 merge 후 Quick Deploy 단계에서 그대로 재사용

### 3.2 Sandbox Quick Deploy (develop push)

- 파일: `deploy-sandbox.yml`
- 트리거: `push` (브랜치: `develop`)
- 역할:
  - merge된 커밋이 어떤 PR에서 왔는지 찾아냄
  - 해당 PR 코멘트에서 `ValidatedDeployId`를 읽어옴
  - `sf project deploy quick --job-id <id>` 로 Sandbox에 Quick Deploy

### 3.3 Production Quick Deploy + Release (main push)

- 파일: `deploy-production.yml`
- 트리거: `push` (브랜치: `main`)
- 역할:
  - Sandbox와 동일하게 PR을 찾고 `ValidatedDeployId`를 읽어 Quick Deploy
  - 배포 성공 시 `release-YYYY.MM.DD-SS` 형태로 태그 생성 및 GitHub Release 생성
  - 승인자 allowlist를 통해 Production 배포 권한을 제한

---

## 4. 공통 전제/준비 사항

> **사전 준비(필수)**  
> 이 Workflow는 **Salesforce Connected App(JWT) 설정**과 **GitHub Secrets/Environments 구성**이 **이미 완료되어 있어야** 정상 동작합니다.  
> 아직 설정하지 않았다면, [기본 설정 가이드](https://muring-blog.vercel.app/salesforce-ci-cd-basic)를 먼저 완료한 뒤 본 Workflow를 사용하십시오.


### 4.1 GitHub Environments

Workflow는 `environment:` 를 사용합니다.

- PR Validate: base 브랜치에 따라
  - base가 `main`이면 `production-validate`
  - base가 `develop`이면 `sandbox-validate`
- Sandbox Deploy: `sandbox`
- Production Deploy: `production`

GitHub Environments를 사용하는 이유:

- Org별 Secret을 분리하고(Production vs Sandbox)
- Production에는 추가 승인(Required reviewers) 같은 정책을 적용할 수 있음
- 배포 대상과 검증 대상을 명확히 구분할 수 있음

### 4.2 필수 Secrets

각 Environment에 다음 Secret이 존재해야 합니다(Workflow에서 Guard로 체크합니다).

- `SF_CLIENT_ID` : Connected App의 Consumer Key
- `SF_USERNAME` : JWT 인증 대상 사용자(Integration User)
- `SF_INSTANCE_URL` : 로그인 URL (예: `https://login.salesforce.com` 또는 Sandbox URL)
- `SF_JWT_KEY` : JWT Private Key (멀티라인 문자열)

> JWT 기반 인증은 `sf org login jwt`(또는 `sf org login jwt`)로 수행하며,  
> CI 환경에서 브라우저 로그인 없이 안정적으로 인증할 수 있다는 장점이 있습니다.

### 4.3 Salesforce 프로젝트 구조(가정)

Delta 생성 스텝이 다음 옵션을 사용합니다.

- `--source-dir "force-app"`

즉, 메타데이터 소스가 기본적으로 `force-app` 하위에 존재하는 구조를 전제로 합니다.  
(다중 패키지 디렉토리 또는 다른 소스 디렉토리를 사용한다면 해당 옵션을 조정해야 합니다.)

---

## 5. PR Validate Workflow 상세 설명 (`pr-validate-on-integration.yml`)

아래는 PR Validate의 핵심 구성입니다.

### 5.1 트리거/동시성/권한

```yml
on:
  pull_request:
    branches: [main, develop]

concurrency:
  group: pr-validate-integration-${{ github.event.pull_request.number }}
  cancel-in-progress: true

permissions:
  contents: read
  pull-requests: write
  security-events: write
  actions: read
```

- **pull_request**: PR이 생성/업데이트될 때마다 실행
- **concurrency**:
  - PR 번호별로 그룹을 만들고
  - 같은 PR에서 커밋이 추가로 올라오면 이전 실행은 취소(`cancel-in-progress: true`)
  - 최신 커밋 기준 결과만 남기기 위함
- **permissions**:
  - PR 코멘트를 남기려면 `pull-requests: write` 필요
  - (주석 처리된) SARIF 업로드를 위해 `security-events: write` 포함

### 5.2 환경 선택: base 브랜치에 따라 검증 대상 Org 전환

```yml
environment: ${{ github.base_ref == 'main' && 'production-validate' || 'sandbox-validate' }}
```

- PR의 base 브랜치가 `main`이면 **Production 검증 Org(또는 Production 자체)** 를 사용
- base가 `develop`이면 **Sandbox 검증 Org(또는 Sandbox 자체)** 를 사용  
→ 같은 Workflow로도 검증 대상을 분기할 수 있습니다.

### 5.3 기본 셋업(Checkout/Node/CLI/Plugin)

- Checkout은 `fetch-depth: 0` 으로 전체 히스토리를 받습니다.  
  Delta 계산이 base/head SHA 기반이므로 전체 히스토리 확보가 안정적입니다.
- Node 20 설치 후 Salesforce CLI 설치:
  - `npm i -g @salesforce/cli`
- `sfdx-git-delta` 플러그인 설치:
  - `echo y | sf plugins install sfdx-git-delta`

### 5.4 JWT Key 파일 생성 + Secret Guard

```bash
echo "${{ secrets.SF_JWT_KEY }}" > server.key
```

- GitHub Secret에 들어 있는 private key를 CI 런타임에서 파일로 만들고,
- 이후 `sf org login jwt` 에서 `--jwt-key-file server.key` 로 사용합니다.

또한 Guard Step에서 필수 Secret 누락을 즉시 실패 처리합니다.  
(배포/검증이 애매하게 실패하지 않도록 “원인”을 명확히 하기 위함)

### 5.5 인증: Target Org 로그인(JWT)

Workflow는 base 브랜치에 따라 ORG_ALIAS를 선택하고, JWT로 인증합니다.
- 예: `ci-prod` / `ci-sandbox` 같은 alias를 지정하여 이후 명령에서 사용

### 5.6 Delta Package 생성: PR base → head

이 Workflow의 성능/안정성 핵심은 변경분만 추출하는 것에 있습니다.

```bash
sf sgd source delta   --from "$FROM_SHA"   --to "$TO_SHA"   --output-dir "delta"   --source-dir "force-app"   --generate-delta
```

- `FROM_SHA`: PR base 커밋 SHA
- `TO_SHA`: PR head 커밋 SHA
- output은 `delta/` 아래에 생성:
  - `delta/package/package.xml` (manifest)
  - `delta/force-app/...` (변경된 소스)
  - `delta/destructiveChanges/destructiveChanges.xml` (삭제 변경이 있을 때)

그리고 아래 로직으로 “변경이 있는지”를 판단합니다.

- manifest에 `<members>` 가 있으면 `HAS_CHANGES=true`
- destructiveChanges에 `<members>` 가 있으면 `HAS_DESTRUCTIVE=true`

변경이 없다면 이후 검증을 생략하고, 최종적으로 PR 코멘트에 `ValidatedDeployId: SKIPPED`를 남기게 됩니다.

### 5.7 PR Body에서 테스트 전략 선택

PR 본문(body)에 특정 패턴을 넣으면 테스트 레벨을 제어할 수 있습니다.

- 특정 테스트만:
  - `Apex::[MyTest1,MyTest2]::Apex`
  - → `RunSpecifiedTests` + `--tests "MyTest1,MyTest2"`
- 전체(기본):
  - `Apex::[all]::Apex` 또는 아무 것도 없으면
  - → `RunLocalTests`

이 방식의 장점:
- 운영자가 “이 PR은 지정 테스트만” 또는 “전체 로컬 테스트”를 정책적으로 선택 가능
- PR 단위로 의도를 명시할 수 있어, 배포 실패 시 책임소재/재현성이 좋아짐

### 5.8 Validate 수행 + Succeeded까지 폴링

핵심 명령:

```bash
sf project deploy validate   --manifest "$MANIFEST"   --target-org "${ORG_ALIAS}"   --wait 1   --json   <TEST_ARGS...>   <EXTRA...>
```

- `--wait 1` 로 짧게 반환받고, 이후 `sf project deploy report`로 상태를 폴링합니다.
- 폴링은 최대 120회 × 30초 = 60분까지 기다립니다.
- 최종 status가 `Succeeded` 가 아니면 실패 처리합니다.

> 중요한 포인트: validate 결과에서 **job id** 를 추출하여 이후 Quick Deploy의 입력으로 재사용합니다.

### 5.9 PR 코멘트로 결과 남기기(ValidatedDeployId + HeadSHA)

마지막 스텝에서 PR 코멘트를 남깁니다.

코멘트 포맷(예시):

```
ValidatedDeployId: 0AfXXXXXXXXXXXX
HeadSHA: abcdef123456...
Note: This id will be used for sf project deploy quick on main merge.
```

이 코멘트가 **merge 후 Quick Deploy workflow가 읽어가는 “브리지” 데이터**입니다.

---

## 6. Sandbox Quick Deploy 상세 (`deploy-sandbox.yml`)

### 6.1 트리거/무시 경로/동시성

```yml
on:
  push:
    branches: [develop]
    paths-ignore:
      - 'sfdx-project.json'
      - 'README.md'
```

- develop에 push(대부분 PR merge)되면 실행
- 문서/설정 파일만 바뀐 경우 배포를 돌리지 않도록 paths-ignore 처리

동시성:

```yml
concurrency:
  group: quick-deploy-sandbox
  cancel-in-progress: false
```

- Sandbox 배포는 순차성이 중요할 수 있으므로(특히 같은 파일 수정 충돌 등)  
  cancel-in-progress를 끄고, 큐 형태로 진행하도록 설정되어 있습니다.

### 6.2 승인자 게이트(allowlist)

```bash
ALLOWED=("Muring" "muring3")
...
if [ "${{ github.actor }}" = "$u" ]; then ...
```

- 특정 GitHub 계정만 Sandbox 배포를 수행할 수 있도록 제한합니다.
- 조직 정책에 따라 develop 배포도 승인자만 수행하도록 운영할 수 있습니다.  
  (팀마다 정책이 다르므로, 필요 없다면 이 스텝을 제거하면 됩니다.)

### 6.3 “이 커밋이 어떤 PR에서 왔는지” 찾기

Quick Deploy는 PR 검증 결과(job id)를 사용해야 합니다.  
하지만 develop push 이벤트는 PR 정보를 직접 제공하지 않습니다.

그래서 아래처럼 현재 커밋 SHA로 연결된 PR을 찾습니다.

```bash
PR_NUMBER="$(gh api "repos/$REPO/commits/$SHA/pulls" --jq '.[0].number' ...)"
```

- GitHub API로 “해당 커밋과 연결된 PR 목록”을 가져오고,
- 첫 번째 PR 번호를 사용합니다.
- PR을 찾지 못하면 실패 처리하여 “무근본 배포”를 막습니다.

### 6.4 PR 코멘트에서 ValidatedDeployId 읽기

```bash
COMMENTS="$(gh api "repos/$REPO/issues/$PR/comments" --paginate --jq '.[].body')"
JOB_ID="$(echo "$COMMENTS" | awk '/^ValidatedDeployId:/{id=$2} END{print id}')"
```

- PR 코멘트를 페이지네이션으로 전부 읽어온 뒤,
- `ValidatedDeployId:` 라인이 있는 코멘트 중 **가장 마지막 값**을 사용합니다.
- 즉, PR에 여러 번 검증이 실행되어 코멘트가 여러 개여도 “최신” 값이 자동 선택됩니다.

### 6.5 변경이 없는 경우(SKIPPED) 처리

PR Validate 단계에서 변경이 없다면 `ValidatedDeployId: SKIPPED` 를 남깁니다.  
Sandbox Quick Deploy는 이를 감지하여 배포를 건너뜁니다.

```yml
if: ${{ steps.job.outputs.JOB_ID == 'SKIPPED' }}
```

### 6.6 JWT 인증 후 Quick Deploy

검증에서 만든 job id로 Quick Deploy:

```bash
sf project deploy quick   --job-id "${{ steps.job.outputs.JOB_ID }}"   --target-org ci-sandbox   --wait 60
```

- 배포 속도가 빠르고,
- PR 검증과 동일한 배포 단위를 재사용하기 때문에 “검증과 배포의 불일치”를 최소화합니다.

---

## 7. Production Quick Deploy + Release 상세 (`deploy-production.yml`)

Production Workflow는 Sandbox와 동일한 Quick Deploy 흐름에 더해,  
**Release 태그/릴리즈 생성**과 **더 강한 게이트**를 포함합니다.

### 7.1 트리거/무시 경로/동시성

- main push에서 실행
- 문서/설정 파일은 ignore
- concurrency 그룹은 production 전용

```yml
concurrency:
  group: quick-deploy-production
  cancel-in-progress: false
```

Production 배포는 순차성이 매우 중요하므로 취소 없이 진행하도록 되어 있습니다.

### 7.2 승인자 게이트(allowlist)

Sandbox와 동일한 방식으로 `github.actor` allowlist를 두었습니다.  
Production은 특히 강력히 권장되는 정책입니다.

또한 GitHub Environment의 Required reviewers까지 조합하면,
- 코드 머지 권한
- 배포 실행 권한
- 배포 승인 권한
을 분리할 수 있습니다.

### 7.3 PR 찾기 → ValidatedDeployId 읽기 → SKIPPED 처리

Sandbox와 100% 동일한 패턴입니다.

- 커밋으로 PR 찾기
- PR 코멘트에서 ValidatedDeployId 추출(최신)
- SKIPPED면 배포/릴리즈 생성까지 모두 스킵

### 7.4 JWT 인증 후 Production Quick Deploy

```bash
sf project deploy quick   --job-id "${{ steps.job.outputs.JOB_ID }}"   --target-org ci-prod   --wait 60
```

### 7.5 배포 리포트로 “Quick Deploy 가능 상태” 확인

배포 전에(또는 직후) `sf project deploy report` 로 job 상태를 출력하고,
status를 확인하는 Diagnose 스텝이 포함되어 있습니다.

- CI 로그에서 배포 상태를 바로 확인 가능
- 문제 발생 시 재현/원인 파악이 쉬움

### 7.6 릴리즈 태그 규칙: release-YYYY.MM.DD-SS

배포가 성공하면 그 날의 릴리즈 태그를 자동 생성합니다.

- 예: `release-2026.02.04-01`, `release-2026.02.04-02`

동일 날짜에 여러 번 배포해도 sequence(SS)가 증가하도록 설계되어 있습니다.

동작 개요:
1. 기존 태그 중 `release-YYYY.MM.DD-*` 패턴을 조회
2. 가장 큰 시퀀스를 찾고 +1
3. 태그 생성/푸시

### 7.7 GitHub Release 자동 생성(노트 자동 생성)

`gh release create` 로 GitHub Release를 만들며, `--generate-notes`로 릴리즈 노트를 자동 생성합니다.

이로써 Production 배포마다 다음이 자동으로 남습니다.

- “어떤 태그가 언제 생성되었는지”
- “그 태그에 포함된 커밋/PR이 무엇인지”(자동 노트)
- 운영 측면에서 배포 이력/추적이 쉬움

---

## 8. “ValidatedDeployId 브릿지” 설계 의도

이 구조의 핵심은 **PR Validate 결과를 merge 이후에도 신뢰할 수 있게 재사용**하는 것입니다.

일반적인 문제:
- PR 단계에서 validate를 통과해도
- merge 이후 push 기반 workflow에서 다시 validate/deploy를 돌리면
  - 소스가 바뀌거나
  - 시간이 오래 걸리고
  - 실패 시 그래프가 더러워지고
  - “왜 PR은 통과했는데 배포는 실패?” 같은 논쟁이 생깁니다.

본 설계:
- PR Validate에서 생성된 job id를 PR 코멘트에 저장(불변 식별자)
- merge 후 push workflow에서 그 값을 읽어 Quick Deploy

→ **“검증한 그 배포”를 그대로 배포**하는 것이므로 일관성이 높습니다.

---

## 9. 운영 규칙/권장사항

### 9.1 PR Merge 정책

- PR Validate workflow가 성공해야 merge 가능하도록 브랜치 보호 규칙을 설정하는 것을 권장합니다.
  - Required status checks에 PR Validate를 추가
- Production(main)으로의 PR은 추가 승인(리뷰어)을 요구하도록 설정하면 안전합니다.

### 9.2 PR 본문에 테스트 지정 규칙을 팀 규약으로 문서화

- 기본은 RunLocalTests
- 특정 상황(핫픽스, 영향 범위 제한)이면 RunSpecifiedTests 사용
- 테스트 클래스 명은 정확히 기재해야 함(오탈자 시 validate 실패)

### 9.3 destructiveChanges 처리 주의

Workflow는 `--post-destructive-changes`를 validate에 포함할 수 있도록 구성되어 있습니다.
단, destructive changes는 조직 정책/권한/대상에 따라 제약이 있을 수 있으므로,
필요 시 mdapi 기반 checkonly/배포로 분리하는 방식을 추가로 고려하십시오.
(Workflow에는 그 확장 포인트가 주석으로 포함되어 있습니다.)

### 9.4 여러 packageDirectories(모노레포) 사용 시

현재 delta 생성은 `--source-dir "force-app"` 고정입니다.  
다중 디렉토리라면 다음 중 하나로 확장할 수 있습니다.

- `--source-dir` 를 여러 번 호출하거나,
- package별로 Workflow를 분리하거나,
- sfdx-git-delta의 입력 디렉토리를 동적으로 계산

---

## 10. 자주 발생하는 이슈와 트러블슈팅

### 10.1 “No PR found for commit” 에러

원인:
- squash merge, rebase merge 등으로 인해 커밋과 PR 연결이 끊겼거나
- commit ↔ PR 매핑이 GitHub API에서 기대대로 나오지 않는 경우

대응:
- 팀의 merge 전략을 통일(merge commit 권장 또는 squash 시에도 연결 가능한지 확인)
- 필요하다면 “merge commit 메시지에 PR 번호를 포함”하고, 그 문자열로 PR을 파싱하는 대체 로직을 추가

### 10.2 ValidatedDeployId가 PR 코멘트에 없음

원인:
- PR Validate가 실행되지 않았거나
- 실행이 실패했거나
- 코멘트 권한(`pull-requests: write`)이 없거나
- PR이 draft 상태 등 특정 이벤트에서 누락

대응:
- 브랜치 보호에 PR Validate를 Required check로 등록
- GitHub token 권한/permissions 확인

### 10.3 Quick Deploy가 실패(Status가 Succeeded가 아님)

원인:
- validate 이후 org 상태가 바뀌어 quick deploy 조건이 깨짐(예: 같은 메타데이터가 선행 배포됨)
- validate job이 오래되어 만료/재사용 불가한 상태

대응:
- Quick Deploy는 “validate 결과가 재사용 가능”해야 하므로,
  - validate 후 가능한 빠르게 merge/배포하는 운영
  - 또는 push workflow에서 validate를 재실행하는 fallback 경로 추가(필요 시)

### 10.4 Delta가 비어있는데 실제로는 변경이 있음

원인:
- `--source-dir` 경로가 실제 소스 구조와 다름
- Git 히스토리가 충분히 fetch되지 않아 diff 계산 실패

대응:
- `fetch-depth: 0` 유지
- source-dir 설정 점검
- `ls -R delta` 출력 로그를 통해 manifest 생성 여부 확인

---

## 11. 파일별 “코드 레벨” 해설(스텝 단위)

아래는 각 Workflow의 주요 Step을 “왜 존재하는지/무엇을 하는지” 관점에서 요약한 표입니다.

### 11.1 PR Validate Step 요약

- Checkout: diff 계산을 위한 히스토리 확보
- Setup Node / Install CLI: Salesforce CLI 실행 환경 준비
- Install sfdx-git-delta: 변경분만 생성(배포 범위 최소화)
- Select target org: base 브랜치 기준 검증 대상 선택
- Create JWT key file + Guard: 인증 실패 원인을 명확히
- Auth: JWT 기반 무인증 로그인
- Build delta: package.xml/destructiveChanges 생성 및 HAS_CHANGES 판단
- Extract tests: PR 본문 규칙으로 테스트 전략 선택
- Validate: delta manifest로 validate 수행, job id 추출
- Poll report: status Succeeded까지 대기(최대 60분)
- Comment: PR에 ValidatedDeployId 기록(Quick Deploy의 입력)

### 11.2 Sandbox Quick Deploy Step 요약

- Gate: 승인자만 배포(정책)
- Find PR: 커밋 SHA로 PR 번호 조회
- Read ValidatedDeployId: PR 코멘트에서 최신 job id 추출
- Skip: SKIPPED면 종료
- Auth: JWT 로그인
- Diagnose: report 출력(상태 확인)
- Quick Deploy: job id 재사용 배포

### 11.3 Production Quick Deploy + Release Step 요약

- Sandbox와 동일 + 추가:
- Compute release tag: 날짜 기반 태그 자동 증가
- Create tag: 태그 생성/푸시
- Create release: GitHub Release 생성 및 노트 자동 생성

---

## 12. 결론: 이 구조의 장점

- **검증과 배포의 정합성**: PR에서 검증한 job id를 그대로 배포
- **속도**: Quick Deploy로 배포 시간 단축
- **안정성**: 변경분(Delta)만 검증/배포하여 실패 가능성 축소
- **운영 편의**: Production 배포마다 태그/릴리즈 자동 생성
- **거버넌스**: GitHub actor allowlist + Environment 정책으로 배포 통제 가능

---

## 부록 A. PR 본문 템플릿 예시

### A-1) 기본(전체 로컬 테스트)

(아무 것도 적지 않거나)

```
Apex::[all]::Apex
```

### A-2) 지정 테스트만 실행

```
Apex::[MyFeature_Test,MyRegression_Test]::Apex
```

---

## 부록 B. 파일 원문

본 문서가 설명한 YAML 원문은 아래 파일에 존재합니다.

- `deploy-production.yml`
- `deploy-sandbox.yml`
- `pr-validate-on-integration.yml`

---

## 13. 핵심 코드 스니펫 상세 해설(실제 YAML 발췌 + 설명)

아래는 “이 구조가 왜 동작하는지”를 이해하는 데 핵심이 되는 코드 블록을 실제 Workflow에서 발췌한 것입니다.  
(가독성을 위해 일부 공백/주석만 정리했으며, 로직은 동일합니다.)

### 13.1 PR에서 base 브랜치에 따라 Org를 선택하는 이유

PR Validate Workflow는 **develop PR**과 **main PR**을 동시에 처리합니다.  
따라서 “어느 Org에 validate를 걸 것인지”를 base 브랜치로 분기합니다.

```yml
- name: Select target org by base branch
  run: |
      set -euo pipefail
      if [ "${{ github.base_ref }}" = "main" ]; then
        echo "ORG_ALIAS=ci-prod" >> "$GITHUB_ENV"
      else
        echo "ORG_ALIAS=ci-sandbox" >> "$GITHUB_ENV"
      fi
```

- `github.base_ref`는 PR의 대상 브랜치입니다.
- `GITHUB_ENV`에 `ORG_ALIAS`를 저장하면 이후 step들이 동일한 변수를 사용할 수 있습니다.
- 이 설계 덕분에, Workflow를 “두 벌”로 쪼개지 않아도 됩니다(중복 감소).

### 13.2 변경분만 추출하는 Delta 빌드(성능/안정성의 핵심)

```yml
- name: Build delta package (PR base -> head)
  id: delta
  run: |
      set -euo pipefail
      FROM_SHA="${{ github.event.pull_request.base.sha }}"
      TO_SHA="${{ github.event.pull_request.head.sha }}"

      rm -rf delta
      mkdir -p delta

      sf sgd source delta         --from "$FROM_SHA"         --to "$TO_SHA"         --output-dir "delta"         --source-dir "force-app"         --generate-delta

      MANIFEST="delta/package/package.xml"
      DC="delta/destructiveChanges/destructiveChanges.xml"

      if [ -f "$MANIFEST" ] && grep -q "<members>" "$MANIFEST"; then
        echo "HAS_CHANGES=true" >> "$GITHUB_OUTPUT"
      else
        echo "HAS_CHANGES=false" >> "$GITHUB_OUTPUT"
      fi

      if [ -f "$DC" ] && grep -q "<members>" "$DC"; then
        echo "HAS_DESTRUCTIVE=true" >> "$GITHUB_OUTPUT"
      else
        echo "HAS_DESTRUCTIVE=false" >> "$GITHUB_OUTPUT"
      fi
```

해설:

- `FROM_SHA`/`TO_SHA`는 PR의 base/head 커밋 SHA이므로, **PR에서 실제 변경된 범위**만 정확히 잡아냅니다.
- 결과물:
  - `delta/package/package.xml`: validate/deploy의 기준이 되는 manifest
  - `delta/destructiveChanges/destructiveChanges.xml`: 삭제(Destructive) 메타데이터
- `HAS_CHANGES`/`HAS_DESTRUCTIVE`를 `GITHUB_OUTPUT`에 기록하면, 이후 step에서 조건문(`if:`)으로 제어할 수 있습니다.
- **변경이 없으면 validate를 하지 않는다**는 정책이 이 지점에서 구현됩니다.

### 13.3 PR 본문에서 테스트 전략을 “규칙”으로 뽑아내는 방식

```yml
- name: Extract tests from PR body
  id: tests
  run: |
      set -euo pipefail
      BODY="${{ github.event.pull_request.body }}"

      TESTS="$(echo "$BODY" | sed -n 's/.*Apex::\[\(.*\)\]::Apex.*//p' | tr -d '[:space:]')"

      if [ -z "$TESTS" ]; then
        echo "APEX_TESTS=all" >> "$GITHUB_OUTPUT"
      else
        echo "APEX_TESTS=$TESTS" >> "$GITHUB_OUTPUT"
      fi
```

해설:

- PR 본문에서 `Apex::[...]::Apex` 패턴을 찾고 `[...]` 내부만 추출합니다.
- `tr -d '[:space:]'` 로 공백을 제거하여 `MyTest1,MyTest2` 형태를 안정적으로 만들었습니다.
- 결과가 비어 있으면 `all` 처리 → 정책상 `RunLocalTests`로 매핑됩니다.

### 13.4 Validate 실행 시, 테스트 레벨/Destructive 옵션을 동적으로 조립

```yml
- name: Validate deployment and wait until Succeeded
  id: validate
  if: ${{ steps.delta.outputs.HAS_CHANGES == 'true' || steps.delta.outputs.HAS_DESTRUCTIVE == 'true' }}
  run: |
      set -euo pipefail

      EXTRA=()
      if [ "${{ steps.delta.outputs.HAS_DESTRUCTIVE }}" = "true" ] && [ -f "delta/destructiveChanges/destructiveChanges.xml" ]; then
        EXTRA+=(--post-destructive-changes "delta/destructiveChanges/destructiveChanges.xml")
      fi

      APEX_TESTS="${{ steps.tests.outputs.APEX_TESTS }}"

      if [ -z "$APEX_TESTS" ] || [ "$APEX_TESTS" = "all" ]; then
        TEST_ARGS=(--test-level RunLocalTests)
      else
        TEST_ARGS=(--test-level RunSpecifiedTests --tests "$APEX_TESTS")
      fi

      OUT="$(sf project deploy validate         --manifest "delta/package/package.xml"         --target-org "${ORG_ALIAS}"         --wait 1         --json         "${TEST_ARGS[@]}"         "${EXTRA[@]}" 2>&1)"
```

해설:

- Bash 배열을 써서 옵션을 안전하게 조립합니다(공백/인용부호 문제 최소화).
- destructive 변경이 있으면 `--post-destructive-changes`를 추가합니다.
- 테스트는:
  - `all` → `RunLocalTests`
  - 그 외 → `RunSpecifiedTests` + `--tests`
- `--wait 1`은 “빠르게 반환”을 유도하고, 아래에서 report 폴링으로 안정적으로 완료를 확인합니다.

### 13.5 Validate Job Id 추출 → PR 코멘트로 저장(Quick Deploy 브릿지)

Validate 결과 JSON에서 job id를 추출합니다.

```bash
JOB_ID="$(echo "$OUT" | jq -r '.result.id // empty')"
echo "JOB_ID=$JOB_ID" >> "$GITHUB_OUTPUT"
```

그리고 마지막에 PR 코멘트로 남깁니다(발췌).

```yml
- name: Comment validation result to PR
  run: |
      PR="${{ github.event.pull_request.number }}"
      JOB_ID="${{ steps.validate.outputs.JOB_ID }}"
      HEAD_SHA="${{ github.event.pull_request.head.sha }}"

      BODY="$(printf "ValidatedDeployId: %s
HeadSHA: %s
Note: This id will be used for sf project deploy quick on main merge.
"         "$JOB_ID" "$HEAD_SHA")"

      gh pr comment "$PR" --body "$BODY"
```

해설:

- Quick Deploy workflow는 PR 이벤트 맥락이 없으므로, “어딘가”에 job id를 저장해야 합니다.
- PR 코멘트는
  - GitHub API로 쉽게 읽을 수 있고
  - PR 히스토리(감사/추적) 관점에서도 자연스럽습니다.

### 13.6 merge 후 push에서 “커밋 SHA → PR 번호”를 역으로 찾는 로직

push 이벤트는 PR 정보를 주지 않기 때문에, 커밋 SHA로 PR을 찾아야 합니다.

```yml
- name: Find PR associated with this commit
  id: pr
  run: |
      SHA="${GITHUB_SHA}"
      REPO="${GITHUB_REPOSITORY}"
      PR_NUMBER="$(gh api "repos/$REPO/commits/$SHA/pulls" --jq '.[0].number' 2>/dev/null || true)"
      if [ -z "$PR_NUMBER" ] || [ "$PR_NUMBER" = "null" ]; then
        echo "No PR found for commit $SHA. Aborting."
        exit 1
      fi
      echo "PR_NUMBER=$PR_NUMBER" >> "$GITHUB_OUTPUT"
```

해설:

- “merge된 커밋”이 어떤 PR에서 왔는지 찾지 못하면, ValidatedDeployId를 알 수 없습니다.
- 따라서 PR을 찾지 못하면 실패 처리하여, **검증 없는 배포**를 방지합니다.

### 13.7 PR 코멘트에서 최신 ValidatedDeployId 추출(여러 번 검증된 경우 대비)

```yml
- name: Read ValidatedDeployId from PR comments
  id: job
  run: |
      REPO="${GITHUB_REPOSITORY}"
      PR="${{ steps.pr.outputs.PR_NUMBER }}"
      COMMENTS="$(gh api "repos/$REPO/issues/$PR/comments" --paginate --jq '.[].body')"
      JOB_ID="$(echo "$COMMENTS" | awk '/^ValidatedDeployId:/{id=$2} END{print id}')"
      if [ -z "$JOB_ID" ]; then
        echo "ValidatedDeployId not found in PR comments. Aborting."
        exit 1
      fi
      echo "JOB_ID=$JOB_ID" >> "$GITHUB_OUTPUT"
```

해설:

- PR 코멘트는 여러 개 있을 수 있으므로, `awk`로 마지막 값을 취합니다.
- 즉, PR 업데이트로 validate가 여러 번 돌았더라도 **최신 job id가 자동 반영**됩니다.

### 13.8 Production 배포 후 릴리즈 태그 자동 증가 로직

```yml
- name: Compute release tag (release-YYYY.MM.DD-SS)
  id: reltag
  run: |
      DATE="$(date +'%Y.%m.%d')"
      PREFIX="release-${DATE}-"
      LAST="$(git tag --list "${PREFIX}*" | sort | tail -n 1 || true)"

      if [ -z "$LAST" ]; then
        NEXT=1
      else
        SEQ=$(echo "$LAST" | awk -F- '{print $3}')
        NEXT=$((10#$SEQ + 1))
      fi

      TAG="release-${DATE}-$(printf '%02d' $NEXT)"
      echo "TAG=$TAG" >> "$GITHUB_OUTPUT"
```

해설:

- 같은 날짜에 여러 번 배포되면 태그가 충돌하므로, 날짜 prefix로 기존 태그를 조회합니다.
- 마지막 태그의 시퀀스를 파싱해 +1 합니다.
- `10#$SEQ`는 앞자리가 0인 숫자를 8진수로 오해하는 Bash 문제를 피하기 위한 안전장치입니다.

---

## 14. 추가 확장 아이디어(필요 시)

- **Fallback Validate**: push workflow에서 ValidatedDeployId가 없으면, 해당 커밋 기준으로 validate를 다시 수행하여 job id를 생성한 뒤 quick deploy(또는 일반 deploy)로 진행
- **배포 대상 분리**: production-validate org와 production org를 분리하여 “검증 전용”과 “실 배포”를 운영적으로 분리
- **Scanner 활성화**: 주석으로 포함된 SFDX Scanner(SARIF 업로드)를 활성화하여 PR 단위 정적 분석 리포트를 PR/보안 탭에서 확인
- **PR 번호 파싱 대체**: commit-to-PR 매핑이 불안정한 팀이라면 merge commit 메시지에서 PR 번호를 정규식으로 추출하는 방식으로 교체
