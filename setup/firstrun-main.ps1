# NARENJI-SETUP main script  (version 4)
# Run by firstrun.ps1. The newest copy is downloaded from GitHub (narenji-tools-updates/setup/firstrun-main.ps1),
# the copy on the USB stick is only the fallback - so this file can be fixed without touching the sticks.
#   - .NET Desktop runtime is installed FIRST so NarenjiStore Tools opens and starts drivers within a minute or two
#   - every installer has a time limit: a stuck one is killed and logged, setup always finishes
#   - setup waits for the driver install (Tools --drivers) before restarting
param([string]$S = 'C:\NarenjiSetup')
$ErrorActionPreference = 'Continue'
$start = Get-Date
$td = "$env:ProgramFiles\NarenjiStore"; $nd = "$env:ProgramFiles\Narenji"
$a = "$S\apps"; $r = "$S\runtimes"
$busyFlag = "$env:WINDIR\Temp\narenji-drivers-busy"
function Note($s, $c = 'Gray') { Write-Host "   $s" -ForegroundColor $c }

# ---------- Start menu fix (Microsoft KB5072911) ----------
# Images with a 2025+ cumulative update can show the first desktop before the XAML shell packages are registered
# for the user: Start, Search and Settings then never open, even after restarts. Register them for this user now,
# and through Active Setup for every account made later (Active Setup runs before that account's desktop starts).
$shellFix = "$env:ProgramData\NarenjiStore\shell-fix.ps1"
New-Item -ItemType Directory -Force (Split-Path $shellFix) | Out-Null
Set-Content $shellFix -Encoding UTF8 -Value @'
foreach ($p in 'Microsoft.UI.Xaml.CBS_8wekyb3d8bbwe', 'MicrosoftWindows.Client.CBS_cw5n1h2txyewy', 'MicrosoftWindows.Client.Core_cw5n1h2txyewy') {
  $m = "$env:WINDIR\SystemApps\$p\appxmanifest.xml"
  if (Test-Path $m) { try { Add-AppxPackage -Register -Path $m -DisableDevelopmentMode -ErrorAction Stop } catch { } }
}
'@
try {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $shellFix
  Get-Process StartMenuExperienceHost, ShellExperienceHost, SearchHost -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  $as = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{6E1B3F2A-9C4D-4E8B-A1F0-5A7C2D9E3B41}'
  New-Item $as -Force | Out-Null
  Set-ItemProperty $as '(default)' 'NarenjiStore Start menu fix'
  Set-ItemProperty $as 'StubPath' "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$shellFix`""
  Set-ItemProperty $as 'Version' '1,0'
  Set-ItemProperty $as 'IsInstalled' 1 -Type DWord
  Note 'Start menu fix applied' Green
} catch { Note "Start menu fix failed: $($_.Exception.Message)" Red }


# ---------- copy-only items + shortcuts first ----------
New-Item -ItemType Directory -Force $nd, $td | Out-Null
Copy-Item "$S\narenji\*" $nd -Recurse -Force
Copy-Item "$S\tools\*"   $td -Recurse -Force
$sh = New-Object -ComObject WScript.Shell
function Link($path, $target, $desc) { $l = $sh.CreateShortcut($path); $l.TargetPath = $target; $l.WorkingDirectory = Split-Path $target; $l.Description = $desc; $l.Save() }
$pubDesk = "$env:PUBLIC\Desktop"; $pubStart = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"
Link "$pubDesk\Narenji.lnk"             "$nd\Narenji.exe"      'Narenji'
Link "$pubStart\Narenji.lnk"            "$nd\Narenji.exe"      'Narenji'
Link "$pubDesk\NarenjiStore Tools.lnk"  "$td\NarenjiTools.exe" 'Update apps and drivers, change account name'
Link "$pubStart\NarenjiStore Tools.lnk" "$td\NarenjiTools.exe" 'Update apps and drivers, change account name'

# ---------- installers ----------
# each: name, file, args, limit (minutes)
$tasks = [Collections.ArrayList]@()
function Launch($name, $file, $arguments, $limit) {
  if (-not (Test-Path $file)) { Note "missing: $file" Red; return }
  $p = Start-Process -FilePath $file -ArgumentList $arguments -PassThru -WindowStyle Hidden
  [void]$tasks.Add([pscustomobject]@{ Name = $name; Proc = $p; Limit = $limit; Start = Get-Date; State = 'installing'; Code = $null })
}

# MSI chain: one at a time (Windows Installer allows one). .NET first -> Tools can start early.
$chain = @(
  @('.NET 8 Desktop',  "$r\windowsdesktop-runtime-8-x64.exe", '/install /quiet /norestart'),
  @('VC++ 2015-2022 x64', "$r\vc2015-2022_x64.exe", '/install /quiet /norestart'),
  @('VC++ 2015-2022 x86', "$r\vc2015-2022_x86.exe", '/install /quiet /norestart'),
  @('Google Chrome',   'msiexec.exe', "/i `"$a\ChromeEnterprise64.msi`" /qn /norestart"),
  @('VC++ 2013 x64', "$r\vc2013_x64.exe", '/install /quiet /norestart'), @('VC++ 2013 x86', "$r\vc2013_x86.exe", '/install /quiet /norestart'),
  @('VC++ 2012 x64', "$r\vc2012_x64.exe", '/install /quiet /norestart'), @('VC++ 2012 x86', "$r\vc2012_x86.exe", '/install /quiet /norestart'),
  @('VC++ 2010 x64', "$r\vc2010_x64.exe", '/q /norestart'), @('VC++ 2010 x86', "$r\vc2010_x86.exe", '/q /norestart'),
  @('VC++ 2008 x64', "$r\vc2008_x64.exe", '/q'), @('VC++ 2008 x86', "$r\vc2008_x86.exe", '/q'),
  @('VC++ 2005 x64', "$r\vc2005_x64.exe", '/q'), @('VC++ 2005 x86', "$r\vc2005_x86.exe", '/q')
)
$chainIdx = 0; $chainCur = $null; $chainLog = @()
function NextInChain {
  while ($script:chainIdx -lt $chain.Count) {
    $c = $chain[$script:chainIdx]; $script:chainIdx++
    if ($c[1] -ne 'msiexec.exe' -and -not (Test-Path $c[1])) { $script:chainLog += "missing $($c[1])"; continue }
    $script:chainCur = [pscustomobject]@{ Name = $c[0]; Proc = (Start-Process -FilePath $c[1] -ArgumentList $c[2] -PassThru -WindowStyle Hidden); Start = Get-Date }
    return
  }
  $script:chainCur = $null
}
NextInChain

Launch 'Microsoft Office' "$S\office\setup.exe" "/configure `"$S\office\config.xml`"" 45
Launch 'WinRAR'  "$a\winrar-x64.exe" '/S' 10
Launch 'VLC'     "$a\vlc-win64.exe"  '/L=1033 /S' 10
Launch 'IDM'     "$a\idman.exe"      '/skipdlgs' 10
Launch 'Hiddify' "$a\Hiddify-Setup-x64.exe" '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' 10
$dx = "$env:TEMP\dxredist"
if (Test-Path "$r\directx_Jun2010_redist.exe") {
  $p = Start-Process cmd.exe -ArgumentList "/c `"`"$r\directx_Jun2010_redist.exe`" /Q /T:`"$dx`" && `"$dx\DXSETUP.exe`" /silent`"" -PassThru -WindowStyle Hidden
  [void]$tasks.Add([pscustomobject]@{ Name = 'DirectX'; Proc = $p; Limit = 15; Start = Get-Date; State = 'installing'; Code = $null })
}

# ---------- live status; starts Tools (drivers) as soon as .NET is in ----------
$toolsStarted = $false
function DotnetReady { [bool](Get-ChildItem "$env:ProgramFiles\dotnet\shared\Microsoft.WindowsDesktop.App" -Directory -Filter '8.*' -ErrorAction SilentlyContinue) }
function KillTree($p) { try { taskkill /T /F /PID $p.Id 2>&1 | Out-Null } catch { } }
$top = try { [Console]::CursorTop + 1 } catch { 0 }
while ($true) {
  # MSI chain: advance / time-limit (10 min per item)
  if ($chainCur) {
    if ($chainCur.Proc.HasExited) { $chainLog += "$($chainCur.Name) -> exit $($chainCur.Proc.ExitCode)"; NextInChain }
    elseif (((Get-Date) - $chainCur.Start).TotalMinutes -gt 10) { KillTree $chainCur.Proc; $chainLog += "$($chainCur.Name) -> TIMED OUT (killed after 10 min)"; NextInChain }
  }
  foreach ($t in $tasks) {
    if ($t.State -ne 'installing') { continue }
    if ($t.Proc.HasExited) { $t.State = 'done'; $t.Code = $t.Proc.ExitCode }
    elseif (((Get-Date) - $t.Start).TotalMinutes -gt $t.Limit) { KillTree $t.Proc; $t.State = 'TIMED OUT'; $t.Code = "killed after $($t.Limit) min" }
  }
  if (-not $toolsStarted -and (DotnetReady)) {
    Start-Process "$td\NarenjiTools.exe" -ArgumentList '--drivers'
    $toolsStarted = $true
  }

  try { [Console]::SetCursorPosition(0, $top) } catch { }
  foreach ($t in $tasks) {
    $col = switch ($t.State) { 'done' { 'Green' } 'installing' { 'Gray' } default { 'Red' } }
    Write-Host ("   [{0,-10}]  {1,-34}" -f $t.State, $t.Name) -ForegroundColor $col
  }
  $cs = if ($chainCur) { "installing: $($chainCur.Name)" } else { 'done' }
  Write-Host ("   [{0,-10}]  Runtimes + Chrome  ({1})          " -f $(if ($chainCur) { 'installing' } else { 'done' }), $cs) -ForegroundColor $(if ($chainCur) { 'Gray' } else { 'Green' })
  $ds = if (-not $toolsStarted) { 'waiting for .NET' } elseif (Test-Path $busyFlag) { 'running in NarenjiStore Tools' } else { 'finished (see Tools window)' }
  Write-Host ("   [ drivers  ]  {0,-40}" -f $ds) -ForegroundColor Cyan
  Write-Host ("`n   elapsed {0:mm\:ss}      " -f ((Get-Date) - $start))
  if (-not $chainCur -and -not ($tasks | ? State -eq 'installing')) { break }
  Start-Sleep 3
}
Write-Host ''
$chainLog | % { Note $_ }
$tasks | % { Note ("{0} -> {1} {2}" -f $_.Name, $_.State, $_.Code) }
Remove-Item $dx -Recurse -Force -ErrorAction SilentlyContinue
if (-not $toolsStarted -and (DotnetReady)) { Start-Process "$td\NarenjiTools.exe" -ArgumentList '--drivers'; $toolsStarted = $true }

# ---------- settings ----------
$adj = 'Sleepy','Dizzy','Jolly','Fuzzy','Sneaky','Bouncy','Grumpy','Happy','Lazy','Zippy','Wobbly','Cheeky','Giggly','Crispy','Spicy','Sunny','Brave','Silly','Lucky','Fluffy'
$nou = 'Mango','Otter','Panda','Pickle','Waffle','Koala','Llama','Taco','Noodle','Penguin','Muffin','Walrus','Cookie','Gecko','Donut','Narenj','Falafel','Kebab','Pistachio','Camel'
do { $name = '{0}{1}-{2}' -f ($adj | Get-Random), ($nou | Get-Random), (Get-Random -Minimum 10 -Maximum 99) } while ($name.Length -gt 15)
Rename-Computer -NewName $name -Force -ErrorAction SilentlyContinue
Note "PC name: $name"
Set-WinHomeLocation -GeoId 224
foreach ($p in 'monitor-timeout-ac','monitor-timeout-dc','standby-timeout-ac','standby-timeout-dc') { powercfg /change $p 30 }

$now = (Get-Date).ToUniversalTime(); $end = $now.AddDays(30)
$ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
New-Item $ux -Force | Out-Null
foreach ($k in 'PauseUpdatesStartTime','PauseFeatureUpdatesStartTime','PauseQualityUpdatesStartTime') { Set-ItemProperty $ux $k $now.ToString('yyyy-MM-ddTHH:mm:ssZ') }
foreach ($k in 'PauseUpdatesExpiryTime','PauseFeatureUpdatesEndTime','PauseQualityUpdatesEndTime') { Set-ItemProperty $ux $k $end.ToString('yyyy-MM-ddTHH:mm:ssZ') }

Copy-Item "$S\DefaultApps.xml" "$td\DefaultApps.xml" -Force
New-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Force | Out-Null
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' DefaultAssociationsConfiguration "$td\DefaultApps.xml"
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' 'NarenjiDefaultAppsDone' 'cmd /c reg delete HKLM\SOFTWARE\Policies\Microsoft\Windows\System /v DefaultAssociationsConfiguration /f'

# IDM in English (LanguageID 9) - current account + default profile
Get-Process IDMan -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep 1
if (-not (Test-Path 'HKCU:\Software\DownloadManager')) { New-Item 'HKCU:\Software\DownloadManager' -Force | Out-Null }
Set-ItemProperty 'HKCU:\Software\DownloadManager' LanguageID 9 -Type DWord
reg load HKU\NJDefault C:\Users\Default\NTUSER.DAT | Out-Null
reg add 'HKU\NJDefault\Software\DownloadManager' /v LanguageID /t REG_DWORD /d 9 /f | Out-Null
[gc]::Collect(); reg unload HKU\NJDefault | Out-Null

foreach ($p in 'HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\General','HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\Privacy') { New-Item $p -Force | Out-Null }
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\General' ShownFirstRunOptin 1
Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common\Privacy' DisconnectedState 0

# ---------- wait for drivers (max 45 min), then restart ----------
if ($toolsStarted) {
  $w = Get-Date
  Start-Sleep 5
  while ((Test-Path $busyFlag) -and ((Get-Date) - $w).TotalMinutes -lt 45) {
    Write-Host ("`r   apps done - waiting for the driver install in NarenjiStore Tools ({0:mm\:ss})   " -f ((Get-Date) - $w)) -NoNewline -ForegroundColor Cyan
    Start-Sleep 5
  }
  Write-Host ''
}
Note ("All done in {0:mm\:ss}. Restarting in 15 seconds..." -f ((Get-Date) - $start)) Green
