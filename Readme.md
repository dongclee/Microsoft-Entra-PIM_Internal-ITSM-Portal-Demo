# Microsoft Entra PIM + Internal ITSM Portal Demo

> **한 줄 소개:** Microsoft Entra 관리자 권한을 회사 내부 ITSM 포털에서 **요청하고, 승인하고, 기간 제한으로 등록하고, 기록하는 방법**을 보여주는 샘플 프로젝트입니다.

**Version:** 2.0.5.1  
**Type:** 교육·고객 데모용 샘플 (운영 제품 아님)

## 왜 만들었나요?

회사에서는 관리자 권한이 필요할 때마다 별도의 포털을 열고, 승인 내역을 다시 ITSM에 옮기는 일이 번거로울 수 있습니다. 이 데모는 **회사의 ITSM 화면에서 요청부터 승인, 권한 등록, 회수, 증적 다운로드까지** 이어지는 경험을 보여줍니다.

**중요:** 이 버전은 Entra PIM을 완전히 대체하지 않습니다. ITSM 포털은 **Eligible(활성화할 수 있는 자격)** 을 등록하고, 사용자가 실제 관리자 권한을 **Activate(활성화)** 하는 단계는 **Microsoft Entra PIM의 My roles**로 이동하여 수행합니다. MFA, 활성화 승인, 최대 활성화 시간은 Entra PIM 정책이 적용합니다.

<img width="1536" height="1024" alt="EntraID_PIM_ITSM_Portal" src="https://github.com/user-attachments/assets/985af3b6-2ade-4eb3-baaa-648a2553a4c3" />

## 30초 만에 이해하기

1. 직원이 내부 포털에서 관리자 권한을 요청합니다.
2. 시스템 담당자, 보안 담당자, 직무분리(SoD) 검토의 세 가지 승인 항목을 통과합니다.
3. 포털이 기간 제한 **Eligible** 등록을 처리합니다.
4. 직원은 Entra PIM에서 필요할 때 역할을 **활성화**합니다.
5. 기간이 끝나면 자격이 만료되며, 포털에서 등록한 자격은 조기 회수할 수 있습니다.
6. 요청과 승인 내역을 ZIP 파일로 다운로드할 수 있습니다.

**예:** 사용자 관리자(User Administrator) 역할을 **30일 동안 활성화 가능한 자격**으로 등록합니다. 사용자가 실제로 관리자 권한을 사용하는 시간은 별도의 PIM 정책을 따릅니다. 포털에 표시된 **4시간은 요청 정보**이지, 포털이 강제로 적용하는 제한이 아닙니다.

## 무엇을 할 수 있나요?

| 기능 | 쉬운 설명 |
|---|---|
| Dashboard | 요청 건수와 진행 상태 보기 |
| PIM 요청 | 대상 사용자, 역할, 업무 사유, 기간 입력 |
| 승인함 | System Owner, Security, SoD의 세 가지 승인 상태 관리 |
| 역할 할당 | 승인 완료 후 기간 제한 Eligible 등록 또는 모의 등록 |
| PIM 활성화 | Entra PIM My roles로 이동하여 실제 활성화 |
| 만료·회수 | 만료 예정 확인, 포털이 생성한 Eligible의 조기 회수 요청 |
| 감사·증적 | 요청·승인·이벤트 CSV 및 SHA-256 목록이 담긴 ZIP 다운로드 |
| 설정·상태 | Simulation/Live 모드, 허용 역할, 상태 확인 |

### Simulation과 Live는 어떻게 다른가요?

- **Simulation (기본값):** 화면과 승인 흐름을 체험하지만, Microsoft Graph의 PIM 권한 데이터는 변경하지 않습니다.
- **Live (선택):** 별도의 권한 승인 후 Microsoft Graph를 호출해 **실제 Entra 디렉터리 역할의 Eligible** 등록·회수 요청을 수행합니다. **승인된 테스트 테넌트에서만** 사용하세요.

## 구조는 간단합니다

```text
직원 / 승인자
      |
      v
회사 내부 ITSM 스타일 포털 (Flask)
      |  요청 -> 3가지 승인 -> 실행 -> 기록
      v
Azure App Service + Microsoft Entra 로그인 (Easy Auth)
      |
      | Live 모드: Managed Identity
      v
Microsoft Graph -> Entra 디렉터리 역할 Eligible 등록/회수
      |
      v
사용자가 Entra PIM My roles에서 실제 역할 활성화
```

- **PowerShell Launcher:** 포털 소스 생성, Azure 배포, 로그인 설정, 검증 및 정리
- **Python Flask + SQLite:** 웹 화면, 티켓, 승인 및 이벤트 기록
- **App Service Easy Auth:** 조직 계정 로그인
- **Managed Identity + Microsoft Graph:** Live 모드에서 Eligible 등록/회수

> **범위:** Microsoft Entra **디렉터리 역할** 데모입니다. Azure 구독·리소스 그룹의 **Azure RBAC PIM**은 포함되지 않습니다. 기존 고객 ITSM과의 실제 연동도 별도 개발이 필요합니다.

## 시작하기

### 준비물

- Windows PowerShell 5.1 또는 PowerShell 7.x
- Azure 구독과 테스트용 Microsoft Entra 테넌트
- Azure 리소스 및 Entra 앱을 만들 수 있는 적절한 권한
- PowerShell 모듈: `Az.Accounts` (3.0.0+), `Az.Resources` (7.0.0+), `Az.Websites` (3.0.0+), `Microsoft.Graph.Authentication` (2.0.0+)
- Azure App Service 사용에 따른 비용 예산. PIM Live 사용 가능 여부와 라이선스는 조직 환경에서 확인

### 1. 스크립트 준비

이 저장소에 포함할 원본 파일:

`Entra-PIM-ITSM-Financial-Portal-Launcher-v2.0.5.1.ps1`

다운로드한 파일을 **`.ps1` 확장자로 복사/이름 변경**하고, PowerShell 5.1을 사용할 경우 **UTF-8 BOM**으로 저장하세요.

### 2. Launcher 실행

```powershell
.\Entra-PIM-ITSM-Financial-Portal-Launcher-v2.0.5.1.ps1 -PortalMode Simulation
```

처음에는 **Simulation**으로 시작하는 것을 권장합니다. 메뉴에서 테넌트 ID, 구독 ID, 리소스 이름을 입력합니다.

### 3. 처음 배포할 때의 메뉴 순서

| 메뉴 | 하는 일 |
|---|---|
| `P` | 필요한 PowerShell 모듈 확인/설치 |
| `1` | 작동 방식과 범위 확인 |
| `2` | Azure 및 Microsoft Graph 로그인 |
| `3` | 테스트 환경 설정 |
| `4` | Flask 포털 코드와 배포 ZIP 생성 |
| `5` | 변경 전 계획 미리 보기(WhatIf) |
| `6` | Azure App Service 생성 |
| `7` | Entra 로그인(Easy Auth) 구성 |
| `9` | 포털 코드 배포 |
| `10` | 로그인 연결, 앱 버전, 주요 경로, 상태 확인 |
| `11` | 포털 주소와 데모 순서 확인 |

**메뉴 8은 기본 데모에 필요하지 않습니다.** Live 권한을 부여하는 별도 작업입니다.

### 4. 포털에서 체험하기

1. Dashboard에서 **Sample request 생성**을 누릅니다.
2. 티켓을 열고 **SystemOwner / Security / SoD** 승인 항목을 모두 승인합니다.
3. **Eligible 실행**을 누릅니다.
4. Simulation 모드라면 `SimulatedEligible` 상태를 확인합니다.
5. **감사·증적** 메뉴에서 Evidence ZIP을 다운로드합니다.

### 5. Live 모드로 전환하려면 (선택)

이미 **같은 버전의 포털이 정상 배포된 경우**:

`2 → 5 → 8 → 10 → 포털에서 Live 실행`

- 메뉴 `8`은 App Service의 Managed Identity에 Microsoft Graph **애플리케이션 권한**을 부여하고 Live 모드로 전환합니다.
- 실제 역할 변경이 가능해지므로 관리자 승인 및 테스트 테넌트가 필요합니다.
- 메뉴 `10`의 배포·인증 검증 후 포털에서 실제 Eligible 요청을 테스트합니다. **메뉴 10의 PASS만으로 실제 Graph 쓰기 성공이 증명되는 것은 아닙니다.**
- 포털 코드가 변경되거나 버전·경로 검증이 실패한 경우에만 메뉴 `4`/`9`로 다시 생성·배포합니다.

## 정리하기

1. Live 모드였다면 포털의 **만료·회수** 메뉴에서 이 포털이 만든 Eligible을 필요한 범위에서 회수합니다.
2. Launcher 메뉴 `12`에서 증적을 내보냅니다.
3. 메뉴 `90`에서 삭제 대상을 미리 봅니다.
4. 메뉴 `99`에서 **Launcher가 추적한 배포 객체**를 정리합니다.

**주의:** 메뉴 `99`는 포털의 PIM Eligible을 일괄 회수하지 않습니다. Launcher가 새로 만든 **전용 리소스 그룹 전체를 삭제**할 수 있으므로 그 그룹에 다른 리소스를 넣지 마세요. 상태 파일을 보관하고 정리 범위를 확인하세요.

## 안전하게 사용하기 위한 주의사항

- **운영 환경에 그대로 배포하지 마세요.** 이 코드는 단일 인스턴스 SQLite를 사용하는 데모입니다.
- 승인 항목이 세 개 있다고 해서 **서로 다른 세 사람이 승인하도록 강제되는 것은 아닙니다.** 승인자 목록이 비어 있으면 로그인한 데모 사용자가 승인할 수 있습니다. 실제 운영에는 담당자별 권한 분리와 자기 승인 방지가 필요합니다.
- Live 모드의 Graph 권한은 강력합니다. 최소 권한, 승인 절차, 감사 및 정기 검토를 적용하세요.
- 실제 운영 전에는 별도의 접근제어, 비밀 관리, 중앙 로그, 데이터 보호, 네트워크 통제 및 안정적인 데이터 저장소가 필요합니다.
- Launcher는 데모용으로 `Publish-AzWebApp`을 사용합니다. 조직의 배포 보안 정책을 검토하세요.
- 생성된 `*-State.json`, 출력 폴더, ZIP 증적, 로그, 테넌트 식별자, 계정 정보, 비밀 값은 **공개 GitHub에 올리지 마세요.**
- 인증 앱에 생성되는 비밀 값은 기본 **7일 수명**입니다. 만료 전에 재구성해야 할 수 있습니다.
- SHA-256 목록은 파일 변경 여부를 확인하기 위한 정보이며, **변조 방지 저장소 자체를 제공하지는 않습니다.**

## 자주 묻는 질문

**Q. Entra 관리 센터 없이 모든 PIM 기능을 사용할 수 있나요?**  
A. 아닙니다. 이 샘플은 **요청·승인·Eligible 등록/회수**를 내부 포털에서 처리합니다. **실제 역할 활성화는 Entra PIM으로 이동**합니다.

**Q. Simulation도 실제 권한을 부여하나요?**  
A. 아니요. 티켓과 상태만 데모로 처리합니다.

**Q. 기존에 있던 Eligible도 삭제하나요?**  
A. 포털의 회수 기능은 포털이 생성하고 추적한 Eligible을 대상으로 설계되어 있습니다. 그래도 Live 실행과 정리 전에는 실제 대상과 상태를 확인하세요.

**Q. 실제 고객 ITSM과 바로 연결되나요?**  
A. 아닙니다. 현재는 **ITSM처럼 보이는 독립 샘플 포털**입니다. ServiceNow 등 실제 ITSM과의 연결은 별도 개발 범위입니다.

## 저장소에 권장하는 파일

```text
README.md                 # 한국어 소개 (이 파일)
README_EN.md              # English guide
Entra-PIM-ITSM-Financial-Portal-Launcher-v2.0.5.1.ps1
.gitignore
LICENSE                   # 배포자가 라이선스를 선택한 경우<img width="1536" height="1024" alt="EntraID_PIM_ITSM_Portal" src="https://github.com/user-attachments/assets/7103f84c-a6b2-4b5d-bd72-82fc0c3001d5" />

```

**공개 전 확인:** 실제 고객명, 이메일, 테넌트 ID, 구독 ID, 인증 비밀, 포털 주소 및 고객 전용 화면을 제거하세요. 고객 설명 PPT를 함께 공개하려면 화면과 메타데이터도 별도로 검토하세요.

---

**참고 자료:** 제공된 Launcher v2.0.5.1 및 고객 설명용 PPT v2.0.5.1을 기반으로 작성했습니다. 이 README는 소스의 기능 범위를 설명하며, 별도의 실제 배포 성공을 보증하지 않습니다.
