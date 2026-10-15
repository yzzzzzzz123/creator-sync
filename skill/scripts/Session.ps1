param([ValidateSet('Discover','Attach')][string]$Action='Discover',[long]$WindowHandle=0,[string]$SitesFile)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$projectRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Windows.Forms
Add-Type -Path "$projectRoot\rpa\native\DingRpa.cs"
[DingRpa]::SetProcessDPIAware() | Out-Null
function Descendants($element){return $element.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)}
function Read-Value($element){$pattern=$null;if($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$pattern)){return $pattern.Current.Value};return ''}
function Session-Windows {
    $items=@()
    foreach($window in [DingRpa]::ListWindows()){
        if(-not $window.Visible -or $window.ClassName -ne 'Chrome_WidgetWin_1'){continue}
        $process=Get-Process -Id $window.ProcessId -ErrorAction SilentlyContinue
        if(-not $process -or $process.ProcessName -ne 'chrome'){continue}
        $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$window.Handle)
        $nodes=Descendants $root
        $tabs=@($nodes | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::TabItem} | ForEach-Object {$_.Current.Name})
        $private=($root.Current.Name -match '无痕|Incognito') -or @($nodes | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $_.Current.Name -match '^(无痕模式|Incognito)'}).Count -gt 0
        $items+=[pscustomobject]@{WindowHandle=$window.Handle;ProcessId=$window.ProcessId;ProcessStartUtc=$process.StartTime.ToUniversalTime().ToString('o');Title=$window.Title;TabNames=$tabs;IsIncognito=[bool]$private;Foreground=([DingRpa]::GetForegroundWindow().ToInt64() -eq $window.Handle)}
    }
    return $items
}
$windows=@(Session-Windows)
if($Action -eq 'Discover'){
    [ordered]@{Desktop=[DingRpa]::DesktopName();InputDesktop=[DingRpa]::InputDesktopName();Windows=$windows} | ConvertTo-Json -Depth 5 -Compress
    exit 0
}
if(Test-Path -LiteralPath "$projectRoot\data\STOP"){throw 'STOP exists; browser takeover is stopped'}
if([DingRpa]::DesktopName() -ne 'Default' -or [DingRpa]::InputDesktopName() -ne 'Default'){throw 'Unlock the Default desktop before browser takeover'}
$matched=@($windows | Where-Object {$_.WindowHandle -eq $WindowHandle -and -not $_.IsIncognito})
if($matched.Count -ne 1){throw 'Expected a current normal Chrome window'}
$bound=$matched[0];$handle=[IntPtr]$WindowHandle
$dialogs=@([DingRpa]::ListWindows() | Where-Object {$_.Visible -and $_.ClassName -eq '#32770' -and [DingRpa]::GetAncestor([IntPtr]$_.Handle,3) -eq $handle})
if($dialogs.Count){throw 'An owned browser dialog needs handling before takeover'}
$binding=[ordered]@{WindowHandle=$WindowHandle;ProcessId=$bound.ProcessId;ProcessStartUtc=$bound.ProcessStartUtc;Title=$bound.Title}
$dataDir=Join-Path $projectRoot 'data';New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
$binding | ConvertTo-Json | Set-Content -LiteralPath "$dataDir\browser-binding.json" -Encoding UTF8
$opened=@()
if($SitesFile){
    $sites=@(Get-Content -LiteralPath $SitesFile -Raw -Encoding UTF8 | ConvertFrom-Json)
    foreach($site in $sites){
        $uri=[Uri]$site.start_url
        if($uri.Scheme -ne 'https' -or $uri.Host -notin @('www.xiaohongshu.com','member.bilibili.com','studio.youtube.com')){throw 'Unexpected startup site'}
        if(@($bound.TabNames | Where-Object {$_ -match $site.tab_pattern}).Count){continue}
        if(Test-Path -LiteralPath "$dataDir\STOP"){throw 'Stopped before opening a platform tab'}
        if((Get-Process -Id $bound.ProcessId).StartTime.ToUniversalTime().ToString('o') -cne $bound.ProcessStartUtc){throw 'Chrome restarted'}
        $null=[DingRpa]::ActivateTarget($handle,$bound.ProcessId)
        $root=[System.Windows.Automation.AutomationElement]::FromHandle($handle)
        $wp=$root.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
        if([DingRpa]::GetForegroundWindow() -ne $handle){$wp.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Normal);Start-Sleep -Milliseconds 450;$wp.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Maximized);Start-Sleep -Milliseconds 400;$null=[DingRpa]::ActivateTarget($handle,$bound.ProcessId)}
        if([DingRpa]::GetForegroundWindow() -ne $handle){throw 'Chrome could not be activated'}
        $before=@((Descendants $root) | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::TabItem}).Count
        [System.Windows.Forms.SendKeys]::SendWait('^t')
        $timer=[Diagnostics.Stopwatch]::StartNew();$address=@()
        do{
            $nodes=Descendants $root
            $after=@($nodes | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::TabItem}).Count
            $address=@($nodes | Where-Object {$_.Current.ClassName -eq 'OmniboxViewViews'})
            if($after -eq $before+1 -and $address.Count -eq 1 -and (Read-Value $address[0]) -in @('','about:blank','chrome://newtab/')){break}
            Start-Sleep -Milliseconds 150
        }while($timer.Elapsed.TotalSeconds -lt 5)
        if($after -ne $before+1 -or $address.Count -ne 1 -or (Read-Value $address[0]) -notin @('','about:blank','chrome://newtab/')){throw 'New blank Chrome tab not verified'}
        $address[0].SetFocus()
        if(-not $address[0].Current.HasKeyboardFocus){throw 'Address field not focused'}
        $address[0].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue([string]$site.start_url)
        if((Read-Value $address[0]) -cne $site.start_url){throw 'Startup URL readback mismatch'}
        [DingRpa]::PressEnter($handle)
        $opened+=$site.key
        Start-Sleep -Milliseconds 400
        $bound.TabNames+=([string]$site.key)
    }
}
[ordered]@{Binding=$binding;OpenedSites=$opened;ExistingTabsPreserved=$true} | ConvertTo-Json -Depth 5 -Compress
