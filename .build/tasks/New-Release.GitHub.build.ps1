param(
    # Base directory of all output (default to 'output')
    [string]$OutputDirectory = (property OutputDirectory (Join-Path $BuildRoot 'output')),

    $ChangelogPath = (property ChangelogPath 'CHANGELOG.md'),

    [string]
    $ProjectName = (property ProjectName $(
            #Find the module manifest to deduce the Project Name
            (Get-ChildItem $BuildRoot\*\*.psd1 | Where-Object {
                ($_.Directory.Name -match 'source|src' -or $_.Directory.Name -eq $_.BaseName) -and
                $(try { Test-ModuleManifest $_.FullName -ErrorAction Stop }catch{$false}) }
            ).BaseName
        )
    ),

    [string]
    $ModuleVersion = (property ModuleVersion $(
            try {
                (gitversion | ConvertFrom-Json -ErrorAction Stop).InformationalVersion
            }
            catch {
                Write-Verbose "Error attempting to use GitVersion $($_)"
                ''
            }
        )),

    [string]
    $GitHubToken = (property GitHubToken '') # retrieves from Environment variable
)

# Synopsis: Packaging the module by Publishing to output folder (incl dependencies)
task package_module_nupkg {

    # Force registering the output repository mapping to the Project's output path
    $null = Unregister-PSRepository -Name output -ErrorAction SilentlyContinue
    $RepositoryParams = @{
        Name            = 'output'
        SourceLocation  = $OutputDirectory
        PublishLocation = $OutputDirectory
        ErrorAction     = 'Stop'
    }

    $null = Register-PSRepository @RepositoryParams

    # Cleaning up existing packaged module
    if ($ModuleToRemove = Get-ChildItem (Join-Path $OutputDirectory "$ProjectName.*.nupkg")) {
        Write-Build DarkGray "  Remove existing $ProjectName package"
        remove-item -force -Path $ModuleToRemove -ErrorAction Stop
    }

    # find Module manifest
    $BuiltModuleManifest = (Get-ChildItem (Join-Path $OutputDirectory $ProjectName) -Depth 2 -Filter "$ProjectName.psd1").FullName
    Write-Build DarkGray "  Built module's Manifest found at $BuiltModuleManifest"

    # load module manifest
    $ModuleInfo = Import-PowerShellDataFile -Path $BuiltModuleManifest

    # Publish dependencies (from environment) so we can publish the built module
    foreach ($module in $ModuleInfo.RequiredModules) {
        if(!(Find-Module -repository output -Name $Module -ErrorAction SilentlyContinue)) {
            # Replace the module by first (path & version) resolved in PSModulePath
            $module = Get-Module -ListAvailable $module | Select-Object -First 1
            if ($Prerelease = $module.PrivateData.PSData.Prerelease) {
                $Prerelease = "-" + $Prerelease
            }
            Write-Build Yellow ("  Packaging Required Module {0} v{1}{2}" -f $Module.Name,$Module.Version.ToString(),$Prerelease)
            Publish-Module -Repository output -ErrorAction SilentlyContinue -Path $module.ModuleBase
        }
    }

    $PublishModuleParams = @{
        Path       = (Join-Path $OutputDirectory $ProjectName)
        Repository = 'output'
        Force      = $true
        ErrorAction = 'Stop'
    }
    Publish-Module @PublishModuleParams
    Write-Build Green "`n  Packaged $ProjectName NuGet package `n"
    Write-Build DarkGray "  Cleaning up"

    $null = Unregister-PSRepository -Name output -ErrorAction SilentlyContinue
}

task Publish_release_to_GitHub -if ($GitHubToken) {
    # Remove metadata from ModuleVersion
    $PSModuleVersion, $PreReleaseTag = ($ModuleVersion -split '\+',2)
    # find Module's nupkg
    $PackageToRelease = Get-ChildItem (Join-Path $OutputDirectory "$ProjectName.$PSModuleVersion.nupkg")
    $ReleaseTag = "v$PSModuleVersion"

    Write-Build DarkGray "About to release $PackageToRelease"
    $remoteURL = git remote get-url origin

    if($remoteURL -notMatch 'github') {
        return
    }

    # find owner repository / remote
    $Repo = GetHumanishRepositoryDetails -RemoteUrl $remoteURL

    # Prerelease label?
    if ($PreReleaseTag) {
        $Prerelease = $true
    }

    # compile changelog for that version
    if(!(Split-Path $ChangelogPath -isAbsolute)) {
        $ChangelogPath = Join-Path $BuildRoot $ChangelogPath | Convert-Path
    }

    # Parse the Changelog and extract unreleased
    if ((Get-Content -raw $ChangelogPath -ErrorAction SilentlyContinue) -match '\[Unreleased\](?<changeLog>[.\s\w\W]*)\n## \[') {
        $ChangeLog = $matches.ChangeLog
    }
    else {
        $ChangeLog = Get-Content -raw $ChangelogPath -ErrorAction SilentlyContinue
    }

    # create release
    # upload artefacts

    $releaseParams = @{
        Owner = $Repo.Owner
        Repository = $Repo.Repository
        Tag = $ReleaseTag
        ReleaseName = $ReleaseTag
        # Branch = "release/$PSModuleVersion"
        AssetPath = $PackageToRelease
        Prerelease = [bool]($PreReleaseTag)
        Description = $ChangeLog
        GitHubToken = $GitHubToken
    }
    $APIResponse = Publish-GitHubRelease @releaseParams
    Write-Build Green "Release Created. Follow the link -> $($APIResponse.html_url)"
}

task Publish_nupkg_to_GitHub_feed {

}


# function GetDescriptionFromChangelog
# {
#     param(
#         [Parameter(Mandatory)]
#         [string]
#         $ChangelogPath
#     )

#     $lines = Get-Content -Path $ChangelogPath
#     # First two lines are the title and newline
#     # Third looks like '## vX.Y.Z-releasetag'
#     $sb = [System.Text.StringBuilder]::new($lines[2])
#     # Read through until the next '## vX.Y.Z-releasetag' H2
#     for ($i = 3; -not $lines[$i].StartsWith('## '); $i++)
#     {
#         $null = $sb.Append("`n").Append($lines[$i])
#     }

#     return $sb.ToString()
# }

# $tag = "v$Version"

# $releaseParams = @{
#     Owner = $TargetFork
#     Repository = $Repository
#     Tag = $tag
#     ReleaseName = $tag
#     Branch = "release/$Version"
#     AssetPath = $AssetPath
#     Prerelease = [bool]($Version.PreReleaseLabel)
#     Description = GetDescriptionFromChangelog -ChangelogPath $ChangelogPath
#     GitHubToken = $GitHubToken
# }
# Publish-GitHubRelease @releaseParams

# from https://github.com/PowerShell/vscode-powershell/blob/master/tools/GitHubTools.psm1
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.
function Publish-GitHubRelease {
    param(
        [Parameter(Mandatory)]
        [string]
        $Owner,

        [Parameter(Mandatory)]
        [string]
        $Repository,

        [Parameter(Mandatory)]
        [string]
        $Tag,

        [Parameter(Mandatory)]
        [string]
        $ReleaseName,

        [Parameter(Mandatory)]
        [string]
        $Description,

        [Parameter(Mandatory)]
        [string]
        $GitHubToken,

        [Parameter()]
        [Alias('Branch', 'Commit')]
        [string]
        $Commitish,

        [Parameter()]
        [string[]]
        $AssetPath,

        [switch]
        $Draft,

        [switch]
        $Prerelease
    )

    $restParams = @{
        tag_name   = $Tag
        name       = $ReleaseName
        body       = $Description
        draft      = [bool]$Draft
        prerelease = [bool]$Prerelease
    }

    if ($Commitish) {
        $restParams.target_commitish = $Commitish
    }

    $restBody = ConvertTo-Json -InputObject $restParams
    $uri = "https://api.github.com/repos/$Owner/$Repository/releases"
    $headers = @{
        Accept        = 'application/vnd.github.v3+json'
        Authorization = "token $GitHubToken"
    }

    $response = Invoke-RestMethod -Method Post -Uri $uri -Body $restBody -Headers $headers

    $releaseId = $response.id
    $assetBaseUri = "https://uploads.github.com/repos/$Owner/$Repository/releases/$releaseId/assets"
    foreach ($asset in $AssetPath) {
        $extension = [System.IO.Path]::GetExtension($asset)
        $fileName = [uri]::EscapeDataString([System.IO.Path]::GetFileName($asset))
        $contentType = 'text/plain'
        switch ($extension) {
            { $_ -in '.zip', '.vsix', 'nupkg' } {
                $contentType = 'application/zip'
                break
            }

            '.json' {
                $contentType = 'application/json'
                break
            }
        }

        $assetUri = "${assetBaseUri}?name=$fileName"
        $headers = @{
            Authorization = "token $GitHubToken"
        }
        # This can be very slow, but it does work
        $null = Invoke-RestMethod -Method Post -Uri $assetUri -InFile $asset -ContentType $contentType -Headers $headers
    }

    return $response
}

# from https://github.com/PowerShell/vscode-powershell/blob/master/tools/GitHubTools.psm1
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.
filter GetHumanishRepositoryDetails
{
    param(
        [string]
        $RemoteUrl
    )

    if ($RemoteUrl.EndsWith('.git'))
    {
        $RemoteUrl = $RemoteUrl.Substring(0, $RemoteUrl.Length - 4)
    }
    else
    {
        $RemoteUrl = $RemoteUrl.Trim('/')
    }

    $lastSlashIdx = $RemoteUrl.LastIndexOf('/')
    $repository =  $RemoteUrl.Substring($lastSlashIdx + 1)
    $secondLastSlashIdx = $RemoteUrl.LastIndexOfAny(('/', ':'), $lastSlashIdx - 1)
    $Owner = $RemoteUrl.Substring($secondLastSlashIdx + 1, $lastSlashIdx - $secondLastSlashIdx - 1)

    return @{
        Owner = $Owner
        Repository = $repository
    }
}