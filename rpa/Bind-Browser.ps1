param([string]$TitleRegex='bilibili|哔哩|创作中心',[long]$WindowHandle=0)
$ErrorActionPreference='Stop'
Add-Type -Path "$PSScriptRoot\native\DingRpa.cs"
$found=@([DingRpa]::ListWindows() | Where-Object {
    $_.Visible -and $_.ClassName -eq 'Chrome_WidgetWin_1' -and
    (Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue).ProcessName -eq 'chrome' -and
    (($WindowHandle -ne 0 -and $_.Handle -eq $WindowHandle) -or ($WindowHandle -eq 0 -and $_.Title -match $TitleRegex))
})
if($found.Count -ne 1){throw ('Expected one Chrome window; found '+$found.Count)}
$process=Get-Process -Id $found[0].ProcessId
$binding=[ordered]@{WindowHandle=$found[0].Handle;ProcessId=$found[0].ProcessId;ProcessStartUtc=$process.StartTime.ToUniversalTime().ToString('o');Title=$found[0].Title}
$dir=Join-Path $PSScriptRoot '..\data';New-Item -ItemType Directory -Force -Path $dir | Out-Null
$binding | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'browser-binding.json') -Encoding UTF8
$binding | ConvertTo-Json -Compress
