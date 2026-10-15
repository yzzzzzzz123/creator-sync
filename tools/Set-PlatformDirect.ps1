# Only the requested Chinese platform hosts bypass the existing system proxy.
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$prior=Get-ItemProperty -LiteralPath $key
$backup=Join-Path $projectRoot 'data\network-before.json'
if(-not (Test-Path -LiteralPath $backup)){
    [ordered]@{ProxyEnable=$prior.ProxyEnable;ProxyServer=$prior.ProxyServer;ProxyOverride=$prior.ProxyOverride;AutoConfigURL=$prior.AutoConfigURL} | ConvertTo-Json | Set-Content -LiteralPath $backup -Encoding UTF8
}
$domains=@('bilibili.com','bilibili.cn','bilivideo.com','bilivideo.cn','hdslb.com','biliapi.com','biliapi.net','xiaohongshu.com','xhscdn.com','xhscdn.net')
$entries=@($prior.ProxyOverride -split ';' | Where-Object {$_})
foreach($domain in $domains){foreach($entry in @($domain,('*.'+$domain))){if($entries -notcontains $entry){$entries+=$entry}}}
Set-ItemProperty -LiteralPath $key -Name ProxyOverride -Value ($entries -join ';')
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class ProxyRefresh{[DllImport("wininet.dll",SetLastError=true)]public static extern bool InternetSetOption(IntPtr handle,int option,IntPtr buffer,int length);}'
if(-not [ProxyRefresh]::InternetSetOption([IntPtr]::Zero,39,[IntPtr]::Zero,0)){throw 'Proxy settings broadcast failed'}
if(-not [ProxyRefresh]::InternetSetOption([IntPtr]::Zero,37,[IntPtr]::Zero,0)){throw 'Proxy refresh failed'}
$after=Get-ItemProperty -LiteralPath $key
if($after.ProxyEnable -ne $prior.ProxyEnable -or $after.ProxyServer -cne $prior.ProxyServer){throw 'Primary proxy unexpectedly changed'}
[ordered]@{SystemBypassDomains=$domains;ProxyEnable=$after.ProxyEnable;ProxyServer=$after.ProxyServer;At=(Get-Date -Format o)} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $projectRoot 'data\network-routing.json') -Encoding UTF8
[ordered]@{ChinesePlatformsBypassAdded=$true;ExistingPrimaryProxyPreserved=$true} | ConvertTo-Json -Compress
