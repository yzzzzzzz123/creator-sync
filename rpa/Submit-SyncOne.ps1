param([Parameter(Mandatory=$true)][string]$Package)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$state=Get-Content -LiteralPath $Package -Raw -Encoding UTF8 | ConvertFrom-Json
if($state.Platform -notin @('tiktok','instagram') -or $state.MaxPosts -ne 1 -or -not $state.CoverAndSettingsVerified){throw 'Verified single-post package required'}
& "$PSScriptRoot\Browser.ps1" -Action Inspect -Stage ($state.Platform+'-pre-publication') | Out-Null
$binding=Get-Content -LiteralPath "$projectRoot\data\browser-binding.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$config=Get-Content -LiteralPath "$projectRoot\config.local.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$source=Get-Content -LiteralPath "$projectRoot\data\douyin\acquisition-check.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$proof=Get-Content -LiteralPath $state.AccountEvidence -Raw -Encoding UTF8 | ConvertFrom-Json
$profile=if($state.Platform -eq 'tiktok'){'https://www.tiktok.com/@'+$state.AccountId}else{'https://www.instagram.com/'+$state.AccountId+'/'}
if($state.AccountId -cne $config.targets.($state.Platform).account_id -or $proof.Window.Handle -ne $binding.WindowHandle -or ([DateTimeOffset]::Now-[DateTimeOffset]::Parse($proof.At)).TotalMinutes -gt 15 -or -not @($proof.Nodes | Where-Object {$_.Value -ceq $profile}).Count){throw 'Fresh target account proof required'}
if($source.Status -ne 'rpa_assets_verified' -or $state.SourceKey -cne $source.LedgerKey -or $state.SourceSha256 -cne $source.Video.sha256 -or $state.Caption -cne $source.EnglishCaption){throw 'Source or caption package mismatch'}
if((Get-FileHash -LiteralPath $source.Video.path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $state.SourceSha256){throw 'Original source changed'}
foreach($purpose in @('Video','Cover')){
    $asset=$state.$purpose
    if((Get-FileHash -LiteralPath $asset.Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $asset.Sha256){throw 'Publication asset changed'}
    $intent=Get-Content -LiteralPath $asset.UploadIntent -Raw -Encoding UTF8 | ConvertFrom-Json
    if($intent.SourceKey -cne $state.SourceKey -or $intent.AccountId -cne $state.AccountId -or $intent.Sha256 -cne $asset.Sha256){throw 'Asset upload intent mismatch'}
}
$dedup=Get-Content -LiteralPath $state.ExistingPostsEvidence -Raw -Encoding UTF8 | ConvertFrom-Json
if($dedup.Window.Handle -ne $binding.WindowHandle -or ([DateTimeOffset]::Now-[DateTimeOffset]::Parse($dedup.At)).TotalMinutes -gt 15){throw 'Fresh existing-post review required'}
$handle=[IntPtr]$binding.WindowHandle
$root=[System.Windows.Automation.AutomationElement]::FromHandle($handle)
function Nodes($element){return $element.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)}
function Value($element){$p=$null;if($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$p)){return $p.Current.Value};return $null}
$all=Nodes $root
$hostName=if($state.Platform -eq 'tiktok'){'www.tiktok.com'}else{'www.instagram.com'}
$docs=@($all | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Document -and -not $_.Current.IsOffscreen -and (Value $_) -match '^https://' -and ([Uri](Value $_)).Host -eq $hostName})
if($docs.Count -ne 1 -or (Value $docs[0]) -cne $state.EditorUrl){throw 'Exact official editor document mismatch'}
$nodes=Nodes $docs[0]
if($state.Platform -eq 'instagram'){
    $dialogs=@($nodes | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Window -and $_.Current.Name -ceq 'Create new post' -and -not $_.Current.IsOffscreen})
    if($dialogs.Count -ne 1){throw 'Expected one final Instagram editor'}
    $nodes=Nodes $dialogs[0]
    if(-not @($nodes | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text -and $_.Current.Name -ceq $state.AccountId}).Count){throw 'Instagram editor account changed'}
    $caption=@($nodes | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and $_.Current.Name -ceq 'Add a caption...'})
    if($caption.Count -ne 1 -or (Value $caption[0]) -cne $state.Caption){throw 'Instagram caption readback mismatch'}
    $buttonName='Share'
}else{
    if(([Uri]$state.EditorUrl).Query -notmatch '(^|[?&])draft_id=\d+(&|$)'){throw 'Resume the exact TikTok draft, never upload again'}
    $caption=@($nodes | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ComboBox -and $_.Current.ClassName -ceq 'notranslate public-DraftEditor-content'})
    if($caption.Count -ne 1 -or $caption[0].GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(-1).TrimEnd([char]13,[char]10) -cne $state.Caption){throw 'TikTok caption readback mismatch'}
    $now=@($nodes | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::RadioButton -and $_.Current.Name -ceq 'Now'})
    if($now.Count -ne 1 -or -not $now[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected -or -not @($nodes | Where-Object {$_.Current.Name -ceq 'Everyone'}).Count){throw 'TikTok timing/visibility changed'}
    $buttonName='Post'
}
$buttons=@($nodes | Where-Object {$_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $_.Current.Name -ceq $buttonName})
if($buttons.Count -ne 1){throw 'Final submit control ambiguous'}
$button=$buttons[0];$scroll=$null
if($button.TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern,[ref]$scroll)){$scroll.ScrollIntoView();Start-Sleep -Milliseconds 400}
if($button.Current.IsOffscreen -or -not $button.Current.IsEnabled){throw 'Final submit is unavailable'}
$rect=$button.Current.BoundingRectangle
$hit=[System.Windows.Automation.AutomationElement]::FromPoint([System.Windows.Point]::new(($rect.Left+$rect.Right)/2,($rect.Top+$rect.Bottom)/2));$matched=$false
for($i=0;$hit -and $i -lt 64;$i++){if([System.Windows.Automation.Automation]::Compare($button,$hit)){$matched=$true;break};$hit=[System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($hit)}
if(-not $matched){throw 'Final submit is covered'}
$intentPath=Join-Path (Split-Path ([IO.Path]::GetFullPath($Package)) -Parent) ($state.Platform+'-submit-intent.json')
$intent=[ordered]@{Platform=$state.Platform;AccountId=$state.AccountId;SourceKey=$state.SourceKey;SourceSha256=$state.SourceSha256;EditorUrl=$state.EditorUrl;Caption=$state.Caption;At=(Get-Date -Format o)}
$stream=[IO.File]::Open($intentPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
try{$bytes=[Text.Encoding]::UTF8.GetBytes(($intent | ConvertTo-Json));$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
& python "$projectRoot\tools\claim_sync_submit.py" ([IO.Path]::GetFullPath($Package))
if($LASTEXITCODE -ne 0){throw 'Ledger claim failed; retained intent, no click performed'}
if(Test-Path -LiteralPath "$projectRoot\data\STOP"){throw 'Stopped after claim; reconcile retained intent'}
[DingRpa]::ClickPoint($handle,[int](($rect.Left+$rect.Right)/2),[int](($rect.Top+$rect.Bottom)/2))
[ordered]@{Platform=$state.Platform;ClickedOnce=$true;Status='AwaitingPlatformReceipt'} | ConvertTo-Json -Compress
