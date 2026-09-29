<#
  fix-flutter-path.ps1

  Purpose
  -------
  Make bare `flutter` resolve to D:\flutter\bin (Flutter 3.41.1 stable)
  instead of D:\flutter_flutter\bin (HarmonyOS branch 3.27.5-ohos).

  Why
  ---
  Windows builds the effective PATH as MACHINE entries first, then USER entries.
  `D:\flutter_flutter\bin` sits in MACHINE PATH at index 0, and `D:\flutter\bin`
  is not in PATH at all -> bare `flutter` always hits the HarmonyOS branch, which
  breaks Android builds (TargetPlatform.ohos exhaustiveness, missing 3.41 APIs).

  This script inserts `D:\flutter\bin` immediately BEFORE `D:\flutter_flutter\bin`
  in MACHINE PATH, leaving the HarmonyOS entry untouched.

  IMPORTANT
  ---------
  * MUST run as Administrator (MACHINE-level PATH write).
  * NEVER uses `setx` -- setx truncates PATH at 1024 chars and would DESTROY it.
    Machine PATH here is ~1442 chars.
  * A backup of the previous MACHINE PATH is written before any change.
  * After running, open a NEW terminal for the change to take effect.

  Usage
  -----
    powershell -ExecutionPolicy Bypass -File fix-flutter-path.ps1            # apply
    powershell -ExecutionPolicy Bypass -File fix-flutter-path.ps1 -Check     # check only
    powershell -ExecutionPolicy Bypass -File fix-flutter-path.ps1 -Rollback  # restore newest backup
#>

param(
    [switch]$Check,
    [switch]$Rollback
)

$ErrorActionPreference = 'Stop'

$WANT  = 'D:\flutter\bin'
$OTHER = 'D:\flutter_flutter\bin'
$STAMP = Get-Date -Format 'yyyyMMdd-HHmmss'
$BACKUP = Join-Path $env:USERPROFILE ("PATH-machine-backup-$STAMP.txt")

function Say  ($m) { Write-Host "       $m" }
function Fine ($m) { Write-Host "[ OK ] $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Die  ($m) { Write-Host "[FAIL] $m" -ForegroundColor Red; exit 1 }

# ---- 1. read MACHINE PATH (readable WITHOUT admin) -----------------------
Write-Host "=== flutter PATH fix ===" -ForegroundColor Cyan
$m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ([string]::IsNullOrWhiteSpace($m)) { Die "Could not read MACHINE PATH." }
Say ("MACHINE PATH length : {0}" -f $m.Length)

# ---- 2. inspect current state --------------------------------------------
$parts = @($m -split ';')
$idxWant  = -1
$idxOther = -1
for ($i = 0; $i -lt $parts.Count; $i++) {
    $t = $parts[$i].Trim()
    if ($t -ieq $WANT)  { $idxWant  = $i }
    if ($t -ieq $OTHER) { $idxOther = $i }
}
Say ("index of {0}  = {1}" -f $WANT,  $idxWant)
Say ("index of {0} = {1}" -f $OTHER, $idxOther)

$alreadyOk = ($idxWant -ge 0) -and (($idxOther -lt 0) -or ($idxWant -lt $idxOther))

# ---- 3. check-only mode: NO admin needed ---------------------------------
if ($Check) {
    if ($alreadyOk) { Fine "Already correct - nothing to do."; exit 0 }
    Warn "Not fixed yet. Apply by running as Administrator without -Check."
    exit 2
}

# ---- 4. admin required from here on --------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Say ("Administrator : {0}" -f $isAdmin)
if (-not $isAdmin) {
    Die "Must run as Administrator. Right-click PowerShell -> 'Run as administrator'."
}

# ---- 5. rollback mode -----------------------------------------------------
if ($Rollback) {
    $b = Get-ChildItem (Join-Path $env:USERPROFILE 'PATH-machine-backup-*.txt') -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $b) { Die "No backup file found in $env:USERPROFILE" }
    $restored = [IO.File]::ReadAllText($b.FullName)
    if ([string]::IsNullOrWhiteSpace($restored)) { Die "Backup file is empty: $($b.Name)" }
    [Environment]::SetEnvironmentVariable('Path', $restored, 'Machine')
    Fine ("Restored MACHINE PATH from {0} ({1} chars)" -f $b.Name, $restored.Length)
    Warn "Open a NEW terminal to pick up the restored PATH."
    exit 0
}

# ---- 6. nothing to do? ----------------------------------------------------
if ($alreadyOk) { Fine "Already correct - nothing to do."; exit 0 }

# ---- 7. build the new list (insert WANT before OTHER) ---------------------
$clean = New-Object System.Collections.ArrayList
foreach ($p in $parts) {
    $t = $p.Trim()
    if ($t -eq '') { continue }
    if ($t -ieq $WANT) { continue }        # drop any stale duplicate of WANT
    [void]$clean.Add($t)
}

$new = New-Object System.Collections.ArrayList
$inserted = $false
foreach ($t in $clean) {
    if ((-not $inserted) -and ($t -ieq $OTHER)) {
        [void]$new.Add($WANT)
        $inserted = $true
    }
    [void]$new.Add($t)
}
if (-not $inserted) {
    # OTHER not present -> just prepend so bare `flutter` resolves to WANT
    $new.Insert(0, $WANT)
}

$newStr = ($new -join ';')

# ---- 8. safety guards -----------------------------------------------------
if ($newStr.Length -lt [int]($m.Length * 0.9)) {
    Die ("Refusing to apply: new PATH ({0}) is much shorter than old ({1})." -f $newStr.Length, $m.Length)
}
if ($newStr.Length -ge 2047) {
    Warn ("New MACHINE PATH is {0} chars (close to the 2047 limit)." -f $newStr.Length)
}

# ---- 9. backup -----------------------------------------------------------
[IO.File]::WriteAllText($BACKUP, $m, (New-Object Text.UTF8Encoding($false)))
Fine ("Backup written: {0}" -f $BACKUP)
Say  ("  ({0} chars)" -f $m.Length)

# ---- 10. apply + read back ------------------------------------------------
[Environment]::SetEnvironmentVariable('Path', $newStr, 'Machine')
$verify = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($verify -ne $newStr) {
    Die "Read-back mismatch. Restore with:  -Rollback"
}
Fine ("Applied. MACHINE PATH length {0} -> {1}" -f $m.Length, $verify.Length)

Write-Host ""
Say "flutter entries in MACHINE PATH (new order):"
$vp = @($verify -split ';')
for ($i = 0; $i -lt $vp.Count; $i++) {
    if ($vp[$i] -match 'flutter') { Say ("  [{0}] {1}" -f $i, $vp[$i]) }
}

Write-Host ""
Write-Host "Next steps" -ForegroundColor Cyan
Say "1. Open a NEW terminal (existing ones keep the old PATH)."
Say "2. Verify:   Get-Command flutter"
Say "             -> should print  D:\flutter\bin\flutter.bat"
Say "3. To undo:  powershell -ExecutionPolicy Bypass -File fix-flutter-path.ps1 -Rollback"
