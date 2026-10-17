#Requires -Version 5.1
<#
    IdentityLifecycle
    Joiner / Mover / Leaver automation anchored on HRIS EmployeeID.

    Design rules (see docs/decisions):
      * Plan first, apply second. New-IdentityPlan never changes anything.
      * EmployeeID is the only automatic match key. Anything fuzzy becomes a Review item.
      * Review items are never applied by automation.
      * Automation only manages groups with the managed prefix (ROLE-). Privileged
        access (PRIV-) is granted through PIM, never by this module.
#>

Set-StrictMode -Version Latest

#region Helpers (private)

function Get-Prop {
    # Trimmed string value of a property, or '' when missing/null. Safe under StrictMode.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return '' }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return ([string]$p.Value).Trim() }
    return ''
}

function Get-PropArray {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return @() }
    $p = $Object.PSObject.Properties[$Name]
    if ($p -and $null -ne $p.Value) { return @($p.Value | Where-Object { $_ }) }
    return @()
}

function Test-Enabled {
    # Accepts a real boolean or its text form; a missing value counts as disabled.
    param($Object)
    if ($null -eq $Object) { return $false }
    $p = $Object.PSObject.Properties['Enabled']
    if (-not $p -or $null -eq $p.Value) { return $false }
    if ($p.Value -is [bool]) { return $p.Value }
    return ([string]$p.Value).Trim() -eq 'true'
}

function ConvertTo-DateOrNull {
    param([string]$Value)
    if (-not $Value) { return $null }
    $d = [datetime]::MinValue
    $formats = [string[]]@('yyyy-MM-dd', 'yyyy-MM-ddTHH:mm:ss', 'MM/dd/yyyy', 'M/d/yyyy')
    if ([datetime]::TryParseExact($Value.Trim(), $formats, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$d)) {
        return $d.Date
    }
    return $null
}

function Test-ExcludedAccount {
    param([string]$SamAccountName, [string[]]$Patterns)
    foreach ($pattern in $Patterns) {
        if ($pattern -and $SamAccountName -like $pattern) { return $true }
    }
    return $false
}

function Get-MapValue {
    param($Map, [string]$Section, [string]$Key)
    if (-not $Key) { return @() }
    $sec = $Map.PSObject.Properties[$Section]
    if (-not $sec -or $null -eq $sec.Value) { return @() }
    $entry = $sec.Value.PSObject.Properties[$Key]
    if (-not $entry) { return @() }
    return @($entry.Value)
}

function New-PlanItem {
    param([string]$Action, [string]$EmployeeID, [string]$SamAccountName, [string]$DisplayName, [string]$Reason)
    [pscustomobject][ordered]@{
        Action           = $Action
        EmployeeID       = $EmployeeID
        SamAccountName   = $SamAccountName
        DisplayName      = $DisplayName
        Reason           = $Reason
        AttributeChanges = [ordered]@{}
        GroupsToAdd      = @()
        GroupsToRemove   = @()
        Details          = [ordered]@{}
    }
}

function Get-PersonFirstName {
    param($Person)
    $preferred = Get-Prop $Person 'PreferredName'
    if ($preferred) { return $preferred }
    return (Get-Prop $Person 'FirstName')
}

function Get-NameKey {
    param([string]$First, [string]$Last)
    $f = ConvertTo-AsciiName $First
    $l = ConvertTo-AsciiName $Last
    if (-not $f -or -not $l) { return '' }
    return "$f|$l"
}

function New-RandomPassword {
    # Random throwaway password. Never logged or returned in plain text; first sign-in
    # uses a Temporary Access Pass or SSPR issued out of band.
    param([int]$Length = 24)
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%^&*-_=+'.ToCharArray()
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        do {
            $bytes = New-Object byte[] $Length
            $rng.GetBytes($bytes)
            $pw = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
        } until ($pw -cmatch '[A-Z]' -and $pw -cmatch '[a-z]' -and $pw -match '\d' -and $pw -match '[^A-Za-z0-9]')
    }
    finally { $rng.Dispose() }
    $secure = New-Object System.Security.SecureString
    foreach ($ch in $pw.ToCharArray()) { $secure.AppendChar($ch) }
    $secure.MakeReadOnly()
    return $secure
}

function Write-AuditEvent {
    param(
        [string]$Path,
        [string]$Action,
        [string]$EmployeeID,
        [string]$SamAccountName,
        [string]$Result,
        [System.Collections.IDictionary]$Data = @{}
    )
    $evt = [ordered]@{
        Timestamp      = (Get-Date).ToUniversalTime().ToString('o')
        Action         = $Action
        EmployeeID     = $EmployeeID
        SamAccountName = $SamAccountName
        Result         = $Result
        Data           = $Data
    }
    $line = $evt | ConvertTo-Json -Compress -Depth 6
    if ($Path) { Add-Content -Path $Path -Value $line -Encoding UTF8 -WhatIf:$false }
    Write-Verbose $line
}

function Assert-ActiveDirectoryModule {
    if (-not (Get-Module -Name ActiveDirectory)) {
        if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
            throw 'The ActiveDirectory module (RSAT) is required to read or change the directory.'
        }
        Import-Module ActiveDirectory -ErrorAction Stop
    }
}

function ConvertTo-LdapFilterValue {
    param([string]$Value)
    return ($Value -replace "'", "''")
}

function Resolve-ManagerDn {
    param([string]$ManagerEmployeeID)
    if (-not $ManagerEmployeeID) { return $null }
    $id = ConvertTo-LdapFilterValue $ManagerEmployeeID
    $mgr = @(Get-ADUser -Filter "EmployeeID -eq '$id'" -ErrorAction Stop)
    if ($mgr.Count -eq 1) { return $mgr[0].DistinguishedName }
    Write-Warning "Manager EmployeeID $ManagerEmployeeID matched $($mgr.Count) accounts; manager not set."
    return $null
}

#endregion

#region Naming

function ConvertTo-AsciiName {
    <#
    .SYNOPSIS
        Normalizes a name for account naming and matching: strips accents, spaces,
        apostrophes and anything that is not a letter or hyphen, then lowercases.
    .EXAMPLE
        ConvertTo-AsciiName "José O'Brien"   # joseobrien
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, ValueFromPipeline)][AllowEmptyString()][string]$Name)
    process {
        $decomposed = $Name.Normalize([Text.NormalizationForm]::FormD)
        $sb = New-Object System.Text.StringBuilder
        foreach ($ch in $decomposed.ToCharArray()) {
            if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
                [void]$sb.Append($ch)
            }
        }
        ($sb.ToString() -replace '[^A-Za-z-]', '').Trim('-').ToLowerInvariant()
    }
}

function New-AccountName {
    <#
    .SYNOPSIS
        Builds a unique first.last account name (sAMAccountName-safe, max 20 chars).
        Collisions get a numeric suffix: first.last2, first.last3 ...
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$FirstName,
        [Parameter(Mandatory)][string]$LastName,
        [AllowEmptyCollection()][string[]]$ExistingNames = @(),
        [ValidateRange(8, 64)][int]$MaxLength = 20
    )
    $first = ConvertTo-AsciiName $FirstName
    $last = ConvertTo-AsciiName $LastName
    if (-not $first -or -not $last) { throw "Cannot build an account name from '$FirstName' '$LastName'." }

    $taken = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $ExistingNames) { if ($n) { [void]$taken.Add($n) } }

    $base = "$first.$last"
    for ($i = 1; $i -lt 100; $i++) {
        $suffix = if ($i -eq 1) { '' } else { [string]$i }
        $stem = $base
        if ($stem.Length + $suffix.Length -gt $MaxLength) {
            $stem = $stem.Substring(0, $MaxLength - $suffix.Length).TrimEnd('.', '-')
        }
        $candidate = $stem + $suffix
        if (-not $taken.Contains($candidate)) { return $candidate }
    }
    throw "No free account name for '$base'."
}

#endregion

#region Role mapping

function Test-RoleMap {
    <#
    .SYNOPSIS
        Validates that every group in the role map carries the managed prefix.
        Stops privileged or unmanaged groups from ever being granted by automation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$RoleMap,
        [Parameter(Mandatory)][string]$ManagedGroupPrefix
    )
    $invalid = New-Object System.Collections.Generic.List[string]
    foreach ($section in $RoleMap.PSObject.Properties) {
        if ($null -eq $section.Value) { continue }
        foreach ($entry in $section.Value.PSObject.Properties) {
            foreach ($group in @($entry.Value)) {
                if ($group -notlike "$ManagedGroupPrefix*") { $invalid.Add("$($section.Name).$($entry.Name): $group") }
            }
        }
    }
    if ($invalid.Count -gt 0) {
        throw "Role map contains groups without the managed prefix '$ManagedGroupPrefix': $($invalid -join '; ')"
    }
    return $true
}

function Get-TargetRoleGroup {
    <#
    .SYNOPSIS
        Returns the role groups a person should hold, from WorkerType, Department,
        JobCode and Location in the role map.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]$Person,
        [Parameter(Mandatory)]$RoleMap
    )
    $groups = @(
        Get-MapValue $RoleMap 'Baseline' (Get-Prop $Person 'WorkerType')
        Get-MapValue $RoleMap 'Departments' (Get-Prop $Person 'Department')
        Get-MapValue $RoleMap 'JobCodes' (Get-Prop $Person 'JobCode')
        Get-MapValue $RoleMap 'Locations' (Get-Prop $Person 'Location')
    )
    # Ordinal sort so the order is identical on every OS and culture.
    $unique = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($g in $groups) { if ($g) { [void]$unique.Add([string]$g) } }
    $sorted = [string[]]@($unique)
    [Array]::Sort($sorted, [StringComparer]::OrdinalIgnoreCase)
    return $sorted
}

#endregion

#region Planning

function New-IdentityPlan {
    <#
    .SYNOPSIS
        Compares HRIS records with directory accounts and returns the changes needed.
        Read-only: nothing is changed.
    .OUTPUTS
        One plan item per person or account. Action is one of:
          Joiner    create a new account
          Activate  enable a pre-hire account on its start date
          Mover     role groups change (department, job code, location or worker type)
          Update    attributes change but role groups do not
          Leaver    disable and strip access
          NoChange  nothing to do (Reason explains why)
          Review    a human must decide; never applied automatically
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$HrisRecords,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$DirectoryUsers,
        [Parameter(Mandatory)]$RoleMap,
        [Parameter(Mandatory)]$Settings,
        [datetime]$AsOf = (Get-Date)
    )

    # Windows PowerShell's ConvertFrom-Json emits a JSON array as one object; flatten
    # one level so callers can pass its output directly.
    $HrisRecords = @($HrisRecords | ForEach-Object { $_ })
    $DirectoryUsers = @($DirectoryUsers | ForEach-Object { $_ })

    $AsOf = $AsOf.Date
    $prefix = [string]$Settings.ManagedGroupPrefix
    $leadDays = [int]$Settings.Joiner.DaysBeforeStartToCreate
    $retentionDays = [int]$Settings.Leaver.RetentionDays
    $excludePatterns = @($Settings.ExcludeAccountPatterns)
    $adminPatterns = if ($Settings.PSObject.Properties['AdminAccountPatterns']) { @($Settings.AdminAccountPatterns) } else { @() }
    $plan = New-Object System.Collections.Generic.List[object]

    # Admin accounts are excluded from role management but still belong to a person:
    # they are offboarded with their owner and flagged when they have no valid owner.
    $adminsById = @{}
    $ownerlessAdmins = New-Object System.Collections.Generic.List[object]
    foreach ($u in $DirectoryUsers) {
        if (-not (Test-ExcludedAccount -SamAccountName (Get-Prop $u 'SamAccountName') -Patterns $adminPatterns)) { continue }
        if (-not (Test-Enabled $u)) { continue }
        $id = Get-Prop $u 'EmployeeID'
        if (-not $id) { $ownerlessAdmins.Add($u); continue }
        if (-not $adminsById.ContainsKey($id)) { $adminsById[$id] = New-Object System.Collections.Generic.List[object] }
        $adminsById[$id].Add($u)
    }
    $addAdminLeavers = {
        param([string]$OwnerId, [string]$OwnerName)
        if (-not $adminsById.ContainsKey($OwnerId)) { return }
        foreach ($a in $adminsById[$OwnerId]) {
            $adm = New-PlanItem 'Leaver' $OwnerId (Get-Prop $a 'SamAccountName') $OwnerName 'Owner terminated; offboard their admin account.'
            $adm.GroupsToRemove = @(Get-PropArray $a 'Groups')
            $adm.Details['UserPrincipalName'] = Get-Prop $a 'UserPrincipalName'
            $adm.Details['DisabledOU'] = [string]$Settings.OUs.Disabled
            $adm.Details['DeleteAfter'] = $AsOf.AddDays($retentionDays).ToString('yyyy-MM-dd')
            $plan.Add($adm)
        }
    }

    # Every existing name counts as taken, including excluded accounts.
    $takenNames = New-Object System.Collections.Generic.List[string]
    foreach ($u in $DirectoryUsers) { $takenNames.Add((Get-Prop $u 'SamAccountName')) }

    # ---- Index the directory by EmployeeID ----
    $dirById = @{}
    $unanchored = New-Object System.Collections.Generic.List[object]
    foreach ($u in $DirectoryUsers) {
        if (Test-ExcludedAccount -SamAccountName (Get-Prop $u 'SamAccountName') -Patterns $excludePatterns) { continue }
        $id = Get-Prop $u 'EmployeeID'
        if (-not $id) { $unanchored.Add($u); continue }
        if (-not $dirById.ContainsKey($id)) { $dirById[$id] = New-Object System.Collections.Generic.List[object] }
        $dirById[$id].Add($u)
    }
    $ambiguousIds = @{}   # EmployeeIDs nobody may act on until a human resolves them
    foreach ($id in @($dirById.Keys)) {
        if ($dirById[$id].Count -gt 1) {
            $sams = ($dirById[$id] | ForEach-Object { Get-Prop $_ 'SamAccountName' }) -join ', '
            $plan.Add((New-PlanItem 'Review' $id '' '' "EmployeeID is on more than one account ($sams). Resolve before automation can manage it."))
            $dirById.Remove($id)
            $ambiguousIds[$id] = $true
        }
    }

    # ---- Index HRIS by EmployeeID ----
    $hrisById = @{}
    $hrisDupes = @{}
    foreach ($h in $HrisRecords) {
        $id = Get-Prop $h 'EmployeeID'
        $name = "$(Get-PersonFirstName $h) $(Get-Prop $h 'LastName')".Trim()
        if (-not $id) {
            $plan.Add((New-PlanItem 'Review' '' '' $name 'HRIS record has no EmployeeID. Fix in HRIS; it cannot be matched.'))
            continue
        }
        if ($hrisById.ContainsKey($id)) { $hrisDupes[$id] = $true } else { $hrisById[$id] = $h }
    }
    foreach ($id in @($hrisDupes.Keys)) {
        $plan.Add((New-PlanItem 'Review' $id '' '' 'EmployeeID appears on more than one HRIS record. Fix in HRIS.'))
        $hrisById.Remove($id)
        if ($dirById.ContainsKey($id)) { $dirById.Remove($id) }   # leave the account alone until HRIS is fixed
    }

    # Unanchored accounts indexed by name, for possible-match detection.
    $unanchoredByName = @{}
    foreach ($u in $unanchored) {
        $key = Get-NameKey (Get-Prop $u 'GivenName') (Get-Prop $u 'Surname')
        if (-not $key) { continue }
        if (-not $unanchoredByName.ContainsKey($key)) { $unanchoredByName[$key] = New-Object System.Collections.Generic.List[object] }
        $unanchoredByName[$key].Add($u)
    }
    $flaggedSams = @{}

    # ---- Evaluate each HRIS person ----
    foreach ($id in ($hrisById.Keys | Sort-Object)) {
        if ($ambiguousIds.ContainsKey($id)) { continue }   # already raised as a Review item
        $h = $hrisById[$id]
        $first = Get-PersonFirstName $h
        $last = Get-Prop $h 'LastName'
        $displayName = "$first $last".Trim()
        $status = Get-Prop $h 'Status'
        $start = ConvertTo-DateOrNull (Get-Prop $h 'StartDate')
        $end = ConvertTo-DateOrNull (Get-Prop $h 'EndDate')
        $d = if ($dirById.ContainsKey($id)) { $dirById[$id][0] } else { $null }
        $sam = Get-Prop $d 'SamAccountName'

        if ($status -notin @('Active', 'Pending', 'Terminated')) {
            $plan.Add((New-PlanItem 'Review' $id $sam $displayName "Unknown HRIS status '$status'."))
            continue
        }

        # ---------- Terminated ----------
        if ($status -eq 'Terminated') {
            if (-not $end -or $end -le $AsOf) { & $addAdminLeavers $id $displayName }
            if (-not $d) {
                $plan.Add((New-PlanItem 'NoChange' $id '' $displayName 'Terminated; no account exists.'))
                continue
            }
            $enabled = (Test-Enabled $d)
            if ($enabled) {
                if ($end -and $end -gt $AsOf) {
                    $plan.Add((New-PlanItem 'NoChange' $id $sam $displayName "Termination scheduled for $($end.ToString('yyyy-MM-dd'))."))
                    continue
                }
                $item = New-PlanItem 'Leaver' $id $sam $displayName $(if ($end) { "Terminated effective $($end.ToString('yyyy-MM-dd'))." } else { 'Terminated (no end date in HRIS); treated as effective now.' })
                $item.GroupsToRemove = @(Get-PropArray $d 'Groups')
                $item.Details['UserPrincipalName'] = Get-Prop $d 'UserPrincipalName'
                $item.Details['DisabledOU'] = [string]$Settings.OUs.Disabled
                $item.Details['DeleteAfter'] = $AsOf.AddDays($retentionDays).ToString('yyyy-MM-dd')
                $plan.Add($item)
                continue
            }
            $disabledOn = $null
            if ((Get-Prop $d 'Description') -match '^Disabled (\d{4}-\d{2}-\d{2})') { $disabledOn = ConvertTo-DateOrNull $Matches[1] }
            if ($disabledOn -and $disabledOn.AddDays($retentionDays) -le $AsOf) {
                $plan.Add((New-PlanItem 'Review' $id $sam $displayName "Disabled $($disabledOn.ToString('yyyy-MM-dd')); $retentionDays-day retention has ended. Eligible for deletion (manual)."))
            }
            else {
                $plan.Add((New-PlanItem 'NoChange' $id $sam $displayName 'Terminated; account already disabled.'))
            }
            continue
        }

        # ---------- Active / Pending, no account ----------
        if (-not $d) {
            if ($start -and $start -gt $AsOf.AddDays($leadDays)) {
                $plan.Add((New-PlanItem 'NoChange' $id '' $displayName "Future hire (starts $($start.ToString('yyyy-MM-dd'))); account is created $leadDays days before start."))
                continue
            }
            $candidates = New-Object System.Collections.Generic.List[object]
            foreach ($f in @(@($first, (Get-Prop $h 'FirstName')) | Select-Object -Unique)) {
                $key = Get-NameKey $f $last
                if ($key -and $unanchoredByName.ContainsKey($key)) { $unanchoredByName[$key] | ForEach-Object { $candidates.Add($_) } }
            }
            if ($candidates.Count -gt 0) {
                $names = ($candidates | ForEach-Object { Get-Prop $_ 'SamAccountName' } | Select-Object -Unique)
                foreach ($n in $names) { $flaggedSams[$n] = $true }
                $plan.Add((New-PlanItem 'Review' $id '' $displayName "Possible existing account without EmployeeID: $($names -join ', '). Link EmployeeID manually instead of creating a duplicate."))
                continue
            }

            $newSam = New-AccountName -FirstName $first -LastName $last -ExistingNames $takenNames.ToArray()
            $takenNames.Add($newSam)
            $isContractor = (Get-Prop $h 'WorkerType') -eq 'Contractor'
            $enableNow = (-not $start) -or ($start -le $AsOf)

            $item = New-PlanItem 'Joiner' $id $newSam $displayName $(if ($enableNow) { 'New hire; start date reached.' } else { "Pre-hire; created disabled, enabled on $($start.ToString('yyyy-MM-dd'))." })
            $item.GroupsToAdd = @(Get-TargetRoleGroup -Person $h -RoleMap $RoleMap)
            $item.Details['GivenName'] = $first
            $item.Details['Surname'] = $last
            $item.Details['UserPrincipalName'] = "$newSam@$($Settings.UpnSuffix)"
            $item.Details['Path'] = if ($isContractor) { [string]$Settings.OUs.Contractors } else { [string]$Settings.OUs.Employees }
            $item.Details['Department'] = Get-Prop $h 'Department'
            $item.Details['Title'] = Get-Prop $h 'JobTitle'
            $item.Details['Office'] = Get-Prop $h 'Location'
            $item.Details['ManagerEmployeeID'] = Get-Prop $h 'ManagerEmployeeID'
            $item.Details['Enable'] = $enableNow
            $item.Details['StartDate'] = if ($start) { $start.ToString('yyyy-MM-dd') } else { '' }
            $plan.Add($item)
            continue
        }

        # ---------- Active / Pending, account exists ----------
        if (-not (Test-Enabled $d)) {
            if ((Get-Prop $d 'Description') -like 'Pre-hire*') {
                if (-not $start -or $start -le $AsOf) {
                    $item = New-PlanItem 'Activate' $id $sam $displayName 'Start date reached; enable pre-hire account.'
                    $item.Details['UserPrincipalName'] = Get-Prop $d 'UserPrincipalName'
                    $plan.Add($item)
                }
                else {
                    $plan.Add((New-PlanItem 'NoChange' $id $sam $displayName "Pre-hire account waiting for start date $($start.ToString('yyyy-MM-dd'))."))
                }
            }
            else {
                $plan.Add((New-PlanItem 'Review' $id $sam $displayName 'HRIS shows active but the account is disabled (rehire or HRIS error). Confirm before re-enabling.'))
            }
            continue
        }

        $target = @(Get-TargetRoleGroup -Person $h -RoleMap $RoleMap)
        $current = @(Get-PropArray $d 'Groups' | Where-Object { $_ -like "$prefix*" })
        $toAdd = @($target | Where-Object { $current -notcontains $_ })
        $toRemove = @($current | Where-Object { $target -notcontains $_ })

        $attrMap = [ordered]@{ Department = 'Department'; Title = 'JobTitle'; Office = 'Location'; ManagerEmployeeID = 'ManagerEmployeeID' }
        $changes = [ordered]@{}
        foreach ($dirAttr in $attrMap.Keys) {
            $from = Get-Prop $d $dirAttr
            $to = Get-Prop $h $attrMap[$dirAttr]
            if ($from -cne $to) { $changes[$dirAttr] = [ordered]@{ From = $from; To = $to } }
        }

        if ($toAdd.Count -gt 0 -or $toRemove.Count -gt 0) {
            $reason = if ($changes.Contains('Department')) { "Department change: $($changes['Department'].From) -> $($changes['Department'].To)." } else { 'Role groups differ from policy.' }
            $item = New-PlanItem 'Mover' $id $sam $displayName $reason
        }
        elseif ($changes.Count -gt 0) {
            $item = New-PlanItem 'Update' $id $sam $displayName "Attribute change: $(@($changes.Keys) -join ', ')."
        }
        else {
            $plan.Add((New-PlanItem 'NoChange' $id $sam $displayName 'In sync with HRIS.'))
            continue
        }
        $item.AttributeChanges = $changes
        $item.GroupsToAdd = $toAdd
        $item.GroupsToRemove = $toRemove
        $plan.Add($item)
    }

    # ---- Directory accounts nobody in HRIS claims ----
    foreach ($id in ($dirById.Keys | Sort-Object)) {
        if ($hrisById.ContainsKey($id)) { continue }
        $u = $dirById[$id][0]
        if (-not (Test-Enabled $u)) { continue }
        $plan.Add((New-PlanItem 'Review' $id (Get-Prop $u 'SamAccountName') "$(Get-Prop $u 'GivenName') $(Get-Prop $u 'Surname')".Trim() 'Orphaned account: EmployeeID not found in HRIS. Confirm owner, then offboard or correct.'))
    }
    foreach ($id in ($adminsById.Keys | Sort-Object)) {
        if ($hrisById.ContainsKey($id) -or $hrisDupes.ContainsKey($id)) { continue }
        foreach ($a in $adminsById[$id]) {
            $plan.Add((New-PlanItem 'Review' $id (Get-Prop $a 'SamAccountName') '' 'Admin account owner (EmployeeID) not found in HRIS. Confirm owner or disable.'))
        }
    }
    foreach ($a in $ownerlessAdmins) {
        $plan.Add((New-PlanItem 'Review' '' (Get-Prop $a 'SamAccountName') '' 'Admin account has no owner EmployeeID. Every admin account must belong to a person.'))
    }
    foreach ($u in $unanchored) {
        $sam = Get-Prop $u 'SamAccountName'
        if (-not (Test-Enabled $u) -or $flaggedSams.ContainsKey($sam)) { continue }
        $plan.Add((New-PlanItem 'Review' '' $sam "$(Get-Prop $u 'GivenName') $(Get-Prop $u 'Surname')".Trim() 'Enabled account has no EmployeeID. Link to an HRIS record, convert to a service account, or disable.'))
    }

    return $plan.ToArray()
}

function ConvertTo-HrisEmailFeed {
    <#
    .SYNOPSIS
        Builds the EmployeeID -> email feed that HRIS imports, so HRIS reads email
        addresses from the directory instead of people typing them in.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$DirectoryUsers,
        [string[]]$ExcludeAccountPatterns = @()
    )
    # Admin and service accounts must never become someone's email of record.
    $eligible = @($DirectoryUsers | Where-Object {
            (Get-Prop $_ 'EmployeeID') -and (Test-Enabled $_) -and (Get-Prop $_ 'UserPrincipalName') -and
            -not (Test-ExcludedAccount -SamAccountName (Get-Prop $_ 'SamAccountName') -Patterns $ExcludeAccountPatterns)
        })
    foreach ($group in ($eligible | Group-Object { Get-Prop $_ 'EmployeeID' } | Sort-Object Name)) {
        if ($group.Count -gt 1) {
            Write-Warning "EmployeeID $($group.Name) is on $($group.Count) eligible accounts; left out of the email feed."
            continue
        }
        [pscustomobject][ordered]@{
            EmployeeID = $group.Name
            Email      = Get-Prop $group.Group[0] 'UserPrincipalName'
        }
    }
}

#endregion

#region Directory read

function Get-DirectorySnapshot {
    <#
    .SYNOPSIS
        Reads user accounts from Active Directory into the shape New-IdentityPlan expects.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SearchBase)

    Assert-ActiveDirectoryModule
    $props = 'EmployeeID', 'GivenName', 'Surname', 'Department', 'Title', 'Office', 'Manager',
             'Description', 'Enabled', 'MemberOf', 'UserPrincipalName'
    $users = @(Get-ADUser -Filter * -SearchBase $SearchBase -Properties $props -ErrorAction Stop)

    $idByDn = @{}
    foreach ($u in $users) { if ($u.EmployeeID) { $idByDn[$u.DistinguishedName] = [string]$u.EmployeeID } }
    $groupNameByDn = @{}   # one lookup per group, not per membership

    foreach ($u in $users) {
        [pscustomobject][ordered]@{
            SamAccountName    = $u.SamAccountName
            UserPrincipalName = $u.UserPrincipalName
            EmployeeID        = [string]$u.EmployeeID
            GivenName         = $u.GivenName
            Surname           = $u.Surname
            Department        = $u.Department
            Title             = $u.Title
            Office            = $u.Office
            ManagerEmployeeID = if ($u.Manager -and $idByDn.ContainsKey($u.Manager)) { $idByDn[$u.Manager] } else { '' }
            Description       = $u.Description
            Enabled           = (Test-Enabled $u)
            DistinguishedName = $u.DistinguishedName
            Groups            = @(foreach ($dn in $u.MemberOf) {
                    if (-not $groupNameByDn.ContainsKey($dn)) { $groupNameByDn[$dn] = (Get-ADGroup -Identity $dn -ErrorAction Stop).Name }
                    $groupNameByDn[$dn]
                })
        }
    }
}

#endregion

#region Apply

function Invoke-JoinerAction {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)]$Settings, [string]$AuditLogPath)
    $d = $Item.Details
    if (-not $PSCmdlet.ShouldProcess("$($d.UserPrincipalName) in $($d.Path)", 'Create account')) { return }

    $params = @{
        Name              = $Item.DisplayName
        SamAccountName    = $Item.SamAccountName
        UserPrincipalName = $d.UserPrincipalName
        EmailAddress      = $d.UserPrincipalName
        GivenName         = $d.GivenName
        Surname           = $d.Surname
        DisplayName       = $Item.DisplayName
        EmployeeID        = $Item.EmployeeID
        Department        = $d.Department
        Title             = $d.Title
        Office            = $d.Office
        Path              = $d.Path
        AccountPassword   = New-RandomPassword
        Enabled           = [bool]$d.Enable
        ErrorAction       = 'Stop'
    }
    if (-not $d.Enable) { $params['Description'] = "Pre-hire: enable on $($d.StartDate)" }
    foreach ($key in @($params.Keys)) {
        if ($params[$key] -is [string] -and -not $params[$key]) { $params.Remove($key) }   # AD rejects empty strings
    }
    New-ADUser @params

    $managerDn = Resolve-ManagerDn $d.ManagerEmployeeID
    if ($managerDn) { Set-ADUser -Identity $Item.SamAccountName -Manager $managerDn -ErrorAction Stop }
    foreach ($group in $Item.GroupsToAdd) { Add-ADGroupMember -Identity $group -Members $Item.SamAccountName -ErrorAction Stop }

    Write-AuditEvent -Path $AuditLogPath -Action 'Joiner' -EmployeeID $Item.EmployeeID -SamAccountName $Item.SamAccountName -Result 'Success' -Data ([ordered]@{ Path = $d.Path; Enabled = [bool]$d.Enable; GroupsAdded = @($Item.GroupsToAdd) })
}

function Invoke-ActivateAction {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)]$Settings, [string]$AuditLogPath)
    if (-not $PSCmdlet.ShouldProcess($Item.SamAccountName, 'Enable pre-hire account')) { return }
    Enable-ADAccount -Identity $Item.SamAccountName -ErrorAction Stop
    Set-ADUser -Identity $Item.SamAccountName -Clear Description -ErrorAction Stop
    Write-AuditEvent -Path $AuditLogPath -Action 'Activate' -EmployeeID $Item.EmployeeID -SamAccountName $Item.SamAccountName -Result 'Success'
}

function Invoke-MoverAction {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)]$Settings, [string]$AuditLogPath)
    if (-not $PSCmdlet.ShouldProcess($Item.SamAccountName, "$($Item.Action): $($Item.Reason)")) { return }

    $set = @{}
    foreach ($attr in @($Item.AttributeChanges.Keys)) {
        if ($attr -eq 'ManagerEmployeeID') { continue }
        $value = $Item.AttributeChanges[$attr].To
        $set[$attr] = if ($value) { $value } else { $null }   # $null clears the attribute
    }
    if ($set.Count -gt 0) { Set-ADUser -Identity $Item.SamAccountName @set -ErrorAction Stop }

    if ($Item.AttributeChanges.Contains('ManagerEmployeeID')) {
        $managerDn = Resolve-ManagerDn $Item.AttributeChanges['ManagerEmployeeID'].To
        if ($managerDn) { Set-ADUser -Identity $Item.SamAccountName -Manager $managerDn -ErrorAction Stop }
        else { Set-ADUser -Identity $Item.SamAccountName -Clear manager -ErrorAction Stop }
    }
    foreach ($group in $Item.GroupsToAdd) { Add-ADGroupMember -Identity $group -Members $Item.SamAccountName -ErrorAction Stop }
    foreach ($group in $Item.GroupsToRemove) { Remove-ADGroupMember -Identity $group -Members $Item.SamAccountName -Confirm:$false -ErrorAction Stop }

    Write-AuditEvent -Path $AuditLogPath -Action $Item.Action -EmployeeID $Item.EmployeeID -SamAccountName $Item.SamAccountName -Result 'Success' -Data ([ordered]@{ AttributeChanges = $Item.AttributeChanges; GroupsAdded = @($Item.GroupsToAdd); GroupsRemoved = @($Item.GroupsToRemove) })
}

function Invoke-LeaverAction {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)]$Item, [Parameter(Mandatory)]$Settings, [string]$AuditLogPath)
    $sam = $Item.SamAccountName
    if (-not $PSCmdlet.ShouldProcess($sam, 'Offboard: disable, revoke sessions, remove access')) { return }

    # Record access before removing it, so it can be restored or reviewed later.
    $user = Get-ADUser -Identity $sam -Properties PrimaryGroup -ErrorAction Stop
    $groups = @(Get-ADPrincipalGroupMembership -Identity $sam -ErrorAction Stop |
        Where-Object { $_.DistinguishedName -ne $user.PrimaryGroup })
    $removedGroups = @($groups | ForEach-Object { $_.Name })

    Disable-ADAccount -Identity $sam -ErrorAction Stop
    Set-ADAccountPassword -Identity $sam -Reset -NewPassword (New-RandomPassword) -ErrorAction Stop
    $today = (Get-Date).ToString('yyyy-MM-dd')
    Set-ADUser -Identity $sam -Description "Disabled $today by identity lifecycle automation (EmployeeID $($Item.EmployeeID)). Delete after $($Item.Details.DeleteAfter)." -ErrorAction Stop
    if ($groups.Count -gt 0) { Remove-ADPrincipalGroupMembership -Identity $sam -MemberOf $groups -Confirm:$false -ErrorAction Stop }

    if ($Settings.Leaver.HideFromGal) {
        try { Set-ADUser -Identity $sam -Replace @{ msExchHideFromAddressLists = $true } -ErrorAction Stop }
        catch { Write-Warning "Could not hide $sam from the GAL (Exchange schema attribute missing?): $_" }
    }

    $sessionsRevoked = $false
    if ($Settings.Leaver.RevokeEntraSessions) {
        if (Get-Command Revoke-MgUserSignInSession -ErrorAction SilentlyContinue) {
            Revoke-MgUserSignInSession -UserId $Item.Details.UserPrincipalName -ErrorAction Stop | Out-Null
            $sessionsRevoked = $true
        }
        else { Write-Warning "Microsoft Graph not loaded; revoke Entra sessions for $($Item.Details.UserPrincipalName) manually." }
    }

    Move-ADObject -Identity $user.DistinguishedName -TargetPath $Item.Details.DisabledOU -ErrorAction Stop

    Write-AuditEvent -Path $AuditLogPath -Action 'Leaver' -EmployeeID $Item.EmployeeID -SamAccountName $sam -Result 'Success' -Data ([ordered]@{ GroupsRemoved = $removedGroups; SessionsRevoked = $sessionsRevoked; MovedTo = $Item.Details.DisabledOU; DeleteAfter = $Item.Details.DeleteAfter })
}

function Invoke-IdentityPlan {
    <#
    .SYNOPSIS
        Applies Joiner, Activate, Mover, Update and Leaver items from a plan.
        NoChange and Review items are skipped. Supports -WhatIf.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plan,
        [Parameter(Mandatory)]$Settings,
        [string]$AuditLogPath
    )
    Assert-ActiveDirectoryModule
    $results = [ordered]@{ Applied = 0; Failed = 0; Skipped = 0 }
    foreach ($item in $Plan) {
        $handler = switch ($item.Action) {
            'Joiner'   { 'Invoke-JoinerAction' }
            'Activate' { 'Invoke-ActivateAction' }
            'Mover'    { 'Invoke-MoverAction' }
            'Update'   { 'Invoke-MoverAction' }
            'Leaver'   { 'Invoke-LeaverAction' }
            default    { $null }
        }
        if (-not $handler) { $results.Skipped++; continue }
        try {
            & $handler -Item $item -Settings $Settings -AuditLogPath $AuditLogPath
            $results.Applied++
        }
        catch {
            $results.Failed++
            Write-AuditEvent -Path $AuditLogPath -Action $item.Action -EmployeeID $item.EmployeeID -SamAccountName $item.SamAccountName -Result 'Failed' -Data ([ordered]@{ Error = "$_" })
            Write-Error "$($item.Action) failed for $($item.SamAccountName) ($($item.EmployeeID)): $_"
        }
    }
    [pscustomobject]$results
}

#endregion

Export-ModuleMember -Function @(
    'ConvertTo-AsciiName', 'New-AccountName', 'Test-RoleMap', 'Get-TargetRoleGroup',
    'New-IdentityPlan', 'ConvertTo-HrisEmailFeed', 'Get-DirectorySnapshot', 'Invoke-IdentityPlan'
)
