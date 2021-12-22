function Get-TemplateProperties {
    pushd
    $ScriptDirName = Split-Path $script:MyInvocation.MyCommand.Path
    if($ScriptDirName -ine "scripts") {
        $scriptsDir = Get-ChildItem scripts -Path $PWD -ErrorAction Stop

        if(-not $scriptsDir) {
            throw "Cannot locate scripts directory."
        }
    } else {
        $scriptsDir = Get-Item $PWD
    }

    $scriptsParentDir = $scriptsDir.PSParentPath

    Set-Location $scriptsParentDir

    $propsFile = Get-ChildItem Directory.Build.props -ErrorAction Stop

    if(-not $propsFile) {
        throw "Cannot locate Directory.Build.props in $scriptsParentDir"
    }

    [xml]$props=Get-Content $propsFile

    $group = $props.Project.PropertyGroup

    $properties = @{}
    $group.ChildNodes | ForEach-Object -Process {
        $element = $_
        $properties.Add($element.Name, $element.InnerText)
    }

    $properties
}

function Set-TemplateValues {
    $properties = Get-TemplateProperties

    if($properties) {
        $files = Get-ChildItem *.cs,*.sln,*.md,*.yml,*.json -Recurse

        if($files) {
            $files | ForEach-Object -Process {
                $file = $_

                $contents = $file | Get-Content

                $fileChanged = $false;

                "Searching in $file [${contents.Length} lines]"

                for($index=0; $index -lt $contents.Length; $index += 1) {
                    $line = $contents[$index]

                    $enumerator = $properties.GetEnumerator()
                    while ($enumerator.MoveNext()) {
                        $property = $enumerator.Current
                        while($line -match $property.Key) {
                            $original = $line
                            $line = $line.Replace($property.Key, $property.Value)
                            $fileChanged = $true
                            "Replaced ${property.Key} with ${property.Value} in $original"
                        }
                    }

                    $contents[$index] = $line
                }

                if($fileChanged) {
                    $contents | Out-File $file

                    "Updated $file"
                }
            }
        }
    }
}

Set-TemplateValues