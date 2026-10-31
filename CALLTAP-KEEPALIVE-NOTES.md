# AirRecord 1.1.5 · Helper 유지 실험

이 버전은 위치 권한 없이 장시간 통화 감시를 검증하기 위한 선택 기능을 포함합니다. 일반 녹음 자동화는 1.1.4의 같은 연결·메뉴 대기·한 번만 누르기를 유지합니다. Helper 유지의 기본값은 꺼짐입니다. 아직 이 새 구조를 iPhone에서 설치하거나 장시간 실행한 결과는 없습니다.

## 설치와 사용

1. SideStore에 AirRecord를 독립 앱으로 설치합니다. **확장 유지**를 선택합니다. 내장 `AirRecordKeepAliveHelper.appex`는 별도 홈 화면 앱 슬롯은 쓰지 않지만 추가 App ID가 필요할 수 있습니다. App ID 제한이 남아 있다면 해제 후 시험합니다.
2. 기존 페어링·개발자 디스크를 준비하고 LocalDevVPN을 연결합니다. 새 데이터 컨테이너로 이동했다면 준비 파일을 다시 가져옵니다.
3. 앱에서 **백그라운드 유지 · 실험 → Helper 디버거 연결 유지**를 켭니다. 자동 시작도 켠 뒤 앱을 열어 둔 채 연결 완료를 기다립니다.
4. 두 프로세스의 실제 디버거 연결과 Helper 응답을 확인한 경우에만 연결 유지 중으로 표시합니다. `get-task-allow`가 없는 서명, 확장 제거, 기존 디버거 연결, 잘못된 페어링·DDI·VPN은 고정 오류로 표시합니다.
5. 일반 백그라운드 제한보다 긴 시간 동안 기기를 두고 수발신을 각각 확인합니다. 근접 센서로 검게 된 화면과 잠금 화면은 다릅니다. 현재 녹음 입력은 잠금 해제 조건을 유지합니다.
6. 자동 시작을 끄면 입력을 먼저 철회한 뒤 디버거를 비동기 해제합니다. 기본 녹음이 시작된 뒤에는 iOS가 녹음과 저장을 담당합니다.

LiveContainer guest는 이 앱의 확장을 OS에 등록하지 않으므로 새 유지 기능을 켤 수 없습니다. LiveContainer에서 기존 녹음 기능은 그대로 사용할 수 있으며 기존 백그라운드 제한도 유지됩니다. SideStore 단독 설치만으로 유지되는 것은 아니며, Helper의 실제 성공 확인이 필요합니다.

## 구현과 중지

- 앱이 loopback `127.0.0.1`의 임의 포트에서 한 세션만 받습니다. 무작위 256비트 nonce와 세션 ID를 사용하며, OS가 반환한 확장 PID와 Helper의 PID가 일치해야 페어링 자료를 보냅니다. 외부 주소를 입력받거나 임의 PID 명령을 제공하지 않습니다.
- 페어링 자료는 메모리에서만 교환하고 Helper 파일이나 로그에 저장하지 않습니다. 전화번호·이름·음성·AX 화면 본문도 이 채널에 보내지 않습니다.
- Helper가 앱에 attach한 뒤 continue하고, 앱의 별도 worker가 Helper에 attach한 뒤 continue합니다. 각 worker는 독립 터널과 Rust runtime을 사용합니다. 자기 자신에게 attach하지 않습니다.
- RSP no-ACK 협상과 detach-on-error 확인 뒤에만 attach합니다. 실제 PID 확인 후 continue합니다. 메모리·레지스터·breakpoint 수정과 kill 명령은 없습니다.
- 유지 판정은 양방향 continue 보고, 앱이 직접 읽은 P_TRACED, Helper가 읽은 P_TRACED, 6초 이내 heartbeat를 모두 요구합니다. detach 후 남을 수 있는 CS_DEBUGGED는 근거로 쓰지 않습니다.
- 일반 UIKit 실행 시간이 만료되면 assertion은 끝냅니다. 유효한 Helper 근거가 있을 때만 CallKit 감시를 유지합니다. 통화가 없을 때 AX 버튼 검사 polling은 하지 않습니다.
- 정상 중지는 앱→Helper 디버거를 먼저 해제하고 그 다음 Helper→앱 연결을 해제합니다. 서로 동시에 interrupt해서 두 프로세스가 멈추는 상황을 피합니다. 각 디버거 정리는 3초 제한 후 안전 연결 종료로 처리합니다. 강제 종료·재부팅·VPN 교체에서 자동 복구를 보장하지 않습니다.
- 연결 손실·만료·사용자 중지는 새 입력을 철회합니다. 이미 보낸 녹음 시작 예약은 재개 후에도 반복하지 않습니다.

## 검증 범위

CI에서는 기존 AX 27개와 유지 RSP 14개 테스트, Swift 통화 정책·lease freshness·오래된 이벤트·IPC 경계 테스트를 실행합니다. 정상 앱과 Helper를 함께 빌드하고 ad-hoc 서명한 뒤 메타데이터와 arm64 구성을 검사합니다. 최종 설치 서명에 실제 디버그 허용이 있는지는 기기에서 다시 확인합니다.

Helper 확장의 수명과 서로 연결한 프로세스의 실제 동작은 기기 시험이 필요합니다. 장시간 수발신, 정지 상태, 화면 잠금·해제, 다른 앱 사용, 통화 종료 후 다음 통화, 유지 끄기, VPN 손실, 재부팅, 배터리 사용을 확인하기 전에는 실사용 안정성을 보장하지 않습니다.

설계 근거: [Apple의 debugger와 background 설명](https://developer.apple.com/forums/thread/796528), [StikJIT의 두 프로세스 설명](https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md#built-in-stikjit-embed-the-framework), [Apple extension 수명 제약](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html). 이 프로젝트는 StikJIT 코드를 포함하지 않고 기존 MIT idevice와 RSP 프로토콜로 전용 연결을 구현합니다.
