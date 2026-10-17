#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'src/IdentityLifecycle/IdentityLifecycle.psd1') -Force

    $script:Settings = Get-Content (Join-Path $repoRoot 'config/settings.example.json') -Raw | ConvertFrom-Json
    $script:RoleMap = Get-Content (Join-Path $repoRoot 'config/roles.example.json') -Raw | ConvertFrom-Json
    $script:AsOf = [datetime]'2026-10-16'

    function New-Hris {
        param([hashtable]$Overrides = @{})
        $record = [ordered]@{
            EmployeeID = '200001'; FirstName = 'Alex'; LastName = 'Rivera'; PreferredName = ''
            Department = 'IT'; JobCode = 'IT-HD'; JobTitle = 'Service Desk Analyst'; Location = 'HQ'
            ManagerEmployeeID = ''; WorkerType = 'Employee'; Status = 'Active'; StartDate = '2024-01-08'; EndDate = ''
        }
        foreach ($k in $Overrides.Keys) { $record[$k] = $Overrides[$k] }
        [pscustomobject]$record
    }

    function New-DirUser {
        param([hashtable]$Overrides = @{})
        $user = [ordered]@{
            SamAccountName = 'alex.rivera'; UserPrincipalName = 'alex.rivera@example.com'; EmployeeID = '200001'
            GivenName = 'Alex'; Surname = 'Rivera'; Department = 'IT'; Title = 'Service Desk Analyst'; Office = 'HQ'
            ManagerEmployeeID = ''; Description = ''; Enabled = $true
            Groups = @('ROLE-All-Employees', 'ROLE-IT', 'ROLE-IT-ServiceDesk', 'ROLE-Site-HQ')
        }
        foreach ($k in $Overrides.Keys) { $user[$k] = $Overrides[$k] }
        [pscustomobject]$user
    }

    function Invoke-Plan {
        param([object[]]$Hris = @(), [object[]]$Directory = @())
        @(New-IdentityPlan -HrisRecords $Hris -DirectoryUsers $Directory -RoleMap $script:RoleMap -Settings $script:Settings -AsOf $script:AsOf)
    }
}

Describe 'ConvertTo-AsciiName' {
    It 'normalizes <Name> to <Expected>' -ForEach @(
        @{ Name = 'José'; Expected = 'jose' }
        @{ Name = "O'Connor"; Expected = 'oconnor' }
        @{ Name = 'Mary Ann'; Expected = 'maryann' }
        @{ Name = 'Smith-Jones'; Expected = 'smith-jones' }
        @{ Name = 'Zoë'; Expected = 'zoe' }
        @{ Name = '  Lee  '; Expected = 'lee' }
    ) {
        ConvertTo-AsciiName $Name | Should -BeExactly $Expected
    }
}

Describe 'New-AccountName' {
    It 'builds first.last' {
        New-AccountName -FirstName 'Dana' -LastName 'Whitfield' | Should -BeExactly 'dana.whitfield'
    }
    It 'adds a numeric suffix on collision, ignoring case' {
        New-AccountName -FirstName 'Marcus' -LastName 'Lee' -ExistingNames 'Marcus.Lee', 'marcus.lee2' | Should -BeExactly 'marcus.lee3'
    }
    It 'stays within 20 characters, including the suffix' {
        $name = New-AccountName -FirstName 'Bartholomew' -LastName 'Fitzgerald-Smythe' -ExistingNames 'bartholomew.fitzgera'
        $name.Length | Should -BeLessOrEqual 20
        $name | Should -BeExactly 'bartholomew.fitzger2'
    }
    It 'throws when a name has no usable letters' {
        { New-AccountName -FirstName '123' -LastName 'Lee' } | Should -Throw
    }
}

Describe 'Test-RoleMap' {
    It 'accepts the example role map' {
        Test-RoleMap -RoleMap $script:RoleMap -ManagedGroupPrefix 'ROLE-' | Should -BeTrue
    }
    It 'rejects a privileged group so automation can never grant it' {
        $bad = [pscustomobject]@{ JobCodes = [pscustomobject]@{ 'IT-SYS' = @('ROLE-IT-Systems', 'PRIV-Domain-Admins') } }
        { Test-RoleMap -RoleMap $bad -ManagedGroupPrefix 'ROLE-' } | Should -Throw '*PRIV-Domain-Admins*'
    }
}

Describe 'Get-TargetRoleGroup' {
    It 'combines baseline, department, job code and location' {
        $groups = Get-TargetRoleGroup -Person (New-Hris @{ Department = 'Finance'; JobCode = 'FIN-AP'; Location = 'SITE-A' }) -RoleMap $script:RoleMap
        $groups | Should -Be @('ROLE-All-Employees', 'ROLE-Finance', 'ROLE-Finance-AP', 'ROLE-Site-A')
    }
    It 'uses the contractor baseline for contractors' {
        $groups = Get-TargetRoleGroup -Person (New-Hris @{ WorkerType = 'Contractor' }) -RoleMap $script:RoleMap
        $groups | Should -Contain 'ROLE-All-Contractors'
        $groups | Should -Not -Contain 'ROLE-All-Employees'
    }
    It 'ignores values that are not in the role map' {
        $groups = Get-TargetRoleGroup -Person (New-Hris @{ JobCode = 'UNKNOWN'; Location = 'MOON' }) -RoleMap $script:RoleMap
        $groups | Should -Be @('ROLE-All-Employees', 'ROLE-IT')
    }
}

Describe 'New-IdentityPlan' {
    Context 'sample data end to end' {
        BeforeAll {
            $repoRoot = Split-Path -Parent $PSScriptRoot
            $hris = @(Import-Csv (Join-Path $repoRoot 'examples/hris-export.sample.csv') -Encoding UTF8)
            $dir = Get-Content (Join-Path $repoRoot 'examples/directory-snapshot.sample.json') -Raw | ConvertFrom-Json   # passed as-is: the module flattens it
            $script:SamplePlan = Invoke-Plan -Hris $hris -Directory $dir
        }
        It 'produces <Count> <Action> item(s)' -ForEach @(
            @{ Action = 'Joiner'; Count = 3 }
            @{ Action = 'Activate'; Count = 1 }
            @{ Action = 'Mover'; Count = 1 }
            @{ Action = 'Update'; Count = 1 }
            @{ Action = 'Leaver'; Count = 1 }
            @{ Action = 'Review'; Count = 6 }
            @{ Action = 'NoChange'; Count = 6 }
        ) {
            @($script:SamplePlan | Where-Object Action -eq $Action).Count | Should -Be $Count
        }
        It 'never plans anything for excluded admin and service accounts' {
            $script:SamplePlan.SamAccountName | Should -Not -Contain 'adm-marcus.lee'
            $script:SamplePlan.SamAccountName | Should -Not -Contain 'svc-backup'
        }
    }

    Context 'joiners' {
        It 'creates an enabled account once the start date is reached' {
            $item = (Invoke-Plan -Hris (New-Hris))[0]
            $item.Action | Should -Be 'Joiner'
            $item.SamAccountName | Should -Be 'alex.rivera'
            $item.Details.UserPrincipalName | Should -Be 'alex.rivera@example.com'
            $item.Details.Enable | Should -BeTrue
            $item.Details.Path | Should -Be $script:Settings.OUs.Employees
            $item.GroupsToAdd | Should -Be @('ROLE-All-Employees', 'ROLE-IT', 'ROLE-IT-ServiceDesk', 'ROLE-Site-HQ')
        }
        It 'creates a disabled pre-hire account inside the lead window' {
            $item = (Invoke-Plan -Hris (New-Hris @{ Status = 'Pending'; StartDate = '2026-10-20' }))[0]
            $item.Action | Should -Be 'Joiner'
            $item.Details.Enable | Should -BeFalse
        }
        It 'waits for hires that start beyond the lead window' {
            $item = (Invoke-Plan -Hris (New-Hris @{ Status = 'Pending'; StartDate = '2026-12-01' }))[0]
            $item.Action | Should -Be 'NoChange'
        }
        It 'places contractors in the contractor OU' {
            $item = (Invoke-Plan -Hris (New-Hris @{ WorkerType = 'Contractor' }))[0]
            $item.Details.Path | Should -Be $script:Settings.OUs.Contractors
        }
        It 'uses the preferred name for the account and display name' {
            $item = (Invoke-Plan -Hris (New-Hris @{ FirstName = 'Alexandra'; PreferredName = 'Alex' }))[0]
            $item.SamAccountName | Should -Be 'alex.rivera'
            $item.DisplayName | Should -Be 'Alex Rivera'
        }
        It 'avoids names already taken in the directory' {
            $existing = New-DirUser @{ EmployeeID = '200999'; Enabled = $false }
            $item = (Invoke-Plan -Hris (New-Hris) -Directory $existing) | Where-Object Action -eq 'Joiner'
            $item.SamAccountName | Should -Be 'alex.rivera2'
        }
        It 'asks for review instead of creating a duplicate when an unanchored account has the same name' {
            $item = (Invoke-Plan -Hris (New-Hris) -Directory (New-DirUser @{ EmployeeID = '' }))[0]
            $item.Action | Should -Be 'Review'
            $item.Reason | Should -BeLike '*alex.rivera*'
        }
    }

    Context 'movers and updates' {
        It 'adds and removes only managed role groups on a department change' {
            $dir = New-DirUser @{ Department = 'Sales'; Groups = @('ROLE-All-Employees', 'ROLE-Sales', 'ROLE-Site-HQ', 'VPN-Users') }
            $item = (Invoke-Plan -Hris (New-Hris) -Directory $dir)[0]
            $item.Action | Should -Be 'Mover'
            $item.GroupsToAdd | Should -Be @('ROLE-IT', 'ROLE-IT-ServiceDesk')
            $item.GroupsToRemove | Should -Be @('ROLE-Sales')
            $item.GroupsToRemove | Should -Not -Contain 'VPN-Users'
            $item.AttributeChanges['Department'].To | Should -Be 'IT'
        }
        It 'reports a title-only change as an Update' {
            $item = (Invoke-Plan -Hris (New-Hris @{ JobTitle = 'Senior Service Desk Analyst' }) -Directory (New-DirUser))[0]
            $item.Action | Should -Be 'Update'
            @($item.AttributeChanges.Keys) | Should -Be @('Title')
        }
        It 'reports NoChange when HRIS and directory agree' {
            (Invoke-Plan -Hris (New-Hris) -Directory (New-DirUser))[0].Action | Should -Be 'NoChange'
        }
    }

    Context 'pre-hire activation and rehires' {
        It 'activates a pre-hire account on its start date' {
            $dir = New-DirUser @{ Enabled = $false; Description = 'Pre-hire: enable on 2026-10-16' }
            (Invoke-Plan -Hris (New-Hris @{ StartDate = '2026-10-16' }) -Directory $dir)[0].Action | Should -Be 'Activate'
        }
        It 'leaves a pre-hire account disabled before its start date' {
            $dir = New-DirUser @{ Enabled = $false; Description = 'Pre-hire: enable on 2026-10-19' }
            (Invoke-Plan -Hris (New-Hris @{ Status = 'Pending'; StartDate = '2026-10-19' }) -Directory $dir)[0].Action | Should -Be 'NoChange'
        }
        It 'never re-enables a disabled former employee automatically' {
            $dir = New-DirUser @{ Enabled = $false; Description = 'Disabled 2026-01-05 by identity lifecycle automation' }
            (Invoke-Plan -Hris (New-Hris) -Directory $dir)[0].Action | Should -Be 'Review'
        }
    }

    Context 'leavers' {
        It 'offboards once the end date has passed' {
            $item = (Invoke-Plan -Hris (New-Hris @{ Status = 'Terminated'; EndDate = '2026-10-15' }) -Directory (New-DirUser))[0]
            $item.Action | Should -Be 'Leaver'
            $item.Details.DisabledOU | Should -Be $script:Settings.OUs.Disabled
            $item.Details.DeleteAfter | Should -Be '2026-11-15'
        }
        It 'treats a termination with no end date as effective now' {
            (Invoke-Plan -Hris (New-Hris @{ Status = 'Terminated' }) -Directory (New-DirUser))[0].Action | Should -Be 'Leaver'
        }
        It 'waits for a future end date' {
            (Invoke-Plan -Hris (New-Hris @{ Status = 'Terminated'; EndDate = '2026-10-31' }) -Directory (New-DirUser))[0].Action | Should -Be 'NoChange'
        }
        It "also offboards the leaver's admin account" {
            $admin = New-DirUser @{ SamAccountName = 'adm-alex.rivera'; UserPrincipalName = 'adm-alex.rivera@example.com'; Groups = @('PRIV-Tier1-Eligible') }
            $plan = Invoke-Plan -Hris (New-Hris @{ Status = 'Terminated'; EndDate = '2026-10-15' }) -Directory @((New-DirUser), $admin)
            @($plan | Where-Object Action -eq 'Leaver').SamAccountName | Should -Be @('adm-alex.rivera', 'alex.rivera')
        }
        It 'leaves admin accounts alone while the owner is active' {
            $admin = New-DirUser @{ SamAccountName = 'adm-alex.rivera'; Groups = @('PRIV-Tier1-Eligible') }
            $plan = Invoke-Plan -Hris (New-Hris) -Directory @((New-DirUser), $admin)
            $plan.SamAccountName | Should -Not -Contain 'adm-alex.rivera'
        }
        It 'flags admin accounts with no valid owner' {
            $plan = Invoke-Plan -Directory @(
                (New-DirUser @{ SamAccountName = 'adm-ghost'; EmployeeID = '' })
                (New-DirUser @{ SamAccountName = 'adm-former'; EmployeeID = '299999' })
            )
            @($plan | Where-Object Action -eq 'Review').SamAccountName | Should -Be @('adm-former', 'adm-ghost')
        }
        It 'flags accounts past retention for manual deletion' {
            $dir = New-DirUser @{ Enabled = $false; Description = 'Disabled 2026-08-01 by identity lifecycle automation' }
            $item = (Invoke-Plan -Hris (New-Hris @{ Status = 'Terminated'; EndDate = '2026-08-01' }) -Directory $dir)[0]
            $item.Action | Should -Be 'Review'
            $item.Reason | Should -BeLike '*Eligible for deletion*'
        }
    }

    Context 'data quality' {
        It 'flags HRIS records without an EmployeeID' {
            (Invoke-Plan -Hris (New-Hris @{ EmployeeID = '' }))[0].Action | Should -Be 'Review'
        }
        It 'flags duplicate EmployeeIDs in HRIS and leaves the account alone' {
            $plan = @(Invoke-Plan -Hris @((New-Hris), (New-Hris @{ FirstName = 'Sam' })) -Directory (New-DirUser))
            $plan.Count | Should -Be 1
            $plan[0].Action | Should -Be 'Review'
        }
        It 'flags an EmployeeID shared by two directory accounts' {
            $plan = Invoke-Plan -Hris (New-Hris) -Directory @((New-DirUser), (New-DirUser @{ SamAccountName = 'arivera' }))
            ($plan | Where-Object Action -eq 'Review').Reason | Should -BeLike '*more than one account*'
            $plan.Action | Should -Not -Contain 'Joiner'
        }
        It 'flags orphaned accounts whose EmployeeID is not in HRIS' {
            (Invoke-Plan -Directory (New-DirUser))[0].Reason | Should -BeLike 'Orphaned*'
        }
        It 'flags enabled accounts with no EmployeeID' {
            (Invoke-Plan -Directory (New-DirUser @{ EmployeeID = '' }))[0].Reason | Should -BeLike '*no EmployeeID*'
        }
        It 'flags unknown HRIS statuses' {
            (Invoke-Plan -Hris (New-Hris @{ Status = 'OnLeave' }))[0].Action | Should -Be 'Review'
        }
        It 'reads Enabled stored as text' {
            (Invoke-Plan -Hris (New-Hris) -Directory (New-DirUser @{ Enabled = 'False'; Description = '' }))[0].Action | Should -Be 'Review'
        }
    }
}

Describe 'ConvertTo-HrisEmailFeed' {
    It 'publishes one email per EmployeeID and skips admin, disabled and unanchored accounts' {
        $dir = @(
            (New-DirUser)
            (New-DirUser @{ SamAccountName = 'adm-alex.rivera'; UserPrincipalName = 'adm-alex.rivera@example.com' })
            (New-DirUser @{ SamAccountName = 'old.user'; EmployeeID = '200002'; Enabled = $false })
            (New-DirUser @{ SamAccountName = 'kiosk'; EmployeeID = '' })
        )
        $feed = @(ConvertTo-HrisEmailFeed -DirectoryUsers $dir -ExcludeAccountPatterns 'adm-*')
        $feed.Count | Should -Be 1
        $feed[0].EmployeeID | Should -Be '200001'
        $feed[0].Email | Should -Be 'alex.rivera@example.com'
    }
    It 'leaves out an EmployeeID that maps to two eligible accounts' {
        $dir = @((New-DirUser), (New-DirUser @{ SamAccountName = 'arivera'; UserPrincipalName = 'arivera@example.com' }))
        @(ConvertTo-HrisEmailFeed -DirectoryUsers $dir -WarningAction SilentlyContinue).Count | Should -Be 0
    }
}

Describe 'Invoke-IdentityPlan' -Tag 'Directory' {
    # Every directory cmdlet is mocked. Stubs stand in where the ActiveDirectory module
    # is not installed (e.g. Linux CI) so the mocks have something to replace.
    BeforeAll {
        $stubs = @{
            'New-ADUser'                        = 'Name,SamAccountName,UserPrincipalName,EmailAddress,GivenName,Surname,DisplayName,EmployeeID,Department,Title,Office,Path,AccountPassword,Enabled,Description'
            'Set-ADUser'                        = 'Identity,Manager,Description,Department,Title,Office,Clear,Replace'
            'Get-ADUser'                        = 'Identity,Filter,Properties,SearchBase'
            'Get-ADGroup'                       = 'Identity'
            'Add-ADGroupMember'                 = 'Identity,Members'
            'Remove-ADGroupMember'              = 'Identity,Members'
            'Enable-ADAccount'                  = 'Identity'
            'Disable-ADAccount'                 = 'Identity'
            'Set-ADAccountPassword'             = 'Identity,Reset,NewPassword'
            'Get-ADPrincipalGroupMembership'    = 'Identity'
            'Remove-ADPrincipalGroupMembership' = 'Identity,MemberOf'
            'Move-ADObject'                     = 'Identity,TargetPath'
        }
        foreach ($name in $stubs.Keys) {
            if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
                $params = ($stubs[$name] -split ',' | ForEach-Object { if ($_ -eq 'Reset') { '[switch]$Reset' } else { "`$$_" } }) -join ', '
                $body = "[CmdletBinding(SupportsShouldProcess)] param($params)"
                Set-Item -Path "function:global:$name" -Value ([scriptblock]::Create($body))
            }
        }

        Mock Assert-ActiveDirectoryModule -ModuleName IdentityLifecycle { }
        foreach ($name in $stubs.Keys) { Mock $name -ModuleName IdentityLifecycle { } }
        Mock Get-ADUser -ModuleName IdentityLifecycle {
            [pscustomobject]@{
                SamAccountName    = 'alex.rivera'
                DistinguishedName = 'CN=Alex Rivera,OU=Employees,OU=Users,OU=Corp,DC=corp,DC=example,DC=com'
                PrimaryGroup      = 'CN=Domain Users,CN=Users,DC=corp,DC=example,DC=com'
            }
        }
        Mock Get-ADPrincipalGroupMembership -ModuleName IdentityLifecycle {
            [pscustomobject]@{ Name = 'Domain Users'; DistinguishedName = 'CN=Domain Users,CN=Users,DC=corp,DC=example,DC=com' }
            [pscustomobject]@{ Name = 'ROLE-IT'; DistinguishedName = 'CN=ROLE-IT,OU=Roles,OU=Groups,OU=Corp,DC=corp,DC=example,DC=com' }
            [pscustomobject]@{ Name = 'VPN-Users'; DistinguishedName = 'CN=VPN-Users,OU=Resources,OU=Groups,OU=Corp,DC=corp,DC=example,DC=com' }
        }

        $script:ApplySettings = $script:Settings | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $script:ApplySettings.Leaver.RevokeEntraSessions = $false
        $script:ApplySettings.Leaver.HideFromGal = $false
    }

    It 'creates a joiner with its role groups' {
        $plan = Invoke-Plan -Hris (New-Hris @{ ManagerEmployeeID = '100101' })
        $result = Invoke-IdentityPlan -Plan $plan -Settings $script:ApplySettings -AuditLogPath "TestDrive:\audit.jsonl" -Confirm:$false
        $result.Applied | Should -Be 1
        Should -Invoke New-ADUser -ModuleName IdentityLifecycle -Times 1 -Exactly -ParameterFilter { $SamAccountName -eq 'alex.rivera' -and $EmployeeID -eq '200001' -and $Enabled -eq $true }
        Should -Invoke Add-ADGroupMember -ModuleName IdentityLifecycle -Times 4 -Exactly
        Should -Invoke Set-ADUser -ModuleName IdentityLifecycle -Times 1 -Exactly -ParameterFilter { $null -ne $Manager }
    }

    It 'changes nothing with -WhatIf' {
        $plan = Invoke-Plan -Hris (New-Hris)
        Invoke-IdentityPlan -Plan $plan -Settings $script:ApplySettings -WhatIf | Out-Null
        Should -Invoke New-ADUser -ModuleName IdentityLifecycle -Times 0 -Exactly
        Should -Invoke Add-ADGroupMember -ModuleName IdentityLifecycle -Times 0 -Exactly
    }

    It 'offboards a leaver: disable, reset, strip groups except primary, move, audit' {
        $audit = "TestDrive:\leaver.jsonl"
        $plan = Invoke-Plan -Hris (New-Hris @{ Status = 'Terminated'; EndDate = '2026-10-15' }) -Directory (New-DirUser)
        $result = Invoke-IdentityPlan -Plan $plan -Settings $script:ApplySettings -AuditLogPath $audit -Confirm:$false
        $result.Applied | Should -Be 1
        Should -Invoke Disable-ADAccount -ModuleName IdentityLifecycle -Times 1 -Exactly
        Should -Invoke Set-ADAccountPassword -ModuleName IdentityLifecycle -Times 1 -Exactly
        Should -Invoke Remove-ADPrincipalGroupMembership -ModuleName IdentityLifecycle -Times 1 -Exactly -ParameterFilter {
            @($MemberOf).Count -eq 2 -and @($MemberOf).Name -notcontains 'Domain Users'
        }
        Should -Invoke Move-ADObject -ModuleName IdentityLifecycle -Times 1 -Exactly -ParameterFilter { $TargetPath -like 'OU=Disabled,*' }

        $entry = Get-Content $audit | Select-Object -Last 1 | ConvertFrom-Json
        $entry.Action | Should -Be 'Leaver'
        $entry.Data.GroupsRemoved | Should -Be @('ROLE-IT', 'VPN-Users')
    }

    It 'never applies Review or NoChange items' {
        $plan = @(
            Invoke-Plan -Hris (New-Hris @{ EmployeeID = '' })
            Invoke-Plan -Hris (New-Hris) -Directory (New-DirUser)
        )
        $result = Invoke-IdentityPlan -Plan $plan -Settings $script:ApplySettings -Confirm:$false
        $result.Applied | Should -Be 0
        $result.Skipped | Should -Be 2
        Should -Invoke New-ADUser -ModuleName IdentityLifecycle -Times 0 -Exactly
        Should -Invoke Set-ADUser -ModuleName IdentityLifecycle -Times 0 -Exactly
    }

    It 'records a failure and carries on with the next item' {
        Mock New-ADUser -ModuleName IdentityLifecycle { throw 'The specified account already exists' }
        $plan = @(
            Invoke-Plan -Hris (New-Hris)   # Joiner: New-ADUser will fail
            Invoke-Plan -Hris (New-Hris @{ EmployeeID = '200002'; Status = 'Terminated' }) -Directory (New-DirUser @{ EmployeeID = '200002'; SamAccountName = 'pat.doe' })   # Leaver
        )
        $plan.Action | Should -Be @('Joiner', 'Leaver')
        $audit = "TestDrive:\failure.jsonl"
        $result = Invoke-IdentityPlan -Plan $plan -Settings $script:ApplySettings -AuditLogPath $audit -Confirm:$false -ErrorAction SilentlyContinue
        $result.Failed | Should -Be 1
        $result.Applied | Should -Be 1
        (Get-Content $audit | ForEach-Object { ($_ | ConvertFrom-Json).Result }) | Should -Be @('Failed', 'Success')
    }
}
