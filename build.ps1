
function DiscoverConfigFiles {
    $configFiles = new-object Collections.Generic.List[IO.FileSystemInfo]
    $configFiles += Get-ChildItem . *.csproj -rec | Where-Object { !( $_ | Select-String "wcf" -quiet) }

    Write-Host "Found csproj files: " $configFiles.count

    foreach ($file in $configFiles) {
        Write-Host "Found csproj " $file.FullName -ForegroundColor Green
    }

    return $configFiles
}

function BumpVersions {
    param(
        [Parameter(Mandatory = $false)]$build,
        [Parameter(Mandatory = $true)][string]$clientStateFIPS,
        [Parameter(Mandatory = $false)][string]$prereleaseSuffix
    )
    
    Write-Host ""
    Write-Host "============================================"
    Write-Host "Start Bumping Version"
    Write-Host "============================================"
    Write-Host ""

    if (-Not $PSBoundParameters.ContainsKey('build')) {
        $build = Get-Build-Config
    }

    Write-Host "Initial Build Version: $env:BUILD_BUILDID"

    $buildId = [int]$env:BUILD_BUILDID

    $versionNumber = "$($clientStateFIPS).$($build.version.major).$($build.version.minor).$buildId"
    if ($buildId -gt 65535){
        $buildId = $buildId - 65535
        $versionNumber = "$($clientStateFIPS).$($build.version.major).$($build.version.minor + 1).$buildId"
        Write-Host "overflow from 16-bit int detected, subtracting 65535 in nasty hack"
    }
    Write-Host "ClientStateFIPS: $clientStateFIPS"
    Write-Host "Major Version: $($build.version.major)"
    Write-Host "Minor Version: $($build.version.minor)"
    Write-Host "Build Version: $buildId"

    
    if ($prereleaseSuffix.length -gt 0) {
        $gitPattern = "refs/heads/"
        $cleanedPreReleaseSuffix = $prereleaseSuffix -replace $gitPattern
        # The ^ is not, so replace everything that is not a letter or number
        $nonAlphaPattern = '[^a-zA-z0-9]'
        $cleanedPreReleaseSuffix = $cleanedPreReleaseSuffix -replace $nonAlphaPattern, ''
        
        Write-Host "Prelease Suffix Detected.  Setting  build version to prerelease $cleanedPreReleaseSuffix."
        $versionNumber = "$versionNumber-$cleanedPreReleaseSuffix"
    }

    $configFiles = DiscoverConfigFiles

    # setting build variables for naming and hopefully tagging https://www.visualstudio.com/en-us/docs/build/define/variables
    Write-Host "##vso[build.addbuildtag]$versionNumber"


    Write-Host "Updating version number to $versionNumber" -ForegroundColor Green
    Write-Host ""
    foreach ($file in $configFiles) {
        (Get-Content $file.PSPath) |
            Foreach-Object { $_ -replace "0.0.0-INTERNAL", $versionNumber } |
            Set-Content $file.PSPath

        (Get-Content $file.PSPath) |
            Foreach-Object { Write-Host $_ }
        Write-Host ""
    }

    Write-Host "Finish Bumping Version"
    Write-Host ""
}


function ExecuteRestore {
    Write-Host ""
    Write-Host "============================================"
    Write-Host "Start Restore"
    Write-Host "============================================"
    Write-Host ""

    $configFiles = DiscoverConfigFiles
    if ($configFiles.length -eq 0) {
        Write-Host "No configfiles found, exiting"
        return
    } 

    if (Test-Path 'application/.nuget/Nuget.config') {
        Write-Host "Running dotnet restore on application/nuget/Nuget.config" -ForegroundColor Green
        foreach ($file in $configFiles) {
            dotnet restore --configfile application/.nuget/Nuget.config  --verbosity Normal $file.FullName
        }
    }
    else {
        Write-Host "Running dotnet restore" -ForegroundColor Green
        foreach ($file in $configFiles) {
            Write-Host "Restoring " $file.FullName -ForegroundColor Green
            dotnet restore --verbosity Normal $file.FullName
        }
    }

    if ($LastExitCode -ne 0) {
        Write-Host "##vso[task.logissue type=error;] ERROR: restoring project"
        exit $LastExitCode
    }

    Write-Host "Finish Restore"
}

function ExecuteBuilds {
    Param($build)

    Write-Host ""
    Write-Host "============================================"
    Write-Host "Executing Builds"
    Write-Host "============================================"
    Write-Host ""

    if ($build.builds) {
        $build.builds | ForEach-Object {
            Write-Host "Executing dotnet build for $($_.path)" -ForegroundColor Green
            dotnet build "$($_.path)\"
            if ($LastExitCode -ne 0) {
                Write-Host "##vso[task.logissue type=error;] ERROR: build project $_"
                exit $LastExitCode
            }
        }
    }
    Write-Host "Finish build"
}

function Get-ExtensionCount {
    param(
        $Root = ".",
        $FileType = ""
    )

    $files = Get-ChildItem $Root -Filter *$FileType | Where-Object { !$_.PSIsContainer }
    return $($files.Count)
}

function Get-HasFileWithExtension {
    param(
        $Root = ".",
        $FileType = ""
    )

    $fileCount = Get-ExtensionCount $Root $FileType 
    Write-Host "Found $fileCount with extension $FileType" -ForegroundColor DarkYellow
    return $fileCount -gt 0
}


function ExecutePublishes {
    Param($build)

    Write-Host ""
    Write-Host "============================================"
    Write-Host "Executing Publishes"
    Write-Host "============================================"
    Write-Host ""

    if ($build.deploys) {
        $build.deploys | ForEach-Object {
            Write-Host "Executing dotnet build/publish for $($_.path)" -ForegroundColor Green
            $output = $env:BUILD_ARTIFACTSTAGINGDIRECTORY + "\" + $_.name
            if ($_.path.EndsWith("csproj") -Or (Get-HasFileWithExtension $_.path csproj )) {
                Write-Host "trying csproj" -ForegroundColor Green
                dotnet build $_.path --configuration Release
                dotnet publish $_.path --output $output --configuration Release 
            }
            else {
                Write-Host "no csproj? trying dotnet on folder" -ForegroundColor Green
                dotnet build "$($_.path)\" --configuration Release
                dotnet publish "$($_.path)\" --output $output --configuration Release
            }

            if ($LastExitCode -ne 0) {
                Write-Host "##vso[task.logissue type=error;] ERROR: build project $_"
                exit $LastExitCode
            }
        }
    }
    else {
        Write-Host "No publish targets" -ForegroundColor DarkYellow
    }

    Write-Host "Finish publishes"
}

function ExecuteDatabaseBuilds {
    Write-Host ""
    Write-Host "============================================"
    Write-Host "Executing Database Builds"
    Write-Host "============================================"
    Write-Host ""

    if ($build.databases) {
        $msbuild15 = "C:\Program Files (x86)\Microsoft Visual Studio\2017\Enterprise\MSBuild\15.0\Bin\MSBuild.exe"
          
        $build.databases| ForEach-Object {
            $output = $env:BUILD_ARTIFACTSTAGINGDIRECTORY + "\" + $_.name
            Write-Host "MSBuild Database to $output" -ForegroundColor Green 

            # build the database
            & $msbuild15 $_.path /p:OutputPath=$output

            if ($LastExitCode -ne 0) {
                Write-Host "##vso[task.logissue type=error;] ERROR: build database $_"
                exit $LastExitCode
            }  
        }
    }
    else {
        Write-Host "No Database projects" -ForegroundColor DarkYellow
    }

    Write-Host "Finish databases"
}

function PackageDatabaseBuilds {
    Param($build)
    if ($build.databases) {
        $build.databases | ForEach-Object {
            Write-Host "DacPack'ing $($_.name))" -ForegroundColor Green
            $artdir = $env:BUILD_ARTIFACTSTAGINGDIRECTORY	
            $sourcedir = $artDir + "\" + $_.name
            $dacpacs = Get-ChildItem -Recurse -Include *.dacpac $sourcedir
            if (($dacpacs | Measure-Object).Count -eq 0) {
                Write-Host "ERROR: No dac-pack created." -ForegroundColor Red
                exit 1
            }     
        
            $dacpacs | Copy-Item -Destination $artdir -verbose
        }
    }
}

function PackageBuilds {
    Param($build)

    if ($build.packages) {
        $build.packages | ForEach-Object {
            Write-Host "Executing dotnet pack for $($_.path)" -ForegroundColor Green
            dotnet pack $_.path
            if ($LastExitCode -ne 0) {
                Write-Host "##vso[task.logissue type=error;] ERROR: packaging project $_"
                exit $LastExitCode
            }  
        }
    }
    else {
        Write-Host "No package targets" -ForegroundColor DarkYellow
    }
}

function ExecuteTests {
    Write-Host ""
    Write-Host "============================================"
    Write-Host "Executing Tests"
    Write-Host "============================================"
    Write-Host ""

    $exitCode = 0;

    if (Test-Path -Path 'application/test/') {
        $testProjects = new-object Collections.Generic.List[IO.FileSystemInfo]
        $testProjects += Get-ChildItem application/test/ -Recurse -include *.csproj 
      
        Write-Host $testProjects
        foreach ($file in $testProjects) {
            $parent = Split-Path (Split-Path -Path $file.Fullname -Parent) -Leaf;
            $testFile = "TEST-RESULTS-$parent.xml";

            Push-Location $file.DirectoryName
            Write-Host "Executing Test $file"
            Get-Location
            if ($file.FullName.EndsWith("csproj")) {
                # This causes a conflict on Json.Net that I hope resolves itself
                # dotnet xunit -xml $testFile;
                dotnet test;
            }
            else {
                dotnet test -xml $testFile;
            }
            Pop-Location         

            if ($LastExitCode -ne 0) {
                Write-Host "##vso[task.logissue type=error;] ERROR: Finished tests in $file with exit code $LastExitCode"
            }

            $exitCode = [System.Math]::Max($LastExitCode, $exitCode);

        }

    }
    else {
        Write-Host "##vso[task.logissue type=warning;] No test file found.  Skipping tests."
    }
    
    if ($exitCode -ne 0) {
        exit $exitCode
    }

    Write-Host "Finish tests"
}

function Get-Build-Config {
    $build = (Get-Content .\build.json | Out-String | ConvertFrom-Json)
    return $build
}

function ExecuteBuildAndPublish {
    param($build)

    if (-Not $PSBoundParameters.ContainsKey('build')) {
        $build = Get-Build-Config
    }

    ExecuteBuilds -build $build
    ExecutePublishes -build $build
    ExecuteDatabaseBuilds -build $build
}

function PackageArtifacts {
    param($build)

    if (-Not $PSBoundParameters.ContainsKey('build')) {
        $build = Get-Build-Config
    }

    PackageBuilds -build $build
    PackageDatabaseBuilds -build $build
}

function StandardBuild {
    param(
        [Parameter(Mandatory = $true)][string]$clientStateFIPS,
        [Parameter(Mandatory = $false)][string]$prereleaseSuffix
    )

    $build = Get-Build-Config
                   
    #Bump the versions first
    BumpVersions -build $build -clientStateFIPS $clientStateFIPS -prereleaseSuffix $prereleaseSuffix

    #Restore the packages
    ExecuteRestore

    #Execute the builds
    ExecuteBuildAndPublish -build $build

    # Test the builds
    ExecuteTests

    #Package the builds
    PackageArtifacts -build $build
}
