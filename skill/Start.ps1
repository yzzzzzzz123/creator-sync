param([ValidateSet('start','status','sites','plan','attach','resume','stop')][string]$Action='start',[ValidateSet('xiaohongshu','bilibili','youtube','tiktok','instagram')][string[]]$Targets,[string]$NoteId,[long]$WindowHandle=0,[switch]$DryRun,[switch]$ClearStop,[switch]$Json)
$ErrorActionPreference='Stop'
$arguments=@('-X','utf8',"$PSScriptRoot\scripts\main.py")
if($Json){$arguments+='--json'}
$arguments+=$Action
if($Targets){$arguments+='--targets';$arguments+=$Targets}
if($NoteId){$arguments+=@('--note-id',$NoteId)}
if($WindowHandle){$arguments+=@('--window-handle',[string]$WindowHandle)}
if($DryRun){$arguments+='--dry-run'}
if($ClearStop){$arguments+='--clear-stop'}
& python @arguments
exit $LASTEXITCODE
