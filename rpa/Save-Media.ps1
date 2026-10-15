param([Parameter(Mandatory=$true)][string]$OutputPath,[ValidateSet('Video','Cover')][string]$Purpose='Video')
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
if(Test-Path -LiteralPath "$projectRoot\data\STOP"){throw 'Stopped before media save'}
$destination=[IO.Path]::GetFullPath($OutputPath)
$dataRoot=[IO.Path]::GetFullPath((Join-Path $projectRoot 'data'))+[IO.Path]::DirectorySeparatorChar
if(-not $destination.StartsWith($dataRoot,[StringComparison]::OrdinalIgnoreCase) -or ($Purpose -eq 'Video' -and [IO.Path]::GetExtension($destination) -ne '.mp4') -or ($Purpose -eq 'Cover' -and [IO.Path]::GetExtension($destination) -notin @('.webp','.jpg','.jpeg','.png'))){throw 'Save MP4/image under project data'}
if(Test-Path -LiteralPath $destination){throw 'Existing media will not be overwritten; verify the file'}
New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
$binding=Get-Content -LiteralPath "$projectRoot\data\browser-binding.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$media=Get-Content -LiteralPath "$projectRoot\data\douyin\active-media.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$uri=[Uri]$media.MediaUrl
if($media.SourceId -notmatch '^\d{10,30}$' -or $uri.Scheme -ne 'https' -or $uri.Host -notmatch '(^|\.)douyinvod\.com$|^v\d+-dy-[a-z0-9-]+\.zjcdn\.com$' -or $uri.Query -notmatch ('(^|[?&])__vid='+[regex]::Escape([string]$media.SourceId)+'(&|$)')){throw 'Own media identity not verified'}
$intentDir=Join-Path $projectRoot ('data\douyin\claims\'+$media.SourceId)
New-Item -ItemType Directory -Force -Path $intentDir | Out-Null
$intentPath=Join-Path $intentDir ($Purpose.ToLowerInvariant()+'-save-intent.json')
if(Test-Path -LiteralPath $intentPath){throw 'Save already claimed; inspect the previous download instead of replaying'}
# Legacy claims remain valid for their original source, not every subsequent video.
foreach($legacyName in @('active-media-save-intent.json',('active-'+$Purpose.ToLowerInvariant()+'-save-intent.json'))){
    $legacyPath=Join-Path $projectRoot ('data\douyin\'+$legacyName)
    if(Test-Path -LiteralPath $legacyPath){$legacy=Get-Content -LiteralPath $legacyPath -Raw -Encoding UTF8 | ConvertFrom-Json;if($legacy.SourceId -ceq $media.SourceId -and ($Purpose -eq 'Video' -or $legacy.Purpose -eq $Purpose)){throw 'Prior save claim for this source exists; inspect it instead of replaying'}}
}
if((Get-Process -Id $binding.ProcessId).StartTime.ToUniversalTime().ToString('o') -cne $binding.ProcessStartUtc){throw 'Chrome binding changed'}
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Windows.Forms
Add-Type -Path "$PSScriptRoot\native\DingRpa.cs"
[DingRpa]::SetProcessDPIAware() | Out-Null
if([DingRpa]::DesktopName() -ne 'Default' -or [DingRpa]::InputDesktopName() -ne 'Default'){throw 'Unlock the Default desktop'}
$owner=[IntPtr]$binding.WindowHandle
$browser=[System.Windows.Automation.AutomationElement]::FromHandle($owner)
$nodes=$browser.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
$expectedDocument=$media.MediaUrl
if($Purpose -eq 'Cover'){
    $config=Get-Content -LiteralPath "$projectRoot\config.local.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    $proof=Get-Content -LiteralPath "$projectRoot\artifacts\douyin-cover-identity.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    if($proof.Window.Handle -ne $binding.WindowHandle -or ([DateTimeOffset]::Now-[DateTimeOffset]::Parse($proof.At)).TotalMinutes -gt 8 -or -not @($proof.Nodes | Where-Object {$_.Value -ceq $media.SourceUrl}).Count -or -not @($proof.Nodes | Where-Object {$_.Name -ceq $config.source.account_id}).Count){throw 'Fresh own-cover identity evidence required'}
    $expectedDocument='https://www.douyin.com/user/self'
}
$docs=@($nodes | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Document} | Where-Object {$p=$null; $_.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$p) -and $p.Current.Value -ceq $expectedDocument})
if($docs.Count -ne 1){throw 'Browser is not on this exact own-media document'}
$dialogs=@([DingRpa]::ListWindows() | Where-Object {$_.Visible -and $_.ClassName -eq '#32770' -and $_.Title -eq '另存为' -and [DingRpa]::GetAncestor([IntPtr]$_.Handle,3) -eq $owner -and (Get-Process -Id $_.ProcessId).ProcessName -eq 'chrome'})
if($dialogs.Count -ne 1){throw 'Expected the owned browser media Save As dialog'}
$dialog=$dialogs[0];$handle=[IntPtr]$dialog.Handle
$null=[DingRpa]::ActivateTarget($handle,[uint32]$dialog.ProcessId)
if([DingRpa]::GetForegroundWindow() -ne $handle){throw 'Media Save As dialog focus failed'}
$root=[System.Windows.Automation.AutomationElement]::FromHandle($handle)
$nodes=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
$filename=@($nodes | Where-Object {$_.Current.AutomationId -eq '1001' -and $_.Current.ClassName -eq 'Edit'})
$save=@($nodes | Where-Object {$_.Current.AutomationId -eq '1' -and $_.Current.Name -eq '保存(S)'})
if($filename.Count -ne 1 -or $save.Count -ne 1){throw 'Media save controls ambiguous'}
if($Purpose -eq 'Cover'){
    $extension=[IO.Path]::GetExtension($filename[0].Current.Name).ToLowerInvariant()
    if($extension -in @('.webp','.jpg','.jpeg','.png')){$destination=[IO.Path]::ChangeExtension($destination,$extension)}
    if(Test-Path -LiteralPath $destination){throw 'Existing cover will not be overwritten'}
}
$point=$filename[0].GetClickablePoint();[DingRpa]::ClickPoint($handle,[int]$point.X,[int]$point.Y)
if([System.Windows.Automation.AutomationElement]::FocusedElement.Current.NativeWindowHandle -ne $filename[0].Current.NativeWindowHandle){throw 'Filename focus changed'}
[System.Windows.Forms.SendKeys]::SendWait('^a');[DingRpa]::TypeUnicodeText($handle,$destination)
if($filename[0].Current.Name -cne $destination){throw 'Media filename readback mismatch'}
if(Test-Path -LiteralPath "$projectRoot\data\STOP"){throw 'Stopped before save click'}
$intent=[ordered]@{SourceId=$media.SourceId;Purpose=$Purpose;Path=$destination;Method='Native browser media/image Save As';At=(Get-Date -Format o)}
$stream=[IO.File]::Open($intentPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
try{$bytes=[Text.Encoding]::UTF8.GetBytes(($intent | ConvertTo-Json));$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
$point=$save[0].GetClickablePoint();[DingRpa]::ClickPoint($handle,[int]$point.X,[int]$point.Y)
$timer=[Diagnostics.Stopwatch]::StartNew();$lastLength=0;$stable=0
while($timer.Elapsed.TotalSeconds -lt 25){
    if(Test-Path -LiteralPath $destination){
        $length=(Get-Item -LiteralPath $destination).Length
        if($length -gt 1000 -and $length -eq $lastLength){$stable++}else{$stable=0}
        $lastLength=$length
        if($stable -ge 3 -and -not (Test-Path -LiteralPath ($destination+'.crdownload'))){[ordered]@{Status='saved';Path=$destination;Bytes=$length;Next=if($Purpose -eq 'Video'){'Probe streams, decode and verify duration'}else{'Verify image format, dimensions and source identity'}} | ConvertTo-Json -Compress;exit 0}
    }
    Start-Sleep -Milliseconds 500
}
[ordered]@{Status='pending';Path=$destination;Next='Inspect the existing browser download; do not replay the save'} | ConvertTo-Json -Compress
