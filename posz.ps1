$script:zscore = @();
$zscoreFile = "$(Split-Path -Parent $MyInvocation.MyCommand.Path)\zscores.csv"

if (Test-Path $zscoreFile) {
    $script:zscore = @(Import-Csv $zscoreFile |
        Select-Object -Property @(
            @{Name='path';Expression={[string]($_.path)}},
            @{Name='frequency';Expression={[int]($_.frequency)}},
            @{Name='recent';Expression={[int]($_.recent)}}))
}

function cd2 {
    param( $path )
    if (-not $path) { return }

    # If $path needs excaping, skip it, since there are various issues matching such paths.
    if($path.Contains('`')) {
        Set-Location $path
        return
    }

    $fullPath = Resolve-Path $path
    
    $existingPath = $script:zscore | Where-Object { $_.path -eq $fullPath.Path }
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
    
    $recentSum = ($script:zscore | Measure-Object -Property recent -Sum).Sum

    if ($recentSum -ge 1000) {
        $script:zscore | ForEach-Object { $_.recent = [int]($_.recent * .9 - .5) }
        $script:zscore = $script:zscore | Where-Object { $_.recent -ge 1 }
    }

    $script:zscore | Export-Csv $zscoreFile -NoTypeInformation
    
    Set-Location $path
}

Set-Alias -Name cd -Value cd2 -Option AllScope

function z ( $path, [switch] $list, [switch] $ranked, [switch] $times){
    if ($list) {
        if (-not $path) {
            return $script:zscore
        }
    }

    # Check $path for common non-regex values
    if (@('.', '..', '\') -contains $path) {
        return "use cd to jump to '.', '..', or '\'."
    }

    # Check if $path is a valid regex
    try {
        $testValidRegex = '' -match $path
    } catch [Exception] {
        $testValidRegex = 'oops'
    }
    if ($testValidRegex -eq 'oops') {
        return "Invalid path regex."
    }

    $expression = '$($_.frequency * $_.recent)'
    if ($ranked) {
        $expression = '$($_.recent)'
    } elseif ($times) {
        $expression = '$($_.frequency)'
    }


    $pathFound = $script:zscore |
        Where-Object { $_ -Match $path } |
        Sort-Object -Property { Invoke-Expression $expression } -Desc |
        Select-Object -First 1
    
    if ($pathFound) { cd $pathFound.path }
    else { "No path matching." }
}