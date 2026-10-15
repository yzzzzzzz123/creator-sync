param([ValidateSet('Inspect','Navigate','SelectTab','ChromeClick','Click','RemoveTag','Type','Hover','Context','Keys','Scroll')][string]$Action='Inspect',[string]$Stage='inspect',[string]$Name,[string]$Type,[string]$Class,[string]$Id,[string]$Within,[string]$Text,[string]$Url,[string]$Keys,[int]$Occurrence=-1,[int]$Notches=-3,[long]$WindowHandle=0,[switch]$PhysicalClick)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
if(Test-Path -LiteralPath "$projectRoot\data\STOP"){throw 'User STOP file exists'}
if($Stage -notmatch '^[a-zA-Z0-9_-]{1,80}$'){throw 'Invalid evidence stage'}
$evidenceDir=Join-Path $projectRoot 'artifacts';New-Item -ItemType Directory -Force -Path $evidenceDir | Out-Null
$binding=Get-Content -LiteralPath "$projectRoot\data\browser-binding.json" -Raw | ConvertFrom-Json
if($WindowHandle -eq 0){$WindowHandle=$binding.WindowHandle}
if($WindowHandle -ne $binding.WindowHandle){throw 'Window does not match current binding'}
$expectedProcessId=[uint32]$binding.ProcessId
$process=Get-Process -Id $expectedProcessId
if($process.StartTime.ToUniversalTime().ToString('o') -cne $binding.ProcessStartUtc){throw 'Bound process restarted'}
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Windows.Forms,System.Drawing
Add-Type -Path "$PSScriptRoot\native\DingRpa.cs"
[DingRpa]::SetProcessDPIAware() | Out-Null
$handle=[IntPtr]$WindowHandle
$window=[DingRpa]::ReadWindow($handle)
$ownedDialogs=@([DingRpa]::ListWindows() | Where-Object {$_.Visible -and $_.ClassName -eq '#32770' -and [DingRpa]::GetAncestor([IntPtr]$_.Handle,3) -eq $handle})
if($ownedDialogs.Count){throw 'Owned browser dialog is open; handle that dialog before browser input'}
if($window.ProcessId -ne $expectedProcessId -or -not $window.Visible -or (Get-Process -Id $window.ProcessId).ProcessName -ne 'chrome'){throw 'Chrome identity changed'}
if([DingRpa]::DesktopName() -ne 'Default' -or [DingRpa]::InputDesktopName() -ne 'Default'){throw 'Unlocked Default desktop unavailable'}
$null=[DingRpa]::ActivateTarget($handle,$expectedProcessId)
$root=[System.Windows.Automation.AutomationElement]::FromHandle($handle)
$wp=$root.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
if([DingRpa]::GetForegroundWindow() -ne $handle){$wp.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Normal);Start-Sleep -Milliseconds 450}
if($wp.Current.WindowVisualState -ne [System.Windows.Automation.WindowVisualState]::Maximized){$wp.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Maximized);Start-Sleep -Milliseconds 400}
if([DingRpa]::GetForegroundWindow() -ne $handle){$null=[DingRpa]::ActivateTarget($handle,$expectedProcessId);Start-Sleep -Milliseconds 200}
if([DingRpa]::GetForegroundWindow() -ne $handle){throw 'Could not activate Chrome'}
function Nodes($from){return $from.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)}
function Value($element){$p=$null;if($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$p)){return $p.Current.Value};return $null}
function Visible($element){$c=$element.Current;return (-not $c.IsOffscreen -and $c.IsEnabled -and $c.BoundingRectangle.Width -gt 0 -and $c.BoundingRectangle.Height -gt 0 -and -not [double]::IsInfinity($c.BoundingRectangle.X) -and -not [double]::IsInfinity($c.BoundingRectangle.Y))}
function Click($element){
    if(-not (Visible $element)){throw 'Target not visible or enabled'}
    $b=$element.Current.BoundingRectangle
    [DingRpa]::ClickPoint($handle,[int](($b.Left+$b.Right)/2),[int](($b.Top+$b.Bottom)/2))
}
function Assert-Unobscured($element){
    $timer=[Diagnostics.Stopwatch]::StartNew()
    do{
        $b=$element.Current.BoundingRectangle
        $point=[System.Windows.Point]::new([double](($b.Left+$b.Right)/2),[double](($b.Top+$b.Bottom)/2))
        $hit=[System.Windows.Automation.AutomationElement]::FromPoint($point)
        $hitName=$hit.Current.Name
        for($depth=0;$hit -and $depth -lt 64;$depth++){
            if([System.Windows.Automation.Automation]::Compare($element,$hit)){return}
            $hit=[System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($hit)
        }
        Start-Sleep -Milliseconds 100
    }while($timer.Elapsed.TotalSeconds -lt 2)
    throw ('Target covered or changed: '+$element.Current.Name+'; hit: '+$hitName)
}
$all=Nodes $root
$address=@($all | Where-Object {$_.Current.Name -eq '地址和搜索栏' -and $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit})
if($address.Count -ne 1){throw 'Address bar ambiguous'}
$current=Value $address[0]
if(-not $current){$current='about:blank'}elseif($current -notmatch '^https?://|^about:|^chrome:'){$current='https://'+$current}
$uri=[Uri]$current
$canonicalHost=$uri.Host
if($canonicalHost -in @('bilibili.com','youtube.com','xiaohongshu.com','douyin.com','tiktok.com','instagram.com')){$canonicalHost='www.'+$canonicalHost}
$allowed=@('www.douyin.com','douyin.com','creator.douyin.com','www.xiaohongshu.com','xiaohongshu.com','creator.xiaohongshu.com','www.youtube.com','youtube.com','studio.youtube.com','accounts.google.com','www.bilibili.com','bilibili.com','member.bilibili.com','space.bilibili.com','passport.bilibili.com','passport.bilibili.cn','www.tiktok.com','tiktok.com','www.instagram.com','instagram.com')
$mediaManifest=Join-Path $projectRoot 'data\douyin\active-media.json'
if(Test-Path -LiteralPath $mediaManifest){
    $media=Get-Content -LiteralPath $mediaManifest -Raw -Encoding UTF8 | ConvertFrom-Json
    $mediaUri=[Uri]$media.MediaUrl
    if($media.SourceId -match '^\d{10,30}$' -and $mediaUri.Scheme -eq 'https' -and $mediaUri.Host -match '(^|\.)douyinvod\.com$|^v\d+-dy-[a-z0-9-]+\.zjcdn\.com$' -and $mediaUri.Query -match ('(^|[?&])__vid='+[regex]::Escape([string]$media.SourceId)+'(&|$)') -and $uri.AbsoluteUri -ceq $mediaUri.AbsoluteUri){$allowed+=$mediaUri.Host}
}
if($uri.Host -notin $allowed -and -not ($Action -in @('Navigate','Inspect','SelectTab') -and $current -in @('about:blank','chrome://newtab/'))){throw ('Unexpected host '+$uri.Host)}
if($canonicalHost -in @('www.douyin.com','creator.douyin.com')){
    if($Action -eq 'Type' -and $Name -notin @('搜索作品','搜索你发布的作品','搜索你感兴趣的内容')){throw 'Douyin is a read-only content source; only search input is allowed'}
    if($Action -eq 'Click' -and $Name -match '^(作品发布|发布作品|编辑作品|设置权限|删除作品|取消置顶|置顶|发送|点赞|收藏|关注|取消关注)$'){throw 'Douyin operations are managed by the user; write action refused'}
    if($Action -eq 'Keys' -and $Keys -eq '{ENTER}'){
        $focused=[System.Windows.Automation.AutomationElement]::FocusedElement
        if($focused.Current.Name -notin @('搜索作品','搜索你发布的作品','搜索你感兴趣的内容')){throw 'Douyin Enter is limited to an identified search field'}
    }
}
if($Action -eq 'Navigate'){
    if(([Uri]$Url).Host -notin $allowed){throw 'Navigation host not allowed'}
    $address[0].SetFocus();Start-Sleep -Milliseconds 100
    if(-not $address[0].Current.HasKeyboardFocus){throw 'Address bar focus failed'}
    $p=$address[0].GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $p.SetValue($Url)
    $timer=[Diagnostics.Stopwatch]::StartNew()
    do{
        $read=Value $address[0]
        if($read -ceq $Url){break}
        if($read.StartsWith($Url,[StringComparison]::Ordinal)){
            $tp=$address[0].GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
            $selection=@($tp.GetSelection() | ForEach-Object {$_.GetText(-1)})
            if($selection.Count -eq 1 -and $selection[0] -ceq $read.Substring($Url.Length) -and $address[0].Current.HasKeyboardFocus){[System.Windows.Forms.SendKeys]::SendWait('{DELETE}')}
        }
        Start-Sleep -Milliseconds 100
    }while($timer.Elapsed.TotalSeconds -lt 4)
    if((Value $address[0]) -cne $Url){throw 'Address readback mismatch'}
    [DingRpa]::PressEnter($handle)
 }elseif($Action -eq 'ChromeClick'){
    if($Name -notmatch '^(Chrome|扩展程序|Proxy SwitchyOmega \(V3\)(\r?\n.*)?|有 [0-9]+ 项下载正在进行|下载)$'){throw 'Chrome control not allowed'}
    $targets=@($all | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $_.Current.Name -ceq $Name -and (Visible $_)})
    if($targets.Count -ne 1){throw 'Chrome control ambiguous'}
    Click $targets[0]
}elseif($Action -eq 'SelectTab'){
    $tabs=@($all | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::TabItem -and $_.Current.Name -ceq $Name -and (Visible $_)})
    if($tabs.Count -ne 1){throw 'Tab identity ambiguous'}
    Click $tabs[0]
}elseif($Action -eq 'Inspect'){
    $cache=New-Object System.Windows.Automation.CacheRequest
    foreach($property in @('Name','ControlType','AutomationId','ClassName','BoundingRectangle','IsOffscreen','IsEnabled')){$cache.Add([System.Windows.Automation.AutomationElement]::("${property}Property"))}
    $scope=$cache.Activate();try{$all=Nodes $root}finally{$scope.Dispose()}
    if($all.Count -gt 15000){throw 'UIA tree limit exceeded'}
    $items=@(for($i=0;$i -lt $all.Count;$i++){
        $e=$all[$i];$c=$e.Cached;$v=$null
        if($c.ControlType.ProgrammaticName -match 'Edit|Document|Hyperlink|RadioButton|CheckBox'){$v=Value $e}
        $selected=$null;$selection=$null
        if($c.ControlType.ProgrammaticName -match 'RadioButton|CheckBox'){
            if($e.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern,[ref]$selection)){$selected=$selection.Current.IsSelected}
        }
        [pscustomobject]@{Index=$i;Name=$c.Name;Type=$c.ControlType.ProgrammaticName;Id=$c.AutomationId;Class=$c.ClassName;Value=$v;Selected=$selected;Offscreen=$c.IsOffscreen;Enabled=$c.IsEnabled;Bounds=@($c.BoundingRectangle.X,$c.BoundingRectangle.Y,$c.BoundingRectangle.Width,$c.BoundingRectangle.Height)}
    })
    [ordered]@{Stage=$Stage;At=(Get-Date -Format o);Window=$window;Url=$current;Nodes=$items} | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath "$evidenceDir\$Stage.json" -Encoding UTF8
    $resultDir=$evidenceDir;. "$PSScriptRoot\core\Screenshot.ps1"
    Save-TargetImage $handle ($Stage+'.png')
    $items | Where-Object {-not $_.Offscreen -and ($_.Name -or $_.Value)} | Select-Object -Last 130 Index,Type,Name,Id,Class,Value,Enabled | ConvertTo-Json -Depth 4 -Compress
}elseif($Action -eq 'Keys'){
    if($Keys -notin @('^t','^+n','^r','^s','{F12}','{ESC}','{TAB}','{ENTER}','{PGDN}','{PGUP}','^a','{DELETE}')){throw 'Unapproved key sequence'}
    [System.Windows.Forms.SendKeys]::SendWait($Keys)
}else{
    if($uri.Host -notin $allowed){throw 'Interaction host not allowed'}
    $docs=@($all | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Document -and (Visible $_) -and (Value $_) -match '^https://' -and ([Uri](Value $_)).Host -in @($uri.Host,$canonicalHost)})
    if($docs.Count -ne 1){throw 'Active website document ambiguous'}
    $searchRoot=$docs[0]
    if($Within){
        $scopes=@((Nodes $searchRoot) | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window -and $_.Current.Name -ceq $Within -and -not $_.Current.IsOffscreen})
        if($scopes.Count -ne 1){throw 'Named website dialog is ambiguous'}
        $searchRoot=$scopes[0]
    }
    $candidates=@((Nodes $searchRoot) | Where-Object {
        $c=$_.Current
        $c.IsEnabled -and $c.BoundingRectangle.Width -gt 0 -and -not [double]::IsInfinity($c.BoundingRectangle.Width) -and (-not $PSBoundParameters.ContainsKey('Name') -or $c.Name -ceq $Name) -and (-not $Type -or $c.ControlType.ProgrammaticName -eq ('ControlType.'+$Type)) -and (-not $Class -or $c.ClassName -ceq $Class) -and (-not $Id -or $c.AutomationId -ceq $Id)
    })
    if($Occurrence -ge 0 -and $Occurrence -lt $candidates.Count){$element=$candidates[$Occurrence]}elseif($Occurrence -lt 0 -and $candidates.Count -eq 1){$element=$candidates[0]}else{throw ('Target match count: '+$candidates.Count)}
    if($Action -eq 'RemoveTag'){
        if($uri.Host -ne 'member.bilibili.com'){throw 'Tag removal only supported in Bilibili creator'}
        $parent=[System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($element)
        for($depth=0;$parent -and $parent.Current.ClassName -cne 'label-item-v2-container' -and $depth -lt 6;$depth++){$parent=[System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($parent)}
        if($parent.Current.ClassName -cne 'label-item-v2-container'){throw 'Selected tag parent identity changed'}
        $close=@((Nodes $parent) | Where-Object {$_.Current.ClassName -ceq 'close icon-sprite icon-sprite-off'})
        if($close.Count -ne 1){throw 'Tag close control ambiguous'}
        $element=$close[0]
    }
    if(-not (Visible $element) -or $Action -in @('Click','Type','RemoveTag')){
        $scrollItem=$null
        if($element.TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern,[ref]$scrollItem)){$scrollItem.ScrollIntoView();Start-Sleep -Milliseconds 350}
        if(-not (Visible $element)){throw 'Target could not be scrolled into view'}
    }
    if($Action -in @('Click','Type','RemoveTag')){Assert-Unobscured $element}
    if($Action -in @('Click','RemoveTag')){
        if($element.Current.Name -match '^(发布|公開|Publish|Post|Share|公开发布|立即投稿|投稿|提交稿件)$'){throw 'Final publication requires a separate single-submit receipt'}
        $pattern=$null
        if($PhysicalClick){Click $element}
        elseif($element.Current.ControlType -eq [System.Windows.Automation.ControlType]::RadioButton -and $element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern,[ref]$pattern)){$pattern.Select()}
        elseif($element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){$pattern.Invoke()}
        else{Click $element}
        Start-Sleep -Milliseconds 450
    }elseif($Action -eq 'Type'){
        $element.SetFocus()
        $focusTimer=[Diagnostics.Stopwatch]::StartNew()
        while(-not $element.Current.HasKeyboardFocus -and $focusTimer.Elapsed.TotalSeconds -lt 2){Start-Sleep -Milliseconds 100}
        if(-not $element.Current.HasKeyboardFocus){throw 'Editor focus not verified'}
        [System.Windows.Forms.SendKeys]::SendWait('^a')
        Start-Sleep -Milliseconds 150
        [DingRpa]::TypeUnicodeText($handle,$Text)
        Start-Sleep -Milliseconds 250
        $back=Value $element
        if($back -cne $Text){
            $tp=$null
            if($element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern,[ref]$tp)){$back=$tp.DocumentRange.GetText(-1).TrimEnd([char]13,[char]10)}
        }
        if($back -cne $Text){throw 'Editor readback mismatch'}
    }elseif($Action -eq 'Context'){
        Assert-Unobscured $element
        $b=$element.Current.BoundingRectangle
        [DingRpa]::RightClickPoint($handle,[int](($b.Left+$b.Right)/2),[int](($b.Top+$b.Bottom)/2))
        Start-Sleep -Milliseconds 350
    }elseif($Action -eq 'Hover'){
        Assert-Unobscured $element
        $b=$element.Current.BoundingRectangle
        if(-not [DingRpa]::SetCursorPos([int](($b.Left+$b.Right)/2),[int](($b.Top+$b.Bottom)/2))){throw 'Pointer move failed'}
        Start-Sleep -Milliseconds 700
    }elseif($Action -eq 'Scroll'){
        $b=$element.Current.BoundingRectangle
        [DingRpa]::WheelNotches($handle,[int](($b.Left+$b.Right)/2),[int](($b.Top+$b.Bottom)/2),$Notches)
        Start-Sleep -Milliseconds 350
    }
}
if($Action -ne 'Inspect'){[ordered]@{Action=$Action;Name=$Name;Path=$uri.AbsolutePath;At=(Get-Date -Format o)} | ConvertTo-Json -Compress}
