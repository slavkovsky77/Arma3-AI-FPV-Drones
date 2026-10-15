# Automated, watchable test runs for FPV AI Drones - singleplayer and multiplayer.
#
#   .\tests\run_tests.ps1                 # build, then singleplayer run, then multiplayer run
#   .\tests\run_tests.ps1 -Mode MP        # just multiplayer (local dedicated server + your client)
#   .\tests\run_tests.ps1 -Mode SP        # just singleplayer
#   .\tests\run_tests.ps1 -KeepOpen       # leave the game running after the last run (e.g. to try Zeus)
#   .\tests\run_tests.ps1 -NoBuild        # skip rebuilding the PBO
#
# Both modes play the same mission (tests\FPVTest.VR) with a chase camera, and
# write results as FPV_TEST lines to the RPT, which this script follows. They
# differ in where the drone AI runs relative to you: in SP your machine is the
# server; in MP the drones live on a dedicated server and you are a client -
# which is where locality bugs (Zeus placement, duplicated explosives) show up.
#
# Only the mod's hard dependencies are loaded - no AI mods, which change how
# drones behave and would muddy the results.

param(
    [ValidateSet("Both", "MP", "SP")] [string]$Mode = "Both",
    [switch]$NoBuild,
    [ValidateRange(1, 10)] [int]$StartStage = 1,   # skip stages that already pass; 10 = skip all (straight to Zeus)
    [switch]$KeepOpen,
    [switch]$Fullscreen,   # for hands-on sessions (Zeus needs the mouse captured); default is windowed
    [switch]$ServerOnly,   # MP: start just the server; join it yourself from the normal Arma launcher
    [int]$TimeoutMinutes = 20,
    [string]$ProfileName = "vulcan420",
    [string]$ArmaDir = "E:\SteamLibrary\steamapps\common\Arma 3"
)

$ErrorActionPreference = "Stop"

$RepoDir   = Split-Path $PSScriptRoot -Parent
$Mission   = Join-Path $PSScriptRoot "FPVTest.VR"
# CBA is required by the Crocus drone mod (ArmaFPV_Data -> cba_settings), not by FPV AI Drones itself.
$Mods      = "!Workshop\@CBA_A3;x\FPV Drone Crocus With Settings;x\FPV_AI_Drones"   # relative to $ArmaDir
$WorkDir   = Join-Path $env:TEMP "fpv_ai_drones_test"     # server profile, config and RPT
$ClientLogs = Join-Path $env:LOCALAPPDATA "Arma 3"
$Password  = "fpvtest"
$Port      = 2402                                         # off the default 2302
$Interesting = 'FPV_TEST\||FPV_AI_Drones:|Error in expression|Error position|Error Undefined|Error Type|Error Missing|Error Generic'

function Stop-TestServer {
    # Closing the game doesn't close the server console, so stop any left over -
    # but only servers running from our test profile directory.
    Get-CimInstance Win32_Process -Filter "Name = 'arma3server_x64.exe'" |
        Where-Object { $_.CommandLine -like "*fpv_ai_drones_test*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host "Stopped test server (pid $($_.ProcessId))." }
}

function Stop-Game {
    Get-Process -Name arma3_x64 -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 3
}

function Start-Game([string[]]$ExtraArgs) {
    # -window: a fullscreen game that starts behind another window (the server console
    # in MP) tends to hang when you switch to it. Windowed avoids that; maximize at will.
    $argList = @("`"-name=$ProfileName`"", "`"-mod=$Mods`"", "-skipIntro", "-noSplash", "-world=empty", "-showScriptErrors") + $ExtraArgs
    if (-not $Fullscreen) { $argList += "-window" }
    Start-Process -FilePath (Join-Path $ArmaDir "arma3_x64.exe") -WorkingDirectory $ArmaDir -ArgumentList $argList | Out-Null
}

# Follows whichever RPT $FindRpt returns, printing FPV lines as they appear.
# Returns @{ Passed; Total } from the SUMMARY line, or $null on timeout / no start.
function Watch-Run([string]$Label, [scriptblock]$FindRpt, [scriptblock]$StillRunning) {
    $seen = 0
    $started = $false
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $startDeadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        $rpt = & $FindRpt
        if ($rpt) {
            $lines = @(Get-Content $rpt.FullName -ErrorAction SilentlyContinue | Where-Object { $_ -match $Interesting })
            for ($i = $seen; $i -lt $lines.Count; $i++) {
                $l = $lines[$i]
                if ($l -match 'FPV_TEST\|START') { $started = $true }
                $color = if ($l -match '\|PASS\|') { "Green" } elseif ($l -match '\|FAIL\||Error') { "Red" } elseif ($l -match 'SUMMARY') { "Cyan" } else { "Gray" }
                Write-Host "[$Label] $l" -ForegroundColor $color
                if ($l -match 'FPV_TEST\|SUMMARY\|(\d+)/(\d+)') { return @{ Passed = [int]$Matches[1]; Total = [int]$Matches[2]; Rpt = $rpt.FullName } }
            }
            $seen = $lines.Count
        }
        if (-not $started -and (Get-Date) -gt $startDeadline) {
            Write-Host "[$Label] The test mission never started (no FPV_TEST|START within 5 minutes)." -ForegroundColor Red
            return $null
        }
        if (-not (& $StillRunning)) { Write-Host "[$Label] Game/server exited before the run finished." -ForegroundColor Red; return $null }
        Start-Sleep -Seconds 2
    }
    Write-Host "[$Label] Timed out after $TimeoutMinutes minutes." -ForegroundColor Red
    return $null
}

function Invoke-SpRun {
    Write-Host "== Singleplayer run ==" -ForegroundColor Cyan
    # -init=playMission only finds missions in the GAME's Missions folder; a copy
    # in the profile's missions folder is silently ignored (the game just sits
    # at the main menu). SP also needs a real player unit (isPlayer) rather than
    # an MP slot (isPlayable).
    $spMission = Join-Path $ArmaDir "Missions\FPVTest.VR"
    if (Test-Path $spMission) { Remove-Item $spMission -Recurse -Force }
    New-Item -ItemType Directory -Force (Split-Path $spMission) | Out-Null
    Copy-Item $Mission $spMission -Recurse
    "FPVT_startStage = $StartStage;" | Set-Content -Encoding ASCII (Join-Path $spMission "testconfig.sqf")
    $sqm = Join-Path $spMission "mission.sqm"
    (Get-Content $sqm -Raw).Replace("isPlayable=1;", "isPlayer=1;") | Set-Content -Encoding ASCII -NoNewline $sqm

    $since = Get-Date
    Start-Game @("-init=playMission['','FPVTest.VR',true]")
    $result = Watch-Run "SP" {
        Get-ChildItem $ClientLogs -Filter "arma3_x64_*.rpt" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $since } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    } { [bool](Get-Process arma3_x64 -ErrorAction SilentlyContinue) }
    return $result
}

function Invoke-MpRun {
    Write-Host "== Multiplayer run (local dedicated server on port $Port) ==" -ForegroundColor Cyan
    $mpMission = Join-Path $ArmaDir "MPMissions\FPVTest.VR"
    if (Test-Path $mpMission) { Remove-Item $mpMission -Recurse -Force }
    New-Item -ItemType Directory -Force (Split-Path $mpMission) | Out-Null
    Copy-Item $Mission $mpMission -Recurse
    "FPVT_startStage = $StartStage;" | Set-Content -Encoding ASCII (Join-Path $mpMission "testconfig.sqf")

    New-Item -ItemType Directory -Force $WorkDir | Out-Null
    Get-ChildItem $WorkDir -Filter *.rpt -ErrorAction SilentlyContinue | Remove-Item -Force
    $serverCfg = Join-Path $WorkDir "server.cfg"
    @"
hostname = "FPV AI Drones test (local)";
password = "$Password";
loopback = 1;
verifySignatures = 0;
BattlEye = 0;
persistent = 1;
kickDuplicate = 0;
class Missions
{
    class FPVTest
    {
        template = "FPVTest.VR";
        difficulty = "Regular";
    };
};
"@ | Set-Content -Encoding ASCII $serverCfg

    $since = Get-Date
    # Minimized: the console taking focus is what left the fullscreen game hanging.
    Start-Process -FilePath (Join-Path $ArmaDir "arma3server_x64.exe") -WorkingDirectory $ArmaDir -WindowStyle Minimized -ArgumentList @(
        "-port=$Port", "`"-config=$serverCfg`"", "`"-profiles=$WorkDir`"", "-name=fpvtest", "`"-mod=$Mods`"", "-autoInit"
    ) | Out-Null

    $listenDeadline = (Get-Date).AddMinutes(2)
    while (-not (Get-NetUDPEndpoint -LocalPort $Port -ErrorAction SilentlyContinue)) {
        if ((Get-Date) -gt $listenDeadline) { throw "Server did not open port $Port within 2 minutes. Check $WorkDir for its RPT." }
        if (-not (Get-Process arma3server_x64 -ErrorAction SilentlyContinue)) { throw "Server exited during startup. Check $WorkDir for its RPT." }
        Start-Sleep -Seconds 2
    }
    Start-Sleep -Seconds 5   # port opens slightly before the mission is ready

    if ($ServerOnly) {
        # Hands-on MP: the player joins from the normal Arma launcher, like real users do.
        Write-Host ""
        Write-Host "Server is up (console minimized on the taskbar). Join it from the Arma 3 Launcher:" -ForegroundColor Green
        Write-Host "  1. Mods: enable CBA_A3, plus the local mods x\FPV Drone Crocus With Settings and x\FPV_AI_Drones"
        Write-Host "  2. Play, then Multiplayer > Direct Connect: 127.0.0.1  port $Port  password $Password"
        Write-Host "  3. You get Zeus ~10s after joining - press Y"
        return @{ Passed = 0; Total = 0 }
    }
    Start-Game @("-connect=127.0.0.1", "-port=$Port", "-password=$Password")
    $result = Watch-Run "MP" {
        Get-ChildItem $WorkDir -Filter *.rpt -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    } { [bool](Get-Process arma3server_x64 -ErrorAction SilentlyContinue) }

    # Detonations must happen on the server only. One in the CLIENT log means
    # explosives are being created on more than one machine again.
    $clientRpt = Get-ChildItem $ClientLogs -Filter "arma3_x64_*.rpt" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $since } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($result -and $clientRpt) {
        $clientLines = @(Get-Content $clientRpt.FullName -ErrorAction SilentlyContinue)
        $clientDetonations = @($clientLines | Where-Object { $_ -match 'FPV_AI_Drones: .* detonating' }).Count
        $clientErrors = @($clientLines | Where-Object { $_ -match 'Error in expression' }).Count
        Write-Host "[MP] client detonations (must be 0): $clientDetonations" -ForegroundColor ($(if ($clientDetonations -eq 0) { "Green" } else { "Red" }))
        if ($clientErrors) { Write-Host "[MP] client script errors: $clientErrors - see $($clientRpt.FullName)" -ForegroundColor Red }
        $result.Total += 1
        if ($clientDetonations -eq 0) { $result.Passed += 1 }
    }
    return $result
}

# --- main ---------------------------------------------------------------------
if ($ServerOnly) {
    # A hands-on session: multiplayer, server stays up, straight to Zeus unless told otherwise.
    $Mode = "MP"
    $KeepOpen = $true
    if (-not $PSBoundParameters.ContainsKey('StartStage')) { $StartStage = 10 }
}
if (-not $ServerOnly -and (Get-Process -Name arma3_x64 -ErrorAction SilentlyContinue)) { throw "Arma 3 is already running. Close it first." }
Stop-TestServer
if (Get-Process -Name arma3server_x64 -ErrorAction SilentlyContinue) { throw "An Arma 3 server that isn't a test server is running. Stop it first." }

if (-not $NoBuild) {
    Write-Host "== Building mod ==" -ForegroundColor Cyan
    & (Join-Path $RepoDir "build.ps1") | Out-Null
}

# @(...) around the whole if: PowerShell unrolls a one-element array returned from an
# if-expression into a plain string, and $modes[-1] would then be its last CHARACTER.
$modes = @(if ($Mode -eq "Both") { "SP", "MP" } else { $Mode })
$results = [ordered]@{}
foreach ($m in $modes) {
    $results[$m] = if ($m -eq "SP") { Invoke-SpRun } else { Invoke-MpRun }
    $isLast = ($m -eq $modes[-1])
    if (-not $isLast -or -not $KeepOpen) {
        Start-Sleep -Seconds 12   # time to read the scoreboard
        Stop-Game
        Stop-TestServer
    }
}

Write-Host ""
$allOk = $true
foreach ($m in $results.Keys) {
    $r = $results[$m]
    if ($r) {
        $ok = $r.Passed -eq $r.Total
        Write-Host ("RESULT {0}: {1}/{2} checks passed" -f $m, $r.Passed, $r.Total) -ForegroundColor ($(if ($ok) { "Green" } else { "Red" }))
    } else {
        $ok = $false
        Write-Host "RESULT ${m}: no summary - see the log above" -ForegroundColor Red
    }
    $allOk = $allOk -and $ok
}
if ($KeepOpen) { Write-Host "Game left running - press Y in game for Zeus. Close it (and the server console, in MP) when done." }

exit ([int](-not $allOk))
