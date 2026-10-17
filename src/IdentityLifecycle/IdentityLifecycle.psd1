@{
    RootModule        = 'IdentityLifecycle.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '6b1f3c52-8d4e-4a8b-9c1d-2e7f5a9b3c41'
    Author            = 'Alex Scheaffer'
    Description       = 'Joiner / mover / leaver automation for Active Directory, anchored on HRIS EmployeeID.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'ConvertTo-AsciiName'
        'New-AccountName'
        'Test-RoleMap'
        'Get-TargetRoleGroup'
        'New-IdentityPlan'
        'ConvertTo-HrisEmailFeed'
        'Get-DirectorySnapshot'
        'Invoke-IdentityPlan'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('ActiveDirectory', 'Identity', 'IAM', 'Onboarding', 'Offboarding', 'RBAC', 'HRIS')
            LicenseUri = 'https://github.com/Moondark87/identity-lifecycle-automation/blob/main/LICENSE'
            ProjectUri = 'https://github.com/Moondark87/identity-lifecycle-automation'
        }
    }
}
