BeforeAll {
    $script:moduleName = 'Sampler'

    # If the module is not found, run the build task 'noop'.
    if (-not (Get-Module -Name $script:moduleName -ListAvailable))
    {
        # Redirect all streams to $null, except the error stream (stream 3)
        & "$PSScriptRoot/../../build.ps1" -Tasks 'noop' 2>&1 4>&1 5>&1 6>&1 > $null
    }

    # Re-import the module using force to get any code changes between runs.
    $importedModule = Import-Module -Name $script:moduleName -Force -PassThru -ErrorAction 'Stop'

    Import-Module -Name "$PSScriptRoot\..\..\IntegrationTestHelpers.psm1"

    Install-TreeCommand
}

AfterAll {
    Remove-Module -Name $script:moduleName
}

Describe 'DSC MOF based resource Plaster Template' {
    Context 'When creating a new MOF DSC Resource' {
        BeforeAll {
            $mockResourceName  = 'MyMofResource'
            $mockModuleRootPath = $TestDrive

            $listOfExpectedFilesAndFolders = @(
                # Folders (relative to module root)
                'source'
                'source/DSCResources'
                'source/DSCResources/DSC_Folder'
                'source/DSCResources/DSC_Folder/en-US'
                'source/Modules'
                'source/Modules/Folder.Common'
                # 'source/Modules/HelperSubmodule'
                'tests'
                'tests/Unit'
                'tests/Unit/DSCResources'
                'tests/Unit/Modules'

                # Files (relative to module root)
                'source/DSCResources/DSC_Folder/DSC_Folder.psm1'
                'source/DSCResources/DSC_Folder/DSC_Folder.schema.mof'
                'source/DSCResources/DSC_Folder/en-US/DSC_Folder.strings.psd1'
                'source/Modules/Folder.Common/Folder.Common.psm1'
                # 'source/Modules/HelperSubmodule/HelperSubmodule.psd1'
                # 'source/Modules/HelperSubmodule/HelperSubmodule.psm1'
                'tests/Unit/DSCResources/DSC_Folder.tests.ps1'
                'tests/Unit/Modules/Folder.Common.tests.ps1'
            )
        }

        It 'Should create a new module without throwing' {
            $invokePlasterParameters = @{
                TemplatePath      = Join-Path -Path $importedModule.ModuleBase -ChildPath 'Templates/MofResource'
                DestinationPath   = $testdrive
                NoLogo            = $true
                Force             = $true

                # Template properties
                ResourceName     = $mockResourceName
                SourceDirectory   = 'source'
                ModuleName        = 'MyModule'
            }

            { Invoke-Plaster @invokePlasterParameters } | Should -Not -Throw
        }

        It 'Should have the expected folder and file structure' {
            $modulePaths = Get-ChildItem -Path $mockModuleRootPath -Recurse -Force

            # Make the path relative to module root.
            $relativeModulePaths = $modulePaths.FullName -replace [RegEx]::Escape($mockModuleRootPath)

            # Change to slash when testing on Windows.
            $relativeModulePaths = ($relativeModulePaths -replace '\\', '/').TrimStart('/')

            # check files & folders discrepencies
            $missingFilesOrFolders    = $listOfExpectedFilesAndFolders.Where{$_ -notin $relativeModulePaths}
            $unexpectedFilesAndFolders  = $relativeModulePaths.Where{$_ -notin $listOfExpectedFilesAndFolders}
            $TreeStructureIsOk = ($missingFilesOrFolders.count -eq 0 -and $unexpectedFilesAndFolders.count -eq 0)

            # format the report to be used in because
            $report = ":`r`n  Missing:`r`n`t$($missingFilesOrFolders -join "`r`n`t")`r`n  Unexpected:`r`n`t$($unexpectedFilesAndFolders -join "`r`n`t")`r`n."

            # Check if tree structure failed. If so output the module directory tree.
            if ( -not $TreeStructureIsOk)
            {
                $treeOutput = Get-DirectoryTree -Path $mockModuleRootPath
                Write-Verbose -Message ($treeOutput | Out-String) -Verbose
            }

            $TreeStructureIsOk | Should -BeTrue -Because $report
        }
    }
}
