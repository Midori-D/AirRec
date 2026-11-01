# AirRecord · 에어레코드

iPhone의 기본 통화 화면에서 ‘더 보기 → 통화 녹음’을 순서대로 눌러 녹음 시작을 돕는 앱입니다. 현재 버전은 **1.1.8 / 빌드 13**입니다. 빌드 13은 소스 정리와 학습 안내를 반영한 재빌드이며, 1.1.8의 통화 감시·위치 대기 동작은 그대로입니다.

## 먼저 읽을 문서

- [소스 공부와 빌드 시작하기](AIRRECORD-START.ko.md)
- [현재 기능과 변경 기록](CALLTAP-AX-NOTES.md)
- [위치 서비스를 이용한 장시간 대기](CALLTAP-LOCATION-NOTES.md)
- [기반 프로젝트 iCTRL의 원래 안내](README-UPSTREAM.md)
- [이전 CallTap 안내](docs/README-CALLTAP-LEGACY.md)

## 빌드

Windows에서는 이 폴더의 변경을 GitHub에 커밋·푸시한 뒤, 저장소의 **Actions → Build CallTap AX without XCTest → Run workflow**를 실행합니다. 해당 Actions는 선택한 Git 커밋을 macOS의 Xcode 27에서 빌드합니다.

```sh
# macOS + Xcode 27 + XcodeGen에서 직접 빌드할 때
bash Scripts/build-calltap-rawax.sh
```

Actions 산출물은 `CallTap-AX-experimental`이며 안에 `CallTap-AX-unsigned.ipa`가 있습니다. SideStore에서 서명해 독립 앱으로 설치합니다. 로컬 `release/` 폴더는 IPA와 빌드 기록을 보관하는 용도로 Git에서 제외되어 있습니다.

## 주요 소스

| 경로 | 역할 |
| --- | --- |
| `iCTRLApp/Views/AirRecordGlassView.swift` | 홈·설정·기록과 Liquid Glass 하단 메뉴 |
| `iCTRLApp/Automation/CallTapRawAXMonitor.swift` | 통화 상태와 자동 시작 제어 |
| `iCTRLApp/Automation/AirRecordLocationKeepAlive.swift` | 선택형 백그라운드 위치 대기 |
| `iCTRLApp/DDI/` | 페어링·LocalDevVPN·개발자 디스크 준비 |
| `RawAX/` | 개발자 접근성 서비스 통신 |
| `project.yml` | Xcode 대상·소스 구성 |
| `.github/workflows/build-calltap-rawax.yml` | 현재 IPA를 만드는 GitHub Actions |

`iCTRLApp`, `iCTRLKit` 등의 디렉터리 이름은 프로젝트에서 참조하는 실제 경로이므로 유지했습니다. 이전 XCTest·Helper 실험 소스도 보존했으며, 현재 일반 앱 빌드에는 Helper 확장이나 XCTest Runner를 넣지 않습니다.

## 실행 조건

iOS 27 대상이며 LocalDevVPN·페어링·개발자 디스크 준비가 필요합니다. 위치 대기는 사용자가 선택하며 좌표를 저장하거나 전송하지 않습니다. 강제 종료·재부팅 후에는 앱을 다시 열어 준비해야 합니다. 녹음과 저장은 iOS가 처리하므로 실제 녹음 타이머와 저장 결과를 확인하세요.

Based on [iCTRL](https://github.com/OpenMinis/iCTRL) (Apache-2.0). See [LICENSE](LICENSE), [NOTICE](NOTICE.md), and the source attribution in [RawAX notes](CALLTAP-AX-NOTES.md).
