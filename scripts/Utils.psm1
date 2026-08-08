#Requires -Version 5.1
Set-StrictMode -Version 3.0

# A temp fix for https://github.com/ScoopInstaller/Scoop/pull/5066#issuecomment-1372087032
function Invoke-ExternalCommand2 {
    [CmdletBinding(DefaultParameterSetName = 'Default')]
    [OutputType([Boolean])]
    param (
        [Parameter(Mandatory = $true,
            Position = 0)]
        [Alias('Path')]
        [ValidateNotNullOrEmpty()]
        [String]
        $FilePath,
        [Parameter(Position = 1)]
        [Alias('Args')]
        [String[]]
        $ArgumentList,
        [Parameter(ParameterSetName = 'UseShellExecute')]
        [Switch]
        $RunAs,
        [Parameter(ParameterSetName = 'UseShellExecute')]
        [Switch]
        $Quiet,
        [Alias('Msg')]
        [String]
        $Activity,
        [Alias('cec')]
        [Hashtable]
        $ContinueExitCodes,
        [Parameter(ParameterSetName = 'Default')]
        [Alias('Log')]
        [String]
        $LogPath
    )
    if ($Activity) {
        Write-Host "$Activity " -NoNewline
    }
    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo.FileName = $FilePath
    $Process.StartInfo.UseShellExecute = $false
    $redirectToLogFile = $false
    if ($LogPath) {
        if ($FilePath -match '^msiexec(.exe)?$') {
            $ArgumentList += "/lwe `"$LogPath`""
        } else {
            $redirectToLogFile = $true
            $Process.StartInfo.RedirectStandardOutput = $true
            $Process.StartInfo.RedirectStandardError = $true
        }
    }
    if ($RunAs) {
        $Process.StartInfo.UseShellExecute = $true
        $Process.StartInfo.Verb = 'RunAs'
    }
    if ($Quiet) {
        $Process.StartInfo.UseShellExecute = $true
        $Process.StartInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    }
    if ($ArgumentList.Length -gt 0) {
        if ($FilePath -match '^((cmd|cscript|wscript|msiexec)(\.exe)?|.*\.(bat|cmd|js|vbs|wsf))$') {
            $Process.StartInfo.Arguments = $ArgumentList -join ' '
        } elseif ($Process.StartInfo.PSObject.Properties.Name -contains 'ArgumentList') {
            # ArgumentList is supported in PowerShell 6.1 and later (built on .NET Core 2.1+)
            # ref-1: https://docs.microsoft.com/en-us/dotnet/api/system.diagnostics.processstartinfo.argumentlist?view=net-6.0
            # ref-2: https://docs.microsoft.com/en-us/powershell/scripting/whats-new/differences-from-windows-powershell?view=powershell-7.2#net-framework-vs-net-core
            $ArgumentList | ForEach-Object { $Process.StartInfo.ArgumentList.Add($_) }
        } else {
            # escape arguments manually in lower versions, refer to https://docs.microsoft.com/en-us/previous-versions/17w5ykft(v=vs.85)
            $escapedArgs = $ArgumentList | ForEach-Object {
                # escape N consecutive backslash(es), which are followed by a double quote, to 2N consecutive ones
                $s = $_ -replace '(\\+)"', '$1$1"'
                # escape N consecutive backslash(es), which are at the end of the string, to 2N consecutive ones
                $s = $s -replace '(\\+)$', '$1$1'
                # escape double quotes
                $s = $s -replace '"', '\"'
                # https://github.com/ScoopInstaller/Scoop/issues/5231#issuecomment-1295840608
                $s
            }
            $Process.StartInfo.Arguments = $escapedArgs -join ' '
            Write-Host $Process.StartInfo.Arguments
        }
    }
    try {
        [void]$Process.Start()
    } catch {
        if ($Activity) {
            Write-Host 'error.' -ForegroundColor DarkRed
        }
        Write-Host $_.Exception.Message -ForegroundColor DarkRed
        return $false
    }
    if ($redirectToLogFile) {
        # we do this to remove a deadlock potential
        # ref: https://docs.microsoft.com/en-us/dotnet/api/system.diagnostics.process.standardoutput?view=netframework-4.5#remarks
        $stdoutTask = $Process.StandardOutput.ReadToEndAsync()
        $stderrTask = $Process.StandardError.ReadToEndAsync()
    }
    $Process.WaitForExit()
    if ($redirectToLogFile) {
        Out-UTF8File -FilePath $LogPath -Append -InputObject $stdoutTask.Result
        Out-UTF8File -FilePath $LogPath -Append -InputObject $stderrTask.Result
    }
    if ($Process.ExitCode -ne 0) {
        if ($ContinueExitCodes -and ($ContinueExitCodes.ContainsKey($Process.ExitCode))) {
            if ($Activity) {
                Write-Host 'done.' -ForegroundColor DarkYellow
            }
            Write-Host $ContinueExitCodes[$Process.ExitCode] -ForegroundColor DarkYellow
            return $true
        } else {
            if ($Activity) {
                Write-Host 'error.' -ForegroundColor DarkRed
            }
            Write-Host "Exit code was $($Process.ExitCode)!" -ForegroundColor DarkRed
            return $false
        }
    }
    if ($Activity) {
        Write-Host 'done.' -ForegroundColor Green
    }
    return $true
}

function Out-UTF8File {
    param(
        [Parameter(Mandatory = $True, Position = 0)]
        [Alias('Path')]
        [String] $FilePath,
        [Switch] $Append,
        [Switch] $NoNewLine,
        [Parameter(ValueFromPipeline = $True)]
        [PSObject] $InputObject
    )
    process {
        if ($Append) {
            [System.IO.File]::AppendAllText($FilePath, $InputObject)
        } else {
            if (!$NoNewLine) {
                # Ref: https://stackoverflow.com/questions/5596982
                # Performance Note: `WriteAllLines` throttles memory usage while
                # `WriteAllText` needs to keep the complete string in memory.
                [System.IO.File]::WriteAllLines($FilePath, $InputObject)
            } else {
                # However `WriteAllText` does not add ending newline.
                [System.IO.File]::WriteAllText($FilePath, $InputObject)
            }
        }
    }
}

function Mount-ExternalRuntimeData {
    <#
    .SYNOPSIS
        Mount external runtime data

    .PARAMETER Source
        The source path, which is the persist_dir

    .PARAMETER Target
        The target path, which is the actual path app uses to access the runtime data
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Source,
        [Parameter(Mandatory = $true, Position = 1)]
        [string] $Target
    )

    if (Test-Path $Source) {
        Remove-Item $Target -Force -Recurse -ErrorAction SilentlyContinue
    } else {
        New-Item -ItemType Directory $Source -Force | Out-Null
        if (Test-Path $Target) {
            Get-ChildItem $Target | Move-Item -Destination $Source -Force
            Remove-Item $Target
        }
    }

    New-Item -ItemType Junction -Path $Target -Target $Source -Force | Out-Null
}

function Dismount-ExternalRuntimeData {
    <#
    .SYNOPSIS
        Unmount external runtime data

    .PARAMETER Target
        The target path, which is the actual path app uses to access the runtime data
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Target
    )

    if (Test-Path $Target) {
        Remove-Item $Target -Force -Recurse
    }
}

function Install-Font {
    <#
    .SYNOPSIS
        Install font files (.ttf/.otf) from a directory into the system.
    .PARAMETER Dir
        Directory containing font files to install.
    .PARAMETER Global
        Install globally (for all users) instead of per-user.
    .PARAMETER Filter
        Regex filter for font file names (default: '\.(otf|ttf)$').
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Dir,
        [switch] $Global,
        [string] $Filter = '\\.(otf|ttf)$'
    )

    if (([Environment]::OSVersion.Version -lt [version]'10.0.17763') -and (-not $Global)) {
        throw "Windows prior to Version 1809 does not allow installation of fonts at the user level. Please install globally."
    }

    Add-Type -AssemblyName PresentationCore, WindowsBase
    $fontDir = if ($Global) { "${env:WINDIR}\Fonts" } else { "${env:LOCALAPPDATA}\Microsoft\Windows\Fonts" }
    $regDrive = if ($Global) { 'HKLM:' } else { 'HKCU:' }
    $regKey = "$regDrive\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"

    $files = Get-ChildItem $Dir -Recurse -File | Where-Object { $_.Name -match $Filter }
    if ($files.Count -eq 0) {
        throw "No font files matching '$Filter' found in '$Dir'."
    }

    # Clean up junk font files (other formats like woff, eot, css, etc.)
    $junk = Get-ChildItem $Dir -Recurse -File | Where-Object {
        ($_.Name -match '\.(ttf|otf|ttc|otc|woff2?|eot|svgz?|s?css)$') -and ($_.Name -notmatch $Filter)
    }
    foreach ($file in $junk) {
        Remove-Item -Force -LiteralPath $file.FullName -ErrorAction SilentlyContinue
    }

    $fonts = [System.Collections.ArrayList]@()
    foreach ($file in $files) {
        if ($file.Name -notmatch '\.(ttf|otf|ttc|otc)$') {
            Write-Error "Unsupported font format: $($file.Name). Only TTF/OTF files are supported."
            continue
        }

        $regValueName = Get-FontRegistryName -FilePath $file.FullName -FallbackName $file.BaseName
        if ($null -eq $regValueName) { continue }

        $fontPath = "$fontDir\$($file.Name)"
        $regValueData = if ($Global) { $file.Name } else { $fontPath }

        # Remove existing font file if present
        if (Test-Path -LiteralPath $fontPath) {
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
            [System.GC]::Collect()
            try {
                Remove-Item -LiteralPath $fontPath -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 100
            } catch {
                Write-Error "Failed to remove existing font file $($file.Name): $($_.Exception.Message)"
                continue
            }
        }

        try {
            Copy-Item -Force -LiteralPath $file.FullName -Destination $fontDir
            $existingKey = Get-ItemProperty -Path $regKey -Name $regValueName -ErrorAction SilentlyContinue
            if ($null -eq $existingKey) {
                New-ItemProperty -Force -Path $regKey -Name $regValueName -Value $regValueData -PropertyType String -ErrorAction Stop | Out-Null
            } else {
                Set-ItemProperty -Force -Path $regKey -Name $regValueName -Value $regValueData -ErrorAction Stop | Out-Null
            }
            [void]$fonts.Add([PSCustomObject]@{ File = $file.Name; Registry = $regValueName; Success = $true })
        } catch {
            Write-Error "Failed to install font $($file.Name): $($_.Exception.Message)"
        }
    }

    if ($fonts.Count -gt 0) {
        $fonts | Select-Object File, Registry, Success | Format-Table -AutoSize
    }
}

function Uninstall-Font {
    <#
    .SYNOPSIS
        Uninstall font files (.ttf/.otf) from a directory out of the system.
    .PARAMETER Dir
        Directory containing the same font files that were installed.
    .PARAMETER Global
        Uninstall from global (all users) instead of per-user.
    .PARAMETER Filter
        Regex filter for font file names (default: '\.(otf|ttf)$').
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Dir,
        [switch] $Global,
        [string] $Filter = '\\.(otf|ttf)$'
    )

    Add-Type -AssemblyName PresentationCore, WindowsBase
    $fontDir = if ($Global) { "${env:WINDIR}\Fonts" } else { "${env:LOCALAPPDATA}\Microsoft\Windows\Fonts" }
    $regDrive = if ($Global) { 'HKLM:' } else { 'HKCU:' }
    $regKey = "$regDrive\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts"

    $files = Get-ChildItem $Dir -Recurse -File | Where-Object { $_.Name -match $Filter }
    if ($files.Count -eq 0) {
        throw "No font files matching '$Filter' found in '$Dir'."
    }

    $fonts = [System.Collections.ArrayList]@()
    foreach ($file in $files) {
        if ($file.Name -notmatch '\.(ttf|otf|ttc|otc)$') {
            Write-Error "Unsupported font format: $($file.Name). Only TTF/OTF files are supported."
            continue
        }

        $regValueName = Get-FontRegistryName -FilePath $file.FullName -FallbackName $file.BaseName
        if ($null -eq $regValueName) { continue }

        $fontPath = "$fontDir\$($file.Name)"

        if (Test-Path -LiteralPath $fontPath) {
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
            [System.GC]::Collect()
            try {
                Remove-Item -LiteralPath $fontPath -Force
                Start-Sleep -Milliseconds 100
            } catch {
                Write-Error "Failed to remove font file $($file.Name): $($_.Exception.Message)"
                continue
            }
        }

        try {
            Remove-ItemProperty -Path $regKey -Name $regValueName -ErrorAction Stop
            [void]$fonts.Add([PSCustomObject]@{ File = $file.Name; Registry = $regValueName; Success = $true })
        } catch {
            Write-Error "Failed to uninstall font $($file.Name): $($_.Exception.Message)"
        }
    }

    if ($fonts.Count -gt 0) {
        $fonts | Select-Object File, Registry, Success | Format-Table -AutoSize
    }
}

function Get-FontRegistryName {
    <#
    .SYNOPSIS
        Read font metadata to build the Windows registry value name.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $FilePath,
        [string] $FallbackName
    )

    $fileUri = [uri]::new($FilePath)
    $glyphTypeface = $null
    $regValueName = $null
    try {
        $glyphTypeface = [System.Windows.Media.GlyphTypeface]::new($fileUri)
        if ($null -ne $glyphTypeface) {
            $culture = [System.Globalization.CultureInfo]::CurrentCulture
            $fontFamilyName = $null
            if (($null -ne $glyphTypeface.FamilyNames) -and ($glyphTypeface.FamilyNames.Count -ne 0)) {
                if ($glyphTypeface.FamilyNames.ContainsKey($culture.LCID)) {
                    $fontFamilyName = $glyphTypeface.FamilyNames[$culture.LCID]
                } elseif ($glyphTypeface.FamilyNames.ContainsKey(0x0409)) {
                    $fontFamilyName = $glyphTypeface.FamilyNames[0x0409]
                }
            }
            $fontFaceName = $null
            if (($null -ne $glyphTypeface.FaceNames) -and ($glyphTypeface.FaceNames.Count -ne 0)) {
                if ($glyphTypeface.FaceNames.ContainsKey($culture.LCID)) {
                    $fontFaceName = $glyphTypeface.FaceNames[$culture.LCID]
                } elseif ($glyphTypeface.FaceNames.ContainsKey(0x0409)) {
                    $fontFaceName = $glyphTypeface.FaceNames[0x0409]
                }
            }
            if (($null -ne $fontFamilyName) -and ($null -ne $fontFaceName)) {
                $regValueName = "$($fontFamilyName.Trim()) $($fontFaceName.Trim()) (TrueType)"
            }
        }
    } finally {
        $glyphTypeface = $null
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }

    if ($null -eq $regValueName) {
        Write-Warning "Could not determine font family name from metadata; using filename as fallback."
        $regValueName = $FallbackName -replace '[-_]+', ' '
    }

    return $regValueName
}

Export-ModuleMember `
    -Function `
    Mount-ExternalRuntimeData, Dismount-ExternalRuntimeData, `
    Invoke-ExternalCommand2, Install-Font, Uninstall-Font
