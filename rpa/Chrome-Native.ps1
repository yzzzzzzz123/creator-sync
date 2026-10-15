param([ValidateSet('Inspect','Click','Hover','Context','Filter')][string]$Action='Inspect',[string]$Stage='chrome-native',[string]$Name,[string]$Type,[string]$Class,[string]$Text,[int]$Occurrence=-1)
# Native Chrome menus and the visible DevTools GUI only. No protocol or JS execution.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
if(Test-Path -LiteralPath "$projectRoot\data\STOP"){throw 'Stopped'}
if($Stage -notmatch '^[a-zA-Z0-9_-]{1,80}$'){throw 'Invalid stage'}
$binding=Get-Content -LiteralPath "$projectRoot\data\browser-binding.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$process=Get-Process -Id $binding.ProcessId
if($process.ProcessName -ne 'chrome' -or $process.StartTime.ToUniversalTime().ToString('o') -cne $binding.ProcessStartUtc){throw 'Chrome binding changed'}
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Windows.Forms,System.Drawing
Add-Type -Path "$PSScriptRoot\native\DingRpa.cs"
[DingRpa]::SetProcessDPIAware() | Out-Null
$handle=[IntPtr]$binding.WindowHandle
if([DingRpa]::DesktopName() -ne 'Default' -or [DingRpa]::InputDesktopName() -ne 'Default'){throw 'Unlock the Default desktop'}
if(@([DingRpa]::ListWindows() | Where-Object {$_.Visible -and $_.ClassName -eq '#32770' -and [DingRpa]::GetAncestor([IntPtr]$_.Handle,3) -eq $handle}).Count){throw 'Handle the owned file dialog first'}
$null=[DingRpa]::ActivateTarget($handle,[uint32]$binding.ProcessId)
if([DingRpa]::GetForegroundWindow() -ne $handle){throw 'Chrome focus not available'}
$root=[System.Windows.Automation.AutomationElement]::FromHandle($handle)
function All($element){return $element.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)}
function Value($element){$pattern=$null;if($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$pattern)){return $pattern.Current.Value};return $null}
$nodes=All $root
if($Action -eq 'Inspect'){
    if($nodes.Count -gt 20000){throw 'UIA tree too large'}
    $items=@(for($index=0;$index -lt $nodes.Count;$index++){
        $element=$nodes[$index];$c=$element.Current;$value=$null
        if($c.ControlType.ProgrammaticName -match 'Document|Edit|Hyperlink' -and -not $c.IsPassword){$value=Value $element}
        [pscustomobject]@{Index=$index;Type=$c.ControlType.ProgrammaticName;Name=$c.Name;Class=$c.ClassName;Value=$value;Offscreen=$c.IsOffscreen;Enabled=$c.IsEnabled;Bounds=@($c.BoundingRectangle.X,$c.BoundingRectangle.Y,$c.BoundingRectangle.Width,$c.BoundingRectangle.Height)}
    })
    [ordered]@{At=(Get-Date -Format o);Stage=$Stage;Binding=$binding;Nodes=$items} | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath "$projectRoot\artifacts\$Stage.json" -Encoding UTF8
    $resultDir=Join-Path $projectRoot 'artifacts';. "$PSScriptRoot\core\Screenshot.ps1"
    Save-TargetImage $handle ($Stage+'.png')
    [ordered]@{Nodes=$items.Count;Evidence="artifacts/$Stage.json"} | ConvertTo-Json -Compress
    exit 0
}
if(-not $Name -and -not $Class){throw 'An exact UIA name or class is required'}
$matches=@($nodes | Where-Object {$c=$_.Current;$c.IsEnabled -and (-not $Name -or $c.Name -ceq $Name) -and (-not $Type -or $c.ControlType.ProgrammaticName -eq ('ControlType.'+$Type)) -and (-not $Class -or $c.ClassName -ceq $Class)})
if($Occurrence -ge 0 -and $Occurrence -lt $matches.Count){$element=$matches[$Occurrence]}elseif($matches.Count -eq 1){$element=$matches[0]}else{throw ('UIA control ambiguous: '+$matches.Count)}
$ancestor=$element;$devtools=$false
while($ancestor -and -not [System.Windows.Automation.Automation]::Compare($ancestor,$root)){
    if($ancestor.Current.ControlType -eq [System.Windows.Automation.ControlType]::Document){
        $document=Value $ancestor
        if($document -notmatch '^devtools://'){throw 'This helper cannot interact with website documents'}
        $devtools=$true
    }
    $ancestor=[System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($ancestor)
}
if($element.Current.IsOffscreen){$scroll=$null;if($element.TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern,[ref]$scroll)){$scroll.ScrollIntoView();Start-Sleep -Milliseconds 250}}
if($element.Current.IsOffscreen){throw 'Control is offscreen'}
$bounds=$element.Current.BoundingRectangle
$uncovered=$false
# Menus can have a tooltip over their centre. Every alternative remains inside
# the live UIA rectangle and must hit this exact element, never a guessed pixel.
:HitSearch foreach($xRatio in @(0.5,0.1,0.9)){
    foreach($yRatio in @(0.5,0.8,0.2)){
        $point=[System.Windows.Point]::new($bounds.Left+$bounds.Width*$xRatio,$bounds.Top+$bounds.Height*$yRatio)
        $hit=[System.Windows.Automation.AutomationElement]::FromPoint($point)
        for($depth=0;$hit -and $depth -lt 64;$depth++){
            if([System.Windows.Automation.Automation]::Compare($element,$hit)){$uncovered=$true;break HitSearch}
            $hit=[System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($hit)
        }
    }
}
if(-not $uncovered){throw 'UIA control is covered'}
if($Action -eq 'Filter'){
    if(-not $devtools -or $Name -notmatch '^(Filter|过滤|过滤器)$' -or $Text -match '[\r\n]'){throw 'Typing is limited to the DevTools network filter'}
    $element.SetFocus()
    [DingRpa]::ClickPoint($handle,[int]$point.X,[int]$point.Y)
    $focusTimer=[Diagnostics.Stopwatch]::StartNew()
    while(-not $element.Current.HasKeyboardFocus -and $focusTimer.Elapsed.TotalSeconds -lt 2){Start-Sleep -Milliseconds 100}
    if(-not $element.Current.HasKeyboardFocus){throw 'Network filter focus failed'}
    [System.Windows.Forms.SendKeys]::SendWait('^a')
    if($Text.Length){[DingRpa]::TypeUnicodeText($handle,$Text)}else{[System.Windows.Forms.SendKeys]::SendWait('{BACKSPACE}')}
    $back=Value $element
    if($back -cne $Text){$pattern=$element.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern);$back=$pattern.DocumentRange.GetText(-1).TrimEnd([char]13,[char]10)}
    if($back -cne $Text -and -not (-not $Text -and $back -eq 'Filter')){throw 'Filter readback mismatch'}
}elseif($Action -eq 'Hover'){
    [DingRpa]::SetCursorPos([int]$point.X,[int]$point.Y) | Out-Null
}elseif($Action -eq 'Context'){
    [DingRpa]::RightClickPoint($handle,[int]$point.X,[int]$point.Y)
}else{
    [DingRpa]::ClickPoint($handle,[int]$point.X,[int]$point.Y)
}
Start-Sleep -Milliseconds 400
[ordered]@{Action=$Action;Name=$Name} | ConvertTo-Json -Compress
