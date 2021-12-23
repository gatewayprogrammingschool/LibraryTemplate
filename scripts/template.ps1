using namespace System;
using namespace System.Collections;

$ErrorActionPreference='Break'
$ErrorView='DetailedView'

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
    Push-Location
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

    $properties
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

function Set-TemplateValues {
    param(
        [switch]$WhatIf = $false,
        [switch]$Verbose = $false
    )

    $valuesChanged = $false
    $ignoreList = @();
    $properties = Get-TemplateProperties
    [MergeResult]$merged = $null;

    if ($properties) {
        $root = $PWD
        $files = Get-ChildItem *.cs, *.sln, *.md, *.yml, *.json -File -Recurse -Verbose:$Verbose

        if ($files) {
            $files | ForEach-Object -Process {
                $file = $_

                $contents = $file | Get-Content -Verbose:$Verbose

                $fileChanged = $false;

                Write-Verbose -Verbose:$Verbose -Message "Searching in $file [${contents.Length} lines]"

                for ($index = 0; $index -lt $contents.Length; $index += 1) {
                    $line = $contents[$index]

                    Merge-TemplateString $properties $line | Set-Variable merged -Force

                    if ($merged -and $merged.IsChanged()) {
                        $contents[$index] = $merged.NewString
                        $fileChanged = $true;
                        Write-Verbose -Verbose:$Verbose -Message "[Set-TemplateValues] Line Changed: `"$($merged.OriginalString)`" => `"$($merged.NewString)`""
                    }
                }

                if (-not $WhatIf) {
                    if ($fileChanged) {
                        $valuesChanged = $true;
                        $contents | Out-File $file -Verbose:$Verbose

                        "Updated contents of $file"
                        Write-Verbose -Verbose:$Verbose -Message "New Contents for ${fileName}:$([System.Environment]::NewLine)${contents}"
                    }
                }
                else {
                    switch ($fileChanged) {
                        $true {
                            "WhatIf: $fileName would be changed."
                            Write-Verbose -Verbose:$Verbose -Message "WhatIf: New Contents for ${fileName}:$([System.Environment]::NewLine)${contents}"
                        }

                        default {
                            "WhatIf: $fileName would not be changed."
                        }
                    }
                }

                $fileName = $file.Name

                Merge-TemplateString $properties $fileName -Verbose:$Verbose | Set-Variable merged -Force

                if ($merged -and $merged.IsChanged()) {
                    $valuesChanged = $true;
                    $to = $merged.NewString
                    $file | Rename-Item -NewName $to -Verbose:$Verbose -WhatIf:$WhatIf -ErrorAction Stop
                    $to = Join-Path $file.PSParentPath -ChildPath $to
                    $newFile = Get-Item $to -ErrorAction Stop -Verbose:$Verbose
                    $wasRenamed = $merged.Changed -and ($null -ne $newFile);
                    "Renamed File from `"$($merged.OriginalString)`" to `"$($merged.NewString)`": $wasRenamed"
                }
            }
        }

        Write-Verbose -Verbose:$Verbose -Message '[Set-TemplateValues] Completed processing files.'

        $direcoryFilters = @();
        $enumerator = $properties.GetEnumerator()
        while ($enumerator.MoveNext()) {
            $direcoryFilters += $enumerator.Current.Key
        }

        function Test-Name {
            param(
                [string[]]$patterns,
                [string]$name
            )

            foreach ($pattern in $patterns) {
                if ($name -match $pattern) {
                    return $true;
                }
            }

            return $false;
        }

        [Queue]$queue = New-Object Queue

        function Get-DirectoriesToRename {
            Set-Location $root > $null
            # Each time we rename a directory we start over.
            $directories = Get-ChildItem -Directory -Path $root -Recurse -Verbose:$Verbose;
            [ArrayList]$toEnqueue = New-Object ArrayList
            $directories | Where-Object {
                        $tested = Test-Name $direcoryFilters $_.Name
                        if($tested) {
                            $currentFullName = $_.PSPath;
                            $ignoredLength = $ignoreList.Length;
                            switch($ignoredLength) {
                                0 { $isIgnored = $false; }
                                1 {
                                    $ignorePath = $ignoreList[0].PSPath;
                                    $isIgnored = $ignorePath -eq $currentFullName
                                }
                                default {
                                    $ignoreMatches = $ignoreList | Where-Object{ $_.PSPath -eq $currentFullName }
                                    $isIgnored = ($ignoreMatches -and ($ignoreMatches.Length -gt 0))
                                }
                            }
                            if(-not $isIgnored) {
                                $toEnqueue.Add($_);
                            } else {
                                "Ignoring [$_]"
                            }
                        }
                    };

            $queue.Clear();

            # [Queue]$directoryQueue = New-Object Queue
            if ($null -ne $toEnqueue) {
                $length = $toEnqueue.Count;
                switch ($length) {
                    0 { return; }
                    1 {
                        $queue.Enqueue($toEnqueue) > $null
                    }
                    default {
                        foreach ($item in $toEnqueue) {
                            $queue.Enqueue($item) > $null
                        }
                    }
                }
            }
            else {

            }
        }

        Get-DirectoriesToRename  > $null

        while ($queue.Count -gt 0) {
            Write-Verbose -Verbose:$Verbose -Message "[Set-TemplateValues] `$directory: [$directory]"

            try {
                Push-Location > $null

                $directoryFullPath = $queue.Dequeue()
                $directory = Get-Item $directoryFullPath
                if ($directory) {
                    $directoryName = $directory.Name

                    Merge-TemplateString $properties $directoryName -Verbose:$Verbose `
                        | Set-Variable merged -Force  > $null

                    if ($merged.IsChanged()) {
                        $path = $directory.Parent
                        Set-Location $path > $null
                        $to = $merged.NewString
                        if(Test-Path $to) {
                            Write-Verbose -Verbose:$Verbose -Message "[$PWD\$to] already exists.  Skipping [$directory]."
                            $ignoreList += $directory;
                        } else {
                            $directory | Rename-Item -NewName $to -ErrorAction Stop -Verbose:$Verbose -WhatIf:$WhatIf > $null
                            $newPath = Join-Path $directory.PSParentPath -Child $to
                            $newPathItem = Get-Item $newPath -ErrorAction Stop -Verbose:$Verbose

                            if($newPathItem) {
                                $valuesChanged = $true;
                                "Renamed Directory from [$directory] to [${to}]."
                            } else {
                                throw "Failed to rename [$directory] to [$to]."
                            }
                        }

                        Get-DirectoriesToRename > $null
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

        Write-Verbose -Verbose:$Verbose -Message '[Set-TemplateValues] Completed processing directories.'

        if($valuesChanged) {
            "[Set-TemplateValues] Changes were applied in template files.  Check your work!"
        } else {
            '[Set-TemplateValues] No Changes were applied in template files.'
        }
    }
}

Set-TemplateValues
