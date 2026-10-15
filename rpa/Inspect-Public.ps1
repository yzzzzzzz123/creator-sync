param([ValidateSet('Open','Inspect','DismissPrompt','Close')][string]$Action='Inspect',[string]$Url,[string]$Stage='public-receipt')
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
if(Test-Path -LiteralPath "$projectRoot\data\STOP"){throw 'Stopped'}
if($Stage -notmatch '^[a-zA-Z0-9_-]{1,80}$'){throw 'Invalid evidence stage'}
$statePath=Join-Path $projectRoot 'data\public-browser.json'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Windows.Forms,System.Drawing
Add-Type -Path "$PSScriptRoot\native\DingRpa.cs"
[DingRpa]::SetProcessDPIAware() | Out-Null
if([DingRpa]::DesktopName() -ne 'Default' -or [DingRpa]::InputDesktopName() -ne 'Default'){throw 'Unlock the Default desktop'}
function Nodes($element){return $element.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)}
function Value($element){$p=$null;if(-not $element.Current.IsPassword -and $element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$p)){return $p.Current.Value};return $null}
if($Action -eq 'Open'){
    if($Url -cnotmatch '^https://www\.(instagram\.com/(?:reel|reels)/[A-Za-z0-9_-]+/|tiktok\.com/@[A-Za-z0-9_.]+/video/\d+)$'){throw 'Expected a known official video permalink'}
    if(Test-Path -LiteralPath $statePath){throw 'Inspect or close the previous task-owned public window first'}
    foreach($existing in @([DingRpa]::ListWindows() | Where-Object {$_.Visible -and $_.ClassName -eq 'Chrome_WidgetWin_1' -and (Get-Process -Id $_.ProcessId).ProcessName -eq 'chrome'})){
        $existingRoot=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$existing.Handle)
        if(@((Nodes $existingRoot) | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $_.Current.Name -match '^(无痕模式|Incognito)'}).Count){throw 'Existing private session may contain a login; preserve it and do not claim logged-out verification'}
    }
    $before=@([DingRpa]::ListWindows() | ForEach-Object {$_.Handle})
    & "$PSScriptRoot\Browser.ps1" -Action Keys -Keys '^+n' | Out-Null
    $timer=[Diagnostics.Stopwatch]::StartNew();$created=@()
    do{
        $created=@([DingRpa]::ListWindows() | Where-Object {$_.Visible -and $_.ClassName -eq 'Chrome_WidgetWin_1' -and $_.Handle -notin $before -and (Get-Process -Id $_.ProcessId).ProcessName -eq 'chrome'})
        if($created.Count -eq 1){break};Start-Sleep -Milliseconds 200
    }while($timer.Elapsed.TotalSeconds -lt 8)
    if($created.Count -ne 1){throw 'New private window was not identified uniquely'}
    $window=$created[0];$handle=[IntPtr]$window.Handle
    $root=[System.Windows.Automation.AutomationElement]::FromHandle($handle);$nodes=Nodes $root
    if(-not @($nodes | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $_.Current.Name -match '^(无痕模式|Incognito)'}).Count){throw 'New window is not visibly private'}
    $state=[ordered]@{WindowHandle=$window.Handle;ProcessId=$window.ProcessId;ProcessStartUtc=(Get-Process -Id $window.ProcessId).StartTime.ToUniversalTime().ToString('o');RequestedUrl=$Url;At=(Get-Date -Format o)}
    $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    $null=[DingRpa]::ActivateTarget($handle,[uint32]$window.ProcessId)
    $address=@($nodes | Where-Object {$_.Current.ClassName -eq 'OmniboxViewViews'})
    if($address.Count -ne 1){throw 'Private address bar ambiguous'}
    $address[0].SetFocus();$address[0].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($Url)
    if((Value $address[0]) -cne $Url){throw 'Private URL readback mismatch'}
    [DingRpa]::PressEnter($handle);Start-Sleep -Seconds 4
}else{
    $state=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if((Get-Process -Id $state.ProcessId).StartTime.ToUniversalTime().ToString('o') -cne $state.ProcessStartUtc){throw 'Private verification window expired'}
    $handle=[IntPtr]$state.WindowHandle;$window=[DingRpa]::ReadWindow($handle)
    if($window.ProcessId -ne $state.ProcessId -or -not $window.Visible){throw 'Private window identity changed'}
    $null=[DingRpa]::ActivateTarget($handle,[uint32]$state.ProcessId)
    $root=[System.Windows.Automation.AutomationElement]::FromHandle($handle)
}
if([DingRpa]::GetForegroundWindow() -ne $handle){throw 'Private window is not foreground'}
$nodes=Nodes $root
$tabs=@($nodes | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::TabItem -and $_.Current.ClassName -eq 'Tab'})
if($tabs.Count -ne 1){throw 'Private window has additional tabs; preserve them for the user'}
if($Action -eq 'DismissPrompt'){
    if($state.RequestedUrl -notmatch '^https://www.instagram.com/' -or -not @($nodes | Where-Object {$_.Current.Name -ceq 'Sign up for Instagram to stay in the loop.'}).Count){throw 'Expected the optional Instagram signup prompt'}
    $close=@($nodes | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $_.Current.Name -ceq 'Close' -and -not $_.Current.IsOffscreen})
    if($close.Count -ne 1){throw 'Signup prompt close control ambiguous'}
    $point=$close[0].GetClickablePoint();$hit=[System.Windows.Automation.AutomationElement]::FromPoint($point);$matches=$false
    for($i=0;$hit -and $i -lt 32;$i++){if([System.Windows.Automation.Automation]::Compare($close[0],$hit)){$matches=$true;break};$hit=[System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($hit)}
    if(-not $matches){throw 'Signup prompt close control covered'}
    [DingRpa]::ClickPoint($handle,[int]$point.X,[int]$point.Y);Start-Sleep -Milliseconds 600
    $nodes=Nodes $root
}
if($Action -eq 'Close'){
    $root.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
    Remove-Item -LiteralPath $statePath
    '{"ClosedTaskOwnedPrivateWindow":true}';exit 0
}
$items=@(for($i=0;$i -lt $nodes.Count;$i++){
    $e=$nodes[$i];$c=$e.Current
    [pscustomobject]@{Index=$i;Type=$c.ControlType.ProgrammaticName;Name=$c.Name;Class=$c.ClassName;Value=(Value $e);Offscreen=$c.IsOffscreen;Bounds=@($c.BoundingRectangle.X,$c.BoundingRectangle.Y,$c.BoundingRectangle.Width,$c.BoundingRectangle.Height)}
})
[ordered]@{At=(Get-Date -Format o);Window=$window;RequestedUrl=$state.RequestedUrl;LoggedOut=$true;Nodes=$items} | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath "$projectRoot\artifacts\$Stage.json" -Encoding UTF8
$resultDir=Join-Path $projectRoot 'artifacts';. "$PSScriptRoot\core\Screenshot.ps1"
Save-TargetImage $handle ($Stage+'.png')
[ordered]@{Evidence="artifacts/$Stage.json";LoggedOut=$true} | ConvertTo-Json -Compress
