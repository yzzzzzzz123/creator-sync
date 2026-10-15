param([ValidateSet('Video','Cover')][string]$Purpose='Video',[switch]$CoverRevision)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
if(Test-Path -LiteralPath "$projectRoot\data\STOP"){throw 'User STOP file exists'}
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Windows.Forms
Add-Type -Path "$PSScriptRoot\native\DingRpa.cs"
$binding=Get-Content -LiteralPath "$projectRoot\data\browser-binding.json" -Raw | ConvertFrom-Json
$process=Get-Process -Id $binding.ProcessId
if($process.StartTime.ToUniversalTime().ToString('o') -cne $binding.ProcessStartUtc){throw 'Bound browser restarted'}
$state=Get-Content -LiteralPath "$projectRoot\data\bilibili-test.json" -Raw | ConvertFrom-Json
if($state.max_posts -ne 1 -or -not $state.account_id){throw 'Bound single-item scope required'}
if($Purpose -eq 'Video'){$assetPath=$state.video_path;$assetHash=$state.video_sha256}else{$assetPath=$state.cover_path;$assetHash=$state.cover_sha256}
if(-not $assetHash -or (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $assetHash){throw 'Asset hash changed or missing'}
$intentPath=Join-Path $projectRoot ('data\bilibili-'+$Purpose.ToLowerInvariant()+'-intent.json')
if($CoverRevision){
    if($Purpose -ne 'Cover'){throw 'Only cover assets can be revised'}
    $intentPath=Join-Path $projectRoot ('data\bilibili-cover-'+$assetHash.Substring(0,16)+'-intent.json')
}
if(Test-Path -LiteralPath $intentPath){throw 'Asset upload intent already exists; inspect before retry'}
$timer=[Diagnostics.Stopwatch]::StartNew();$fileEdit=@()
do{
    $dialog=[DingRpa]::ReadWindow([DingRpa]::GetForegroundWindow())
    if($dialog.ClassName -eq '#32770' -and $dialog.Title -in @('打开','Open') -and (Get-Process -Id $dialog.ProcessId).ProcessName -eq 'chrome' -and [DingRpa]::GetAncestor([IntPtr]$dialog.Handle,3).ToInt64() -eq $binding.WindowHandle){
        $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$dialog.Handle)
        $nodes=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
        $fileEdit=@($nodes | Where-Object {$_.Current.ClassName -eq 'Edit' -and $_.Current.AutomationId -in @('1148','1001')})
        if($fileEdit.Count -eq 1){break}
    }
    Start-Sleep -Milliseconds 200
}while($timer.Elapsed.TotalSeconds -lt 15)
if($fileEdit.Count -ne 1){throw 'Owned Chrome file picker not ready'}
$handle=[IntPtr]$dialog.Handle
$point=$fileEdit[0].GetClickablePoint();[DingRpa]::ClickPoint($handle,[int]$point.X,[int]$point.Y)
if([System.Windows.Automation.AutomationElement]::FocusedElement.Current.NativeWindowHandle -ne $fileEdit[0].Current.NativeWindowHandle){throw 'File name focus mismatch'}
[System.Windows.Forms.SendKeys]::SendWait('^a');[DingRpa]::TypeUnicodeText($handle,$assetPath)
Start-Sleep -Milliseconds 200
$readback=$fileEdit[0].Current.Name;$pattern=$null
if($fileEdit[0].TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$pattern)){$readback=$pattern.Current.Value}
if($readback -cne $assetPath){throw 'File name readback mismatch'}
$open=@($nodes | Where-Object {$_.Current.AutomationId -eq '1' -and $_.Current.Name -in @('打开(O)','Open')})
if($open.Count -ne 1){throw 'Open button ambiguous'}
$intent=[ordered]@{Action=('BilibiliUpload'+$Purpose);AccountId=$state.account_id;NoteId=$state.note_id;Sha256=$assetHash;At=(Get-Date -Format o)} | ConvertTo-Json -Compress
$stream=[IO.File]::Open($intentPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try{$bytes=[Text.Encoding]::UTF8.GetBytes($intent);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
if(Test-Path -LiteralPath "$projectRoot\data\STOP"){throw 'Stopped before upload; intent retained for reconciliation'}
$point=$open[0].GetClickablePoint();[DingRpa]::ClickPoint($handle,[int]$point.X,[int]$point.Y)
[ordered]@{AssetSelected=$Purpose;Sha256=$assetHash} | ConvertTo-Json -Compress
