$env:BUILD_BUILDID = 12345
$env:BUILD_ARTIFACTSTAGINGDIRECTORY = 'C:\temp\artifacts'
. .\build.ps1
StandardBuild
