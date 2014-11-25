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
    param( [string]$matchRegex = '.*',
           [ValidateSet('Recent', 'Frequent', 'Frecent')] $orderBy = 'Frecent' )

    $result = @($script:zscore | Where-Object { $_.path -Match $matchRegex })

    # SideNote: in posh it is required to wrap expression in @(...)
    # to ensure result type is an array. Otherwise result would be either
    # empty or single element or an array of the results. i.e.
    # @(1,2,3) | where {$_ -gt 5} yields empty result;
    # @(1,2,3) | where {$_ -eq 2} yields [int]2; and
    # @(1,2,3) | where {$_ -lt 3} yields @(1,2).
    # if wrapped in @(...) they will yield correspondingly @(), @(2), and @(1,2)
    #
    # WOW: @(1,2,3) === @(@(1,2,3)) === @(@(@(1,2,3)))...

    # Compose order-by expression.
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

function Get-MatchRegex-From-JumpSpec {
    param( [string[]]$jumpSpecs )

    function IsValidRegex( [string]$rx ) {
        try {
            # Note: have to cast to string otherwise comparison is over truthy/falthy
            $testValidRegex = [string]('' -match $rx)
        } catch [Exception] {
            $testValidRegex = 'oops'
        }
        return $testValidRegex -ne 'oops'
    }

    # By default, for empty specs, match anything.
    if (-not $jumpSpecs) {
        return '.*'
    }

    # First try to match single special path values.
    if (($jumpSpecs.Length -eq 1) -and ($jumpSpecs[0] -eq '..' -or $jumpSpecs[0] -eq '/' -or $jumpSpecs[0] -eq '.')) {
        $regex = ((Resolve-Path $jumpSpecs[0]).Path) -Replace "\\","\\"
        return "^" + $regex + "$"
    }

    # Then try to interpret as single path specification.
    if ($jumpSpecs.Length -eq 1) {
        $path = Resolve-Path $jumpSpecs[0] -ErrorAction SilentlyContinue
        if ($path) {
            $regex = ($path[0]).Path -Replace "\\","\\"
            return "^" + $regex + "$"
        }
    }

    # Then try to match any of the $jumpSpecs quite literally for the case of exact path.
    # This is primarily for the case when using tab expansion.
    # With tab expansion one of the $jumpSpecs would be exact path with a single match,
    # which is the desired jump location.
    # This may be quite strange semantics, but this is due to the way tab expansion works.
    foreach ($jumpSpec in $jumpSpecs) {
        $result = @($script:zscore | Where-Object { $_.path -eq $jumpSpec })
        if ($result -and $result.Length -eq 1) {
            # THE match found - we're done
            $regex = ($result[0]).path -Replace "\\","\\"
            return "^" + $regex + "$"
        }
    }

    # Otherwice interpret as regexes and build up combined regex from jumpSpecs.
    $jumpRegex = $null
    foreach ($jumpSpec in $jumpSpecs) {
        if (-not (IsValidRegex($jumpSpec))) {
            # If $jumpSpec is not valid regex, try interpreting as path.
            $jumpSpec = $jumpSpec -Replace "\\","\\"
            if (-not (IsValidRegex($jumpSpec))) {
                # If still not valid then abort and make resulting regex valid, but matching nothing.
                return "^$"
            }
        }
        # Attach current spec to the regex.
        $jumpRegex = if ($jumpRegex -eq $null) { $jumpSpec } else { $jumpRegex + ".*" + $jumpSpec }
    }
    return $jumpRegex
}

function Jump-Location {
    param( [string] $part1, # This is  very  weird
           [string] $part2, # way to take multiple
           [string] $part3, # parameters, but  can
           [string] $part4, # not find and  better
           [string] $part5, # way to do it  :(  :(
           [switch] $l,
           [switch] $r,
           [switch] $t,
           [switch] $x)

    function Write-Host-Inverse ( [string]$str, [switch]$NoNewline ) {
        if ($NoNewline) {
            Write-Host $str -ForegroundColor ([Console]::BackgroundColor) `
                            -BackgroundColor ([Console]::ForegroundColor) -NoNewline
        } else {
            Write-Host $str -ForegroundColor ([Console]::BackgroundColor) `
                            -BackgroundColor ([Console]::ForegroundColor)
        }
    }

    # And now assemble all provided parts
    $paths = @()
    if ($part1) { $paths += $part1 }
    if ($part2) { $paths += $part2 }
    if ($part3) { $paths += $part3 }
    if ($part4) { $paths += $part4 }
    if ($part5) { $paths += $part5 }

    $matchRegex = Get-MatchRegex-From-JumpSpec $paths

    # -l and -x are logically exclusive, so if both specified
    # making -l take precedence to opt on the safe side.
    if ($l) {
        if ($r) {
            $recs = Get-MatchingJumpLocations $matchRegex -orderBy Frequent
        } elseif ($t) {
            $recs = Get-MatchingJumpLocations $matchRegex -orderBy Recent
        } else {
            $recs = Get-MatchingJumpLocations $matchRegex
        }

	# When showing fill list highlight nothing.
        if ($matchRegex -eq ".*") { $matchRegex = "^$" }
        $totalF = 0
        $totalR = 0
        Write-Host "Recent Frequency Path"
        Write-Host "------ --------- ----"
        foreach ($rec in $recs) {
            $totalR = $totalR + $rec.recent
            $totalF = $totalF + $rec.frequency
            Write-Host ("{0,6} {1,9} " -f $rec.recent,$rec.frequency) -NoNewline
            $match = $rec.path | Select-String -Pattern $matchRegex | Select-Object -ExpandProperty Matches
            $start = $match.Index
            $len = $match.Length

            Write-Host $rec.path.SubString(0, $start) -NoNewline
            Write-Host-Inverse $rec.path.SubString($start, $len) -NoNewline
            Write-Host $rec.path.Substring($start + $len)
        }
        Write-Host "------ --------- ----"
        Write-Host ("{0,6} {1,9} " -f $totalR,$totalF)
        return
    }

    if ($x) {
        # Filter just those whose path doesn't start with the value of $pwd
        $script:zscore = $script:zscore |
            Where-Object { -not $_.path.ToUpper().StartsWith($pwd.Path.ToUpper()) }

        # Persist state.
        $script:zscore | Export-Csv $zscoreFile -NoTypeInformation

        "All paths under $pwd have been forgotten."
        return
    }

    if ($r) {
        $locations = Get-MatchingJumpLocations $matchRegex -orderBy Frequent
    } elseif ($t) {
        $locations = Get-MatchingJumpLocations $matchRegex -orderBy Recent
    } else {
        $locations = Get-MatchingJumpLocations $matchRegex
    }
    $pathFound = $locations | Select-Object -First 1
    
    if ($pathFound) {
        Update-JumpLocations $pathFound.path
        Set-Location $pathFound.path
    } else {
        "No matching path found."
    }
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
    function zInterpretBlock {
        param( [string] $part1, # This is  very  weird
               [string] $part2, # way to take multiple
               [string] $part3, # parameters, but  can
               [string] $part4, # not find and  better
               [string] $part5) # way to do it  :(  :(

        $paths = @()
        if ($part1) { $paths += $part1 }
        if ($part2) { $paths += $part2 }
        if ($part3) { $paths += $part3 }
        if ($part4) { $paths += $part4 }
        if ($part5) { $paths += $part5 }
        return @($paths)
    }

    function zTabExpansion($lastBlock) {
        # Remove command-alias from block
        $expr = $lastBlock -replace "^$(Get-AliasPattern 'Jump-Location') ",""
        # Use zInterpretBlock to substitute expansion parameters in consistent way.
        $expr = "zInterpretBlock " + $expr
        $paths = Invoke-Expression $expr

        # Same computation to get the jump path.
        $matchRegex = Get-MatchRegex-From-JumpSpec $paths
        $pathFound = Get-MatchingJumpLocations $matchRegex

        if ($pathFound) {
            return $pathFound.path
        }
    }

    $lastBlock = [regex]::Split($line, '[|;]')[-1].TrimStart()

    switch -regex ($lastBlock) {
        # Execute z tab completion for all z aliases
        "^$(Get-AliasPattern 'Jump-Location') (.*)" { zTabExpansion $lastBlock }

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
