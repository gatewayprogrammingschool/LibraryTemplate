using namespace System;
using namespace System.Collections;

param(
    [switch]$WhatIf = $false,
    [switch]$Verbose = $false
)

$ErrorActionPreference = 'Break'
$ErrorView = 'DetailedView'

$root = $PWD
$valuesChanged = $false

class MergeResult {
    # Property: Holds original string
    [string] $OriginalString;

    # Property: Holds modified string
    [string] $NewString;

    # Method: Get state of new string value.
    [bool] IsChanged() {
        $result = $this.IsSame($true);
        return (-not $result);
    }

    # Method: Get equivalence of new string value.
    [bool] IsSame([bool]$caseSensitive = $true) {
        [bool]$result = $false;

        switch ($caseSensitive) {
            $true {
                $result = $this.OriginalString -eq $this.NewString
            }
            $false {
                $result = $this.OriginalString -ieq $this.NewString
            }
            default {
                throw 'Unexpected non-boolean value.'
            }
        }

        return $result
    }

    # Constructor: Creates a new MyClass object, with the specified name
    MergeResult([string] $original, [string] $new) {
        $this.OriginalString = $original
        $this.NewString = $new
    }
}

function Get-TemplateProperties {
    param(
        [switch]$WhatIf = $false,
        [switch]$Verbose = $false
    )

    try {
        Push-Location > $null

        $ScriptDirName = Split-Path $script:MyInvocation.MyCommand.Path
        if ($ScriptDirName -ine 'scripts') {
            $scriptsDir = Get-ChildItem scripts -Path $PWD -ErrorAction Stop

            if (-not $scriptsDir) {
                throw 'Cannot locate scripts directory.'
            }
        }
        else {
            $scriptsDir = Get-Item $PWD
        }

        $scriptsParentDir = $scriptsDir.PSParentPath

        Set-Location $scriptsParentDir

        $propsFile = Get-ChildItem Directory.Build.props -ErrorAction Stop

        if (-not $propsFile) {
            throw "Cannot locate Directory.Build.props in $scriptsParentDir"
        }

        [xml]$props = Get-Content $propsFile

        $group = $props.Project.PropertyGroup

        $properties = @{}
        $group.ChildNodes | ForEach-Object -Process {
            $element = $_
            $properties.Add($element.Name, $element.InnerText)
        }

        return $properties;
    }
    finally {
        Pop-Location > $null
    }
}

function Get-DirectoriesToRename {
    param(
        [Queue]$queue,
        [switch]$WhatIf = $false,
        [switch]$Verbose = $false
    )

    [ArrayList]$toEnqueue = New-Object ArrayList
    [string[]]$directoryFilters = @();

    $queue.Clear();

    $enumerator = $properties.GetEnumerator()
    while ($enumerator.MoveNext()) {
        $directoryFilters += $enumerator.Current.Key
    }

    Set-Location $root > $null

    $directories = `
        Get-ChildItem `
            -Directory `
            -Path $root `
            -Recurse `
            -Verbose:$Verbose;

    $directories | Where-Object {
        $directory = $_;
        $tested = Test-Name $directoryFilters $directory.Name
        if ($tested) {
            $currentFullName = $directory.PSPath;
            $ignoredLength = $ignoreList.Length;
            switch ($ignoredLength) {
                0 {
                    $isIgnored = $false;
                }
                1 {
                    $ignorePath = $ignoreList[0].PSPath;
                    $isIgnored = $ignorePath -eq $currentFullName
                }
                default {
                    $ignoreMatches = $ignoreList | Where-Object { $_.PSPath -eq $currentFullName }
                    $isIgnored = ($ignoreMatches -and ($ignoreMatches.Length -gt 0))
                }
            }
            if (-not $isIgnored) {
                $toEnqueue.Add($directory);
            }
            else {
                Write-Information "[Get-DirectoriesToRename] Ignoring [$directory]"
            }
        }
    };

    if ($null -ne $toEnqueue) {
        $enumerator = $toEnqueue.GetEnumerator()
        while ($enumerator.MoveNext()) {
            $queue.Enqueue($enumerator.Current.Key);
        }
    }
}

function Test-Name {
    param(
        [string[]]$patterns,
        [string]$name,
        [switch]$WhatIf = $false,
        [switch]$Verbose = $false
    )

    foreach ($pattern in $patterns) {
        if ($name -match $pattern) {
            return $true;
        }
    }

    return $false;
}

function Merge-TemplateString {
    param (
        [IEnumerable]$props,
        [string]$originalString,
        [switch]$Verbose = $false
    )
    Write-Verbose -Verbose:$Verbose -Message "[Merge-TemplateString] Merging $originalString with [$props]"

    $newString = $originalString

    $enumerator = $props.GetEnumerator()
    while ($enumerator.MoveNext()) {
        $property = $enumerator.Current
        while ($newString -imatch $property.Key) {
            $newString = $newString.Replace($property.Key, $property.Value)
            Write-Verbose -Verbose:$Verbose -Message "[Merge-TemplateString] Replaced ${property.Key} with ${property.Value} in $originalString"
        }
    }

    [MergeResult]$mergeResult = New-Object MergeResult -ArgumentList $originalString, $newString;

    if ($mergeResult.IsChanged()) {
        Write-Verbose -Verbose:$Verbose -Message "[Merge-TemplateString] Merged   : `"$($mergeResult.OriginalString)`" to `"$($mergeResult.NewString)`""
    }
    else {
        Write-Verbose -Verbose:$Verbose -Message "[Merge-TemplateString] Unchanged: `"$($mergeResult.OriginalString)`""
    }

    return $mergeResult;
}

function Merge-FileName {
    param(
        [hashtable]$Properties,
        [string]$Filename,
        [switch]$WhatIf = $false,
        [switch]$Verbose = $false
    )

    [bool]$valuesChanged = $false;
    [MergeResult]$merged = $null;

    Merge-TemplateString $Properties $FileName -Verbose:$Verbose | Set-Variable merged -Force

    if ($merged -and $merged.IsChanged()) {
        $valuesChanged = $true;
        $to = $merged.NewString
        $file | Rename-Item -NewName $to -Verbose:$Verbose -WhatIf:$WhatIf -ErrorAction Stop
        $to = Join-Path $file.PSParentPath -ChildPath $to
        $newFile = Get-Item $to -ErrorAction Stop -Verbose:$Verbose
        $wasRenamed = $merged.Changed -and ($null -ne $newFile);
        Write-Information "[Merge-TemplateFiles] Renamed File from `"$($merged.OriginalString)`" to `"$($merged.NewString)`": $wasRenamed"
    }

    return $valuesChanged
}

function Merge-FileContents {
    param(
        [hashtable]$Properties,
        [IO.FileInfo]$File,
        [switch]$WhatIf = $false,
        [switch]$Verbose = $false
    )

    $fileChanged = $false;

    if (-not $fileName.EndsWith('.csproj', [StringComparison]::OrdinalIgnoreCase)) {
        $contents = $File | Get-Content -Verbose:$Verbose

        Write-Verbose -Verbose:$Verbose -Message "[Merge-TemplateFiles] Searching in $file [${contents.Length} lines]"

        for ($index = 0; $index -lt $contents.Length; $index += 1) {
            $line = $contents[$index]

            [MergeResult]$merged = $null;
            Merge-TemplateString $Properties $line | Set-Variable merged -Force

            if ($merged -and $merged.IsChanged()) {
                $contents[$index] = $merged.NewString
                $fileChanged = $true;
                Write-Verbose -Verbose:$Verbose -Message "[Merge-TemplateFiles] Line Changed: `"$($merged.OriginalString)`" => `"$($merged.NewString)`""
            }
        }

        if (-not $WhatIf) {
            if ($fileChanged) {
                $contents | Out-File $file -Verbose:$Verbose

                Write-Information "[Merge-TemplateFiles] Updated contents of $file"
            }
        }
        else {
            switch ($fileChanged) {
                $true {
                    Write-Information "[Merge-TemplateFiles] WhatIf: $fileName would be changed."
                }

                default {
                    Write-Information "[Merge-TemplateFiles] WhatIf: $fileName would not be changed."
                }
            }
        }
    }

    return $fileChanged
}

function Merge-TemplateDirectories {
    param(
        [hashtable]$Properties,
        [switch]$WhatIf = $false,
        [switch]$Verbose = $false
    )

    [bool]$valuesChanged = $false;
    [MergeResult]$merged = $null;
    [Queue]$queue = New-Object Queue

    $ignoreList = @();
    Write-Information "[Merge-TemplateDirectories] Get-DirectoriesToRename: $(Get-DirectoriesToRename $queue)"

    while ($queue.Count -gt 0) {
        Write-Verbose -Verbose:$Verbose -Message "[Merge-TemplateDirectories] `$directory: [$directory]"

        try {
            Push-Location > $null

            $directoryFullPath = $queue.Dequeue()
            $directory = Get-Item $directoryFullPath
            if ($directory) {
                $directoryName = $directory.Name

                Merge-TemplateString $properties $directoryName -Verbose:$Verbose `
                | Set-Variable merged -Force > $null

                if ($merged.IsChanged()) {
                    $path = $directory.Parent
                    Set-Location $path > $null
                    $to = $merged.NewString
                    if (Test-Path $to) {
                        Write-Verbose -Verbose:$Verbose -Message "[Merge-TemplateDirectories] [$PWD\$to] already exists.  Skipping [$directory]."
                        $ignoreList += $directory;
                    }
                    else {
                        $directory | Rename-Item -NewName $to -ErrorAction Stop -Verbose:$Verbose -WhatIf:$WhatIf > $null
                        $newPath = Join-Path $directory.PSParentPath -Child $to
                        $newPathItem = Get-Item $newPath -ErrorAction Stop -Verbose:$Verbose

                        if ($newPathItem) {
                            $valuesChanged = $true;
                            Write-Information "[Merge-TemplateDirectories] Renamed Directory from [$directory] to [${to}]."
                        }
                        else {
                            throw "[Merge-TemplateDirectories] Failed to rename [$directory] to [$to]."
                        }
                    }

                    Get-DirectoriesToRename $queue > $null
                }
            }
        }
        catch {
            $Err = $_
            $Err
            throw $Err
        }
        finally {
            Pop-Location > $null
        }
    }

    Write-Information '[Merge-TemplateDirectories] Completed processing directories.'

    return $valuesChanged;
}

function Merge-TemplateFiles {
    param(
        [hashtable]$Properties,
        [switch]$WhatIf = $false,
        [switch]$Verbose = $false
    )

    [bool]$valuesChanged = $false;
    $fileFilters = @('*.cs', '*.sln', '*.md', '*.yml', '*.json', '*.csproj')

    $files = Get-ChildItem $fileFilters -File -Recurse -Verbose:$Verbose

    if ($files) {
        $files `
            | ForEach-Object -Process {
                $file = $_

                $fileNamesChanged = Merge-FileName `
                    -Properties $properties `
                    -Filename $file.Name `
                    -Verbose:$Verbose `
                    -WhatIf:$WhatIf

                $fileContentsChanged = Merge-FileContents `
                    -Properties $properties `
                    -File $file `
                    -Verbose:$Verbose `
                    -WhatIf:$WhatIf

                return $valuesChange `
                        -or $fileNamesChanged `
                        -or $fileContentsChanged;
            } `
            | Set-Variable $valuesChanged
    }

    Write-Verbose -Verbose:$Verbose -Message '[Merge-TemplateFiles] Completed processing files.'

    return $valuesChanged
}

function Set-TemplateValues {
    param(
        [switch]$WhatIf = $false,
        [switch]$Verbose = $false
    )

    $properties = Get-TemplateProperties

    if ($properties) {

        [bool]$directoriesChanged = `
            Merge-TemplateDirectories `
                -Properties $properties
                -WhatIf:$WhatIf `
                -Verbose:$Verbose

        [bool]$filesChanged = `
            Merge-TemplateFiles `
                -Properties $properties
                -WhatIf:$WhatIf `
                -Verbose:$Verbose

        if ($directoriesChanged -or $filesChanged) {
            Write-Information '[Set-TemplateValues] Changes were applied in template files.  Check your work!'
        }
        else {
            Write-Information '[Set-TemplateValues] No Changes were applied in template files.'
        }
    }
}

Set-TemplateValues -WhatIf:$WhatIf -Verbose:$Verbose
