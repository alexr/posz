$script:zscore = @();

# Enable to specify custom zscores.csv file location and name.
# Set $zscoreFile variable before sourcing this script to use custom file.
if (-not (Test-Path variable:\zscoreFile)) {
    $zscoreFile = "$(Split-Path -Parent $MyInvocation.MyCommand.Path)\zscores.csv"
}

if (Test-Path $zscoreFile) {
    $script:zscore = @(Import-Csv $zscoreFile |
        Select-Object -Property @(
            @{Name='path';Expression={[string]($_.path)}},
            @{Name='frequency';Expression={[int]($_.frequency)}},
            @{Name='recent';Expression={[int]($_.recent)}}))
}

function Get-MatchingJumpLocations {
    param( [string]$jumpSpec = '.*',
           [ValidateSet('Recent', 'Frequent', 'Frecent')] $orderBy = 'Frecent' )

    function IsValidRegex( [string]$rx ) {
        try {
            # Note: have to cast to string otherwise comparison is over truthy/falthy
            $testValidRegex = [string]('' -match $rx)
        } catch [Exception] {
            $testValidRegex = 'oops'
        }
        return $testValidRegex -ne 'oops'
    }

    function MatchIfValid( [string]$path) {
        $result = @()
        if (IsValidRegex($path)) {
            $result = @($script:zscore | Where-Object { $_.path -Match $path })
        }
        return $result
    }

    # First try to match the $jumpSpec quite literally for the case of exact path.
    # This is primarily for the case when using tab expansion.
    # With tab expansion $jumpSpec would be exact path with a single match,
    # which is the desired jump location.
    $result = @($script:zscore | Where-Object { $_.path -eq $jumpSpec })
    if ($result -and $result.Length -eq 1) {
        return $result # THE match found - we're done
    }

    # Try interpreting $jumpSpec as regex if valid regex.
    $result = @(MatchIfValid $jumpSpec)

    # Try to interpret $jumpSpec as path if valid.
    $jumpSpec = $jumpSpec -Replace "\\","\\"
    $result = @($result) + @(MatchIfValid $jumpSpec)

    # SideNote: in posh it is required to wrap expression in @(...)
    # to ensure result type is an array. Otherwise result would be either
    # empty or single element or an array of the results. i.e.
    # @(1,2,3) | where {$_ -gt 5} yields empty result;
    # @(1,2,3) | where {$_ -eq 2} yields [int]2; and
    # @(1,2,3) | where {$_ -lt 3} yields @(1,2).
    # if wrapped in @(...) they will yield correspondingly @(), @(2), and @(1,2)
    #
    # WOW: @(1,2,3) === @(@(1,2,3)) === @(@(@(1,2,3)))...

    # Compose order by expression.
    $expression = '$($_.frequency * $_.recent)'
    if ($orderBy -eq 'Recent') {
        $expression = '$($_.recent)'
    } elseif ($orderBy -eq 'Frequent') {
        $expression = '$($_.frequency)'
    }

    return $result |
        Group-Object -Property { $_.path } |
        ForEach-Object { $_.Group[0] } |
        Sort-Object -Property { Invoke-Expression $expression } -Desc
}

function Update-JumpLocations {
    param( $path )
    if (-not $path) { return }

    # If path needs escaping, skip it, we do not track such paths
    # due to various issues in matching them correctly.
    if ($path.ToString().Contains('`')) { return }

    # If path is not valid don't try to save it.
    $fullPath = Resolve-Path -Path $path -ErrorAction SilentlyContinue
    if ($fullPath) { $fullPath = $fullPath.Path }
    else { return }

    # Exclude current location.
    if ($fullPath -eq $PWD.Path) { return }

    # Update zscore state.
    $existingPath = $script:zscore | Where-Object { $_.path -eq $fullPath }
    if ($existingPath) {
        $existingPath.frequency += 1
        $existingPath.recent += 10
    } else {
        $newPath = New-Object psobject
        $newPath | Add-Member -Name path -Type NoteProperty -Value $fullPath
        $newPath | Add-Member -Name frequency -Type NoteProperty -Value 1
        $newPath | Add-Member -Name recent -Type NoteProperty -Value 10
        $script:zscore += $newPath
    }
    
    # Trim down state when sum of recent is more than 1000 ==>
    #     reduce recent by 10% and
    #     remove those whose recent dropped below 1
    $recentSum = ($script:zscore | Measure-Object -Property recent -Sum).Sum
    if ($recentSum -ge 1000) {
        $script:zscore | ForEach-Object { $_.recent = [int]($_.recent * .9 - .5) }
        $script:zscore = $script:zscore | Where-Object { $_.recent -ge 1 }
    }

    # Persist state.
    $script:zscore | Export-Csv $zscoreFile -NoTypeInformation
}

function Jump-Location {
    param( [string]$path,
           [switch] $l,
           [switch] $r,
           [switch] $t )

    if ($l) {
        if ($r) {
            return Get-MatchingJumpLocations $path -orderBy Frequent
        } elseif ($t) {
            return Get-MatchingJumpLocations $path -orderBy Recent
        } else {
            return Get-MatchingJumpLocations $path
        }
    }

    if ($path -eq '..' -or $path -eq '/') {
        # For special values of path.
        $locations = @((Resolve-Path $path).Path)
    } elseif ($r) {
        $locations = Get-MatchingJumpLocations $path -orderBy Frequent
    } elseif ($t) {
        $locations = Get-MatchingJumpLocations $path -orderBy Recent
    } else {
        $locations = Get-MatchingJumpLocations $path
    }
    $pathFound = $locations | Select-Object -First 1
    
    if ($pathFound) { cd $pathFound.path }
    else { "No matching path found." }
}

# Support for tab expansion.
# Adopted from Christoph Karner's code (https://github.com/chKarner/posz/tree/tabexpansion),
# who took the idea from posh-git (https://github.com/dahlbyk/posh-git).
if (Test-Path Function:\TabExpansion) {
    Rename-Item Function:\TabExpansion TabExpansionPreJumpLocation
}

if (-not (Test-Path Function:\Get-AliasPattern)) {
    function Get-AliasPattern( $exe ) {
        $aliases = @($exe) + @(Get-Alias | where { $_.Definition -eq $exe } | select -Exp Name)
        "($($aliases -join '|'))"
    }
}

function TabExpansion($line, $lastWord) {
    function zTabExpansion($lastBlock) {
        # Remove command-alias from block
        $toExpand = $lastBlock -replace "^$(Get-AliasPattern 'Jump-Location') ",""

        $pathFound = Get-MatchingJumpLocations $toExpand

        if($pathFound){
            return $pathFound.path
        }
    }
    
    $lastBlock = [regex]::Split($line, '[|;]')[-1].TrimStart()
    switch -regex ($lastBlock) {
        # Execute z tab completion for all z aliases
        "^$(Get-AliasPattern z) (.*)" { zTabExpansion $lastBlock }

        # Fall back on existing tab expansion
        default { if (Test-Path Function:\TabExpansionPreZ) { TabExpansionPreJumpLocation $line $lastWord } }
    }
}


# Example usage
function cd2 {
    param( $path='' )
    Update-JumpLocations $path
    Set-Location $path
}
function pd2 {
    param( $path='' )
    Update-JumpLocations $path
    Push-Location $path
}

Set-Alias -Name cd -Value cd2 -Option AllScope
Set-Alias -Name pd -Value pd2 -Option AllScope
Set-Alias -Name z  -Value Jump-Location -Option AllScope
