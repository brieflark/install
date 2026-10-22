#!/bin/bash
# Brieflark 맥 한 줄 설치. 정본 모델은 Windows 한 줄 설치(.claude/launcher/windows/install.ps1)이고 단계·문구·신뢰 경계를 그대로 맞춘다.
# 설계: wiki/drafts/2026-10-20 - Windows 한 줄 설치 설계안.md
#
# 이 파일은 손으로 실행하지 않는다. `.claude/tools/install_oneliner.py --os mac` 이 만든 한 줄이 커밋 고정 raw 주소에서 이 파일을
# 임시 파일로 받고, 그 파일을 설명자 3·4로 두 번 연 뒤 지운다(디스크에 남지 않는다). 4로 SHA256 을 대조하고, 맞을 때만 3을 `bash` 에 넘긴다.
# 그래서 (1) BOM 없는 UTF-8 + LF 로 저장하고 (2) 저장소에서는 .gitattributes 의 `-text` 로 줄 끝 변환을 막는다(해시가 곧 서빙 바이트).
# 맥 기본 bash 3.2 에서 돈다: 연관 배열·${var,,}·mapfile 을 쓰지 않고, set -u 에서 빈 "$@"·빈 배열을 펼치지 않는다.
#
# 원칙: 관리자 비밀번호(sudo)를 쓰지 않고, 모든 설치는 사용자 폴더(~/.local, ~/.bun)에 한다. 예외는 1단계의 Apple 명령줄 도구
# (Command Line Tools)뿐인데, 그것도 이 스크립트가 설치하지 않고 Apple 설치 창(xcode-select --install)을 열어 준 뒤 멈춘다.
# 설치 마법사는 "대신 실행 안 함"(setup_prereq.py)이고, 이 스크립트는 "붙여넣은 스크립트가 단계마다 묻고 설치"하는 예외다.
#
# 단계 (있으면 건너뛰고, 없으면 이름·출처·설치 위치를 보인 뒤 Enter):
#   0 점검   1 Git(명령줄 도구)   2 uv   3 bun   4 Node.js   5 Claude Code   6 GitHub CLI·로그인   7 Google Cloud CLI   8 제품 받기 + 서명 확인   9 설치 마법사
#
# 받는 것의 무결성:
#   uv·bun·Node.js·GitHub CLI·gcloud — 고정 버전 + 내장 SHA256(맞지 않으면 "공지와 다른 파일" 로 멈춘다). install.ps1 과 같다.
#   Claude Code — Anthropic 공식 설치 스크립트(install.ps1 과 같은 출처 원칙). 스크립트 자체는 HTTPS 로만 믿고, 그 스크립트가 같은 서버의
#     manifest.json 의 SHA256 과 대조하며, 이 스크립트가 설치 뒤 Anthropic 의 Apple 개발자 서명(팀 ID)을 다시 확인한다.
#     공식 스크립트는 파이프(curl | sh)로 돌리지 않고 파일로 다 받은 뒤 돌린다(중간에 끊긴 스크립트가 반만 실행되지 않게).
#   gcloud 맥 압축에는 Python 이 들어 있지 않다(구글 install.sh 는 python.org 설치 파일을 관리자 권한으로 깐다) → uv 가 관리 Python 3.12 를
#     ~/.local/bin/python3.12 로 두고, gcloud 는 PATH 에서 python3.12 를 찾는다(uv 는 받는 Python 의 SHA256 을 대조한다).
#
# 시험용 환경변수 (사용자에게 안내하지 않는다):
#   BRIEFLARK_INSTALL_ROOT   제품 폴더를 ~/Brieflark 대신 이 절대 경로로 (운영 설치와 분리해 시험할 때).
#   BRIEFLARK_INSTALL_YES=1  "Enter를 누르면" 질문을 묻지 않고 진행 (자동 시험용).
#   BRIEFLARK_SKIP_WIZARD=1  9단계(마법사)를 건너뛴다 (운영 맥에서는 설치 가드가 멈추는 것이 정상).

set -euo pipefail

# ---- 고정값 (바꾸면 .claude/launcher/macos/test_install_sh.py 가 정본·install.ps1 과 짝을 확인한다) ------------------------
PRODUCT_URL='https://github.com/brieflark/brieflark.git'

# 릴리스 서명 공개 키 줄: 현재 + 예비. .claude/trust/allowed_signers 의 키 줄, install.ps1 의 $EmbeddedSigners 와 글자 그대로 같아야 한다(시험이 확인).
EMBEDDED_SIGNER_1='release@brieflark.invalid namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE7DkGEQhcGOIZk7SKYV2Iaht/cADbs+Lb825qtVdYiW'
EMBEDDED_SIGNER_2='release@brieflark.invalid namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMvcwRfBrbmxMp9tXDxShD6fbqP+BJOePHZ5f06qILEz'

# uv·bun: 공식 GitHub 릴리스 압축. 버전은 install.ps1 과 같다. 해시 = 2026-10-22 받아 잰 값 = 공식 sha256.sum·SHASUMS256.txt 의 값.
UV_VERSION='0.13.4'
UV_URL_ARM64='https://github.com/astral-sh/uv/releases/download/0.13.4/uv-aarch64-apple-darwin.tar.gz'
UV_SHA256_ARM64='e0b1d4743ce64c55d9f0f4a444afa6b81125680070ee04e853fcd0f6c1ebf8f1'
UV_URL_X64='https://github.com/astral-sh/uv/releases/download/0.13.4/uv-x86_64-apple-darwin.tar.gz'
UV_SHA256_X64='7be2dcd316122f4b3e5a0a7889f6248266c14425374e105ff7dc9779184603a6'

BUN_VERSION='1.4.3'
BUN_URL_ARM64='https://github.com/oven-sh/bun/releases/download/bun-v1.4.3/bun-darwin-aarch64.zip'
BUN_SHA256_ARM64='80afd4c069b46a6fa8f3ec520bebc750a7843e4a8d5b9583d29ad436c00a3403'
BUN_URL_X64='https://github.com/oven-sh/bun/releases/download/bun-v1.4.3/bun-darwin-x64.zip'
BUN_SHA256_X64='62660e6438eb872278877acca77e1152d5d031324df368d4a81b428211489d2d'

# Node.js: nodejs.org 공식 릴리스 tar.gz. 버전은 install.ps1 과 같다. 해시는 2026-10-22 맥에서 받아 잰 값 = 공식 SHASUMS256.txt 의 값.
NODE_VERSION='24.22.0'
NODE_URL_ARM64='https://nodejs.org/dist/v24.22.0/node-v24.22.0-darwin-arm64.tar.gz'
NODE_SHA256_ARM64='6a9724d9b50a5f22b4816cded441b5a8d9ddae546191a5e5b7efa5a5e2ee26d5'
NODE_URL_X64='https://nodejs.org/dist/v24.22.0/node-v24.22.0-darwin-x64.tar.gz'
NODE_SHA256_X64='495e3f273c645f3c4677d438304cdfc701729ea5dec5728f5c8e76a2dece4b91'

# GitHub CLI: cli/cli 공식 릴리스 macOS zip. 버전은 install.ps1 과 같다. 해시 = 2026-10-22 받아 잰 값 = 공식 gh_2.102.0_checksums.txt 의 값.
GH_VERSION='2.102.0'
GH_URL_ARM64='https://github.com/cli/cli/releases/download/v2.102.0/gh_2.102.0_macOS_arm64.zip'
GH_SHA256_ARM64='da922c20d1792e5b2cbf375593d7a658acf034c12c84e007e71c76ef959c337e'
GH_URL_X64='https://github.com/cli/cli/releases/download/v2.102.0/gh_2.102.0_macOS_amd64.zip'
GH_SHA256_X64='b245f24eb2bf5f75b426b4c26da3651a107f8d5b6f4fddfbfccc5679041378b3'

# Google Cloud CLI(gcloud): 구글 공식 versioned archive (맥 arm / x86_64). 버전은 install.ps1 과 같다(590.0.0).
# 공식 문서(downloads-versioned-archives)는 맥 파일의 SHA256 을 최신판에만 싣는다 → 2026-10-22 받아 잰 SHA256 을 고정하고,
# 구글 저장소(storage.googleapis.com/cloud-sdk-release)의 MD5 머리글이 받은 파일과 같은지 확인했다. 설치 스크립트(install.sh) 없이 풀기만 한다.
GCLOUD_VERSION='590.0.0'
GCLOUD_URL_ARM64='https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-590.0.0-darwin-arm.tar.gz'
GCLOUD_SHA256_ARM64='a3327108b808f3cc42aa57912bb1b175ccae16fe6cedb90fdd05cd84f8b89b49'
GCLOUD_URL_X64='https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-590.0.0-darwin-x86_64.tar.gz'
GCLOUD_SHA256_X64='3b1380b3118e9bb89dc108b6eb291e41468289415dcd2a33cdfc55e2570d3ede'

# Claude Code 공식 설치 스크립트 (setup_prereq.py 의 맥 안내와 같은 주소, 2026-10 확인)
CLAUDE_INSTALL_URL='https://claude.ai/install.sh'   # https://code.claude.com/docs/en/setup (2026-10)
CLAUDE_TEAM_ID='Q6L2SF6YDW'                         # Developer ID Application: Anthropic PBC (2026-10-22 설치본 codesign 으로 확인)

MIN_MACOS='13.5'   # Node.js 24 의 맥 최소 버전(BUILDING.md)
MIN_GIT='2.34.0'   # ssh 서명 확인(gpg.format=ssh)
MIN_UV='0.5.0'
MIN_NODE='18.0.0'

# 새 터미널에서도 도구가 보이도록 로그인 셸 설정 파일에 더하는 한 줄. 작은따옴표라서 $HOME·$PATH 는 그 셸이 펼친다. 같은 줄이 있으면 더하지 않는다.
PROFILE_LINE='export PATH="$HOME/.local/bin:$HOME/.local/node/bin:$HOME/.bun/bin:$HOME/.local/google-cloud-sdk/bin:$PATH" # Brieflark 설치가 더한 줄'

# ---- 상태 ------------------------------------------------------------------------------------------------------------
STEP='점검'
WORK_DIR=''
DECLINED=0
STOPPED=0
INTERRUPTED=0
FINISHED=0
PROFILE_DONE=0
GCLOUD_STAGING=''
LOG_LINES=''
LOG_PATH="$HOME/Library/Application Support/VaultAssistant/install-last-error.log"
VERIFIED_FILE=''
PLAIN_FILE=''
ANSWER=''
RUN_OUT=''
RUN_CODE=0
FOUND=''
FOUND_VERSION=''
GIT_PATH=''
SSH_KEYGEN=''
UV_PATH=''
ARCH=''
UV_URL='' UV_SHA256='' UV_ARCH=''
BUN_URL='' BUN_SHA256='' BUN_ARCH=''
NODE_URL='' NODE_SHA256='' NODE_ARCH=''
GH_URL='' GH_SHA256='' GH_ARCH=''
GCLOUD_URL='' GCLOUD_SHA256='' GCLOUD_ARCH=''

# ---- 도우미 ------------------------------------------------------------------------------------------------------------
say() { printf '%s\n' "$*"; }

log() { LOG_LINES="${LOG_LINES}$(date '+%Y-%m-%d %H:%M:%S') $*"$'\n'; }

write_log() {
    mkdir -p "$(dirname "$LOG_PATH")" 2>/dev/null || return 0
    printf '%s' "$LOG_LINES" > "$LOG_PATH" 2>/dev/null || return 0
    say "  기록: $LOG_PATH"
}

# 멈춤: 무엇이 안 됨 / 아마 이유 / 할 일. 넷째 인자 1 은 해시·서명 불일치(변조 — 다시 하지 말고 안내한 사람에게).
# 명령 치환 $(...) 안에서 부르지 않는다(그 안의 exit 는 바깥 스크립트를 멈추지 못한다).
stop_install() {
    local what="$1" why="$2" todo="$3" tamper="${4:-0}"
    STOPPED=1
    log "멈춤 [$STEP] $what / $why"
    say ''
    say "멈췄어요: $what"
    if [ "$tamper" = 1 ]; then
        say '  공지와 다른 파일이에요. 아무것도 실행하지 않았어요. 다시 하지 말고 안내한 사람에게 알려 주세요.'
    else
        say "  아마 이유: $why"
        say "  할 일: $todo"
        say '  같은 한 줄을 다시 붙여넣으면 이어서 해요.'
    fi
    write_log
    exit 1
}

# 잠깐 멈춤: 사람이 다른 창에서 할 일이 있어서 멈춘다(오류가 아니다).
pause_install() {
    STOPPED=1
    log "잠깐 멈춤 [$STEP] $1"
    say ''
    say "설치를 잠깐 멈춰요: $1"
    say "  할 일: $2"
    say '  끝나면 같은 한 줄을 다시 붙여넣으면 이어서 해요.'
    exit 3
}

on_exit() {
    local code=$?
    set +e
    if [ "$code" -ne 0 ] && [ "$STOPPED" != 1 ] && [ "$INTERRUPTED" != 1 ] && [ "$FINISHED" != 1 ]; then
        log "예상하지 못한 오류 [$STEP] 종료 코드 $code"
        say ''
        say "멈췄어요: 예상하지 못한 오류로 멈췄어요 ($STEP)"
        say "  아마 이유: 명령 하나가 실패했어요(종료 코드 $code)."
        say '  할 일: 인터넷 연결을 확인하고 같은 한 줄을 다시 붙여넣어 주세요. 계속되면 안내한 사람에게 아래 기록 파일을 보여 주세요.'
        say '  같은 한 줄을 다시 붙여넣으면 이어서 해요.'
        write_log
    fi
    if [ -n "$GCLOUD_STAGING" ]; then rm -rf "$GCLOUD_STAGING"; fi
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then rm -rf "$WORK_DIR"; fi
}

on_interrupt() {
    INTERRUPTED=1
    say ''
    say '그만뒀어요. 같은 한 줄을 다시 붙여넣으면 이어서 해요.'
    exit 130
}

start_step() {
    STEP="$1 $2"
    say ''
    say "[$1/9] $2"
}

# 한 줄 답을 읽는다. 입력이 닫혀 있으면(키보드가 없는 창) 동의 없이 넘어가지 않고 멈춘다.
read_answer() {
    ANSWER=''
    if ! IFS= read -r ANSWER; then
        say ''
        stop_install '입력을 받을 수 없어요' '이 창이 키보드 입력을 받지 못해요.' '터미널 앱(응용 프로그램 → 유틸리티 → 터미널)을 열어 같은 한 줄을 다시 붙여넣어 주세요.'
    fi
    ANSWER=$(printf '%s' "$ANSWER" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
}

# 다섯째 인자 1: 선택 도구는 s 로 건너뛸 수 있다(건너뛰면 DECLINED=1). 필수 도구는 Enter 뿐이다.
confirm_install() {
    local name="$1" source="$2" where="$3" notice="${4:-}" optional="${5:-0}"
    DECLINED=0
    say "  없어서 설치해요: $name"
    say "    출처: $source"
    say "    설치 위치: $where"
    if [ -n "$notice" ]; then say "    $notice"; fi
    if [ "${BRIEFLARK_INSTALL_YES:-}" = 1 ]; then return 0; fi
    if [ "$optional" = 1 ]; then
        printf '%s' '    Enter를 누르면 설치해요 (건너뛰려면 s, 그만두려면 Ctrl+C) '
        read_answer
        if [ "$ANSWER" = s ]; then DECLINED=1; fi
        return 0
    fi
    printf '%s' '    Enter를 누르면 설치해요 (그만두려면 Ctrl+C) '
    read_answer
}

# 명령을 돌려 출력(RUN_OUT)과 종료 코드(RUN_CODE)를 받는다. set -e 로 죽지 않는다.
run_capture() {
    RUN_CODE=0
    RUN_OUT=$("$@" 2>&1) || RUN_CODE=$?
}

# 첫 x.y.z 를 FOUND_VERSION 에. 실행이 실패하거나 숫자가 없으면 1.
tool_version() {
    local pattern='([0-9]+)\.([0-9]+)\.([0-9]+)'
    FOUND_VERSION=''
    run_capture "$1" "${2:---version}"
    if [ "$RUN_CODE" -ne 0 ]; then return 1; fi
    if [[ $RUN_OUT =~ $pattern ]]; then
        FOUND_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
        return 0
    fi
    return 1
}

# $1 >= $2 (x.y.z, 빠진 칸은 0)
version_ge() {
    local left="$1" right="$2" i l r
    for i in 1 2 3; do
        l=$(printf '%s' "$left" | cut -d. -f"$i")
        r=$(printf '%s' "$right" | cut -d. -f"$i")
        l=${l%%[!0-9]*}; r=${r%%[!0-9]*}
        l=${l:-0}; r=${r:-0}
        if [ "$((10#$l))" -gt "$((10#$r))" ]; then return 0; fi
        if [ "$((10#$l))" -lt "$((10#$r))" ]; then return 1; fi
    done
    return 0
}

# 알려진 자리(인자들)를 먼저, 그다음 PATH. 찾으면 FOUND 에.
find_program() {
    local name="$1" candidate
    FOUND=''
    shift
    for candidate in ${1+"$@"}; do
        if [ -f "$candidate" ] && [ -x "$candidate" ]; then FOUND="$candidate"; return 0; fi
    done
    candidate=$(command -v "$name" 2>/dev/null || true)
    case "$candidate" in
        /*) if [ -x "$candidate" ]; then FOUND="$candidate"; return 0; fi ;;
    esac
    return 1
}

# Apple 명령줄 도구(Command Line Tools)가 깔려 있는가. /usr/bin/git·/usr/bin/python3 은 그것이 없으면 실행하는 순간 설치 창을 띄우는
# 대리 파일이라, 이 확인을 하기 전에는 실행하지 않는다.
clt_ready() { xcode-select -p >/dev/null 2>&1; }

# Git ≥ 2.34 + ssh-keygen (product_trust.ssh_keygen_program 과 같은 판정: 맥은 PATH 의 ssh-keygen).
find_git() {
    GIT_PATH=''
    SSH_KEYGEN=''
    find_program git || return 1
    if [ "$FOUND" = /usr/bin/git ] && ! clt_ready; then return 1; fi
    local path="$FOUND"
    tool_version "$path" || return 1
    version_ge "$FOUND_VERSION" "$MIN_GIT" || return 1
    find_program ssh-keygen || return 1
    SSH_KEYGEN="$FOUND"
    GIT_PATH="$path"
    FOUND_VERSION_GIT="$FOUND_VERSION"
    return 0
}
FOUND_VERSION_GIT=''

new_work_folder() {
    if [ -z "$WORK_DIR" ]; then
        WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/brieflark-install.XXXXXXXX")
    fi
}

curl_get() {
    curl -fL --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 20 --max-time 1200 --progress-bar -o "$1" "$2"
}

# 내려받기: 새 임시 폴더에 받고 → 해시 대조 → 맞을 때만 VERIFIED_FILE 에. 받지 못하면 1(부른 쪽이 멈출지 정한다),
# 해시가 다르면 지우고 변조로 멈춘다.
get_verified_file() {
    local url="$1" sha="$2" name="$3" target actual
    VERIFIED_FILE=''
    new_work_folder
    target="$WORK_DIR/$name"
    say "    내려받는 중... ($name)"
    if ! curl_get "$target" "$url"; then
        rm -f "$target"
        log "curl 실패 ($name)"
        return 1
    fi
    actual=$(shasum -a 256 "$target" 2>/dev/null | cut -c1-64) || actual=''
    if [ "$actual" != "$sha" ]; then
        rm -f "$target"
        log "해시 불일치 $name 기대 $sha 실제 $actual"
        stop_install "$name 의 해시가 공지와 달라요" '받은 파일이 안내된 것과 다른 파일이에요.' '' 1
    fi
    VERIFIED_FILE="$target"
    return 0
}

# 공식 설치 스크립트 받기(고정 해시 없음 — 머리 주석). 파일로 다 받은 뒤에 돌린다.
get_official_script() {
    local url="$1" name="$2"
    PLAIN_FILE=''
    new_work_folder
    if ! curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 20 --max-time 300 -o "$WORK_DIR/$name" "$url"; then
        log "공식 설치 스크립트 받기 실패 ($url)"
        return 1
    fi
    PLAIN_FILE="$WORK_DIR/$name"
    return 0
}

# 로그인 셸 설정 파일: zsh(맥 기본) → ~/.zprofile. bash 는 로그인 셸이 읽는 순서(~/.bash_profile → ~/.bash_login → ~/.profile)에서
# 처음 있는 파일에 쓴다 — ~/.bash_profile 을 새로 만들면 bash 가 기존 ~/.profile 을 더는 읽지 않기 때문이다. 셋 다 없을 때만 ~/.bash_profile.
# 그 밖의 셸은 건드리지 않는다.
profile_file() {
    local candidate
    case "${SHELL:-/bin/zsh}" in
        */zsh) printf '%s' "$HOME/.zprofile" ;;
        */bash)
            for candidate in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
                if [ -e "$candidate" ]; then printf '%s' "$candidate"; return 0; fi
            done
            printf '%s' "$HOME/.bash_profile" ;;
        *) printf '' ;;
    esac
}

# 도구를 사용자 폴더에 설치한 뒤 한 번: 로그인 셸 설정 파일에 PATH 한 줄. 같은 줄이 이미 있으면 더하지 않는다(재실행해도 한 줄).
# 묻지 않고 알린다 — install.ps1 이 사용자 PATH 에 더하는 것과 같다. 쓰지 못해도 멈추지 않는다(이 창에서는 이미 PATH 에 있다).
add_profile_path() {
    local file
    if [ "$PROFILE_DONE" = 1 ]; then return 0; fi
    PROFILE_DONE=1
    file=$(profile_file)
    if [ -z "$file" ]; then
        say "  (지금 쓰는 셸(${SHELL:-})은 자동으로 설정하지 않아요. 새 창에서 도구가 안 보이면 안내한 사람에게 알려 주세요.)"
        return 0
    fi
    if [ -f "$file" ] && grep -qxF "$PROFILE_LINE" "$file"; then return 0; fi
    say "  새 터미널 창에서도 도구가 보이도록 $file 에 PATH 한 줄을 더해요."
    if printf '\n%s\n' "$PROFILE_LINE" >> "$file" 2>/dev/null; then
        log "PATH 줄 추가: $file"
    else
        log "PATH 줄 추가 실패: $file"
        say "  ($file 에 쓰지 못했어요. 이 창에서는 계속 쓸 수 있어요.)"
    fi
}

repo_address() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E \
        -e 's#^[[:space:]]+##' -e 's#[[:space:]]+$##' \
        -e 's#^https?://([^@/]+@)?##' -e 's#^git@github\.com:#github.com/#' \
        -e 's#/+$##' -e 's#\.git$##'
}

# 서명자 줄 묶음 정규화: 앞뒤 공백·빈 줄·주석 줄을 빼고, 공백을 하나로, 정렬.
signer_set() {
    awk '{ sub(/^[ \t\r]+/, ""); sub(/[ \t\r]+$/, ""); if ($0 == "" || substr($0, 1, 1) == "#") next; gsub(/[ \t]+/, " "); print }' | LC_ALL=C sort
}

# 맥 기본 python3 이 마법사를 시작할 수 있는가(3.9 이상). /usr/bin/python3 은 명령줄 도구가 있을 때만 실행한다.
system_python_ok() {
    find_program python3 || return 1
    if [ "$FOUND" = /usr/bin/python3 ] && ! clt_ready; then return 1; fi
    "$FOUND" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1
}

# ---- 단계 ------------------------------------------------------------------------------------------------------------
step_check() {
    local kernel macos translated tool
    start_step 0 '이 맥 점검'
    kernel=$(uname -s 2>/dev/null || true)
    if [ "$kernel" != Darwin ]; then
        stop_install "이 컴퓨터는 맥이 아니에요($kernel)" '이 한 줄은 macOS 전용이에요.' 'Windows라면 Windows용 한 줄을 안내한 사람에게 받아 주세요.'
    fi
    macos=$(sw_vers -productVersion 2>/dev/null || true)
    log "bash $BASH_VERSION / macOS $macos"
    if [ -z "$macos" ] || ! version_ge "$macos" "$MIN_MACOS"; then
        stop_install "macOS 버전이 낮아요(${macos:-알 수 없음})" "macOS $MIN_MACOS 이상이어야 해요." '시스템 설정 → 일반 → 소프트웨어 업데이트로 올린 뒤 같은 한 줄을 다시 붙여넣어 주세요.'
    fi
    if [ "$(id -u)" = 0 ]; then
        stop_install '관리자(root)로 실행했어요' 'sudo 로 실행하면 받은 파일이 관리자 소유가 돼 나중에 권한이 어긋나요.' 'sudo 없이 같은 한 줄을 다시 붙여넣어 주세요.'
    fi
    ARCH=$(uname -m 2>/dev/null || true)
    # Rosetta 로 돌던 터미널은 Apple 칩에서도 x86_64 라고 답한다 → 진짜 칩을 본다.
    translated=$(sysctl -in sysctl.proc_translated 2>/dev/null || true)
    if [ "$translated" = 1 ]; then ARCH=arm64; fi
    case "$ARCH" in
        arm64)
            UV_URL="$UV_URL_ARM64"; UV_SHA256="$UV_SHA256_ARM64"; UV_ARCH=aarch64
            BUN_URL="$BUN_URL_ARM64"; BUN_SHA256="$BUN_SHA256_ARM64"; BUN_ARCH=aarch64
            NODE_URL="$NODE_URL_ARM64"; NODE_SHA256="$NODE_SHA256_ARM64"; NODE_ARCH=arm64
            GH_URL="$GH_URL_ARM64"; GH_SHA256="$GH_SHA256_ARM64"; GH_ARCH=arm64
            GCLOUD_URL="$GCLOUD_URL_ARM64"; GCLOUD_SHA256="$GCLOUD_SHA256_ARM64"; GCLOUD_ARCH=arm ;;
        x86_64)
            UV_URL="$UV_URL_X64"; UV_SHA256="$UV_SHA256_X64"; UV_ARCH=x86_64
            BUN_URL="$BUN_URL_X64"; BUN_SHA256="$BUN_SHA256_X64"; BUN_ARCH=x64
            NODE_URL="$NODE_URL_X64"; NODE_SHA256="$NODE_SHA256_X64"; NODE_ARCH=x64
            GH_URL="$GH_URL_X64"; GH_SHA256="$GH_SHA256_X64"; GH_ARCH=amd64
            GCLOUD_URL="$GCLOUD_URL_X64"; GCLOUD_SHA256="$GCLOUD_SHA256_X64"; GCLOUD_ARCH=x86_64 ;;
        *)
            stop_install "이 맥의 CPU 종류($ARCH)는 지원하지 않아요" 'Apple 칩(arm64)과 Intel(x86_64) 맥만 지원해요.' '안내한 사람에게 알려 주세요.' ;;
    esac
    for tool in curl shasum tar unzip; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            stop_install "이 맥에 기본 도구($tool)가 없어요" 'macOS에 원래 들어 있는 도구인데 찾지 못했어요.' '안내한 사람에게 알려 주세요.'
        fi
    done
    # 설치하는 폴더를 이 창의 PATH 앞에 둔다(설치 직후 새 창 없이 이어 간다). 마법사는 자식이라 물려받는다.
    export PATH="$HOME/.local/bin:$HOME/.local/node/bin:$HOME/.bun/bin:$HOME/.local/google-cloud-sdk/bin:$PATH"
    say "  통과 ($ARCH, macOS $macos)"
}

step_git() {
    start_step 1 'Git (Apple 명령줄 도구)'
    if find_git; then
        say "  이미 있어요: Git $FOUND_VERSION_GIT (건너뜀)"
        return 0
    fi
    if clt_ready && [ "$(command -v git 2>/dev/null || true)" = /usr/bin/git ]; then
        stop_install 'Git이 실행되지 않아요' 'Xcode 사용권 동의가 남았거나 명령줄 도구가 망가졌을 수 있어요.' '터미널에서 git --version 을 실행해 나오는 안내를 따른 뒤, 같은 한 줄을 다시 붙여넣어 주세요.'
    fi
    if clt_ready && ! command -v ssh-keygen >/dev/null 2>&1; then
        stop_install '서명 확인 도구(ssh-keygen)가 없어요' 'macOS에 원래 들어 있는 도구인데 찾지 못했어요.' '안내한 사람에게 알려 주세요.'
    fi
    confirm_install 'Apple 명령줄 도구 (Command Line Tools, git 포함)' 'Apple 공식 (xcode-select --install)' '/Library/Developer/CommandLineTools' 'Apple 설치 창이 열려요. 관리자 암호를 물을 수 있어요(이 스크립트는 암호를 받지 않아요).'
    xcode-select --install >/dev/null 2>&1 || log 'xcode-select --install 이 0이 아닌 값으로 끝남(이미 요청됐을 수 있음)'
    pause_install 'Apple 명령줄 도구 설치 창을 열었어요' "창에서 '설치'를 누르고 끝날 때까지(몇 분~수십 분) 기다려 주세요. 창이 안 보이면 Dock을 확인해 주세요."
}

step_uv() {
    local directory="$HOME/.local/bin" files source name
    start_step 2 'uv (Python 실행기)'
    if find_program uv "$directory/uv" "$HOME/.cargo/bin/uv" && tool_version "$FOUND" && version_ge "$FOUND_VERSION" "$MIN_UV"; then
        UV_PATH="$FOUND"
        say "  이미 있어요: uv $FOUND_VERSION (건너뜀)"
        return 0
    fi
    confirm_install "uv $UV_VERSION" 'GitHub astral-sh/uv 릴리스 (SHA256 대조)' "$directory"
    if ! get_verified_file "$UV_URL" "$UV_SHA256" "uv-$UV_VERSION-$UV_ARCH-apple-darwin.tar.gz"; then
        stop_install 'uv를 내려받지 못했어요' '인터넷이 끊겼을 수 있어요.' '인터넷 연결을 확인하고 같은 한 줄을 다시 붙여넣어 주세요.'
    fi
    files="$WORK_DIR/uv-files"
    mkdir -p "$files"
    tar -xzf "$VERIFIED_FILE" -C "$files"
    source="$files/uv-$UV_ARCH-apple-darwin"
    if [ ! -f "$source/uv" ]; then
        stop_install 'uv 압축 안에 uv가 없어요' '받은 압축 파일의 모양이 달라졌어요.' '안내한 사람에게 알려 주세요.'
    fi
    mkdir -p "$directory"
    for name in uv uvx; do
        if [ -f "$source/$name" ]; then cp -f "$source/$name" "$directory/$name"; chmod 755 "$directory/$name"; fi
    done
    hash -r
    add_profile_path
    UV_PATH="$directory/uv"
    if ! tool_version "$UV_PATH"; then
        stop_install 'uv를 설치했는데 실행되지 않아요' '보안 프로그램이 막았을 수 있어요.' '안내한 사람에게 알려 주세요.'
    fi
    say "  설치했어요: uv $FOUND_VERSION"
}

step_bun() {
    local directory="$HOME/.bun/bin" files source
    start_step 3 'bun'
    if find_program bun "$directory/bun" && tool_version "$FOUND"; then
        say "  이미 있어요: bun $FOUND_VERSION (건너뜀)"
        return 0
    fi
    confirm_install "bun $BUN_VERSION" 'GitHub oven-sh/bun 릴리스 (SHA256 대조)' "$directory"
    if ! get_verified_file "$BUN_URL" "$BUN_SHA256" "bun-$BUN_VERSION-darwin-$BUN_ARCH.zip"; then
        stop_install 'bun을 내려받지 못했어요' '인터넷이 끊겼을 수 있어요.' '인터넷 연결을 확인하고 같은 한 줄을 다시 붙여넣어 주세요.'
    fi
    files="$WORK_DIR/bun-files"
    mkdir -p "$files"
    unzip -q "$VERIFIED_FILE" -d "$files"
    source="$files/bun-darwin-$BUN_ARCH/bun"
    if [ ! -f "$source" ]; then
        stop_install 'bun 압축 안에 bun이 없어요' '받은 압축 파일의 모양이 달라졌어요.' '안내한 사람에게 알려 주세요.'
    fi
    # 공식 설치 스크립트와 같은 자리(~/.bun/bin)에 bun 과 bunx(같은 파일을 가리키는 링크)를 둔다. 셸 설정은 우리 PATH 한 줄뿐이다.
    mkdir -p "$directory"
    cp -f "$source" "$directory/bun"
    chmod 755 "$directory/bun"
    ln -sf bun "$directory/bunx"
    hash -r
    add_profile_path
    if ! tool_version "$directory/bun"; then
        stop_install 'bun을 설치했는데 실행되지 않아요' '보안 프로그램이 막았을 수 있어요.' '안내한 사람에게 알려 주세요.'
    fi
    say "  설치했어요: bun $FOUND_VERSION"
}

step_node() {
    local home="$HOME/.local/node" files source
    start_step 4 'Node.js'
    if find_program node "$home/bin/node" && tool_version "$FOUND" && version_ge "$FOUND_VERSION" "$MIN_NODE"; then
        say "  이미 있어요: Node.js $FOUND_VERSION (건너뜀)"
        return 0
    fi
    confirm_install "Node.js $NODE_VERSION" 'nodejs.org 공식 릴리스 (SHA256 대조)' "$home"
    if ! get_verified_file "$NODE_URL" "$NODE_SHA256" "node-v$NODE_VERSION-darwin-$NODE_ARCH.tar.gz"; then
        stop_install 'Node.js를 내려받지 못했어요' '인터넷이 끊겼을 수 있어요.' '인터넷 연결을 확인하고 같은 한 줄을 다시 붙여넣어 주세요.'
    fi
    files="$WORK_DIR/node-files"
    mkdir -p "$files"
    tar -xzf "$VERIFIED_FILE" -C "$files"
    source="$files/node-v$NODE_VERSION-darwin-$NODE_ARCH"
    if [ ! -f "$source/bin/node" ]; then
        stop_install 'Node.js 압축 안에 node가 없어요' '받은 압축 파일의 모양이 달라졌어요.' '안내한 사람에게 알려 주세요.'
    fi
    # 폴더째 교체: 옛 버전 파일이 섞이지 않도록 지우고 옮긴다(임시 폴더에서 이미 풀었다).
    rm -rf "$home"
    mkdir -p "$(dirname "$home")"
    mv "$source" "$home"
    hash -r
    add_profile_path
    if ! tool_version "$home/bin/node"; then
        stop_install 'Node.js를 설치했는데 실행되지 않아요' '보안 프로그램이 막았을 수 있어요.' '안내한 사람에게 알려 주세요.'
    fi
    say "  설치했어요: Node.js $NODE_VERSION"
}

step_claude() {
    local directory="$HOME/.local/bin" path requirement
    start_step 5 'Claude Code'
    if find_program claude "$directory/claude" "$HOME/.claude/local/claude"; then
        say '  이미 있어요: Claude Code (건너뜀)'
        return 0
    fi
    confirm_install 'Claude Code' "Anthropic 공식 설치 스크립트 ($CLAUDE_INSTALL_URL)" "$directory"
    if ! get_official_script "$CLAUDE_INSTALL_URL" 'claude-install.sh'; then
        stop_install 'Claude Code 설치 스크립트를 받지 못했어요' '인터넷이 끊겼을 수 있어요.' '인터넷 연결을 확인하고 같은 한 줄을 다시 붙여넣어 주세요.'
    fi
    say '    진행 표시가 없을 수 있어요. 1~2분 기다려 주세요.'
    if ! bash "$PLAIN_FILE"; then
        log 'Claude 공식 설치 스크립트 실패'
    fi
    hash -r
    if ! find_program claude "$directory/claude" "$HOME/.claude/local/claude"; then
        stop_install 'Claude Code를 설치하지 못했어요' '공식 설치 스크립트가 끝나지 못했어요.' '인터넷 연결을 확인하고 같은 한 줄을 다시 붙여넣어 주세요.'
    fi
    path="$FOUND"
    # 설치된 파일이 Anthropic 의 Apple 개발자 서명(팀 ID)인지 확인한다(install.ps1 의 Authenticode 확인과 같은 자리).
    requirement="anchor apple generic and certificate leaf[subject.OU] = \"$CLAUDE_TEAM_ID\""
    if ! codesign --verify --strict -R="$requirement" "$path" >/dev/null 2>&1; then
        log "claude 서명 확인 실패: $path"
        # 공식 설치기는 이미 돌았다 — 아무것도 실행하지 않았다고 하지 않고, 이 파일이 PATH 에서 빠지도록 이름을 바꾼다.
        mv -f "$path" "$path.unverified" 2>/dev/null || log 'claude 이름 바꾸기 실패'
        hash -r
        stop_install '설치된 claude가 Anthropic 서명이 아니에요. 계속하지 않았어요' "Apple 개발자 서명(팀 $CLAUDE_TEAM_ID)이 확인되지 않았어요." '그 파일은 claude.unverified 로 이름을 바꿔 PATH 에서 뺐어요. 실행하지 말고 안내한 사람에게 알려 주세요.'
    fi
    add_profile_path
    say "  설치했어요: Claude Code (서명자: Anthropic PBC 팀 $CLAUDE_TEAM_ID 확인)"
}

step_gh() {
    local directory="$HOME/.local/bin" gh files source
    start_step 6 'GitHub CLI·로그인'
    if find_program gh "$directory/gh" && tool_version "$FOUND"; then
        gh="$FOUND"
        say "  이미 있어요: GitHub CLI $FOUND_VERSION (건너뜀)"
    else
        confirm_install "GitHub CLI $GH_VERSION" 'GitHub cli/cli 릴리스 (SHA256 대조)' "$directory"
        if ! get_verified_file "$GH_URL" "$GH_SHA256" "gh_${GH_VERSION}_macOS_$GH_ARCH.zip"; then
            stop_install 'GitHub CLI를 내려받지 못했어요' '인터넷이 끊겼을 수 있어요.' '인터넷 연결을 확인하고 같은 한 줄을 다시 붙여넣어 주세요.'
        fi
        files="$WORK_DIR/gh-files"
        mkdir -p "$files"
        unzip -q "$VERIFIED_FILE" -d "$files"
        source="$files/gh_${GH_VERSION}_macOS_$GH_ARCH/bin/gh"
        if [ ! -f "$source" ]; then
            stop_install 'GitHub CLI 압축 안에 gh가 없어요' '받은 압축 파일의 모양이 달라졌어요.' '안내한 사람에게 알려 주세요.'
        fi
        mkdir -p "$directory"
        cp -f "$source" "$directory/gh"
        chmod 755 "$directory/gh"
        hash -r
        add_profile_path
        gh="$directory/gh"
        if ! tool_version "$gh"; then
            stop_install 'GitHub CLI를 설치했는데 실행되지 않아요' '보안 프로그램이 막았을 수 있어요.' '안내한 사람에게 알려 주세요.'
        fi
        say "  설치했어요: GitHub CLI $GH_VERSION"
    fi
    if "$gh" auth status --hostname github.com >/dev/null 2>&1; then
        say '  GitHub에 이미 로그인돼 있어요 (건너뜀)'
    else
        say '  GitHub 로그인이 필요해요. 제품 저장소는 초대받은 사람만 볼 수 있어서, 초대를 수락한 계정으로 로그인해 주세요.'
        if [ "${BRIEFLARK_INSTALL_YES:-}" != 1 ]; then
            printf '%s' '    Enter를 누르면 브라우저가 열려요 (그만두려면 Ctrl+C) '
            read_answer
        fi
        if ! "$gh" auth login --hostname github.com --git-protocol https --web; then
            stop_install 'GitHub 로그인이 끝나지 않았어요' '브라우저에서 코드 입력·허용을 끝내지 못했을 수 있어요.' '같은 한 줄을 다시 붙여넣어 로그인을 처음부터 해 주세요.'
        fi
    fi
    # git 이 gh 의 로그인으로 clone 하게 한다 (전역 git 설정에 GitHub 자격 증명 도우미 한 줄이 들어간다).
    say '  GitHub 로그인 정보를 git이 쓰도록 이 맥의 git 설정에 한 줄 더해요.'
    run_capture "$gh" auth setup-git --hostname github.com
    if [ "$RUN_CODE" -ne 0 ]; then
        log "gh auth setup-git 종료 $RUN_CODE"
        stop_install 'git에 GitHub 로그인을 연결하지 못했어요' 'gh auth setup-git 가 실패했어요.' '같은 한 줄을 다시 붙여넣어 주세요.'
    fi
}

gcloud_runs() {
    CLOUDSDK_CORE_DISABLE_PROMPTS=1 tool_version "$1"
}

# 받기(해시) → 같은 볼륨의 스테이징에 풀기 → 폴더째 교체 → PATH → gcloud 가 쓸 Python 3.12. 실패하면 1(멈추지 않는다),
# 해시 불일치(변조)만 get_verified_file 안에서 멈춘다. 이 함수는 `if` 안에서 불리므로 set -e 가 꺼져 있다 → 단계마다 `|| return 1`.
install_gcloud() {
    local home="$1"
    GCLOUD_STAGING="$HOME/.local/gcloud-new"
    rm -rf "$GCLOUD_STAGING" || return 1
    mkdir -p "$GCLOUD_STAGING" || return 1
    get_verified_file "$GCLOUD_URL" "$GCLOUD_SHA256" "google-cloud-cli-$GCLOUD_VERSION-darwin-$GCLOUD_ARCH.tar.gz" || return 1
    say '    압축을 푸는 중... (파일이 많아 1~2분 걸릴 수 있어요)'
    tar -xzf "$VERIFIED_FILE" -C "$GCLOUD_STAGING" || return 1
    if [ ! -f "$GCLOUD_STAGING/google-cloud-sdk/bin/gcloud" ]; then
        log 'gcloud 압축 안에 bin/gcloud 가 없어요'
        return 1
    fi
    rm -rf "$home" || return 1
    mv "$GCLOUD_STAGING/google-cloud-sdk" "$home" || return 1
    rm -rf "$GCLOUD_STAGING"
    GCLOUD_STAGING=''
    add_profile_path
    say '    gcloud가 쓸 Python 3.12를 uv로 준비해요.'
    "$UV_PATH" python install 3.12 >/dev/null 2>&1 || log 'uv python install 3.12 실패'
    hash -r
    return 0
}

step_gcloud() {
    local home="$HOME/.local/google-cloud-sdk"
    # 마법사의 Google 연결이 프로젝트 만들기·API 켜기를 자동으로 하는 데 쓴다. 선택 도구라 해시 불일치(변조)가 아니면 실패해도 멈추지 않는다
    # (gcloud 없이는 마법사가 콘솔 안내로 대신한다).
    start_step 7 'Google Cloud CLI (gcloud)'
    if find_program gcloud "$home/bin/gcloud" && gcloud_runs "$FOUND"; then
        say "  이미 있어요: Google Cloud CLI $FOUND_VERSION (건너뜀)"
        return 0
    fi
    confirm_install "Google Cloud CLI $GCLOUD_VERSION" 'Google 공식 다운로드 dl.google.com (SHA256 대조)' "$home" '(약 55MB를 받아 풀고, gcloud가 쓸 Python 3.12를 uv로 받아요. 몇 분 걸릴 수 있어요. 없어도 설치는 계속돼요.)' 1
    if [ "$DECLINED" = 1 ]; then
        log 'gcloud 설치를 사용자가 건너뜀'
        say '  건너뛰었어요. Google 연결은 콘솔 안내로 해요(나중에 한 줄 설치를 다시 실행하면 gcloud를 설치해요).'
        return 0
    fi
    if ! install_gcloud "$home"; then
        if [ -n "$GCLOUD_STAGING" ]; then rm -rf "$GCLOUD_STAGING"; GCLOUD_STAGING=''; fi
        log 'gcloud 설치 실패'
        say '  gcloud를 설치하지 못했어요. 건너뛰고 계속해요(Google 연결은 콘솔 안내로 해요).'
        return 0
    fi
    if gcloud_runs "$home/bin/gcloud"; then
        say "  설치했어요: Google Cloud CLI $GCLOUD_VERSION"
    else
        log 'gcloud 설치 뒤 실행 확인 실패'
        say '  gcloud를 풀었는데 실행되지 않아요. 건너뛰고 계속해요(Google 연결은 콘솔 안내로 해요).'
    fi
}

step_product() {
    local root="$1" partial remote address addresses='' wanted tag tag_object tag_type signers verify_code verify_out
    local header header_line header_object='' header_type='' header_name='' commit
    local object_pattern='^object ([0-9a-f]{40})$' sha_pattern='^[0-9a-f]{40}$'
    start_step 8 '제품 받기와 서명 확인'
    case "$root" in
        /*) ;;
        *) stop_install "설치 폴더가 절대 경로가 아니에요: $root" '설치 위치를 정하지 못했어요.' '안내한 사람에게 알려 주세요.' ;;
    esac
    case "$root/" in
        "$HOME/Library/Mobile Documents/"*|"$HOME/Library/CloudStorage/"*)
            stop_install "설치 폴더가 iCloud·클라우드 동기화 폴더 안이에요: $root" '동기화가 파일을 올리고 지우며 git 폴더를 망가뜨릴 수 있어요.' '동기화 폴더 밖에 설치해야 해요. 안내한 사람에게 알려 주세요.' ;;
    esac
    say "  설치 위치: $root"

    if [ -e "$root" ]; then
        if [ -d "$root" ] && [ -z "$(ls -A "$root" 2>/dev/null)" ]; then
            rmdir "$root"
        elif [ -e "$root/.git" ]; then
            for remote in origin upstream; do
                run_capture "$GIT_PATH" -C "$root" remote get-url "$remote"
                if [ "$RUN_CODE" -eq 0 ]; then addresses="$addresses|$(repo_address "$RUN_OUT")|"; fi
            done
            wanted="|$(repo_address "$PRODUCT_URL")|"
            case "$addresses" in
                *"$wanted"*)
                    if [ ! -f "$root/setup.py" ]; then
                        stop_install "이 폴더는 제품 저장소지만 설치 파일(setup.py)이 없어요: $root" '받다가 끊겼거나 파일이 지워진 폴더일 수 있어서 아무것도 바꾸지 않았어요.' '그 폴더는 그대로 두고, 안내한 사람에게 알려 주세요.'
                    fi
                    say '  이미 받아 둔 제품 폴더예요 (건너뜀)'
                    return 0 ;;
                *)
                    stop_install "이 폴더에 다른 git 저장소가 있어요: $root" '제품 저장소가 아니라서 아무것도 바꾸지 않았어요.' '그 폴더는 그대로 두고, 안내한 사람에게 다른 설치 위치를 물어봐 주세요.' ;;
            esac
        else
            stop_install "이 폴더가 이미 있고 비어 있지 않아요: $root" '제품 폴더가 아니라서 아무것도 바꾸지 않았어요.' '그 폴더는 그대로 두고, 안내한 사람에게 다른 설치 위치를 물어봐 주세요.'
        fi
    fi

    confirm_install 'Brieflark 제품 파일' "$PRODUCT_URL (서명된 최신 release/* 태그)" "$root"
    partial="$root.installing"
    rm -rf "$partial"
    mkdir -p "$(dirname "$root")"

    say '  내려받는 중... (파일은 서명 확인이 끝난 뒤에야 펼쳐져요)'
    run_capture env GIT_TERMINAL_PROMPT=0 "$GIT_PATH" clone --no-checkout "$PRODUCT_URL" "$partial"
    if [ "$RUN_CODE" -ne 0 ]; then
        log "git clone 종료 $RUN_CODE: $RUN_OUT"
        stop_install '제품 저장소를 받지 못했어요' '인터넷이 끊겼거나, GitHub 계정이 저장소 초대를 아직 수락하지 않았을 수 있어요.' '초대 메일의 수락 버튼을 눌렀는지 확인하고 같은 한 줄을 다시 붙여넣어 주세요.'
    fi
    run_capture env GIT_TERMINAL_PROMPT=0 "$GIT_PATH" -C "$partial" fetch --quiet origin 'refs/tags/release/*:refs/tags/release/*'
    if [ "$RUN_CODE" -ne 0 ]; then
        log "git fetch tags 종료 $RUN_CODE: $RUN_OUT"
        stop_install '릴리스 태그를 받지 못했어요' '인터넷이 끊겼을 수 있어요.' '같은 한 줄을 다시 붙여넣어 주세요.'
    fi

    # 최신 release/* 태그 (이름 정렬 최댓값). 이름이 release/날짜-시각 모양인 것만.
    run_capture "$GIT_PATH" -C "$partial" tag --list 'release/*'
    tag=$(printf '%s\n' "$RUN_OUT" | tr -d '\r' | grep -E '^release/[0-9]{8}-[0-9]{4}$' | LC_ALL=C sort | tail -n 1 || true)
    if [ -z "$tag" ]; then
        stop_install '서명된 릴리스 태그가 아직 없어요' '제품 저장소에 release/* 태그가 없어요.' '안내한 사람에게 알려 주세요.'
    fi
    say "  최신 릴리스: $tag"
    run_capture "$GIT_PATH" -C "$partial" rev-parse --verify "refs/tags/$tag"
    tag_object="$RUN_OUT"
    if [ "$RUN_CODE" -ne 0 ] || ! [[ $tag_object =~ $sha_pattern ]]; then
        stop_install "릴리스 태그($tag)를 읽지 못했어요" 'git rev-parse 가 태그 객체를 돌려주지 않았어요.' '같은 한 줄을 다시 붙여넣어 주세요.'
    fi
    run_capture "$GIT_PATH" -C "$partial" cat-file -t "$tag_object"
    tag_type="$RUN_OUT"

    # 내장 키만 담은 임시 파일
    new_work_folder
    signers="$WORK_DIR/allowed_signers"
    printf '%s\n%s\n' "$EMBEDDED_SIGNER_1" "$EMBEDDED_SIGNER_2" > "$signers"
    run_capture "$GIT_PATH" -C "$partial" -c gpg.format=ssh -c "gpg.ssh.allowedSignersFile=$signers" -c "gpg.ssh.program=$SSH_KEYGEN" verify-tag "$tag_object"
    verify_code="$RUN_CODE"
    verify_out="$RUN_OUT"
    log "verify-tag $tag 종료 $verify_code: $verify_out"
    if [ "$tag_type" != tag ] || [ "$verify_code" -ne 0 ] || [[ $verify_out != *'Good "git" signature'* ]]; then
        stop_install "릴리스 태그($tag)의 서명이 공지와 달라요" '내장된 서명 키로 확인되지 않았어요.' '' 1
    fi

    # 서명은 태그 객체 안의 머리글(object·type·tag)을 덮는다. 다른 릴리스의 서명된 태그 객체를 이 이름으로 바꿔치기하면
    # 서명은 맞아도 머리글의 태그 이름이 달라서 여기서 걸린다. 펼칠 커밋도 이 태그 객체에서만 얻는다(이름을 다시 풀지 않는다).
    run_capture "$GIT_PATH" -C "$partial" cat-file tag "$tag_object"
    header="$RUN_OUT"
    local header_code="$RUN_CODE"
    while IFS= read -r header_line; do
        header_line="${header_line%$'\r'}"
        if [ -z "$header_line" ]; then break; fi
        if [[ $header_line =~ $object_pattern ]]; then header_object="${BASH_REMATCH[1]}"
        elif [[ $header_line == 'type '* ]]; then header_type="${header_line#type }"
        elif [[ $header_line == 'tag '* ]]; then header_name="${header_line#tag }"
        fi
    done <<< "$header"
    run_capture "$GIT_PATH" -C "$partial" rev-parse --verify "$tag_object^{commit}"
    commit="$RUN_OUT"
    if [ "$header_code" -ne 0 ] || [ "$header_type" != commit ] || [ "$header_name" != "$tag" ] || [ "$header_object" != "$commit" ]; then
        log "태그 머리글 불일치: 종료 $header_code type=$header_type tag=$header_name object=$header_object commit=$commit"
        stop_install "릴리스 태그($tag)의 머리글이 이름·커밋과 맞지 않아요" '서명된 태그 객체가 다른 이름이거나 커밋이 아닌 것을 가리켜요.' '' 1
    fi
    run_capture "$GIT_PATH" -C "$partial" show "$commit:.claude/trust/allowed_signers"
    if [ "$RUN_CODE" -ne 0 ] || [ "$(printf '%s\n' "$RUN_OUT" | signer_set)" != "$(printf '%s\n%s\n' "$EMBEDDED_SIGNER_1" "$EMBEDDED_SIGNER_2" | signer_set)" ]; then
        log "태그 커밋의 allowed_signers 가 내장 키와 다름 (git show 종료 $RUN_CODE)"
        stop_install '릴리스에 실린 서명자 목록이 공지와 달라요' '내장된 서명 키와 이 릴리스의 .claude/trust/allowed_signers 가 같지 않아요.' '' 1
    fi
    say '  서명 확인 통과'

    # 서명한 커밋을 main 으로 (마법사 5단계가 main 만 허용한다). main 의 upstream(origin/main)은 그대로 둔다.
    run_capture "$GIT_PATH" -C "$partial" checkout --quiet -B main "$commit"
    if [ "$RUN_CODE" -ne 0 ]; then
        log "git checkout 종료 $RUN_CODE: $RUN_OUT"
        stop_install '제품 파일을 펼치지 못했어요' 'git checkout 이 실패했어요.' '같은 한 줄을 다시 붙여넣어 주세요.'
    fi
    run_capture "$GIT_PATH" -C "$partial" branch --quiet --set-upstream-to=origin/main main
    mv "$partial" "$root"
    say '  받았어요'
}

step_wizard() {
    local root="$1" code=0
    start_step 9 '설치 마법사'
    if [ "${BRIEFLARK_SKIP_WIZARD:-}" = 1 ]; then
        say '  BRIEFLARK_SKIP_WIZARD=1 이라 마법사는 건너뛰어요.'
        log '마법사 건너뜀(시험)'
        return 0
    fi
    cd "$root"
    # 맥 기본 python3(3.9, 명령줄 도구에 들어 있다)으로 시작하면 마법사가 uv 의 Python 3.12 로 다시 실행한다(setup_prereq.py).
    # 그래서 맥에는 Windows 의 setup.cmd 같은 시작 파일이 따로 필요 없다. python3 이 없거나 낮을 때만 uv 로 3.12 를 바로 쓴다.
    if system_python_ok; then
        "$FOUND" setup.py || code=$?
    else
        say '  맥 기본 python3을 쓸 수 없어서 uv의 Python 3.12로 마법사를 시작해요.'
        "$UV_PATH" run --no-project --python 3.12 python -X utf8 setup.py || code=$?
    fi
    if [ "$code" -ne 0 ]; then
        log "마법사 종료 $code"
        stop_install "설치 마법사가 중간에 멈췄어요(종료 코드 $code)" '마법사 화면에 이유가 적혀 있어요.' '화면의 안내대로 한 뒤, 같은 한 줄을 다시 붙여넣으면 이어서 해요.'
    fi
}

main() {
    local root="${BRIEFLARK_INSTALL_ROOT:-$HOME/Brieflark}"
    trap on_exit EXIT
    trap on_interrupt INT TERM
    # 한 줄이 열어 둔 설명자 3·4를 닫는다(bash 는 /dev/fd/3 을 따로 열어 읽고 있다). 마법사·gh 같은 자식이 지운 임시 파일을 붙잡지 않게.
    exec 3<&- 4<&-
    while [ "${#root}" -gt 1 ] && [ "${root%/}" != "$root" ]; do root="${root%/}"; done

    say 'Brieflark 설치를 시작해요. 단계마다 이미 있는 것은 건너뛰고, 없는 것만 알려 드린 뒤 Enter를 물어봐요.'
    say '중간에 멈춰도 같은 한 줄을 다시 붙여넣으면 이어서 해요.'

    step_check
    step_git
    step_uv
    step_bun
    step_node
    step_claude
    step_gh
    step_gcloud
    step_product "$root"
    step_wizard "$root"
    FINISHED=1
}

main
