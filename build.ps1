
function DiscoverConfigFiles{
    $configFiles = new-object Collections.Generic.List[IO.FileSystemInfo]
    $configFiles += Get-ChildItem . project.json -rec
    $configFiles += Get-ChildItem . *.csproj -rec | Where-Object { !( $_ | Select-String "wcf" -quiet) }
    return $configFiles
}

function BumpVersions
{
    param(
        [Parameter(Mandatory=$true)]$build,
        [Parameter(Mandatory=$true)][string]$clientStateFIPS
    )

    $versionNumber = "$($clientStateFIPS).$($build.version.major).$($build.version.minor).$env:BUILD_BUILDID"

    $configFiles = DiscoverConfigFiles

    # setting build variables for naming and hopefully tagging https://www.visualstudio.com/en-us/docs/build/define/variables
    Write-Host "##vso[build.addbuildtag]$versionNumber"


    Write-Host "Updating version number to $versionNumber" -ForegroundColor Green
    foreach ($file in $configFiles)
    {
        (Get-Content $file.PSPath) |
        Foreach-Object { $_ -replace "0.0.0-INTERNAL", $versionNumber } |
        Set-Content $file.PSPath
    }
}


function ExecuteRestore
{
    if(Test-Path 'application/.nuget/Nuget.config') 
    {
        Write-Host "Running dotnet restore on application/nuget/Nuget.config" -ForegroundColor Green
        $configFiles = DiscoverConfigFiles
        foreach ($file in $configFiles)
        {
            dotnet restore --configfile application/.nuget/Nuget.config  --verbosity Minimal --disable-parallel --no-cache $file.FullName
        }
    }
    else
    {
        Write-Host "Running dotnet restore" -ForegroundColor Green
        $configFiles = DiscoverConfigFiles
        foreach ($file in $configFiles)
        {
            dotnet restore --verbosity Minimal --disable-parallel --no-cache $file.FullName
        }
    }

    if ($LASTEXITCODE -eq 1)
    {
        Write-Host "Error restoring project" -ForegroundColor Red
        exit 1
    }
}

function ExecuteBuilds
{
    Param($build)

    if ($build.builds)
    {
        $build.builds | ForEach {
          Write-Host "Executing dotnet build for $($_.path)" -ForegroundColor Green
          dotnet build "$($_.path)\"
          if ($LASTEXITCODE -eq 1)
          {
              Write-Host "Error build project $_" -ForegroundColor Red
              exit 1
          }
        }
    }
}

function Get-ExtensionCount {
    param(
        $Root = ".",
        $FileType = ""
    )

    $files = Get-ChildItem $Root -Filter *$FileType | ? { !$_.PSIsContainer }
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


function ExecutePublishes
{
    Param($build)


    if ($build.deploys)
    {
        $build.deploys | ForEach {
          Write-Host "Executing dotnet build/publish for $($_.path)" -ForegroundColor Green
           $output = $env:BUILD_ARTIFACTSTAGINGDIRECTORY + "\" + $_.name
            if ($_.path.EndsWith("csproj") -Or (Get-HasFileWithExtension $_.path csproj ))
            {
                Write-Host "trying csproj" -ForegroundColor Green
                dotnet build $_.path --configuration Release
                dotnet publish $_.path --output $output --configuration Release 
            }
            elseif ($_.path.EndsWith("json") -Or (Get-HasFileWithExtension $_.path json ))
            {
                Write-Host "trying project.json" -ForegroundColor Green
                dotnet build "$($_.path)\project.json" --configuration Release
                dotnet publish "$($_.path)\project.json" --output $output --configuration Release
            }
            else 
            {
                Write-Host "no csproj or json? trying dotnet on folder" -ForegroundColor Green
                dotnet build "$($_.path)\" --configuration Release
                dotnet publish "$($_.path)\" --output $output --configuration Release
                
            }
            if ($LASTEXITCODE -eq 1)
          {
              Write-Host "Error build project $_" -ForegroundColor Red
              exit 1
          }
        }
    }
    else
    {
      Write-Host "No publish targets" -ForegroundColor DarkYellow
    }

}

function ExecuteDatabaseBuilds
{
    if ($build.databases)
    {
        $msbuild15 = "C:\Program Files (x86)\Microsoft Visual Studio\2017\Enterprise\MSBuild\15.0\Bin\MSBuild.exe"
        $msbuild14 = "C:\Program Files (x86)\MSBuild\14.0\bin\msbuild.exe"
          
        if(Test-Path $msbuild15)
        {
                $build.databases| ForEach {
                  $output = $env:BUILD_ARTIFACTSTAGINGDIRECTORY + "\" + $_.name
                   Write-Host "MSBuild Database to $output" -ForegroundColor Green
                   & $msbuild15 $_.path /p:OutputPath=$output
                  if ($LASTEXITCODE -eq 1)
                  {
                      Write-Host "Error build database $_" -ForegroundColor Red
                      exit 1
                  }  
                }
        }
        else
        {
                $build.databases| ForEach {
                  $output = $env:BUILD_ARTIFACTSTAGINGDIRECTORY + "\" + $_.name
                   Write-Host "MSBuild Database to $output" -ForegroundColor Green
                   & $msbuild14 $_.path /p:OutputPath=$output
                  if ($LASTEXITCODE -eq 1)
                  {
                      Write-Host "Error build database $_" -ForegroundColor Red
                      exit 1
                  }  
                }
        }

    }
    else
    {
        Write-Host "No Database projects" -ForegroundColor DarkYellow
    }
}

function PackageDatabaseBuilds
{
    Param($build)
    if ($build.databases)
    {
        $build.databases | ForEach {
        Write-Host "DacPack'ing $($_.name))" -ForegroundColor Green
	    $artdir = $env:BUILD_ARTIFACTSTAGINGDIRECTORY	
            $sourcedir = $artDir + "\" + $_.name
            $dacpacs = Get-ChildItem -Recurse -Include *.dacpac $sourcedir
            if (($dacpacs | Measure-Object).Count -eq 0){
                Write-Host "No dac-pack created." -ForegroundColor Red
                exit 1
            }     
        
            $dacpacs | Copy-Item -Destination $artdir -verbose
        }
    }
}

function PackageBuilds
{
    Param($build)

    if ($build.packages)
    {
         Write-Host "Executing dotnet pack for $($_.path)" -ForegroundColor Green
         $build.packages | ForEach {
         dotnet pack $_.path
          if ($LASTEXITCODE -eq 1)
          {
              Write-Host "Error packaging project $_" -ForegroundColor Red
              exit 1
          }  
        }
    }
    else
    {
        Write-Host "No package targets" -ForegroundColor DarkYellow
    }
}

function ExecuteTests
{
    $exitCode = 0;

    if (Test-Path -Path 'application/test/') {
      $testProjects = new-object Collections.Generic.List[IO.FileSystemInfo]
      $testProjects += Get-ChildItem application/test/ -Recurse -include project.json 
      $testProjects += Get-ChildItem application/test/ -Recurse -include *.csproj 
      
      Write-Host $testProjects -ForegroundColor DarkYellow
      foreach ($file in $testProjects)
      {
        $parent = Split-Path (Split-Path -Path $file.Fullname -Parent) -Leaf;
        $testFile = "TEST-RESULTS-$parent.xml";


        if ($file.FullName.EndsWith("csproj"))
        {
                Push-Location $file.DirectoryName
                dotnet xunit -xml $testFile;
                Pop-Location 
        }
        else
        {
                dotnet test $file -xml $testFile;
        }

        $exitCode = [System.Math]::Max($lastExitCode, $exitCode);

      }

    }
    else
    {
      Write-Warning "No test file found.  Skipping tests."
    }
    
    if ($exitCode -ne 0)
    {
        exit $exitCode
    }
}

function StandardBuild
{
    param(
        [Parameter(Mandatory=$true)][string]$clientStateFIPS
    )

        $build = (Get-Content .\build.json | Out-String | ConvertFrom-Json)
                   
        #Bump the versions first
        BumpVersions $build $clientStateFIPS
        Write-Warning "Finish Bump"

        #Restore the packages
        ExecuteRestore
        Write-Warning "Finish Restore"

        #Execute the builds
        ExecuteBuilds $build
        Write-Warning "Finish build"
        ExecutePublishes $build
        Write-Warning "Finish publishes"
        ExecuteDatabaseBuilds $build
        Write-Warning "Finish databases"


        # Test the builds
        ExecuteTests
        Write-Warning "Finish tests"

        #Package the builds
        PackageBuilds $build
        PackageDatabaseBuilds $build
}
