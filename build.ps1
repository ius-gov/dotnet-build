function ExecuteRestore
{
    if(Test-Path 'application/.nuget/Nuget.config') 
    {
        Write-Host "Running dotnet restore on application/nuget/Nuget.config" -ForegroundColor Green
        dotnet restore --configfile application/.nuget/Nuget.config  --verbosity Minimal --disable-parallel --no-cache
    }
    else
    {
        Write-Host "Running dotnet restore" -ForegroundColor Green
        dotnet restore --verbosity Minimal --disable-parallel --no-cache
    }
}

function ExecuteBuilds
{
    Param($build)

    if ($build.builds)
    {
        $build.builds | ForEach {
          Write-Host "Executing dotnet build for $($_.path)" -ForegroundColor Green
          dotnet build "$($_.path)\project.json"
          if ($LASTEXITCODE -eq 1)
          {
              Write-Host "Error build project $_" -ForegroundColor Red
              exit 1
          }
        }
    }
    else
    {
      Write-Host "No build targets" -ForegroundColor DarkYellow
    }

}

function ExecutePublishes
{
    Param($build)


    if ($build.deploys)
    {
        $build.deploys | ForEach {
          Write-Host "Executing dotnet build/publish for $($_.path)" -ForegroundColor Green
           $output = "$(Build.ArtifactStagingDirectory)" + "\" + $_.name
            dotnet build $_.path --configuration Release
            dotnet publish "$($_.path)\project.json" --output $output --configuration Release
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
        $build.databases| ForEach {
          $output = "$(Build.ArtifactStagingDirectory)" + "\" + $_.name
          
          
           Write-Host "MSBuild Database to $output" -ForegroundColor Green
           & "C:\Program Files (x86)\MSBuild\14.0\bin\msbuild.exe" $_.path /p:OutputPath=$output
          if ($LASTEXITCODE -eq 1)
          {
              Write-Host "Error build database $_" -ForegroundColor Red
              exit 1
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
	    $artdir = "$(Build.ArtifactStagingDirectory)"	
            $sourcedir = $artDir + "\" + $_.name
            $dacpacs = Get-ChildItem -Recurse -Include *.dacpac $sourcedir
            if (($dacpacs | Measure-Object).Count == 0){
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

    if(Test-Path -Path 'application/test/') {
      Get-ChildItem application/test/ -Recurse -include project.json | ForEach {
        $parent = Split-Path (Split-Path -Path $_.Fullname -Parent) -Leaf;
        $testFile = "TEST-RESULTS-$parent.xml";
        dotnet test $_.Fullname -xml $testFile;
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
           

ExecuteRestore

$build = (Get-Content .\build.json | Out-String | ConvertFrom-Json)

ExecuteBuilds $build
ExecutePublishes $build
ExecuteDatabaseBuilds $build
PackageBuilds $build
PackageDatabaseBuilds $build

ExecuteTests