# Brieflark Windows 한 줄 설치 (W8). 설계: wiki/drafts/2026-10-20 - Windows 한 줄 설치 설계안.md
#
# 이 파일은 파일로 실행하지 않는다. `.claude/tools/install_oneliner.py`가 만든 한 줄이 이 파일의 바이트를 받아
# SHA256을 대조한 뒤 UTF-8로 풀어 `iex`로 돌린다. 그래서 (1) BOM 없는 UTF-8 + LF 로 저장하고(Windows PowerShell 5.1이
# BOM 없는 파일을 ANSI로 읽는 문제는 파일로 실행할 때만 생긴다), (2) 서버가 보내는 charset·줄 끝에 기대지 않는다.
# 저장소에서는 .gitattributes 의 `-text` 로 줄 끝 변환을 막아 둔다(해시가 곧 서빙되는 바이트).
#
# 단계 (있으면 건너뛰고, 없으면 이름·출처·설치 위치를 보인 뒤 Enter):
#   0 점검   1 Git   2 uv   3 bun   4 Node.js   5 Claude Code   6 GitHub CLI·로그인   7 제품 받기 + 서명 확인   8 설치 마법사
#
# 시험용 환경변수 (사용자에게 안내하지 않는다):
#   BRIEFLARK_INSTALL_ROOT   제품 폴더를 %USERPROFILE%\Brieflark 대신 이 경로로 (운영 설치와 분리해 시험할 때). 60자 이하·OneDrive 밖.
#   BRIEFLARK_INSTALL_YES=1  "Enter를 누르면" 질문을 묻지 않고 진행 (자동 시험용).
#   BRIEFLARK_ALLOW_ADMIN=1  관리자 창에서도 진행 (Windows Sandbox 처럼 관리자뿐인 시험 환경용).
#   BRIEFLARK_SKIP_WIZARD=1  8단계(마법사)를 넘기지 않고 건너뛴다 (운영 PC에서는 설치 가드가 멈추는 것이 정상).
#
# 전체를 함수로 감싸 프로세스 종료 명령 대신 `return` 만 쓴다 — iex 안에서 종료하면 사용자의 PowerShell 창이 닫힌다.

function Invoke-BrieflarkInstall {
    [CmdletBinding()]
    param()

    # ---- 고정값 (바꾸면 .claude/launcher/windows/test_install_ps1.py 가 짝을 확인한다) ---------------------------------
    $ProductUrl = 'https://github.com/brieflark/brieflark.git'

    # 릴리스 서명 공개 키 줄: 현재 + 예비. .claude/trust/allowed_signers 의 키 줄과 글자 그대로 같아야 한다(시험이 확인).
    $EmbeddedSigners = @(
        'release@brieflark.invalid namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE7DkGEQhcGOIZk7SKYV2Iaht/cADbs+Lb825qtVdYiW',
        'release@brieflark.invalid namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMvcwRfBrbmxMp9tXDxShD6fbqP+BJOePHZ5f06qILEz'
    )

    # uv / bun / GitHub CLI: 고정 버전 release zip + 내장 SHA256 (2026-10-21 받아서 계산)
    $UvVersion = '0.13.4'
    $UvUrl = 'https://github.com/astral-sh/uv/releases/download/0.13.4/uv-x86_64-pc-windows-msvc.zip'
    $UvSha256 = 'ccec7508a07d9933d7cb1261880633efcf1f30d6e6eddab21823f1dae6f23225'

    $BunVersion = '1.4.3'
    $BunUrl = 'https://github.com/oven-sh/bun/releases/download/bun-v1.4.3/bun-windows-x64.zip'
    $BunSha256 = '0bf84e808552beea67bf1202a287a35c6c825d837b287b3f8e9dd513dba35d3d'

    # Node.js (Windows 캘린더 연결의 MCP 서버가 node 로 돈다): nodejs.org 공식 릴리스 zip (2026-10-21 Windows 에서 해시·실행 확인)
    $NodeVersion = '24.22.0'
    $NodeUrl = 'https://nodejs.org/dist/v24.22.0/node-v24.22.0-win-x64.zip'
    $NodeSha256 = 'f9683a19877e12a9b167305c8db71040d812876359de21f0d2e97c3f321f80c3'

    $GhVersion = '2.102.0'
    $GhUrl = 'https://github.com/cli/cli/releases/download/v2.102.0/gh_2.102.0_windows_amd64.zip'
    $GhSha256 = 'ae64e556ecc240b200f7eba60d550e4bb60d78e860e69dd88c449405b86067f4'

    # Git for Windows 설치 파일: winget 이 없거나 실패했을 때만 쓴다.
    $GitVersion = '2.56.0.2'
    $GitUrl = 'https://github.com/git-for-windows/git/releases/download/v2.56.0.windows.2/Git-2.56.0.2-64-bit.exe'
    $GitSha256 = '52188f917b378f00c70ec136bcf090005f30d44fbc4eba0bce759cc6592d60f6'

    $ClaudeInstallUrl = 'https://claude.ai/install.ps1'   # https://code.claude.com/docs/en/setup (2026-10)
    $ClaudeSigner = 'Anthropic, PBC'
    $MinGit = [version]'2.34.0'
    $MinUv = [version]'0.5.0'
    $MinNode = [version]'18.0.0'
    $MaxRootLength = 60

    # ---- 상태 --------------------------------------------------------------------------------------------------------
    $savedErrorAction = $ErrorActionPreference
    $savedEncoding = $null
    $savedPath = $env:Path
    $savedSetupLauncher = $env:BRIEFLARK_SETUP_LAUNCHER
    $savedGitPrompt = $env:GIT_TERMINAL_PROMPT
    $LogPath = $null
    $LogLines = New-Object System.Collections.Generic.List[string]
    $State = @{ Step = '점검'; WorkFolder = $null }
    $ErrorActionPreference = 'Stop'

    # ---- 도우미 ------------------------------------------------------------------------------------------------------
    function Say([string]$Text) { Write-Host $Text }

    function Log([string]$Text) { $LogLines.Add(('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text)) }

    # 멈춤: 무엇이 안 됨 / 아마 이유 / 할 일. $Tamper 는 해시·서명 불일치(다시 하지 말고 안내한 사람에게).
    function Stop-Install([string]$What, [string]$Why, [string]$Todo, [bool]$Tamper = $false) {
        $failure = New-Object System.Exception 'BRIEFLARK_STOP'
        $failure.Data['what'] = $What
        $failure.Data['why'] = $Why
        $failure.Data['todo'] = $Todo
        $failure.Data['tamper'] = $Tamper
        throw $failure
    }

    function Start-Step([string]$Number, [string]$Title) {
        $State.Step = "$Number $Title"
        Say ''
        Say "[$Number/8] $Title"
    }

    function Confirm-Install([string]$Name, [string]$Source, [string]$Where, [string]$Notice = '') {
        Say "  없어서 설치해요: $Name"
        Say "    출처: $Source"
        Say "    설치 위치: $Where"
        if ($Notice) { Say "    $Notice" }
        if ($env:BRIEFLARK_INSTALL_YES -eq '1') { return }
        [void](Read-Host '    Enter를 누르면 설치해요 (그만두려면 Ctrl+C)')
    }

    function ConvertTo-ForwardSlash([string]$Path) { return $Path.Replace('\', '/') }

    # 네이티브 명령: PowerShell 5.1 은 stderr 를 오류로 바꿔 Stop 설정에서 죽는다 → 여기서만 Continue 로 받아 문자열로.
    # 시작 자체가 실패하면(파일 없음·차단) Code=-1. 호출 전에 종료 코드를 0으로 비워 지난 명령의 값을 읽지 않게 한다.
    function Invoke-Native([string]$File, [string[]]$Arguments) {
        $ErrorActionPreference = 'Continue'
        Set-Variable -Name LASTEXITCODE -Scope Global -Value 0
        try {
            $lines = @(& $File @Arguments 2>&1 | ForEach-Object {
                    if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
                })
            $code = $LASTEXITCODE
        } catch {
            return [pscustomobject]@{ Code = -1; Text = [string]$_.Exception.Message }
        }
        return [pscustomobject]@{ Code = $code; Text = ($lines -join "`n") }
    }

    function Get-RealPath([string]$Path) {
        $expanded = [Environment]::ExpandEnvironmentVariables($Path)
        return $expanded.TrimEnd('\').ToLowerInvariant()
    }

    # 사용자 PATH 는 레지스트리(HKCU\Environment)를 직접 읽고 쓴다: [Environment]::SetEnvironmentVariable 은 %변수% 가 든 REG_EXPAND_SZ 를
    # 펼친 값의 REG_SZ 로 바꿔 버린다. 값을 펼치지 않고 읽고, 원래 종류(REG_SZ 면 REG_SZ)를 그대로 써서 한 항목만 덧붙인다.
    function Add-UserPathEntry([string]$Directory) {
        $key = Get-Item -LiteralPath 'HKCU:\Environment'
        $current = ''
        $kind = 'ExpandString'
        if (@($key.GetValueNames()) -contains 'Path') {
            $current = [string]$key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
            if ($key.GetValueKind('Path').ToString() -eq 'String') { $kind = 'String' }
        }
        $wanted = Get-RealPath $Directory
        foreach ($entry in $current.Split(';')) {
            if ($entry -and ((Get-RealPath $entry) -eq $wanted)) { return }
        }
        $joined = if ($current) { $current.TrimEnd(';') + ';' + $Directory } else { $Directory }
        Set-ItemProperty -LiteralPath 'HKCU:\Environment' -Name 'Path' -Value $joined -Type $kind
        Log "User PATH 에 추가: $Directory"
        # 이미 열린 창·탐색기에 환경 변경을 알린다(임시 변수를 만들었다 지우면 WM_SETTINGCHANGE 가 나간다).
        try {
            [Environment]::SetEnvironmentVariable('BRIEFLARK_PATH_NOTIFY', '1', 'User')
            [Environment]::SetEnvironmentVariable('BRIEFLARK_PATH_NOTIFY', $null, 'User')
        } catch { Log '환경 변경 알림 실패(무시)' }
    }

    # PATH 재조립: 알려진 설치 폴더 + Machine + User + 지금 값. 설치마다 불러서 "새 창을 여세요" 없이 이어 간다.
    function Update-SessionPath {
        $known = @(
            (Join-Path $env:USERPROFILE '.local\bin'),
            (Join-Path $env:USERPROFILE '.bun\bin'),
            (Join-Path $env:USERPROFILE '.local\node'),
            (Join-Path $env:ProgramFiles 'Git\cmd'),
            (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd')
        )
        $parts = @($known)
        foreach ($scope in 'Machine', 'User') {
            $value = [Environment]::GetEnvironmentVariable('Path', $scope)
            if ($value) { $parts += $value.Split(';') }
        }
        if ($env:Path) { $parts += $env:Path.Split(';') }
        $seen = @{}
        $result = New-Object System.Collections.Generic.List[string]
        foreach ($part in $parts) {
            $entry = [Environment]::ExpandEnvironmentVariables(([string]$part).Trim())
            if (-not $entry) { continue }
            $key = $entry.TrimEnd('\').ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $result.Add($entry)
        }
        $env:Path = $result -join ';'
    }

    function Find-Program([string]$Name, [string[]]$Extra) {
        foreach ($candidate in $Extra) {
            if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
        }
        $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return $command.Source }
        return $null
    }

    function Get-ToolVersion([string]$File, [string]$Argument = '--version') {
        try {
            $answer = Invoke-Native $File @($Argument)
            if ($answer.Code -ne 0) { return $null }
            $match = [regex]::Match($answer.Text, '(\d+)\.(\d+)\.(\d+)')
            if (-not $match.Success) { return $null }
            return [version]('{0}.{1}.{2}' -f $match.Groups[1].Value, $match.Groups[2].Value, $match.Groups[3].Value)
        } catch { return $null }
    }

    # ssh-keygen: product_trust.ssh_keygen_program 과 같은 판정 — git 경로의 위 세 단계 안에서 usr\bin\ssh-keygen.exe
    function Find-BundledSshKeygen([string]$GitPath) {
        $folder = Split-Path -Parent $GitPath
        for ($i = 0; $i -lt 3 -and $folder; $i++) {
            $candidate = Join-Path $folder 'usr\bin\ssh-keygen.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
            $folder = Split-Path -Parent $folder
        }
        return $null
    }

    function Find-Git {
        $path = Find-Program 'git' @()
        if (-not $path) { return $null }
        $version = Get-ToolVersion $path
        if ($null -eq $version -or $version -lt $MinGit) { return $null }
        $keygen = Find-BundledSshKeygen $path
        if (-not $keygen) { return $null }
        return [pscustomobject]@{ Path = $path; SshKeygen = $keygen; Version = $version }
    }

    function New-WorkFolder {
        if (-not $State.WorkFolder) {
            $State.WorkFolder = Join-Path $env:TEMP ('brieflark-install-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
            [void](New-Item -ItemType Directory -Path $State.WorkFolder)
        }
        return $State.WorkFolder
    }

    function Get-FileSha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

    # 내려받기: 새 임시 폴더에 받고 → 해시 대조 → 맞을 때만 돌려준다. curl.exe(Win10 1803+)를 먼저 쓴다
    # (Invoke-WebRequest 는 큰 파일에서 멈춘 적이 있다 — 2026-10-21 Sandbox).
    function Get-VerifiedFile([string]$Url, [string]$Sha256, [string]$Name) {
        $target = Join-Path (New-WorkFolder) $Name
        Say "    내려받는 중... ($Name)"
        $curl = Join-Path ([Environment]::SystemDirectory) 'curl.exe'
        $done = $false
        if (Test-Path -LiteralPath $curl -PathType Leaf) {
            $ErrorActionPreference = 'Continue'
            & $curl -fL --retry 3 --connect-timeout 20 --max-time 1200 --progress-bar -o $target $Url
            $curlCode = $LASTEXITCODE
            $ErrorActionPreference = 'Stop'
            $done = ($curlCode -eq 0) -and (Test-Path -LiteralPath $target -PathType Leaf)
            if (-not $done) { Log "curl.exe 실패 코드 $curlCode ($Name)" }
        }
        if (-not $done) {
            $savedProgress = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            try { Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $target -TimeoutSec 1200 }
            finally { $ProgressPreference = $savedProgress }
        }
        $actual = Get-FileSha256 $target
        if ($actual -ne $Sha256.ToLowerInvariant()) {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            Log "해시 불일치 $Name 기대 $Sha256 실제 $actual"
            Stop-Install "$Name 의 해시가 공지와 달라요" '받은 파일이 안내된 것과 다른 파일이에요.' '' $true
        }
        return $target
    }

    function Expand-VerifiedZip([string]$Zip, [string]$Name) {
        $folder = Join-Path (New-WorkFolder) ($Name + '-files')
        Expand-Archive -LiteralPath $Zip -DestinationPath $folder -Force
        return $folder
    }

    function Copy-IntoPlace([string]$Source, [string]$Directory, [string]$TargetName) {
        [void](New-Item -ItemType Directory -Path $Directory -Force)
        Copy-Item -LiteralPath $Source -Destination (Join-Path $Directory $TargetName) -Force
    }

    function Get-RepoAddress([string]$Raw) {
        $text = $Raw.Trim().ToLowerInvariant()
        $text = $text -replace '^https?://([^@/]+@)?', ''
        $text = $text -replace '^git@github\.com:', 'github.com/'
        $text = $text.TrimEnd('/')
        if ($text.EndsWith('.git')) { $text = $text.Substring(0, $text.Length - 4) }
        return $text
    }

    function Get-SignerSet([string[]]$Lines) {
        $set = @()
        foreach ($line in $Lines) {
            $text = ([string]$line).Trim()
            if (-not $text -or $text.StartsWith('#')) { continue }
            $set += ($text -replace '\s+', ' ')
        }
        return ($set | Sort-Object) -join "`n"
    }

    # ---- 본체 --------------------------------------------------------------------------------------------------------
    try {
        try {
            $savedEncoding = [Console]::OutputEncoding
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        } catch { $savedEncoding = $null }

        $localData = $env:LOCALAPPDATA
        if (-not $localData) { $localData = Join-Path $env:USERPROFILE 'AppData\Local' }
        $LogPath = Join-Path $localData 'VaultAssistant\install-last-error.log'

        Say 'Brieflark 설치를 시작해요. 단계마다 이미 있는 것은 건너뛰고, 없는 것만 알려 드린 뒤 Enter를 물어봐요.'
        Say '중간에 멈춰도 같은 한 줄을 다시 붙여넣으면 이어서 해요.'

        # ---- 0 점검 ----
        Start-Step '0' '이 PC 점검'
        $osVersion = [Environment]::OSVersion.Version
        Log ("PS {0} / OS {1}" -f $PSVersionTable.PSVersion, $osVersion)
        if ($osVersion -lt [version]'10.0.17763') {
            Stop-Install 'Windows 버전이 낮아요' 'Windows 10 1809 이상이어야 해요.' 'Windows 업데이트를 한 뒤 다시 붙여넣어 주세요.'
        }
        $architecture = $env:PROCESSOR_ARCHITEW6432
        if (-not $architecture) { $architecture = $env:PROCESSOR_ARCHITECTURE }
        if ($architecture -ne 'AMD64') {
            Stop-Install "이 PC의 CPU 종류($architecture)는 아직 지원하지 않아요" '지금은 일반 64비트(x64) Windows만 지원해요. ARM 지원은 아직 정해지지 않았어요(TBD).' '안내한 사람에게 알려 주세요.'
        }
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -and $env:BRIEFLARK_ALLOW_ADMIN -ne '1') {
            Stop-Install '관리자 권한 창에서 실행했어요' '관리자 창에서 받은 파일은 관리자 소유가 돼 나중에 권한이 어긋나요.' '이 창을 닫고, 시작 메뉴에서 PowerShell을 그냥(관리자 아님) 열어 같은 한 줄을 붙여넣어 주세요.'
        }
        if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
            Stop-Install 'PowerShell이 제한 모드예요' '회사·학교 정책이 스크립트를 제한하고 있어요.' '안내한 사람에게 알려 주세요.'
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Update-SessionPath
        Say '  통과'

        # ---- 1 Git ----
        Start-Step '1' 'Git'
        $git = Find-Git
        if ($git) {
            Say "  이미 있어요: Git $($git.Version) (건너뜀)"
        } else {
            $wingetPath = Find-Program 'winget' @()
            if ($wingetPath) {
                Confirm-Install 'Git for Windows' 'winget (패키지 Git.Git)' '사용자 범위(안 되면 Program Files — 이때 관리자 허용 창이 한 번 떠요)' '(Enter를 누르면 winget과 Git 패키지의 사용 약관에 동의하고 설치하는 것으로 처리해요.)'
                Say '    몇 분 걸릴 수 있어요. 멈춘 것처럼 보여도 기다려 주세요.'
                $wingetArgs = @('install', '--id', 'Git.Git', '-e', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements')
                # 출력을 잡지 않고 그대로 보여 준다(winget 진행 표시가 보이도록).
                $userArgs = $wingetArgs + @('--scope', 'user')
                & $wingetPath @userArgs
                Log "winget(user) 종료 $LASTEXITCODE"
                Update-SessionPath
                $git = Find-Git
                if (-not $git) {
                    & $wingetPath @wingetArgs
                    Log "winget(기본) 종료 $LASTEXITCODE"
                    Update-SessionPath
                    $git = Find-Git
                }
            }
            if (-not $git) {
                Confirm-Install "Git for Windows $GitVersion" 'Git for Windows 공식 릴리스 설치 파일 (github.com/git-for-windows)' 'C:\Program Files\Git (관리자 허용 창이 한 번 떠요)'
                $installer = Get-VerifiedFile $GitUrl $GitSha256 "Git-$GitVersion-64-bit.exe"
                Say '    설치 창이 열려요. 끝날 때까지 기다려 주세요.'
                try {
                    $process = Start-Process -FilePath $installer -ArgumentList @('/SILENT', '/NORESTART', '/SUPPRESSMSGBOXES', '/SP-') -Wait -PassThru
                    Log "Git 설치 파일 종료 $($process.ExitCode)"
                } catch {
                    # 관리자 허용 창을 거절하면 시작 예외가 난다 → 아래 '설치하지 못했어요' 안내로 이어진다.
                    Log "Git 설치 파일 시작 실패: $($_.Exception.Message)"
                }
                Update-SessionPath
                $git = Find-Git
            }
            if (-not $git) {
                Stop-Install 'Git을 설치하지 못했어요' '관리자 허용 창을 거절했거나 설치가 중간에 끊겼을 수 있어요.' '허용 창이 뜨면 "예"를 누르고, 같은 한 줄을 다시 붙여넣어 주세요.'
            }
            Say "  설치했어요: Git $($git.Version)"
        }

        # ---- 2 uv ----
        Start-Step '2' 'uv (Python 실행기)'
        $uvDirectory = Join-Path $env:USERPROFILE '.local\bin'
        $uvPath = Find-Program 'uv' @((Join-Path $uvDirectory 'uv.exe'))
        $uvVersionFound = $null
        if ($uvPath) { $uvVersionFound = Get-ToolVersion $uvPath }
        if ($uvVersionFound -and $uvVersionFound -ge $MinUv) {
            Say "  이미 있어요: uv $uvVersionFound (건너뜀)"
        } else {
            Confirm-Install "uv $UvVersion" 'GitHub astral-sh/uv 릴리스 (SHA256 대조)' $uvDirectory
            $zip = Get-VerifiedFile $UvUrl $UvSha256 "uv-$UvVersion-x86_64-pc-windows-msvc.zip"
            $files = Expand-VerifiedZip $zip 'uv'
            foreach ($name in 'uv.exe', 'uvx.exe', 'uvw.exe') {
                $source = Join-Path $files $name
                if (Test-Path -LiteralPath $source -PathType Leaf) { Copy-IntoPlace $source $uvDirectory $name }
            }
            Add-UserPathEntry $uvDirectory
            Update-SessionPath
            $uvPath = Join-Path $uvDirectory 'uv.exe'
            if (-not (Get-ToolVersion $uvPath)) {
                Stop-Install 'uv를 설치했는데 실행되지 않아요' '보안 프로그램이 막았을 수 있어요.' "$uvDirectory 폴더를 보안 프로그램 예외에 넣거나 안내한 사람에게 알려 주세요."
            }
            Say "  설치했어요: uv $UvVersion"
        }

        # ---- 3 bun ----
        Start-Step '3' 'bun'
        $bunDirectory = Join-Path $env:USERPROFILE '.bun\bin'
        $bunPath = Find-Program 'bun' @((Join-Path $bunDirectory 'bun.exe'))
        $bunVersionFound = $null
        if ($bunPath) { $bunVersionFound = Get-ToolVersion $bunPath }
        if ($bunVersionFound) {
            Say "  이미 있어요: bun $bunVersionFound (건너뜀)"
        } else {
            Confirm-Install "bun $BunVersion" 'GitHub oven-sh/bun 릴리스 (SHA256 대조)' $bunDirectory
            $zip = Get-VerifiedFile $BunUrl $BunSha256 "bun-$BunVersion-windows-x64.zip"
            $files = Expand-VerifiedZip $zip 'bun'
            $source = Join-Path $files 'bun-windows-x64\bun.exe'
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                Stop-Install 'bun 압축 안에 bun.exe가 없어요' '받은 압축 파일의 모양이 달라졌어요.' '안내한 사람에게 알려 주세요.'
            }
            Copy-IntoPlace $source $bunDirectory 'bun.exe'
            Copy-IntoPlace $source $bunDirectory 'bunx.exe'
            Add-UserPathEntry $bunDirectory
            Update-SessionPath
            if (-not (Get-ToolVersion (Join-Path $bunDirectory 'bun.exe'))) {
                Stop-Install 'bun을 설치했는데 실행되지 않아요' '이 PC의 CPU가 너무 오래됐거나(AVX2 없음) 보안 프로그램이 막았을 수 있어요.' '안내한 사람에게 알려 주세요.'
            }
            Say "  설치했어요: bun $BunVersion"
        }

        # ---- 4 Node.js ----
        Start-Step '4' 'Node.js'
        $nodeHome = Join-Path $env:USERPROFILE '.local\node'
        $nodePath = Find-Program 'node' @((Join-Path $nodeHome 'node.exe'))
        $nodeVersionFound = $null
        if ($nodePath) { $nodeVersionFound = Get-ToolVersion $nodePath }
        if ($nodeVersionFound -and $nodeVersionFound -ge $MinNode) {
            Say "  이미 있어요: Node.js $nodeVersionFound (건너뜀)"
        } else {
            Confirm-Install "Node.js $NodeVersion" 'nodejs.org 공식 릴리스 (SHA256 대조)' $nodeHome
            $zip = Get-VerifiedFile $NodeUrl $NodeSha256 "node-v$NodeVersion-win-x64.zip"
            $files = Expand-VerifiedZip $zip 'node'
            $source = Join-Path $files "node-v$NodeVersion-win-x64"
            if (-not (Test-Path -LiteralPath (Join-Path $source 'node.exe') -PathType Leaf)) {
                Stop-Install 'Node.js 압축 안에 node.exe가 없어요' '받은 압축 파일의 모양이 달라졌어요.' '안내한 사람에게 알려 주세요.'
            }
            # 폴더째 교체: 옛 버전 파일이 섞이지 않도록 지우고 새로 채운다(임시 폴더에서 이미 풀었다).
            if (Test-Path -LiteralPath $nodeHome) { Remove-Item -LiteralPath $nodeHome -Recurse -Force }
            [void](New-Item -ItemType Directory -Path $nodeHome -Force)
            Copy-Item -Path (Join-Path $source '*') -Destination $nodeHome -Recurse -Force
            Add-UserPathEntry $nodeHome
            Update-SessionPath
            if (-not (Get-ToolVersion (Join-Path $nodeHome 'node.exe'))) {
                Stop-Install 'Node.js를 설치했는데 실행되지 않아요' '보안 프로그램이 막았을 수 있어요.' "${nodeHome} 폴더를 보안 프로그램 예외에 넣거나 안내한 사람에게 알려 주세요."
            }
            Say "  설치했어요: Node.js $NodeVersion"
        }

        # ---- 5 Claude Code ----
        Start-Step '5' 'Claude Code'
        $claudeDirectory = Join-Path $env:USERPROFILE '.local\bin'
        $claudePath = Find-Program 'claude' @((Join-Path $claudeDirectory 'claude.exe'))
        if ($claudePath) {
            Say '  이미 있어요: Claude Code (건너뜀)'
        } else {
            Confirm-Install 'Claude Code' "Anthropic 공식 설치기 ($ClaudeInstallUrl)" $claudeDirectory
            Say '    진행 표시가 없어요. 1~2분 기다려 주세요.'
            $powershell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
            $command = "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; irm $ClaudeInstallUrl | iex"
            $answer = Invoke-Native $powershell @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $command)
            Log "Claude 공식 설치기 종료 $($answer.Code)"
            Add-UserPathEntry $claudeDirectory
            Update-SessionPath
            $claudePath = Find-Program 'claude' @((Join-Path $claudeDirectory 'claude.exe'))
            if (-not $claudePath) {
                Stop-Install 'Claude Code를 설치하지 못했어요' '공식 설치기가 끝나지 못했어요.' '인터넷 연결을 확인하고 같은 한 줄을 다시 붙여넣어 주세요.'
            }
            $signature = Get-AuthenticodeSignature -LiteralPath $claudePath
            $signer = ''
            if ($signature.SignerCertificate) { $signer = $signature.SignerCertificate.Subject }
            if ($signature.Status -ne 'Valid' -or $signer -notmatch ('CN="?' + [regex]::Escape($ClaudeSigner) + '"?(,|$)')) {
                Log "Claude 서명 상태 $($signature.Status) 서명자 $signer"
                # 공식 설치기는 이미 돌았다 — 아무것도 실행하지 않았다고 하지 않고, 이 파일이 PATH 에서 빠지도록 이름을 바꾼다.
                try { Move-Item -LiteralPath $claudePath -Destination ($claudePath + '.unverified') -Force; Update-SessionPath }
                catch { Log "claude 이름 바꾸기 실패: $($_.Exception.Message)" }
                Stop-Install '설치된 claude가 Anthropic 서명이 아니에요. 계속하지 않았어요' "서명 상태는 $($signature.Status), 서명자는 '$signer' 예요." "그 파일은 claude.exe.unverified 로 이름을 바꿔 PATH 에서 뺐어요. 실행하지 말고 안내한 사람에게 알려 주세요."
            }
            Say '  설치했어요: Claude Code (서명자: Anthropic, PBC 확인)'
        }

        # ---- 6 GitHub CLI + 로그인 ----
        Start-Step '6' 'GitHub CLI·로그인'
        $ghDirectory = Join-Path $env:USERPROFILE '.local\bin'
        $ghPath = Find-Program 'gh' @((Join-Path $ghDirectory 'gh.exe'))
        $ghVersionFound = $null
        if ($ghPath) { $ghVersionFound = Get-ToolVersion $ghPath }
        if ($ghVersionFound) {
            Say "  이미 있어요: GitHub CLI $ghVersionFound (건너뜀)"
        } else {
            Confirm-Install "GitHub CLI $GhVersion" 'GitHub cli/cli 릴리스 (SHA256 대조)' $ghDirectory
            $zip = Get-VerifiedFile $GhUrl $GhSha256 "gh_${GhVersion}_windows_amd64.zip"
            $files = Expand-VerifiedZip $zip 'gh'
            $source = Join-Path $files 'bin\gh.exe'
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                Stop-Install 'GitHub CLI 압축 안에 gh.exe가 없어요' '받은 압축 파일의 모양이 달라졌어요.' '안내한 사람에게 알려 주세요.'
            }
            Copy-IntoPlace $source $ghDirectory 'gh.exe'
            Add-UserPathEntry $ghDirectory
            Update-SessionPath
            $ghPath = Join-Path $ghDirectory 'gh.exe'
            if (-not (Get-ToolVersion $ghPath)) {
                Stop-Install 'GitHub CLI를 설치했는데 실행되지 않아요' '보안 프로그램이 막았을 수 있어요.' '안내한 사람에게 알려 주세요.'
            }
            Say "  설치했어요: GitHub CLI $GhVersion"
        }
        $login = Invoke-Native $ghPath @('auth', 'status', '--hostname', 'github.com')
        if ($login.Code -eq 0) {
            Say '  GitHub에 이미 로그인돼 있어요 (건너뜀)'
        } else {
            Say '  GitHub 로그인이 필요해요. 제품 저장소는 초대받은 사람만 볼 수 있어서, 초대를 수락한 계정으로 로그인해 주세요.'
            if ($env:BRIEFLARK_INSTALL_YES -ne '1') { [void](Read-Host '    Enter를 누르면 브라우저가 열려요 (그만두려면 Ctrl+C)') }
            & $ghPath auth login --hostname github.com --git-protocol https --web
            if ($LASTEXITCODE -ne 0) {
                Stop-Install 'GitHub 로그인이 끝나지 않았어요' '브라우저에서 코드 입력·허용을 끝내지 못했을 수 있어요.' '같은 한 줄을 다시 붙여넣어 로그인을 처음부터 해 주세요.'
            }
        }
        # git 이 gh 의 로그인으로 clone 하게 한다 (전역 git 설정에 GitHub 자격 증명 도우미 한 줄이 들어간다).
        Say '  GitHub 로그인 정보를 git이 쓰도록 이 PC의 git 설정에 한 줄 더해요.'
        $setup = Invoke-Native $ghPath @('auth', 'setup-git', '--hostname', 'github.com')
        if ($setup.Code -ne 0) {
            Log "gh auth setup-git 종료 $($setup.Code)"
            Stop-Install 'git에 GitHub 로그인을 연결하지 못했어요' 'gh auth setup-git 가 실패했어요.' '같은 한 줄을 다시 붙여넣어 주세요.'
        }

        # ---- 6 제품 받기 + 서명 확인 ----
        Start-Step '7' '제품 받기와 서명 확인'
        $root = $env:BRIEFLARK_INSTALL_ROOT
        if (-not $root) { $root = Join-Path $env:USERPROFILE 'Brieflark' }
        $root = [IO.Path]::GetFullPath($root).TrimEnd('\')
        $oneDriveRoots = @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial) | Where-Object { $_ }
        $underOneDrive = ($root -match '(^|\\)OneDrive[^\\]*(\\|$)')
        foreach ($oneDrive in $oneDriveRoots) {
            $prefix = $oneDrive.TrimEnd('\') + '\'
            if ($root.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { $underOneDrive = $true }
        }
        if ($underOneDrive) {
            Stop-Install "설치 폴더가 OneDrive 안이에요: $root" 'OneDrive가 파일을 올리고 지우며 git 폴더를 망가뜨릴 수 있어요.' 'OneDrive 밖에 설치해야 해요. 안내한 사람에게 알려 주세요.'
        }
        if ($root.Length -gt $MaxRootLength) {
            Stop-Install "설치 폴더 경로가 너무 길어요($($root.Length)자 > ${MaxRootLength}자): $root" 'Windows는 긴 경로에서 파일을 못 만들 때가 있어요.' '더 짧은 경로로 해야 해요. 안내한 사람에게 알려 주세요.'
        }
        Say "  설치 위치: $root"

        $gitFile = $git.Path
        $env:GIT_TERMINAL_PROMPT = '0'
        $installed = $false
        if (Test-Path -LiteralPath $root) {
            $entries = @(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue)
            if ($entries.Count -eq 0) {
                [IO.Directory]::Delete($root, $false)
            } elseif (Test-Path -LiteralPath (Join-Path $root '.git')) {
                $addresses = @()
                foreach ($remote in 'origin', 'upstream') {
                    $found = Invoke-Native $gitFile @('-C', $root, 'remote', 'get-url', $remote)
                    if ($found.Code -eq 0) { $addresses += (Get-RepoAddress $found.Text) }
                }
                if ($addresses -contains (Get-RepoAddress $ProductUrl)) {
                    $hasSetup = (Test-Path -LiteralPath (Join-Path $root 'setup.cmd') -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $root 'setup.py') -PathType Leaf)
                    if (-not $hasSetup) {
                        Stop-Install "이 폴더는 제품 저장소지만 설치 파일(setup.cmd·setup.py)이 없어요: $root" '받다가 끊겼거나 파일이 지워진 폴더일 수 있어서 아무것도 바꾸지 않았어요.' '그 폴더는 그대로 두고, 안내한 사람에게 알려 주세요.'
                    }
                    Say '  이미 받아 둔 제품 폴더예요 (건너뜀)'
                    $installed = $true
                } else {
                    Stop-Install "이 폴더에 다른 git 저장소가 있어요: $root" '제품 저장소가 아니라서 아무것도 바꾸지 않았어요.' '그 폴더는 그대로 두고, 안내한 사람에게 다른 설치 위치를 물어봐 주세요.'
                }
            } else {
                Stop-Install "이 폴더가 이미 있고 비어 있지 않아요: $root" '제품 폴더가 아니라서 아무것도 바꾸지 않았어요.' '그 폴더는 그대로 두고, 안내한 사람에게 다른 설치 위치를 물어봐 주세요.'
            }
        }

        if (-not $installed) {
            Confirm-Install 'Brieflark 제품 파일' "$ProductUrl (서명된 최신 release/* 태그)" $root
            $partial = $root + '.installing'
            if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Recurse -Force }
            $rootParent = Split-Path -Parent $root
            if (-not (Test-Path -LiteralPath $rootParent)) { [void](New-Item -ItemType Directory -Path $rootParent -Force) }

            Say '  내려받는 중... (파일은 서명 확인이 끝난 뒤에야 펼쳐져요)'
            $clone = Invoke-Native $gitFile @('-c', 'core.longpaths=true', '-c', 'core.autocrlf=false', 'clone', '--no-checkout', $ProductUrl, $partial)
            if ($clone.Code -ne 0) {
                Log "git clone 종료 $($clone.Code): $($clone.Text)"
                Stop-Install '제품 저장소를 받지 못했어요' '인터넷이 끊겼거나, GitHub 계정이 저장소 초대를 아직 수락하지 않았을 수 있어요.' '초대 메일의 수락 버튼을 눌렀는지 확인하고 같은 한 줄을 다시 붙여넣어 주세요.'
            }
            [void](Invoke-Native $gitFile @('-C', $partial, 'config', 'core.longpaths', 'true'))
            [void](Invoke-Native $gitFile @('-C', $partial, 'config', 'core.autocrlf', 'false'))
            $fetch = Invoke-Native $gitFile @('-C', $partial, 'fetch', '--quiet', 'origin', 'refs/tags/release/*:refs/tags/release/*')
            if ($fetch.Code -ne 0) {
                Log "git fetch tags 종료 $($fetch.Code): $($fetch.Text)"
                Stop-Install '릴리스 태그를 받지 못했어요' '인터넷이 끊겼을 수 있어요.' '같은 한 줄을 다시 붙여넣어 주세요.'
            }

            # 최신 release/* 태그 (이름 정렬 최댓값). 이름이 release/날짜-시각 모양인 것만.
            $tagList = Invoke-Native $gitFile @('-C', $partial, 'tag', '--list', 'release/*')
            $tags = @($tagList.Text -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^release/\d{8}-\d{4}$' })
            if ($tags.Count -eq 0) {
                Stop-Install '서명된 릴리스 태그가 아직 없어요' '제품 저장소에 release/* 태그가 없어요.' '안내한 사람에게 알려 주세요.'
            }
            $tag = (@($tags | Sort-Object))[-1]
            Say "  최신 릴리스: $tag"
            $tagObject = (Invoke-Native $gitFile @('-C', $partial, 'rev-parse', '--verify', "refs/tags/$tag")).Text.Trim()
            if ($tagObject -notmatch '^[0-9a-f]{40}$') {
                Stop-Install "릴리스 태그($tag)를 읽지 못했어요" 'git rev-parse 가 태그 객체를 돌려주지 않았어요.' '같은 한 줄을 다시 붙여넣어 주세요.'
            }
            $tagType = (Invoke-Native $gitFile @('-C', $partial, 'cat-file', '-t', $tagObject)).Text.Trim()

            # 내장 키만 담은 임시 파일 (ASCII, LF)
            $signersFile = Join-Path (New-WorkFolder) 'allowed_signers'
            [IO.File]::WriteAllText($signersFile, (($EmbeddedSigners -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
            $verifyArgs = @('-C', $partial, '-c', 'gpg.format=ssh',
                '-c', ('gpg.ssh.allowedSignersFile=' + (ConvertTo-ForwardSlash $signersFile)),
                '-c', ('gpg.ssh.program=' + (ConvertTo-ForwardSlash $git.SshKeygen)),
                'verify-tag', $tagObject)
            $verify = Invoke-Native $gitFile $verifyArgs
            Log "verify-tag $tag 종료 $($verify.Code): $($verify.Text)"
            if ($tagType -ne 'tag' -or $verify.Code -ne 0 -or $verify.Text -notmatch 'Good "git" signature') {
                Stop-Install "릴리스 태그($tag)의 서명이 공지와 달라요" '내장된 서명 키로 확인되지 않았어요.' '' $true
            }

            # 서명은 태그 객체 안의 머리글(object·type·tag)을 덮는다. 다른 릴리스의 서명된 태그 객체를 이 이름으로 바꿔치기하면
            # 서명은 맞아도 머리글의 태그 이름이 달라서 여기서 걸린다. 펼칠 커밋도 이 태그 객체에서만 얻는다(이름을 다시 풀지 않는다).
            $tagHeader = Invoke-Native $gitFile @('-C', $partial, 'cat-file', 'tag', $tagObject)
            $headerObject = ''
            $headerType = ''
            $headerName = ''
            foreach ($headerLine in ($tagHeader.Text -split "`n")) {
                $headerLine = $headerLine.TrimEnd("`r")
                if ($headerLine -eq '') { break }
                if ($headerLine -match '^object ([0-9a-f]{40})$') { $headerObject = $Matches[1] }
                elseif ($headerLine -match '^type (.+)$') { $headerType = $Matches[1] }
                elseif ($headerLine -match '^tag (.+)$') { $headerName = $Matches[1] }
            }
            $commit = (Invoke-Native $gitFile @('-C', $partial, 'rev-parse', '--verify', ($tagObject + '^{commit}'))).Text.Trim()
            if ($tagHeader.Code -ne 0 -or $headerType -ne 'commit' -or $headerName -cne $tag -or $headerObject -cne $commit) {
                Log "태그 머리글 불일치: 종료 $($tagHeader.Code) type=$headerType tag=$headerName object=$headerObject commit=$commit"
                Stop-Install "릴리스 태그($tag)의 머리글이 이름·커밋과 맞지 않아요" '서명된 태그 객체가 다른 이름이거나 커밋이 아닌 것을 가리켜요.' '' $true
            }
            $shown = Invoke-Native $gitFile @('-C', $partial, 'show', ($commit + ':.claude/trust/allowed_signers'))
            if ($shown.Code -ne 0 -or (Get-SignerSet ($shown.Text -split "`n")) -cne (Get-SignerSet $EmbeddedSigners)) {
                Log "태그 커밋의 allowed_signers 가 내장 키와 다름 (git show 종료 $($shown.Code))"
                Stop-Install '릴리스에 실린 서명자 목록이 공지와 달라요' '내장된 서명 키와 이 릴리스의 .claude/trust/allowed_signers 가 같지 않아요.' '' $true
            }
            Say '  서명 확인 통과'

            # 서명한 커밋을 main 으로 (마법사 5단계가 main 만 허용한다). main 의 upstream(origin/main)은 그대로 둔다.
            $checkout = Invoke-Native $gitFile @('-C', $partial, 'checkout', '--quiet', '-B', 'main', $commit)
            if ($checkout.Code -ne 0) {
                Log "git checkout 종료 $($checkout.Code): $($checkout.Text)"
                Stop-Install '제품 파일을 펼치지 못했어요' 'git checkout 이 실패했어요.' '같은 한 줄을 다시 붙여넣어 주세요.'
            }
            [void](Invoke-Native $gitFile @('-C', $partial, 'branch', '--quiet', '--set-upstream-to=origin/main', 'main'))
            # 백신·탐색기가 방금 만든 폴더를 잠시 붙잡고 있으면 이름 바꾸기가 실패한다 → 2초 간격 5회 재시도.
            $moved = $false
            for ($attempt = 1; $attempt -le 5 -and -not $moved; $attempt++) {
                try {
                    Move-Item -LiteralPath $partial -Destination $root
                    $moved = $true
                } catch {
                    Log "폴더 옮기기 실패 ${attempt}/5: $($_.Exception.Message)"
                    if ($attempt -ge 5) { throw }
                    Start-Sleep -Seconds 2
                }
            }
            Say '  받았어요'
        }

        # ---- 7 마법사 ----
        Start-Step '8' '설치 마법사'
        if ($env:BRIEFLARK_SKIP_WIZARD -eq '1') {
            Say '  BRIEFLARK_SKIP_WIZARD=1 이라 마법사는 건너뛰어요.'
            Log '마법사 건너뜀(시험)'
            return
        }
        # 인증서 준비: 갓 만든 Windows는 루트 인증서 저장소에 텔레그램 체인의 루트가 아직 없다. 마법사의 Python은 저장소에 이미 있는
        # 인증서만 읽고, Windows의 자동 루트 갱신은 schannel(curl.exe)이 체인을 만들 때만 일어난다 → 마법사 전에 curl.exe 로 한 번 접속해
        # 저장소를 데운다(2026-10-21 Sandbox: CERTIFICATE_VERIFY_FAILED). 출력은 버리고, 실패해도 멈추지 않고 기록만 한다.
        # 마법사의 Python 이 Windows에서 접속하는 곳은 텔레그램 서버뿐이다(Google 로그인은 맥 전용).
        $certCurl = Join-Path ([Environment]::SystemDirectory) 'curl.exe'
        $certHosts = @('https://api.telegram.org/')
        foreach ($certHost in $certHosts) {
            if (-not (Test-Path -LiteralPath $certCurl -PathType Leaf)) { Log 'curl.exe 가 없어 인증서 준비를 건너뜀'; break }
            $savedCertPreference = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & $certCurl -sS -o NUL --connect-timeout 20 --max-time 30 $certHost 2>&1 | Out-Null
                Log "인증서 준비 $certHost 종료 코드 $LASTEXITCODE"
            } catch {
                Log "인증서 준비 실패 $certHost"
            } finally {
                $ErrorActionPreference = $savedCertPreference
            }
        }
        Push-Location -LiteralPath $root
        try {
            $env:GIT_TERMINAL_PROMPT = $savedGitPrompt
            $setupCmd = Join-Path $root 'setup.cmd'
            if (Test-Path -LiteralPath $setupCmd -PathType Leaf) {
                $env:BRIEFLARK_SETUP_LAUNCHER = 'cmd'
                & $setupCmd
            } else {
                & uv run --no-project --python 3.12 python -X utf8 setup.py
            }
            $wizardCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        if ($wizardCode -ne 0) {
            Log "마법사 종료 $wizardCode"
            Stop-Install "설치 마법사가 중간에 멈췄어요(종료 코드 $wizardCode)" '마법사 화면에 이유가 적혀 있어요.' '화면의 안내대로 한 뒤, 같은 한 줄을 다시 붙여넣으면 이어서 해요.'
        }
    } catch {
        $caught = $_.Exception
        $isStop = ($caught.Message -eq 'BRIEFLARK_STOP')
        if ($isStop) {
            $what = [string]$caught.Data['what']; $why = [string]$caught.Data['why']; $todo = [string]$caught.Data['todo']
            $tamper = [bool]$caught.Data['tamper']
        } else {
            $what = "예상하지 못한 오류로 멈췄어요 ($($State.Step))"
            $why = [string]$caught.Message
            $todo = '인터넷 연결을 확인하고 같은 한 줄을 다시 붙여넣어 주세요. 계속되면 안내한 사람에게 아래 기록 파일을 보여 주세요.'
            $tamper = $false
        }
        Log "멈춤 [$($State.Step)] $what / $why"
        Say ''
        Say "멈췄어요: $what"
        if ($tamper) {
            Say '  공지와 다른 파일이에요. 아무것도 실행하지 않았어요. 다시 하지 말고 안내한 사람에게 알려 주세요.'
        } else {
            Say "  아마 이유: $why"
            Say "  할 일: $todo"
            Say '  같은 한 줄을 다시 붙여넣으면 이어서 해요.'
        }
        try {
            [void](New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force)
            [IO.File]::WriteAllText($LogPath, (($LogLines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
            Say "  기록: $LogPath"
        } catch { }
        return
    } finally {
        if ($State.WorkFolder -and (Test-Path -LiteralPath $State.WorkFolder)) {
            Remove-Item -LiteralPath $State.WorkFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
        $env:GIT_TERMINAL_PROMPT = $savedGitPrompt
        $env:BRIEFLARK_SETUP_LAUNCHER = $savedSetupLauncher
        if ($savedEncoding) { try { [Console]::OutputEncoding = $savedEncoding } catch { } }
        $ErrorActionPreference = $savedErrorAction
    }
}

Invoke-BrieflarkInstall
