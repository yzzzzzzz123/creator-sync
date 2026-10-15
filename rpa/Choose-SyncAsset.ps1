param([Parameter(Mandatory=$true)][ValidateSet('tiktok','instagram')][string]$Platform,[Parameter(Mandatory=$true)][string]$AccountEvidence,[ValidateSet('Video','Cover')][string]$Purpose='Video',[switch]$ReplaceVideo)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
if(Test-Path -LiteralPath "$projectRoot\data\STOP"){throw 'Stopped before asset selection'}
$source=Get-Content -LiteralPath "$projectRoot\data\douyin\acquisition-check.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$config=Get-Content -LiteralPath "$projectRoot\config.local.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$binding=Get-Content -LiteralPath "$projectRoot\data\browser-binding.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$proof=Get-Content -LiteralPath $AccountEvidence -Raw -Encoding UTF8 | ConvertFrom-Json
$account=$config.targets.$Platform.account_id
$profile=if($Platform -eq 'tiktok'){'https://www.tiktok.com/@'+$account}else{'https://www.instagram.com/'+$account+'/'}
if(-not $account -or $account -like 'SET_*' -or $proof.Window.Handle -ne $binding.WindowHandle -or ([DateTimeOffset]::Now-[DateTimeOffset]::Parse($proof.At)).TotalMinutes -gt 6 -or -not @($proof.Nodes | Where-Object {$_.Type -eq 'ControlType.Hyperlink' -and $_.Value -ceq $profile}).Count){throw 'Fresh evidence for this exact target account is required'}
if($source.Status -ne 'rpa_assets_verified' -or $source.Video.status -ne 'verified' -or (Get-FileHash -LiteralPath $source.Video.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $source.Video.sha256){throw 'Verified own source media required'}
$asset=$source.Video
if($Purpose -eq 'Video' -and $source.UploadVideo){
    $asset=$source.UploadVideo
    if($asset.source_sha256 -cne $source.Video.sha256 -or -not $asset.audio_bitstream_unchanged){throw 'Compatible video is not linked to the verified original'}
}elseif($Purpose -eq 'Cover'){
    $asset=$source.UploadCover
    if(-not $asset -or $asset.source_sha256 -cne $source.Video.sha256){throw 'Verified generated cover for this source required'}
}
if($asset.status -ne 'verified' -or (Get-FileHash -LiteralPath $asset.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $asset.sha256){throw 'Upload asset changed'}
$intentDir=Join-Path $projectRoot ('data\rpa-tests\douyin-'+$source.SourceId)
New-Item -ItemType Directory -Force -Path $intentDir | Out-Null
$baseIntent=Join-Path $intentDir ($Platform+'-'+$Purpose.ToLowerInvariant()+'-upload-intent.json')
$intentPath=$baseIntent
if($Purpose -eq 'Cover' -or $ReplaceVideo){
    if($ReplaceVideo -and $Purpose -ne 'Video'){throw 'ReplaceVideo only applies to video'}
    if($ReplaceVideo -and -not (Test-Path -LiteralPath $baseIntent)){throw 'No earlier upload to replace'}
    if($ReplaceVideo){$prior=Get-Content -LiteralPath $baseIntent -Raw -Encoding UTF8 | ConvertFrom-Json;if($prior.SourceKey -cne $source.LedgerKey -or $prior.AccountId -cne $account -or $prior.Sha256 -ceq $asset.sha256){throw 'Replacement must be the same source/account with a different verified encoding'}}
    $intentPath=Join-Path $intentDir ($Platform+'-'+$Purpose.ToLowerInvariant()+'-'+$asset.sha256.Substring(0,16)+'-upload-intent.json')
}
if(Test-Path -LiteralPath $intentPath){throw 'Upload already claimed; inspect the existing editor'}
if((Get-Process -Id $binding.ProcessId).StartTime.ToUniversalTime().ToString('o') -cne $binding.ProcessStartUtc){throw 'Chrome restarted'}
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Windows.Forms
Add-Type -Path "$PSScriptRoot\native\DingRpa.cs"
[DingRpa]::SetProcessDPIAware() | Out-Null
if([DingRpa]::DesktopName() -ne 'Default' -or [DingRpa]::InputDesktopName() -ne 'Default'){throw 'Unlock the Default desktop'}
$owner=[IntPtr]$binding.WindowHandle
$browser=[System.Windows.Automation.AutomationElement]::FromHandle($owner)
$documents=$browser.FindAll([System.Windows.Automation.TreeScope]::Descendants,(New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::Document)))
$expectedHost=if($Platform -eq 'tiktok'){'www.tiktok.com'}else{'www.instagram.com'}
$verifiedDocs=@($documents | Where-Object {$p=$null;if($_.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$p)){([Uri]$p.Current.Value).Host -eq $expectedHost}})
if($verifiedDocs.Count -ne 1){throw 'Target website document not identified'}
$timer=[Diagnostics.Stopwatch]::StartNew();$fileEdit=@()
do{
    $dialog=[DingRpa]::ReadWindow([DingRpa]::GetForegroundWindow())
    if($dialog.ClassName -eq '#32770' -and $dialog.Title -in @('打开','Open') -and [DingRpa]::GetAncestor([IntPtr]$dialog.Handle,3) -eq $owner -and (Get-Process -Id $dialog.ProcessId).ProcessName -eq 'chrome'){
        $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$dialog.Handle)
        $nodes=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
        $fileEdit=@($nodes | Where-Object {$_.Current.ClassName -eq 'Edit' -and $_.Current.AutomationId -in @('1148','1001')})
        if($fileEdit.Count -eq 1){break}
    }
    Start-Sleep -Milliseconds 200
}while($timer.Elapsed.TotalSeconds -lt 12)
if($fileEdit.Count -ne 1){throw 'Owned Chrome file picker not ready'}
$handle=[IntPtr]$dialog.Handle
$point=$fileEdit[0].GetClickablePoint();[DingRpa]::ClickPoint($handle,[int]$point.X,[int]$point.Y)
if([System.Windows.Automation.AutomationElement]::FocusedElement.Current.NativeWindowHandle -ne $fileEdit[0].Current.NativeWindowHandle){throw 'File editor focus changed'}
[System.Windows.Forms.SendKeys]::SendWait('^a');[DingRpa]::TypeUnicodeText($handle,$asset.path)
$back=$fileEdit[0].Current.Name;$pattern=$null
if($fileEdit[0].TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$pattern)){$back=$pattern.Current.Value}
if($back -cne $asset.path){throw 'Asset filename readback mismatch'}
$open=@($nodes | Where-Object {$_.Current.AutomationId -eq '1' -and $_.Current.Name -in @('打开(O)','Open')})
if($open.Count -ne 1){throw 'Open button ambiguous'}
$intent=[ordered]@{Platform=$Platform;AccountId=$account;SourceKey=$source.LedgerKey;SourceSha256=$source.Video.sha256;Sha256=$asset.sha256;AssetPurpose=$Purpose;Replaces=if($ReplaceVideo){$baseIntent}else{$null};Purpose='Upload POC, no final publication';At=(Get-Date -Format o)}
$stream=[IO.File]::Open($intentPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
try{$bytes=[Text.Encoding]::UTF8.GetBytes(($intent | ConvertTo-Json));$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
if(Test-Path -LiteralPath "$projectRoot\data\STOP"){throw 'Stopped before upload; intent retained'}
$point=$open[0].GetClickablePoint();[DingRpa]::ClickPoint($handle,[int]$point.X,[int]$point.Y)
[ordered]@{Platform=$Platform;Account=$account;Selected=$Purpose;Published=$false} | ConvertTo-Json -Compress
