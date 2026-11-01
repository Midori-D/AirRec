# AirRecord 1.1.6 · Helper 유지 실험

이 버전은 위치 권한 없이 장시간 통화 감시를 검증하기 위한 선택 기능을 포함합니다. 일반 녹음 자동화는 1.1.4의 같은 연결·메뉴 대기·한 번만 누르기를 유지합니다. Helper 유지의 기본값은 꺼짐입니다. 1.1.5에서는 기기의 양방향 연결 및 일반 백그라운드 시간 만료 뒤 유지 표시를 확인했습니다. 이후 앱 복귀 직후 응답 확인 실패와 재연결이 발생했으므로 상시 실행은 검증되지 않았습니다.

1.1.6은 오래된 heartbeat만으로 디버거를 곧바로 정리하지 않습니다. 입력을 보류하고 새 challenge를 보내며, 8초 이내의 일치하는 새 pong과 실제 추적 상태로만 복구합니다. 일반 heartbeat와 큐에 밀린 오래된 표본은 복구 근거가 되지 않습니다. 앱·Helper의 샘플 시점은 같은 기기의 monotonic uptime을 사용합니다. 이 수정은 응답 공백 동안 실행이 유지됐음을 증명하거나 iOS의 정지 제한을 제거하지 않습니다.

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
- 유지 판정은 양방향 continue 보고, 실제 worker 상태, 앱이 직접 읽은 P_TRACED, Helper가 읽은 P_TRACED, 샘플 시점 기준 6초 이내 heartbeat를 모두 요구합니다. 응답만 오래된 경우 별도 8초 challenge 재확인 중에는 입력을 중지합니다. 실제 추적 해제·작업 종료·IPC 종료는 재확인 대기 없이 중지합니다. detach 후 남을 수 있는 CS_DEBUGGED는 근거로 쓰지 않습니다.
- 일반 UIKit 실행 시간이 만료되면 assertion은 끝냅니다. 유효한 Helper 근거가 있을 때만 CallKit 감시를 유지합니다. 통화가 없을 때 AX 버튼 검사 polling은 하지 않습니다.
- 정상 중지는 앱→Helper 연결을 먼저 해제하고 그 다음 Helper→앱 연결을 해제합니다. 실행 중인 대상에는 interrupt를 보내지 않고 미리 확인한 detach-on-error 동작으로 연결 종료 시 해제합니다. 갑작스러운 IPC 손실에도 양쪽이 서로 정지시키지 않습니다. 이미 정지한 대상에만 detach 요청을 보내며 정리에는 3초 제한을 둡니다. 강제 종료·재부팅·VPN 교체에서 자동 복구를 보장하지 않습니다.
- 연결 손실·만료·사용자 중지는 새 입력을 철회합니다. 재확인 복구에서는 기존 준비 기한과 More·녹음 시작 예약을 유지하며 입력 기회를 새로 부여하지 않습니다.

## 다음 실기기 확인

업데이트한 뒤 연결 완료를 확인하고 AirRecord를 백그라운드로 둡니다. 다음 통화 시험에서는 AirRecord를 먼저 다시 열지 말고, 잠금 해제 상태에서 기본 전화로 직접 통화를 연결해 녹음 타이머를 확인합니다. 그 뒤 AirRecord의 최근 상태를 확인합니다. 전화 앱 열림 자동화에 ‘통화 감시 재개’가 있다면 그 동작으로 새로 깨운 결과와 장시간 유지 결과를 구분해야 합니다. 응답 재확인 성공만으로 공백 중 감시 성공을 주장하지 않습니다.

## 검증 범위

CI에서는 기존 AX 27개와 유지 RSP 15개 테스트, Swift 통화 정책·lease freshness·오래된 이벤트·IPC 경계 테스트를 실행합니다. 정상 앱과 Helper를 함께 빌드하고 ad-hoc 서명한 뒤 메타데이터와 arm64 구성을 검사합니다. 최종 설치 서명에 실제 디버그 허용이 있는지는 기기에서 다시 확인합니다.

Helper 확장의 수명과 서로 연결한 프로세스의 실제 동작은 기기 시험이 필요합니다. 장시간 수발신, 정지 상태, 화면 잠금·해제, 다른 앱 사용, 통화 종료 후 다음 통화, 유지 끄기, VPN 손실, 재부팅, 배터리 사용을 확인하기 전에는 실사용 안정성을 보장하지 않습니다.

설계 근거: [Apple의 debugger와 background 설명](https://developer.apple.com/forums/thread/796528), [StikJIT의 두 프로세스 설명](https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md#built-in-stikjit-embed-the-framework), [Apple extension 수명 제약](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html). 이 프로젝트는 StikJIT 코드를 포함하지 않고 기존 MIT idevice와 RSP 프로토콜로 전용 연결을 구현합니다.
