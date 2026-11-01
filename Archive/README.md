# 이전 CallTap · iCTRL 소스 보관함

`Legacy-CallTap-iCTRL/`은 정리 전 커밋 `92da8711984013fb786a504486e84e0432898834`의 Git 추적 파일을 원래 경로와 내용으로 보존한 스냅샷입니다. 자체 `.git`은 포함하지 않습니다.

현재 앱은 프로젝트 루트의 `Sources/`, `Native/`, `Scripts/`, `Tests/Policy/`에서 개발합니다. 빌드는 `.github/workflows/build-airrecord.yml`의 **Build AirRecord**를 사용하세요.

보관함에는 이전 XCTest Runner, Helper 확장, CLI·GUI 도구, 빌드 스크립트와 실험 문서가 있습니다. 과거 변경 기록은 당시 설명을 그대로 보존하며 현재 사용법은 루트 README와 `docs/START.ko.md`를 따릅니다.

이전 Helper의 Rust·Swift lease/wire 회귀 테스트는 현재 빌드 스크립트가 필요한 보관 소스를 명시적으로 읽어 실행합니다. Helper 확장이나 XCTest Runner가 현재 앱에 포함되는 것은 아닙니다.

보관된 Markdown 문서는 현재 앱의 빌드 리소스가 아닙니다. 라이선스·출처와 과거 실험을 확인할 때 참고하세요. `LICENSE`, `NOTICE.md`, `Native/IPB-LICENSE` 등 현재 프로젝트의 출처 자료도 유지합니다.
