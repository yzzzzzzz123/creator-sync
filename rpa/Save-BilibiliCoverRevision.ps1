$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
if(Test-Path -LiteralPath "$projectRoot\data\STOP"){throw 'Stopped'}
& "$PSScriptRoot\Browser.ps1" -Action Inspect -Stage 'bili-cover-edit-pre-submit' | Out-Null
$snapshot=Get-Content -LiteralPath "$projectRoot\artifacts\bili-cover-edit-pre-submit.json" -Raw | ConvertFrom-Json
$state=Get-Content -LiteralPath "$projectRoot\data\bilibili-test.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$receipt=Get-Content -LiteralPath "$projectRoot\data\receipts\bilibili\result.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$binding=Get-Content -LiteralPath "$projectRoot\data\browser-binding.json" -Raw | ConvertFrom-Json
$docs=@($snapshot.Nodes | Where-Object {$_.Type -eq 'ControlType.Document' -and -not $_.Offscreen})
if($docs.Count -ne 1){throw 'One visible document required'}
$uri=[Uri]$docs[0].Value
if($uri.Host -ne 'member.bilibili.com' -or $uri.AbsolutePath -ne '/platform/upload/video/frame' -or $uri.Query -notmatch '(?:\?|&)type=edit(?:&|$)' -or $uri.Query -notmatch ('(?:\?|&)bvid='+[Regex]::Escape($receipt.bvid)+'(?:&|$)')){throw 'Must edit the existing verified video'}
if($receipt.account_id -cne $state.account_id -or $receipt.note_id -cne $state.note_id -or $receipt.video_sha256 -cne $state.video_sha256 -or $state.max_posts -ne 1){throw 'Existing delivery identity changed'}
$titles=@($snapshot.Nodes | Where-Object {$_.Name -eq '请输入稿件标题'})
if($titles.Count -ne 1 -or $titles[0].Value -cne $state.title){throw 'Existing title changed'}
if(@($snapshot.Nodes | Where-Object {$_.Name -eq '封面制作'}).Count -or -not $state.revised_cover_visually_verified){throw 'Cover editor still open or both-ratio preview not verified'}
if((Get-FileHash -LiteralPath $state.cover_path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $state.cover_sha256){throw 'Revised image changed'}
$shortHash=$state.cover_sha256.Substring(0,16)
$upload=Get-Content -LiteralPath "$projectRoot\data\bilibili-cover-$shortHash-intent.json" -Raw | ConvertFrom-Json
if($upload.Sha256 -cne $state.cover_sha256 -or $upload.AccountId -cne $state.account_id){throw 'Revised cover upload receipt mismatch'}
$handle=[IntPtr]$binding.WindowHandle
$root=[System.Windows.Automation.AutomationElement]::FromHandle($handle)
$nodes=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
$submit=@($nodes | Where-Object {$_.Current.Name -ceq '立即投稿' -and $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text})
if($submit.Count -ne 1){throw 'Edit submit control ambiguous'}
$scroll=$null;if($submit[0].TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern,[ref]$scroll)){$scroll.ScrollIntoView();Start-Sleep -Milliseconds 600}
$matched=$false;$timer=[Diagnostics.Stopwatch]::StartNew()
do{
 $rect=$submit[0].Current.BoundingRectangle
 $hit=[System.Windows.Automation.AutomationElement]::FromPoint([System.Windows.Point]::new([double](($rect.Left+$rect.Right)/2),[double](($rect.Top+$rect.Bottom)/2)))
 for($i=0;$hit -and $i -lt 32;$i++){if([System.Windows.Automation.Automation]::Compare($submit[0],$hit)){$matched=$true;break};$hit=[System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($hit)}
 if($matched){break};Start-Sleep -Milliseconds 100
}while($timer.Elapsed.TotalSeconds -lt 3)
if(-not $matched -or $submit[0].Current.IsOffscreen -or -not $submit[0].Current.IsEnabled){throw 'Edit submit unavailable or covered'}
$intentPath=Join-Path $projectRoot ('data\bilibili-edit-'+$receipt.bvid+'-'+$shortHash+'-intent.json')
$intent=[ordered]@{Action='EditExistingCover';Bvid=$receipt.bvid;AccountId=$state.account_id;CoverSha256=$state.cover_sha256;At=(Get-Date -Format o)} | ConvertTo-Json -Compress
$stream=[IO.File]::Open($intentPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try{$bytes=[Text.Encoding]::UTF8.GetBytes($intent);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
if(Test-Path -LiteralPath "$projectRoot\data\STOP"){throw 'Stopped after cover-edit intent; reconcile before retry'}
[DingRpa]::ClickPoint($handle,[int](($rect.Left+$rect.Right)/2),[int](($rect.Top+$rect.Bottom)/2))
[ordered]@{EditedExistingVideo=$receipt.bvid;CoverSubmissionClickedOnce=$true} | ConvertTo-Json -Compress
