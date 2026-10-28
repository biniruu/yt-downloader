# 🎬 YouTube 8K Downloader for macOS

<div align="center">

![macOS 14.0+](https://img.shields.io/badge/macOS-14.0%2B%20(Sonoma)-black?style=flat-square&logo=apple)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange?style=flat-square&logo=swift)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI%20%2F%20Observation-blue?style=flat-square)
![Architecture](https://img.shields.io/badge/Architecture-Actor%20Concurrency-brightgreen?style=flat-square)
![Version](https://img.shields.io/badge/Release-v1.3.2%20(Build%208)-red?style=flat-square)

**macOS를 위한 고성능 YouTube 8K/4K/FHD 비디오 & 재생목록 다운로더**  
QuickTime Player 코덱 호환성 자동 감지, 다국어(한국어) 더빙 우선 매칭, 직렬 대기열 및 완벽한 프로세스 정리 엔진 탑재

</div>

---

## 📌 주요 기능 (Key Features)

- **8K UHD / 초고화질 무손실 다운로드 & Muxing**
  - 최대 4320p(8K), 2160p(4K), 1440p(2K), 1080p(FHD) 등 원본 해상도 완벽 지원
  - 고화질 비디오 스트림과 최고음질 오디오 스트림을 분리 다운로드 후 자동 무손실 병합
- **QuickTime Player 호환성 지능형 판별**
  - 다운로드 전 VP9 / AV1 / Opus 코덱 여부를 사전 분석하여 QuickTime 호환 여부 뱃지 노출
  - 1080p 이하 영상에 대해 `[🍎 QuickTime 호환 (MP4 변환)]` vs `[⚡️ 원본 유지 (WebM/빠름)]` 선택 옵션 제공
- **한국어 다국어 더빙 트랙 우선 매칭**
  - 여러 언어의 오디오 트랙이 포함된 영상에서 한국어(`ko`) 오디오 트랙 자동 우선 매칭
- **재생목록(Playlist) 초고속 파싱 & 일괄 다운로드**
  - `list=` 파라미터 감지 시 1~2초 내에 재생목록을 초고속 파싱(`--flat-playlist`)
  - 인라인 스크롤 체크리스트를 통한 개별 영상 선택/해제 및 전체 선택/해제
  - 백그라운드 실시간 해상도 탐색 및 `⭐️ 원본 최고 화질 (각각 자동)` 옵션 지원
- **Swift Concurrency 기반 직렬 대기열 (`DownloadQueueActor`)**
  - 시스템 및 네트워크 과부하를 막는 1개씩 순차 처리 직렬 큐 엔진
  - 다운로드 진행률, 병합 상태, 다운로드 속도 실시간 모니터링
- **대기/다운로드 중 작업 즉시 강제 종료 & 디스크 청소 (v1.3.2)**
  - 대기열의 모든 상태(대기 중, 다운로드 중, 병합 중, 에러 등)에서 `[삭제]` 상시 지원
  - 다운로드 중단 시 `pkill` 기반 프로세스 트리(`/opt/homebrew/bin/yt-dlp` 및 자식 `ffmpeg`) 즉시 강제 종료
  - 다운로드 중단 시 남겨지는 `*.part`, `*.ytdl`, `*.temp`, 임시 분리 스트림(`.f...`) 즉시 자동 청소
- **macOS Finder 스타일 파일명 중복 보존**
  - 동일한 이름의 파일이 존재할 경우 덮어쓰지 않고 `파일명 2.mp4`, `파일명 3.mp4`로 자동 보존
- **`ffprobe` 디스크 실측 검증 및 로깅**
  - 다운로드 완료 후 실제 파일의 코덱을 실측 검사하여 `[H.264 / AAC]` 등의 실제 코덱 뱃지 표기
  - 시스템 로그(`/tmp/ytdlp_app.log`)에 상세 실행 내역 기록

---

## ⚠️ 필수 사전 요구사항 (External Dependencies)

> [!IMPORTANT]
> 본 애플리케이션은 **외부 CLI 바이너리(yt-dlp, ffmpeg 등)를 앱 번들에 내장하지 않습니다.**  
> 시스템에 설치된 고성능 CLI 엔진을 호출하여 동작하므로, **앱 실행 전 로컬 머신에 아래 엔진들이 반드시 설치되어 있어야 합니다.**

Apple Silicon Mac 기준, [Homebrew](https://brew.sh/)를 통해 아래 도구들을 설치해야 합니다:

```zsh
# Homebrew를 통한 필수 외부 엔진 설치
brew install yt-dlp ffmpeg deno
```

### 필수 외부 엔진 경로
앱은 다음 고정 경로에서 실행 바이너리를 참조합니다:
- **`yt-dlp`**: `/opt/homebrew/bin/yt-dlp` (최신 YouTube 영상/오디오 스트림 추출 엔진)
- **`ffmpeg`**: `/opt/homebrew/bin/ffmpeg` (스트림 무손실 병합 및 코덱 트랜스코딩)
- **`ffprobe`**: `/opt/homebrew/bin/ffprobe` (다운로드 완료된 미디어 파일의 실제 코덱 실측 검증)
- **`deno`**: `/opt/homebrew/bin/deno` (최신 yt-dlp JS 챌린지 및 스크립트 실행 지원)

> [!TIP]
> YouTube의 스트리밍 알고리즘 변경에 대응하기 위해 주기적으로 `yt-dlp`를 최신 버전으로 업데이트하는 것을 권장합니다:
> ```zsh
> brew upgrade yt-dlp
> ```

---

## 🛠 기술 스택 (Tech Stack)

| 분류 | 세부 사양 |
|---|---|
| **OS 타겟** | macOS 14.0+ (Sonoma 이상, `arm64-apple-macosx14.0`) |
| **개발 언어** | Swift 5.9 |
| **UI 프레임워크** | SwiftUI, Swift Observation Framework (`@Observable`) |
| **동시성 처리** | Swift Concurrency (`Actor`, `-strict-concurrency=complete`) |
| **외부 엔진** | `yt-dlp`, `ffmpeg`, `ffprobe`, `deno` (Homebrew CLI 기반 연동) |
| **보안 설정** | App Sandbox 비활성화 (CLI 프로세스 제어용), Hardened Runtime 활성화 |
| **기본 저장소** | 사용자 다운로드 폴더 (`~/Downloads`) |

---

## 📂 프로젝트 구조 (Project Structure)

```
YouTube8KDownloader/
├── App/
│   └── YouTube8KDownloaderApp.swift    # 앱 진입점 및 창 닫기 시 프로세스 완전 종료 처리
├── Models/
│   ├── VideoQuality.swift              # 8K ~ 480p 해상도 정의 및 yt-dlp 포맷 파라미터 빌더
│   ├── VideoMetadata.swift             # 단일 영상 메타데이터, QuickTime 호환성 판별
│   ├── PlaylistMetadata.swift          # 재생목록 메타데이터, 실제 지원 화질 필터링
│   └── DownloadQueueItem.swift         # 다운로드 대기열 아이템 모델 및 상태 관리
├── Services/
│   ├── YTDLPService.swift              # yt-dlp/ffmpeg 프로세스 실행, 트리 강제 종료 및 임시 파일 정리
│   └── DownloadQueueActor.swift        # Swift Concurrency 기반 1개씩 순차 처리 직렬 큐 액터
├── ViewModels/
│   └── DownloaderViewModel.swift       # 앱 상태 관리, URL 분석 요청, 대기열 추가 및 즉시 삭제 제어
└── Views/
    ├── MainContentView.swift          # 메인 윈도우 루트 레이아웃 (세로 리사이징 최적화)
    ├── AnalyzerHeaderView.swift       # 상단 분석 패널 (높이 고정, 버전 뱃지, 재생목록 체크리스트)
    └── QueueItemRowView.swift          # 대기열 항목 뷰 (상시 삭제 버튼, 실측 코덱 뱃지, 진행률)
```

---

## 🏗️ 빌드 및 설치 (Build & Deployment)

본 프로젝트는 Xcode 프로젝트 파일(`YouTube8KDownloader.xcodeproj`)을 사용하거나 터미널에서 `swiftc`로 직접 빌드할 수 있습니다.

### 터미널 CLI 빌드 스크립트

```zsh
# 1. Swift 소스 컴파일
xcrun swiftc -module-cache-path /tmp/swift-module-cache \
  -target arm64-apple-macosx14.0 -O -strict-concurrency=complete -parse-as-library \
  YouTube8KDownloader/App/YouTube8KDownloaderApp.swift \
  YouTube8KDownloader/Models/VideoQuality.swift \
  YouTube8KDownloader/Models/VideoMetadata.swift \
  YouTube8KDownloader/Models/PlaylistMetadata.swift \
  YouTube8KDownloader/Models/DownloadQueueItem.swift \
  YouTube8KDownloader/Services/YTDLPService.swift \
  YouTube8KDownloader/Services/DownloadQueueActor.swift \
  YouTube8KDownloader/ViewModels/DownloaderViewModel.swift \
  YouTube8KDownloader/Views/MainContentView.swift \
  YouTube8KDownloader/Views/AnalyzerHeaderView.swift \
  YouTube8KDownloader/Views/QueueItemRowView.swift \
  -o "build/Release/YouTube 8K Downloader.app/Contents/MacOS/YouTube 8K Downloader"

# 2. 번들 Hardened Runtime 코드 서명
codesign --force --sign - \
  --entitlements YouTube8KDownloader/YouTube8KDownloader.entitlements \
  --options runtime "build/Release/YouTube 8K Downloader.app"

# 3. /Applications 폴더로 배포 및 서명 갱신
rm -rf "/Applications/YouTube 8K Downloader.app"
cp -R "build/Release/YouTube 8K Downloader.app" "/Applications/"
codesign --force --sign - \
  --entitlements YouTube8KDownloader/YouTube8KDownloader.entitlements \
  --options runtime "/Applications/YouTube 8K Downloader.app"
```

---

## 📋 버전 릴리스 노트 (Release Highlights)

### `v1.3.2 (Build 8)`
- **대기/다운로드 중 작업 상시 삭제 및 즉각 강제 종료 UI 도입**
  - 대기열의 모든 상태(대기 중, 다운로드 중, 병합 중, 완료, 에러)에서 `[삭제]` 버튼 상시 노출
  - `/usr/bin/pkill -TERM -P <PID>`를 적용하여 `yt-dlp`와 하위 `ffmpeg` 프로세스까지 누수 없이 즉시 종료
- **미완료 임시 파일 자동 청소 엔진 (`cleanupIncompleteFiles`)**
  - 작업 취소 시 타겟 파일 및 `*.part`, `*.ytdl`, `*.temp`, 중간 스트림(`.f...`) 파일들을 디스크에서 즉시 삭제
  - 이미 완료된 기존 파일을 보호하기 위해 최근 10분 내 수정 파일 필터링 및 2차 지연 청소(300ms) 적용

### `v1.3.1 (Build 7)`
- **윈도우 리사이징 레이아웃 최적화**
  - 창을 세로로 확장할 때 상단 분석 패널(`AnalyzerHeaderView`) 높이를 고정(`.fixedSize`)
  - 모든 확장 공간을 하단 대기열 스크롤 뷰(`ScrollView`)에 전담 할당하여 뷰 왜곡 방지

### `v1.3.0`
- **재생목록(Playlist) 초고속 파싱 & 일괄 다운로드**
  - `--flat-playlist -J` 기반 초고속 목록 파싱 및 인라인 스크롤 체크리스트 UI
  - 재생목록 개별 영상 화질 보존 `⭐️ 원본 최고 화질 (각각 자동)` 옵션 도입

### `v1.2.2`
- **macOS Finder 스타일 파일명 중복 보존**
  - 중복 파일 발견 시 기존 파일을 덮어쓰지 않고 순차 번호(` 2.mp4`, ` 3.mp4`) 부여

### `v1.2.1`
- **오디오/비디오 스트림 분리 격리**
  - 360p 통합 스트림(포맷 18)의 오인식 방지 및 순수 오디오 스트림 분리 파이프라인 정립

---

## 📄 라이선스 및 면책 조항 (Disclaimer)

- 본 프로그램은 개인적인 연구 및 오프라인 백업 용도로 제작되었습니다.
- 다운로드하는 콘텐츠의 저작권 및 이용 약관은 해당 플랫폼(YouTube 등)과 콘텐츠 소유자의 규정을 따르며, 저작권 침해에 대한 책임은 사용자 본인에게 있습니다.
- `yt-dlp`, `ffmpeg`, `deno`는 각 해당 프로젝트의 고유 오픈소스 라이선스에 따라 배포됩니다.
