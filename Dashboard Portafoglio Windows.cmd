@echo off
setlocal EnableExtensions

rem Dashboard Portafoglio - installer, aggiornamento e avvio per Windows.
rem Repository GitHub: Msantelli-dev/Dashboard_Portafoglio

set "DASH_SELF=%~f0"
set "DASH_PS=%TEMP%\dashboard_portafoglio_%RANDOM%_%RANDOM%.ps1"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$content=[IO.File]::ReadAllText($env:DASH_SELF); $marker=':POWERSHELL'+'_SCRIPT'; $index=$content.IndexOf($marker); if($index -lt 0){exit 2}; $script=$content.Substring($index+$marker.Length); $utf8=New-Object System.Text.UTF8Encoding($false); [IO.File]::WriteAllText($env:DASH_PS,$script,$utf8)"
if errorlevel 1 (
  echo.
  echo Errore: non riesco a preparare il programma di avvio.
  pause
  exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DASH_PS%"
set "DASH_EXIT=%ERRORLEVEL%"
del /q "%DASH_PS%" >nul 2>&1

if not "%DASH_EXIT%"=="0" (
  echo.
  echo Operazione non completata. Codice errore: %DASH_EXIT%
  pause
)
exit /b %DASH_EXIT%

:POWERSHELL_SCRIPT
$ErrorActionPreference = 'Stop'

$Repo = 'Msantelli-dev/Dashboard_Portafoglio'
$AssetName = 'Dashboard_Portafoglio_Locale.zip'
$AppDir = Join-Path $env:LOCALAPPDATA 'Dashboard_Portafoglio'
$ApiUrl = "https://api.github.com/repos/$Repo/releases/latest"
$LocalUrl = 'http://127.0.0.1:8765'
$Port = 8765
$PidFile = Join-Path $AppDir '.dashboard_server.pid'
$LogFile = Join-Path $AppDir 'dashboard_server.log'
$ErrorLogFile = Join-Path $AppDir 'dashboard_server_error.log'

function Write-Info([string]$Message) {
    Write-Host $Message -ForegroundColor Cyan
}

function Write-Success([string]$Message) {
    Write-Host $Message -ForegroundColor Green
}

function Fail([string]$Message) {
    Write-Host ''
    Write-Host "Errore: $Message" -ForegroundColor Red
    exit 1
}

function Get-PythonLauncher {
    $py = Get-Command 'py.exe' -ErrorAction SilentlyContinue
    if ($py) {
        try {
            & $py.Source -3 --version *> $null
            if ($LASTEXITCODE -eq 0) {
                return [pscustomobject]@{ File = $py.Source; Prefix = @('-3') }
            }
        } catch {}
    }

    foreach ($name in @('python.exe', 'python3.exe')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) {
            try {
                & $command.Source --version *> $null
                if ($LASTEXITCODE -eq 0) {
                    return [pscustomobject]@{ File = $command.Source; Prefix = @() }
                }
            } catch {}
        }
    }
    return $null
}

function Test-DashboardServer {
    try {
        $response = Invoke-RestMethod -Uri "$LocalUrl/api/status" -TimeoutSec 1
        return [bool]($response.ok)
    } catch {
        return $false
    }
}

function Stop-DashboardServer {
    if (-not (Test-DashboardServer)) {
        return
    }

    $stopped = $false
    if (Test-Path -LiteralPath $PidFile) {
        $savedPid = (Get-Content -LiteralPath $PidFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($savedPid -match '^\d+$') {
            $process = Get-Process -Id ([int]$savedPid) -ErrorAction SilentlyContinue
            if ($process) {
                Write-Info 'Arresto la versione precedente...'
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                $stopped = $true
            }
        }
    }

    if (-not $stopped) {
        try {
            $escapedPath = [Regex]::Escape((Join-Path $AppDir 'dashboard_server.py'))
            $processes = Get-CimInstance Win32_Process -ErrorAction Stop |
                Where-Object { $_.CommandLine -and $_.CommandLine -match $escapedPath }
            foreach ($process in $processes) {
                Write-Info 'Arresto la versione precedente...'
                Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
                $stopped = $true
            }
        } catch {}
    }

    if ($stopped) {
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep -Milliseconds 200
            if (-not (Test-DashboardServer)) { break }
        }
    }
}

$python = Get-PythonLauncher
if (-not $python) {
    Write-Host 'Python 3 non e installato o non e disponibile nel PATH.' -ForegroundColor Yellow
    Write-Host 'Scaricalo da https://www.python.org/downloads/windows/'
    Write-Host 'Durante l installazione seleziona Add python.exe to PATH.'
    try { Start-Process 'https://www.python.org/downloads/windows/' } catch {}
    exit 1
}

$tempDir = Join-Path ([IO.Path]::GetTempPath()) ("dashboard-portafoglio-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    Write-Info 'Controllo aggiornamenti Dashboard Portafoglio...'
    $headers = @{
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'Dashboard-Portafoglio-Windows'
    }
    $release = Invoke-RestMethod -Uri $ApiUrl -Headers $headers -TimeoutSec 30

    $latestTag = [string]$release.tag_name
    if ([string]::IsNullOrWhiteSpace($latestTag)) {
        Fail 'La Release piu recente non contiene un tag valido.'
    }

    $asset = $release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
    if (-not $asset) {
        Fail "Nella Release $latestTag non trovo l asset $AssetName."
    }

    $latestVersion = $latestTag.TrimStart('v')
    $versionFile = Join-Path $AppDir 'VERSION'
    $localVersion = ''
    if (Test-Path -LiteralPath $versionFile) {
        $localVersion = (Get-Content -LiteralPath $versionFile -Raw).Trim()
    }

    $serverPath = Join-Path $AppDir 'dashboard_server.py'
    $htmlPath = Join-Path $AppDir 'dashboard_portafoglio_locale.html'
    $needsUpdate = (-not (Test-Path -LiteralPath $serverPath)) -or
                   (-not (Test-Path -LiteralPath $htmlPath)) -or
                   ($localVersion -ne $latestVersion)

    if ($needsUpdate) {
        Write-Info "Installazione o aggiornamento alla versione $latestVersion..."
        $zipPath = Join-Path $tempDir $AssetName
        $unpackDir = Join-Path $tempDir 'unpacked'
        New-Item -ItemType Directory -Path $unpackDir -Force | Out-Null

        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -Headers @{ 'User-Agent' = 'Dashboard-Portafoglio-Windows' } -TimeoutSec 120
        Expand-Archive -LiteralPath $zipPath -DestinationPath $unpackDir -Force

        $serverSource = Get-ChildItem -LiteralPath $unpackDir -Recurse -File -Filter 'dashboard_server.py' | Select-Object -First 1
        if (-not $serverSource) {
            Fail 'Nello ZIP non trovo dashboard_server.py.'
        }
        $sourceDir = $serverSource.Directory.FullName
        $htmlSource = Join-Path $sourceDir 'dashboard_portafoglio_locale.html'
        if (-not (Test-Path -LiteralPath $htmlSource)) {
            Fail 'Nello ZIP non trovo dashboard_portafoglio_locale.html.'
        }

        Stop-DashboardServer
        New-Item -ItemType Directory -Path $AppDir -Force | Out-Null
        Copy-Item -LiteralPath $serverSource.FullName -Destination $serverPath -Force
        Copy-Item -LiteralPath $htmlSource -Destination $htmlPath -Force

        $readmeSource = Join-Path $sourceDir 'LEGGIMI.txt'
        if (Test-Path -LiteralPath $readmeSource) {
            Copy-Item -LiteralPath $readmeSource -Destination (Join-Path $AppDir 'LEGGIMI.txt') -Force
        }
        Set-Content -LiteralPath $versionFile -Value $latestVersion -Encoding ASCII
        Write-Success 'Aggiornamento completato.'
    } else {
        Write-Success "Versione $localVersion gia aggiornata."
    }

    if (Test-DashboardServer) {
        Write-Success 'La dashboard e gia avviata.'
        Start-Process $LocalUrl
        exit 0
    }

    Write-Info 'Avvio della dashboard locale...'
    New-Item -ItemType Directory -Path $AppDir -Force | Out-Null
    Remove-Item -LiteralPath $LogFile, $ErrorLogFile -Force -ErrorAction SilentlyContinue

    $arguments = @()
    $arguments += $python.Prefix
    $arguments += ('"' + $serverPath + '"')
    $arguments += '--no-browser'

    $process = Start-Process -FilePath $python.File `
        -ArgumentList $arguments `
        -WorkingDirectory $AppDir `
        -WindowStyle Hidden `
        -RedirectStandardOutput $LogFile `
        -RedirectStandardError $ErrorLogFile `
        -PassThru

    Set-Content -LiteralPath $PidFile -Value $process.Id -Encoding ASCII

    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 300
        if (Test-DashboardServer) {
            Write-Success "Dashboard avviata: $LocalUrl"
            Start-Process $LocalUrl
            exit 0
        }
        if ($process.HasExited) { break }
    }

    Write-Host 'Il server non si e avviato correttamente.' -ForegroundColor Red
    Write-Host "Controlla i file:`n$LogFile`n$ErrorLogFile"
    exit 1
}
catch {
    Write-Host ''
    Write-Host 'Errore durante installazione o avvio:' -ForegroundColor Red
    Write-Host $_.Exception.Message
    exit 1
}
finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
