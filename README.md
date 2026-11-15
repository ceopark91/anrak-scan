# 안락 스캔 (ANRAK SCAN)

아이폰 라이다(RoomPlan)로 방을 스캔해 평면도·천장도를 만들고, 결과를 **안락실측 백업 JSON**으로 보내는 앱.

- iOS 17 이상, 라이다가 있는 아이폰 프로 모델
- 빌드: main에 올리면 GitHub Actions가 서명 없는 `AnrakScan.ipa`를 만듦 (Actions → 최신 실행 → Artifacts)
- 설치: Windows PC의 Sideloadly로 무료 애플 ID 서명 후 설치 (7일마다 재서명, Sideloadly 자동 갱신)
- 변환 검산: `python3 tools/test_geometry.py`
