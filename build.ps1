# Builds and signs the FPV AI Drones addon.
#
#   .\build.ps1                 # build + sign with the current key
#   .\build.ps1 -KeyName v1_2   # start a new key version for a new release
#
# Re-sign after EVERY rebuild: the signature is over the built PBO, so a stale
# .bisign fails verification exactly as hard as no signature at all.

param(
    [string]$KeyName  = "fpv_ai_drones_v1_1",
    [string]$ToolsDir = "E:\SteamLibrary\steamapps\common\Arma 3 Tools"
)

$ErrorActionPreference = "Stop"

# The Arma tools write banners to stderr on success. Windows PowerShell turns
# that into a terminating NativeCommandError under -ErrorActionPreference Stop,
# so run native exes with it relaxed and judge them by their exit code instead.
function Invoke-Tool {
    param([string]$Exe, [string[]]$Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Exe @Arguments 2>&1 | ForEach-Object { Write-Host "  $_" }
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($LASTEXITCODE -ne 0) {
        throw "$(Split-Path $Exe -Leaf) failed with exit code $LASTEXITCODE"
    }
}

$SrcDir     = $PSScriptRoot                                  # ...\FPV_AI_Drones\addons\fpv_ai_drones
$AddonsDir  = Split-Path $SrcDir -Parent                     # ...\FPV_AI_Drones\addons
$ModDir     = Split-Path $AddonsDir -Parent                  # ...\FPV_AI_Drones
$KeysDir    = Join-Path $ModDir "keys"                       # shipped public key
$PrivateDir = Join-Path (Split-Path $ModDir -Parent) "fpv_ai_drones_private"   # OUTSIDE $ModDir: Publisher uploads the whole mod folder
$Pbo        = Join-Path $AddonsDir "fpv_ai_drones.pbo"

$AddonBuilder = Join-Path $ToolsDir "AddonBuilder\AddonBuilder.exe"
$DSCreateKey  = Join-Path $ToolsDir "DSSignFile\DSCreateKey.exe"
$DSSignFile   = Join-Path $ToolsDir "DSSignFile\DSSignFile.exe"

foreach ($exe in @($AddonBuilder, $DSCreateKey, $DSSignFile)) {
    if (-not (Test-Path $exe)) { throw "Missing Arma 3 Tools component: $exe" }
}

foreach ($d in @($KeysDir, $PrivateDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

# --- key ---------------------------------------------------------------------
$PrivateKey = Join-Path $PrivateDir "$KeyName.biprivatekey"
$PublicKey  = Join-Path $KeysDir    "$KeyName.bikey"

if (-not (Test-Path $PrivateKey)) {
    Write-Host "Creating signing key '$KeyName'..."
    Push-Location $PrivateDir
    try { Invoke-Tool $DSCreateKey @($KeyName) } finally { Pop-Location }

    # DSCreateKey drops both halves next to each other; the public half ships.
    $madePublic = Join-Path $PrivateDir "$KeyName.bikey"
    if (Test-Path $madePublic) { Move-Item $madePublic $PublicKey -Force }
} else {
    Write-Host "Reusing existing key '$KeyName'."
}

# --- build -------------------------------------------------------------------
Write-Host "Building $Pbo ..."
Get-ChildItem -Path $AddonsDir -Filter "fpv_ai_drones.pbo.*.bisign" -ErrorAction SilentlyContinue |
    Remove-Item -Force            # drop signatures belonging to the previous build

Invoke-Tool $AddonBuilder @($SrcDir, $AddonsDir, "-clear", "-packonly", "-exclude=$(Join-Path $SrcDir "build_exclude.txt")")
if (-not (Test-Path $Pbo)) { throw "AddonBuilder did not produce $Pbo" }

# --- mod root metadata -------------------------------------------------------
# mod.cpp is kept in source control alongside the addon, but Arma only reads it
# from the mod ROOT. It is excluded from the PBO (build_exclude.txt) because a
# copy packed inside the archive is inert.
Copy-Item (Join-Path $SrcDir "mod.cpp") (Join-Path $ModDir "mod.cpp") -Force
Write-Host "Copied mod.cpp to mod root."

# meta.cpp carries the Workshop publishedid. Without it the Publisher uploads a
# NEW Workshop item instead of updating the existing one.
$Meta = Join-Path $ModDir "meta.cpp"
if (-not (Test-Path $Meta)) {
    Write-Warning "No meta.cpp at $ModDir - publishing from here would create a DUPLICATE Workshop item."
    Write-Warning "Create it with the publishedid from your Workshop URL before uploading:"
    Write-Warning '    protocol = 1;'
    Write-Warning '    publishedid = <id from ...?id=NNNNNNNNNN>;'
    Write-Warning '    name = "FPV AI Drones";'
}

# --- sign --------------------------------------------------------------------
Write-Host "Signing with $KeyName ..."
Invoke-Tool $DSSignFile @($PrivateKey, $Pbo)

Write-Host ""
Write-Host "Done. Ship these:"
Write-Host "  $Pbo"
Get-ChildItem -Path $AddonsDir -Filter "*.bisign" | ForEach-Object { Write-Host "  $($_.FullName)" }
Write-Host "  $PublicKey"
Write-Host ""
Write-Host "Private key (never distribute, never commit): $PrivateDir"
