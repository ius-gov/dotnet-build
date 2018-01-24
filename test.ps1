function Get-ScriptDirectory { Split-Path $MyInvocation.ScriptName }
$script = Join-Path (Get-ScriptDirectory) 'build.ps1'

$env:BUILD_BUILDID = 12345
$env:BUILD_ARTIFACTSTAGINGDIRECTORY = 'C:\temp\artifacts'
. $script
StandardBuild -clientStateFIPS 0 -prereleaseSuffix ci
