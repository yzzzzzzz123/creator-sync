param([switch]$Check)
# Domestic hosts bypass the existing proxy; overseas hosts keep it.
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$projectRoot=Split-Path $PSScriptRoot -Parent
$key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$prior=Get-ItemProperty -LiteralPath $key
$domains=@('douyin.com','iesdouyin.com','amemv.com','douyinvod.com','douyinpic.com','douyincdn.com','douyinstatic.com','douyinvideo.net','v5-dy-ov-experiment.zjcdn.com','bilibili.com','bilibili.cn','bilivideo.com','bilivideo.cn','hdslb.com','biliapi.com','biliapi.net','xiaohongshu.com','xhscdn.com','xhscdn.net')
$mediaManifest=Join-Path $projectRoot 'data\douyin\active-media.json'
if(Test-Path -LiteralPath $mediaManifest){
    $media=Get-Content -LiteralPath $mediaManifest -Raw -Encoding UTF8 | ConvertFrom-Json
    $uri=[Uri]$media.MediaUrl
    if($media.SourceId -match '^\d{10,30}$' -and $uri.Scheme -eq 'https' -and $uri.Host -match '(^|\.)douyinvod\.com$|^v\d+-dy-[a-z0-9-]+\.zjcdn\.com$' -and $uri.Query -match ('(^|[?&])__vid='+[regex]::Escape([string]$media.SourceId)+'(&|$)') -and $domains -notcontains $uri.Host){$domains+=$uri.Host}
}
$overseas=@('youtube.com','googlevideo.com','ytimg.com','tiktok.com','tiktokcdn.com','tiktokv.com','tiktokcdn-us.com','ibytedtos.com','byteoversea.com','instagram.com','cdninstagram.com','fbcdn.net')
$entries=@($prior.ProxyOverride -split ';' | Where-Object {$_})
if($prior.ProxyEnable -ne 1 -or -not $prior.ProxyServer){throw 'An existing system proxy is required for overseas targets'}
if($prior.AutoConfigURL){throw 'A PAC is configured; inspect effective Chrome routing before changing bypass rules'}
foreach($domain in $overseas){foreach($sample in @($domain,('www.'+$domain),('media.'+$domain))){foreach($entry in $entries){if($sample -like $entry){throw ('Overseas host unexpectedly bypasses the proxy: '+$sample+' matches '+$entry)}}}}
if($Check){
    $missing=@();foreach($domain in $domains){foreach($entry in @($domain,('*.'+$domain))){if($entries -notcontains $entry){$missing+=$entry}}}
    [ordered]@{ConfigurationVerified=($missing.Count -eq 0);DirectPlatforms=@('douyin','xiaohongshu','bilibili');ProxyPlatforms=@('youtube','tiktok','instagram');MissingBypassEntries=$missing;ExistingPrimaryProxyPreserved=$true;Verification='Windows system proxy configuration; page connectivity is checked separately'} | ConvertTo-Json -Depth 4 -Compress
    exit 0
}
New-Item -ItemType Directory -Force -Path (Join-Path $projectRoot 'data') | Out-Null
$backup=Join-Path $projectRoot 'data\network-before.json'
if(-not (Test-Path -LiteralPath $backup)){
    [ordered]@{ProxyEnable=$prior.ProxyEnable;ProxyServer=$prior.ProxyServer;ProxyOverride=$prior.ProxyOverride;AutoConfigURL=$prior.AutoConfigURL} | ConvertTo-Json | Set-Content -LiteralPath $backup -Encoding UTF8
}
foreach($domain in $domains){foreach($entry in @($domain,('*.'+$domain))){if($entries -notcontains $entry){$entries+=$entry}}}
Set-ItemProperty -LiteralPath $key -Name ProxyOverride -Value ($entries -join ';')
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class ProxyRefresh{[DllImport("wininet.dll",SetLastError=true)]public static extern bool InternetSetOption(IntPtr handle,int option,IntPtr buffer,int length);}'
if(-not [ProxyRefresh]::InternetSetOption([IntPtr]::Zero,39,[IntPtr]::Zero,0)){throw 'Proxy settings broadcast failed'}
if(-not [ProxyRefresh]::InternetSetOption([IntPtr]::Zero,37,[IntPtr]::Zero,0)){throw 'Proxy refresh failed'}
$after=Get-ItemProperty -LiteralPath $key
if($after.ProxyEnable -ne $prior.ProxyEnable -or $after.ProxyServer -cne $prior.ProxyServer){throw 'Primary proxy unexpectedly changed'}
[ordered]@{SystemBypassDomains=$domains;ProxyEnable=$after.ProxyEnable;ProxyServer=$after.ProxyServer;At=(Get-Date -Format o)} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $projectRoot 'data\network-routing.json') -Encoding UTF8
[ordered]@{ChinesePlatformsBypassAdded=$true;DirectPlatforms=@('douyin','xiaohongshu','bilibili');ProxyPlatforms=@('youtube','tiktok','instagram');ExistingPrimaryProxyPreserved=$true} | ConvertTo-Json -Depth 4 -Compress
