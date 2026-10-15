param([Parameter(Mandatory=$true)][string]$ExpectedUrl,[Parameter(Mandatory=$true)][string]$OutputPath,[switch]$ResumeDialog,[switch]$HtmlOnly)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
if(Test-Path -LiteralPath "$projectRoot\data\STOP"){throw 'Stopped before page export input'}
$destination=[IO.Path]::GetFullPath($OutputPath)
$dataRoot=[IO.Path]::GetFullPath((Join-Path $projectRoot 'data'))+[IO.Path]::DirectorySeparatorChar
if(-not $destination.StartsWith($dataRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($destination) -ne '.html'){throw 'Export must be an HTML file under project data'}
if(Test-Path -LiteralPath $destination){throw 'Existing export will not be overwritten'}
New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
if(-not $ResumeDialog){& "$PSScriptRoot\Browser.ps1" -Action Inspect -Stage 'before-save-page' | Out-Null}
$snapshot=Get-Content -LiteralPath "$projectRoot\artifacts\before-save-page.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$documents=@($snapshot.Nodes | Where-Object {$_.Type -eq 'ControlType.Document' -and $_.Value -ceq $ExpectedUrl})
if($documents.Count -ne 1){throw 'Expected document identity not confirmed'}
$binding=Get-Content -LiteralPath "$projectRoot\data\browser-binding.json" -Raw | ConvertFrom-Json
if($snapshot.Window.Handle -ne $binding.WindowHandle -or ([DateTimeOffset]::Now-[DateTimeOffset]::Parse($snapshot.At)).TotalMinutes -gt 5){throw 'Fresh document evidence for this bound window is required'}
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Windows.Forms
Add-Type -Path "$PSScriptRoot\native\DingRpa.cs"
if((Get-Process -Id $binding.ProcessId).StartTime.ToUniversalTime().ToString('o') -cne $binding.ProcessStartUtc){throw 'Bound Chrome restarted'}
$ownerHandle=[IntPtr]$binding.WindowHandle
if(-not $ResumeDialog){& "$PSScriptRoot\Browser.ps1" -Action Keys -Keys '^s' | Out-Null}
$timer=[Diagnostics.Stopwatch]::StartNew();$dialog=$null
while($timer.Elapsed.TotalSeconds -lt 12){
    $window=[DingRpa]::ReadWindow([DingRpa]::GetForegroundWindow())
    if($window.ClassName -eq '#32770' -and $window.Title -eq '另存为' -and (Get-Process -Id $window.ProcessId).ProcessName -eq 'chrome' -and [DingRpa]::GetAncestor([IntPtr]$window.Handle,3) -eq $ownerHandle){$dialog=$window;break}
    Start-Sleep -Milliseconds 200
}
if(-not $dialog){throw 'Owned Chrome Save As dialog did not appear; preserve current UI'}
$dialogHandle=[IntPtr]$dialog.Handle
$root=[System.Windows.Automation.AutomationElement]::FromHandle($dialogHandle)
$timer.Restart()
do{
    $nodes=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
    $filename=@($nodes | Where-Object {$_.Current.AutomationId -eq '1001' -and $_.Current.ClassName -eq 'Edit'})
    $save=@($nodes | Where-Object {$_.Current.AutomationId -eq '1' -and $_.Current.Name -eq '保存(S)'})
    if($filename.Count -eq 1 -and $save.Count -eq 1){break}
    Start-Sleep -Milliseconds 200
}while($timer.Elapsed.TotalSeconds -lt 8)
if($filename.Count -ne 1 -or $save.Count -ne 1){throw 'Save dialog controls ambiguous'}
$point=$filename[0].GetClickablePoint()
[DingRpa]::ClickPoint($dialogHandle,[int]$point.X,[int]$point.Y)
if([System.Windows.Automation.AutomationElement]::FocusedElement.Current.NativeWindowHandle -ne $filename[0].Current.NativeWindowHandle){throw 'Filename editor focus mismatch'}
[System.Windows.Forms.SendKeys]::SendWait('^a')
[DingRpa]::TypeUnicodeText($dialogHandle,$destination)
if($filename[0].Current.Name -cne $destination){throw 'Export filename readback mismatch'}
if($HtmlOnly){
    $fileType=@($nodes | Where-Object {$_.Current.AutomationId -eq 'FileTypeControlHost'})
    if($fileType.Count -ne 1){throw 'Save type selector ambiguous'}
    $point=$fileType[0].GetClickablePoint()
    [DingRpa]::ClickPoint($dialogHandle,[int]$point.X,[int]$point.Y)
    Start-Sleep -Milliseconds 250
    $choices=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
    $html=@($choices | Where-Object {-not $_.Current.IsOffscreen -and $_.Current.Name -match '仅.*HTML|HTML.only' -and $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ListItem})
    if($html.Count -ne 1){throw 'HTML-only option not identified; keep dialog for inspection'}
    $point=$html[0].GetClickablePoint()
    [DingRpa]::ClickPoint($dialogHandle,[int]$point.X,[int]$point.Y)
}
if(Test-Path -LiteralPath "$projectRoot\data\STOP"){throw 'Stopped before saving page'}
if([DingRpa]::GetForegroundWindow() -ne $dialogHandle){throw 'Save dialog lost foreground'}
$point=$save[0].GetClickablePoint()
[DingRpa]::ClickPoint($dialogHandle,[int]$point.X,[int]$point.Y)
$timer.Restart();$lastLength=0;$stable=0
while($timer.Elapsed.TotalSeconds -lt 20){
    if(Test-Path -LiteralPath $destination){
        $length=(Get-Item -LiteralPath $destination).Length
        if($length -gt 1000 -and $length -eq $lastLength){$stable++}else{$stable=0}
        $lastLength=$length
        if($stable -ge 3){[ordered]@{Status='saved';Path=$destination;Bytes=$length} | ConvertTo-Json -Compress;exit 0}
    }
    Start-Sleep -Milliseconds 500
}
[ordered]@{Status='pending';Path=$destination;Message='Chrome export may finish later; inspect the same file before retrying'} | ConvertTo-Json -Compress
