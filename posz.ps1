$script:zscore = @();
$zscoreFile = "$(Split-Path -Parent $MyInvocation.MyCommand.Path)\zscores.csv"

if (Test-Path $zscoreFile) {
    $script:zscore = @(Import-Csv $zscoreFile |
        Select-Object -Property @(
            @{Name='path';Expression={[string]($_.path)}},
            @{Name='frequency';Expression={[int]($_.frequency)}},
            @{Name='recent';Expression={[int]($_.recent)}}))
}

function Get-MatchingJumpLocations {
    param( [string]$path = '.*',
           [ValidateSet('Recent', 'Frequent', 'Frecent')] $orderBy = 'Frecent' )

    # Check if $path is a valid regex.
    try {
        # Note: have to cast to string otherwise comparison is over truthy/falthy
        $testValidRegex = [string]('' -match $path)
    } catch [Exception] {
        $testValidRegex = 'oops'
    }
    if ($testValidRegex -eq 'oops') {
        return @()
    }

    # Compose order by expression.
    $expression = '$($_.frequency * $_.recent)'
    if ($orderBy -eq 'Recent') {
        $expression = '$($_.recent)'
    } elseif ($orderBy -eq 'Frequent') {
        $expression = '$($_.frequency)'
    }

    return $script:zscore |
        Where-Object { $_ -Match $path } |
        Sort-Object -Property { Invoke-Expression $expression } -Desc
}

function Update-JumpLocations {
    param( $path )
    if (-not $path) { return }

    # If path needs escaping, skip it, we do not track such paths
    # due to various issues in matching them correctly.
    if ($path.Contains('`')) { return }

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

function z {
    param( [string]$path,
           [switch] $l,
           [switch] $r,
           [switch] $t)

    if ($l) {
        if ($r) {
            return Get-MatchingJumpLocations $path -orderBy Frequent
        } elseif ($t) {
            return Get-MatchingJumpLocations $path -orderBy Recent
        } else {
            return Get-MatchingJumpLocations $path
        }
    }

    # Special values of path.
    if ($path -eq '..') {
        cd2 '..'
    } elseif ($path -eq '\') {
        cd2 '\'
    }

    if ($r) {
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