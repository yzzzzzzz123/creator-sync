$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
if(Test-Path -LiteralPath "$projectRoot\data\STOP"){throw 'Stopped'}
& "$PSScriptRoot\Browser.ps1" -Action Inspect -Stage 'bili-pre-submit' | Out-Null
$binding=Get-Content -LiteralPath "$projectRoot\data\browser-binding.json" -Raw | ConvertFrom-Json
$state=Get-Content -LiteralPath "$projectRoot\data\bilibili-test.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$account=Get-Content -LiteralPath "$projectRoot\data\bilibili-account-check.json" -Raw | ConvertFrom-Json
if($state.max_posts -ne 1 -or $account.AccountId -cne $state.account_id -or $account.WindowHandle -ne $binding.WindowHandle -or $account.ProcessStartUtc -cne $binding.ProcessStartUtc -or ((Get-Date)-[DateTime]$account.At).TotalMinutes -gt 5){throw 'Current bound account proof missing or expired'}
foreach($purpose in @('video','cover')){
    $path=$state."${purpose}_path";$hash=$state."${purpose}_sha256"
    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $hash){throw 'Package asset changed'}
    $intent=Get-Content -LiteralPath "$projectRoot\data\bilibili-$purpose-intent.json" -Raw | ConvertFrom-Json
    if($intent.Sha256 -cne $hash -or $intent.AccountId -cne $state.account_id -or $intent.NoteId -cne $state.note_id){throw 'Asset upload receipt mismatch'}
}
$handle=[IntPtr]$binding.WindowHandle
$root=[System.Windows.Automation.AutomationElement]::FromHandle($handle)
function Nodes($from){return $from.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)}
function Value($e){$p=$null;if($e.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$p)){return $p.Current.Value};return $null}
$all=Nodes $root
$address=@($all | Where-Object {$_.Current.ClassName -eq 'OmniboxViewViews'})
$docs=@($all | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Document -and -not $_.Current.IsOffscreen -and (Value $_) -match '^https://member\.bilibili\.com/platform/upload/video/frame(?:\?|$)'})
if($address.Count -ne 1 -or $docs.Count -ne 1 -or (Value $address[0]) -notmatch '^(https://)?member\.bilibili\.com/platform/upload/video/frame(?:\?|$)'){throw 'Official uploader address/document mismatch'}
$nodes=Nodes $docs[0]
$title=@($nodes | Where-Object {$_.Current.Name -eq '请输入稿件标题'})
$declaration=@($nodes | Where-Object {$_.Current.Name -eq '请选择符合您视频内容的创作声明'})
if($title.Count -ne 1 -or (Value $title[0]) -cne $state.title -or $declaration.Count -ne 1 -or (Value $declaration[0]) -cne '内容无需标注'){throw 'Metadata readback mismatch'}
$tags=@($nodes | Where-Object {$_.Current.ClassName -ceq 'label-item-v2-container'} | ForEach-Object {(Nodes $_) | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text} | ForEach-Object {$_.Current.Name}})
if($tags.Count -ne $state.tags.Count -or (Compare-Object ($tags | Sort-Object) ($state.tags | Sort-Object))){throw 'Selected tag chips mismatch'}
$desc=@($nodes | Where-Object {$_.Current.Name -ceq $state.description})
if($desc.Count -ne 1 -or @($nodes | Where-Object {$_.Current.Name -ceq '音乐'}).Count -ne 1 -or @($nodes | Where-Object {$_.Current.Name -ceq '上传完成'}).Count -ne 2){throw 'Description/category/upload completion mismatch'}
if(@($nodes | Where-Object {$_.Current.Name -ceq '封面制作'}).Count -or -not $state.cover_and_public_settings_visually_verified){throw 'Cover dialog still open or final visual settings proof missing'}
$submit=@($nodes | Where-Object {$_.Current.Name -ceq '立即投稿' -and $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text})
if($submit.Count -ne 1){throw 'Submit control ambiguous'}
$scroll=$null
if($submit[0].TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern,[ref]$scroll)){$scroll.ScrollIntoView();Start-Sleep -Milliseconds 500}
$rect=$submit[0].Current.BoundingRectangle
if($submit[0].Current.IsOffscreen -or -not $submit[0].Current.IsEnabled -or $rect.Width -le 0){throw 'Submit control unavailable'}
$parent=[System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($submit[0])
for($i=0;$parent -and $parent.Current.ClassName -notmatch '^submit-add(?: |$)' -and $i -lt 5;$i++){$parent=[System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($parent)}
if(-not $parent -or $parent.Current.ClassName -notmatch '^submit-add(?: |$)' -or $parent.Current.ClassName -match 'disabled|loading'){throw 'Submit wrapper unavailable'}
$match=$false
$timer=[Diagnostics.Stopwatch]::StartNew()
do{
    $rect=$submit[0].Current.BoundingRectangle
    $hit=[System.Windows.Automation.AutomationElement]::FromPoint([System.Windows.Point]::new([double](($rect.Left+$rect.Right)/2),[double](($rect.Top+$rect.Bottom)/2)))
    $hitName=$hit.Current.Name
    for($i=0;$hit -and $i -lt 32;$i++){if([System.Windows.Automation.Automation]::Compare($submit[0],$hit)){$match=$true;break};$hit=[System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($hit)}
    if($match){break};Start-Sleep -Milliseconds 100
}while($timer.Elapsed.TotalSeconds -lt 3)
if(-not $match){throw ('Submit control covered; hit: '+$hitName)}
$intentPath=Join-Path $projectRoot 'data\bilibili-submit-intent.json'
$intent=[ordered]@{Platform='bilibili';AccountId=$state.account_id;NoteId=$state.note_id;Title=$state.title;VideoSha256=$state.video_sha256;At=(Get-Date -Format o)} | ConvertTo-Json -Compress
$stream=[IO.File]::Open($intentPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try{$bytes=[Text.Encoding]::UTF8.GetBytes($intent);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
& python "$projectRoot\tools\claim_bilibili_submit.py"
if($LASTEXITCODE -ne 0){throw 'SQLite submission claim failed; no click performed'}
if(Test-Path -LiteralPath "$projectRoot\data\STOP"){throw 'Stopped after claim; reconcile retained intent'}
[DingRpa]::ClickPoint($handle,[int](($rect.Left+$rect.Right)/2),[int](($rect.Top+$rect.Bottom)/2))
[ordered]@{SubmitClickedOnce=$true;Status='AwaitingPlatformReceipt';At=(Get-Date -Format o)} | ConvertTo-Json -Compress
