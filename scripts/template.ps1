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
        [Property(Mandatory = $true, Position = 0)][IEnumerable]$props,
        [Property(Mandatory = $true, Position = 1)][string]$originalString,
        [switch]$Verbose=$false
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

    [MergeResult]$mergeResult = [MergeResult]::new($originalString, $newString);

    if ($mergeResult.IsChanged()) {
        Write-Verbose -Verbose:$Verbose -Message "[Merge-TemplateString] Merged   : `"${mergeResult.OriginalString}`" to `"${mergeResult.NewString}`""
    } else {
        Write-Verbose -Verbose:$Verbose -Message "[Merge-TemplateString] Unchanged: `"${mergeResult.OriginalString}`""
    }

    return $mergeResult;
}

class MergeResult {
    # Property: Holds original string
    [string] $OriginalString;

    # Property: Holds modified string
    [string] $NewString;

    # Method: Get state of new string value.
    [bool] IsChanged() {
        $result = this.IsSame($true);
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
    MyClass([string] $original, [string] $new) {
        $this.OriginalString = $original
        $this.NewString = $new
    }
}

function Set-TemplateValues {
    param(
        [switch]$WhatIf = $false,
        [switch]$Verbose = $false
    )

    $properties = Get-TemplateProperties

    if ($properties) {
        $files = Get-ChildItem *.cs, *.sln, *.md, *.yml, *.json -Recurse -Verbose:$Verbose

        if ($files) {
            $files | ForEach-Object -Process {
                $file = $_

                $contents = $file | Get-Content -Verbose:$Verbose

                $fileChanged = $false;

                Write-Verbose -Verbose:$Verbose -Message "Searching in $file [${contents.Length} lines]"

                for ($index = 0; $index -lt $contents.Length; $index += 1) {
                    $line = $contents[$index]

                    [MergeResult]$merged = Merge-TemplateString $properties $line

                    if ($merged.IsChanged()) {
                        $contents[$index] = $merged.NewString
                        $fileChanged = $true;
                    }
                }

                if (-not $WhatIf) {
                    if ($fileChanged) {
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

                [MergeResult]$merged = Merge-TemplateString $properties $fileName -Verbose:$Verbose

                if ($merged.IsChanged()) {
                    Rename-Item "${merged.OriginalString}" "${merged.NewString}"
                    "Renamed File from ${merged.OriginalString} to ${merged.NewString}: $(${merged.Changed} -eq (TestPath ${merged.NewString}))"
                }
            }
        }

        Write-Verbose -Verbose:$Verbose -Message 'Completed processing files.'

        # Each time we rename a directory we start over.
        $directory = Get-ChildItem -Directory -Recurse -Verbose:$Verbose | Select-Object -First

        do {
            try {
                Push-Location
                if ($directory) {
                    $directoryName = $directory.Name

                    [MergeResult]$merged = Merge-TemplateString $properties $directoryName

                    if (-not $WhatIf) {
                        if ($merged.IsChanged()) {
                            Set-Location ${directory.Parent}
                            Rename-Item $merged.OriginalString $merged.NewString -Verbose:$Verbose
                            "Renamed Directory from ${merged.OriginalString} to ${merged.NewString}: $(${merged.Changed} -eq (TestPath $merged.NewString))"
                        }
                    }
                    elseif ($merged.IsChanged()) {
                        "WhatIf: ${merged.OriginalString} would be renamed to ${merged.NewString}"
                    }
                }
            }
            finally {
                Pop-Location
            }

            $directories = Get-ChildItem -Directory -Recurse -Verbose:$Verbose | Select-Object -First
        } until ((-not $directories) -or ($directories.Length -eq 0))

        Write-Verbose -Verbose:$Verbose -Message "Completed processing directories."
    }
}

Set-TemplateValues