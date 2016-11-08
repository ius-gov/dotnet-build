$build = (Get-Content .\build.json | Out-String | ConvertFrom-Json)
if ($build.builds)
{
    $build.builds | ForEach {
      dotnet build $_.path
      if ($LASTEXITCODE -eq 1)
      {
          Write-Host "Error build project $_"
          exit 1
      }
    }
}
else
{
  Write-Host "No build targets"
}

if ($build.deploys)
{
    $build.deploys | ForEach {
      $output = "$(Build.ArtifactStagingDirectory)" + "\" + $_.name
      dotnet build $_.path --configuration Release
      dotnet publish $_.path --output $output --configuration Release
      if ($LASTEXITCODE -eq 1)
      {
          Write-Host "Error build project $_"
          exit 1
      }
    }
}
else
{
  Write-Host "No publish targets"
}
