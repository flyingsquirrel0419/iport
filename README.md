# iPort

**아이폰에서 스팀 PC 게임을 다운로드해 폰에서 직접 실행하는 앱.** 스트리밍이 아니라 폰의 CPU/GPU로 돌립니다.
[Playport](https://github.com/playportdev/playport)(GPL-3.0)를 참고·재사용해 앱 계층을 새로 구성했고, **빌드를 쉽게** 만드는 데 초점을 뒀습니다.

| 기능 | 내용 |
| --- | --- |
| Steam 계정 | QR 코드(Steam 모바일 앱으로 스캔) 또는 아이디/비밀번호 + Steam Guard |
| 라이브러리 | 보유한 Windows 게임 전체, 아트워크, 검색, 설치됨 / ARM 빌드 필터 |
| **ARM 우선 다운로드** | 게임이 Windows-on-ARM(arm64) 디포를 제공하면 그것을 받아 **네이티브 ARM64**로 실행, 없으면 x64 빌드를 받아 FEX로 변환 실행 |
| 다운로드 매니저 | 큐(한 번에 하나), 진행률·속도·남은 시간, 일시정지/재개/취소/먼저 받기/순서 변경, 전체 일시정지, 앱이 죽어도 이어받기(청크 저널), Wi-Fi 전용 옵션, 완료 알림, 업데이트·검증·복구·삭제 |
| 터치 Xbox 컨트롤러 | 좌/우 플로팅 스틱, 8방향 D-pad, ABXY(버튼 사이 슬라이드), LB/RB/LT/RT, View/Menu, L3/R3, 햅틱 |
| **컨트롤러 연결 시 자동 숨김** | Xbox/듀얼센스/MFi 패드가 연결되면 터치 컨트롤러가 사라지고, 마지막 패드가 끊기면 다시 나타남. 화면을 탭하면 잠깐 다시 보이게 할 수도 있음(설정) |
| 레이아웃 편집기 | 버튼 이동·크기·숨기기·투명도, 전역 또는 게임별 저장 |
| 멀티 컨트롤러 | 최대 4개를 XInput 슬롯 0–3에 순서대로 배정 |
| 게임 내 메뉴 | 패드의 Xbox/Home 버튼, 터치 ◎, 또는 모서리 일시정지 버튼 → 일시정지/재개/레이아웃/종료 |
| 실행 설정(게임별) | 그래픽 백엔드(Vulkan: DXVK·vkd3d-proton / Metal: DXMT), 렌더 해상도, HUD, 인자, 환경변수 |
| 아이폰다운 UI | 가로 전용, 좌측 레일(홈·라이브러리·다운로드·설정), 다크 모드, 파일 앱에서 게임 폴더 접근 |

## 가장 쉬운 빌드: 맥 없이 (GitHub Actions)

1. 이 저장소를 GitHub에 올리거나 Fork 합니다.
2. **Actions › Build IPA › Run workflow** 를 누릅니다.
3. 끝나면 실행 결과의 **Artifacts** 에서 `iPort-ipa` 를 받습니다 → `iPort.ipa`.
4. SideStore / AltStore / Sideloadly / LiveContainer 로 설치합니다. 서명 도구가 *Increased Memory Limit* 권한을 유지하도록 하세요.

## 맥에서 빌드

```sh
git clone <이 저장소> iport && cd iport
make ipa            # → dist/iPort.ipa  (Xcode 필요; 서브모듈과 XcodeGen은 자동으로 준비)
```

Xcode 프로젝트를 직접 열고 싶으면 `make project` 후 `iPort.xcodeproj` 를 엽니다.

## 두 단계 구조 (왜 빌드가 쉬운가)

```
┌──────────────────────────────── iPort.app ────────────────────────────────┐
│ SwiftUI 앱 (App/Sources)            ← 매번 빌드, 1~3분                     │
│   라이브러리 · 다운로드 매니저 · 터치 패드 · 컨트롤러 · 실행                │
│ IPortCore (Packages/IPortCore)     ← 순수 Swift, Linux에서도 `make test`  │
│ SteamClientKit (vendor/playport)   ← Steam CM 프로토콜·디포·CDN·설치       │
│ iport_runtime.h  (C 브리지, 한 개의 ABI)                                    │
├────────────────────────────────────────────────────────────────────────────┤
│ Windows 런타임 (Runtime/)           ← 한 번 빌드해서 배포, 이후엔 다운로드  │
│   Wine(iOS 패치) · FEX(x86→ARM64) · DXVK · vkd3d-proton · DXMT ·            │
│   KosmicKrisp(Vulkan on Metal) · Steam API 에뮬레이터                       │
└────────────────────────────────────────────────────────────────────────────┘
```

* **런타임 없이**(`make ipa`) 빌드해도 앱 전체(로그인, 라이브러리, 다운로드, 터치/패드, 레이아웃 편집기)가 동작합니다. Play 를 누르면 "런타임이 없는 빌드"라고 안내합니다.
* **런타임 포함**(`make runtime && make ipa RUNTIME=1`): `runtime.lock` 에 적힌 미리 빌드된 런타임 아카이브를 받아 정적 링크합니다. 툴체인이 필요 없습니다.
* **런타임 직접 빌드**(`make runtime-from-source`, x86-64 Linux): Playport의 파이프라인(`vendor/playport/pp build --to notices`)으로 Wine/FEX/Mesa 등을 핀 고정 버전 + 패치로 빌드하고 `dist/iport-runtime-<commit>.tar.gz` 로 묶습니다. 수 시간·대용량 디스크와 `vendor/playport/docs/BUILDING.md` 의 툴체인(llvm-mingw, xtool로 만든 iOS SDK, ld64, Rust)이 필요합니다. **핀당 한 번만** 하고, 결과물을 GitHub Release에 올린 뒤 `runtime.lock` 에 URL과 sha256을 적으면 모두가 `make runtime` 으로 받아 씁니다. Actions 에서는 저장소 변수 `IPORT_RUNTIME_URL` / `IPORT_RUNTIME_SHA256` 를 설정하고 `runtime` 체크박스를 켜면 됩니다.

## 폰에서 실행 조건

* **iOS 26 이상**(런타임의 JIT 방식), 개발자 모드 켜기.
* **JIT**: StikDebug(+ LocalDevVPN)로 iPort에 JIT 활성화, 또는 LiveContainer 에서 JIT로 실행. 게임 시작 시 JIT가 없으면 "JIT 대기" 화면과 StikDebug 열기 버튼이 나옵니다.
* **Increased Memory Limit** 권한을 유지하는 서명.
* Wine은 앱 프로세스당 게임 하나만 실행합니다. 게임을 끝내면 iPort를 닫았다가 다시 여세요(종료 화면에서 안내).

## "ARM용으로 다운로드"의 실제 의미

Steam의 대부분 PC 게임은 **x86/x64 Windows 빌드만** 있습니다. iPort는 앱의 디포 목록에서 Windows-on-ARM(arm64) 디포를 찾으면 그것만(+공용 데이터 디포) 받아 FEX 없이 네이티브로 실행하고, 없으면 x64 빌드를 받아 ARM64EC + FEX로 실행합니다(라이브러리의 *ARM builds* 필터, 게임 페이지의 배지로 표시). 설정에서 끌 수 있습니다. 로직: `Packages/IPortCore/Sources/IPortCore/DepotPolicy.swift`.

## 저장소 구조

```
App/Sources/
  App/        진입점, 경로, 설치 목록·설정·레이아웃 저장소
  Steam/      Steam 계정(로그인·라이브러리·아트), 다운로드 드라이버(TitleInstaller + ARM 정책)
  Downloads/  다운로드 매니저(큐 래퍼, 백그라운드, 네트워크, 알림)
  Input/      GameController 허브, 멀티터치 Xbox 패드, 레이아웃 편집기
  Runtime/    게임 세션(JIT→Wine→실행→대기), 플레이 화면, 게임 내 메뉴, 키보드
  Views/      홈·라이브러리·게임 상세·다운로드·설정·로그인
App/RuntimeBridge/  iport_runtime.h/.c — 런타임 C ABI(런타임 없으면 스텁)
Packages/IPortCore/ 게임패드 모델, 터치 해석기, 컨트롤러 중재, 다운로드 큐, ARM 디포 정책, 실행 계획 (+테스트 29개)
vendor/playport/    Playport (서브모듈, 커밋 고정) — SteamClientKit/ContentKit 및 런타임 소스
scripts/            build-ipa · fetch-runtime · build-runtime · pack-runtime · gen-project
project.yml         XcodeGen 스펙 (런타임 마커는 gen-project.py가 채움)
```

## 테스트

```sh
make test     # IPortCore: 터치 해석, 스틱 데드존, D-pad 8방향, 패드 연결 시 터치 숨김, 슬롯 배정,
              # 다운로드 큐(순서/일시정지/재개/취소/차단/실패/영속화), ARM 디포 선택, 실행 계획
```

## 알려진 한계

* 앱(SwiftUI) 부분은 macOS/Xcode가 없는 환경에서 작성되어 이 저장소 안에서 컴파일 검증을 하지 못했습니다. 첫 `make ipa` / Actions 실행에서 나오는 컴파일 오류는 이슈로 알려 주세요. IPortCore 와 C 브리지(양쪽 모드)는 검증됨.
* 런타임 포함 빌드는 Playport 파이프라인 산출물에 의존하며, 런타임 연동(브리지)은 실기기에서 아직 검증되지 않았습니다.
* GOG/Epic/Battle.net, 클라우드 세이브 동기화, 업적 업로드, 마우스/키보드 터치 모드, 자동 재실행(idevice)은 Playport에는 있지만 iPort에는 아직 없습니다.
* DRM(Denuvo 등)이나 안티치트가 있는 게임은 실행되지 않습니다. 호환 목록: <https://playport.dev/compatibility/>

## 라이선스

GPL-3.0-or-later (`LICENSE`). Playport, Wine, FEX, DXVK, vkd3d-proton, DXMT, Mesa 등의 라이선스와 고지는 런타임 아카이브의 `Licenses/` 에 포함되어 앱에 함께 들어갑니다. 런타임 IPA를 배포한다면 GPL에 따라 소스(이 저장소 + 고정된 `vendor/playport` 커밋)도 함께 제공해야 합니다.
