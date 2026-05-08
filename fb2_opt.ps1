<#
.SYNOPSIS
    Оптимизатор FB2 и FB2.ZIP файлов.
    Извлекает изображения, оптимизирует их выборочно и упаковывает обратно с проверкой размера.
    Поддерживает многопоточность и ускорение упаковки/распаковки через 7-Zip.

.PARAMETER InputPath
    Путь к исходной папке с книгами.
.PARAMETER OutputPath
    Путь к папке для сохранения оптимизированных книг.
.PARAMETER j
    0 - Использовать все ядра (параллельная обработка файлов, скрипты в 1 поток).
    1 - Последовательная обработка файлов (скрипты используют свои механизмы многопоточности).
    >1 - Заданное число потоков для файлов (скрипты в 1 поток).
#>
param(
    [Parameter(Mandatory=$true, Position=0)][string]$InputPath,
    [Parameter(Mandatory=$true, Position=1)][string]$OutputPath,
    [int]$j = 0,
    [switch]$AsciiTempMode
)

# --- Настройка путей к скриптам ---
$ScriptDir = $PSScriptRoot
$ScriptJpeg = Join-Path $ScriptDir "jpg_opt_losless.ps1"
$ScriptPng  = Join-Path $ScriptDir "png_opt.ps1"
$ScriptGif  = Join-Path $ScriptDir "gif_opt_losless.ps1"

# Проверка наличия
if (-not (Test-Path $ScriptJpeg) -or -not (Test-Path $ScriptPng) -or -not (Test-Path $ScriptGif))
{
    Write-Error "Не найдены скрипты оптимизации в папке $ScriptDir"
    exit 1
}

# Проверка наличия 7-Zip
$Has7z = [bool](Get-Command 7z -ErrorAction SilentlyContinue)

# --- Логика потоков ---
if ($j -eq 0)
{
    $Threads = (Get-CimInstance Win32_Processor).NumberOfCores
} else
{
    $Threads = $j
}

$SubScriptJ = if ($Threads -gt 1)
{ 1 
} else
{ 0 
}

if (-not (Test-Path -LiteralPath $OutputPath))
{
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Write-Host "Сканирование папки: $InputPath" -ForegroundColor Green
Write-Host "Использование 7-Zip: $Has7z" -ForegroundColor Green
$Files = Get-ChildItem -LiteralPath $InputPath -Include "*.fb2", "*.zip" -Recurse -File
Write-Host "Найдено: $($Files.Count). Потоков: $Threads" -ForegroundColor Green

$Files = $Files | Sort-Object -Property Length -Descending

# --- ЗАПУСК ПАРАЛЛЕЛЬНОЙ ОБРАБОТКИ ---
$Files | ForEach-Object -Parallel {
    $File = $_

    # Передача переменных внутрь runspace
    $InputPath    = $using:InputPath
    $OutputPath   = $using:OutputPath
    $ScriptJpeg   = $using:ScriptJpeg
    $ScriptPng    = $using:ScriptPng
    $ScriptGif    = $using:ScriptGif
    $SubScriptJ   = $using:SubScriptJ
    $GlobalAscii  = $using:AsciiTempMode
    $Use7z        = $using:Has7z

    # -- БУФЕР ЛОГОВ --
    $LogBuffer = [System.Text.StringBuilder]::new()
    function Log-Message
    { param($Msg) [void]$LogBuffer.AppendLine($Msg) 
    }

    function Get-FileEncoding
    {
        param([string]$FilePath)
        $bytes = [System.IO.File]::ReadAllBytes($FilePath) | Select-Object -First 4

        if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        {
            return [System.Text.Encoding]::UTF8
        }
        if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE)
        {
            return [System.Text.Encoding]::Unicode
        }
        if ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF)
        {
            return [System.Text.Encoding]::BigEndianUnicode
        }

        try
        {
            $bytes = [System.IO.File]::ReadAllBytes($FilePath) | Select-Object -First 1024
            $text = [System.Text.Encoding]::ASCII.GetString($bytes)

            $match = [regex]::Match($text, 'encoding\s*=\s*["'']([^"'']+)["'']')
            if ($match.Success)
            {
                $encodingName = $match.Groups[1].Value
                try
                {
                    return [System.Text.Encoding]::GetEncoding($encodingName)
                } catch
                {
                    Log-Message "Не удалось получить кодировку '$encodingName'. Используется UTF-8."
                }
            }
        } catch
        { 
        }

        return [System.Text.UTF8Encoding]::new($false)
    }

    function Run-ImageOptimizers
    {
        param($ImgDirIn, $ImgDirOut)

        if (-not (Test-Path -LiteralPath $ImgDirOut))
        { New-Item -ItemType Directory -Path $ImgDirOut -Force | Out-Null 
        }

        $IsPathAscii = ($ImgDirIn -match "^[\x00-\x7F]*$") -and ($ImgDirOut -match "^[\x00-\x7F]*$")
        $UseAsciiMode = $GlobalAscii -or (-not $IsPathAscii)

        if ($true -in (Test-Path (Join-Path $ImgDirIn "*.jpg"), (Join-Path $ImgDirIn "*.jpeg") -PathType Leaf))
        {
            $res = & $ScriptJpeg -InputPath $ImgDirIn -OutputPath $ImgDirOut -j $SubScriptJ -AsciiTempMode:$UseAsciiMode *>&1 | Out-String
            if ($res)
            { Write-Output $res.Trim() 
            }
        }
        if (Test-Path (Join-Path $ImgDirIn "*.png") -PathType Leaf)
        {
            $res = & $ScriptPng -InputPath $ImgDirIn -OutputPath $ImgDirOut -j $SubScriptJ -AsciiTempMode:$UseAsciiMode *>&1 | Out-String
            if ($res)
            { Write-Output $res.Trim() 
            }
        }
        if (Test-Path (Join-Path $ImgDirIn "*.gif") -PathType Leaf)
        {
            $res = & $ScriptGif -InputPath $ImgDirIn -OutputPath $ImgDirOut -j $SubScriptJ -AsciiTempMode:$UseAsciiMode *>&1 | Out-String
            if ($res)
            { Write-Output $res.Trim() 
            }
        }
    }

    function Process-Fb2Content
    {
        param($FilePath)

        $encoding = Get-FileEncoding -FilePath $FilePath
        $Content = [System.IO.File]::ReadAllText($FilePath, $encoding)
        $Regex = [regex]'(?si)<binary\s+id="([^"]+)"\s+content-type="([^"]+)">\s*(.*?)\s*<\/binary>'
        $MatchesFound = $Regex.Matches($Content)

        if ($MatchesFound.Count -eq 0)
        { return $false 
        }

        $TempSessionId = [System.IO.Path]::GetRandomFileName()
        $TempDirBase = Join-Path $env:TEMP "fb2opt_$TempSessionId"
        $TempImgIn   = Join-Path $TempDirBase "in"
        $TempImgOut  = Join-Path $TempDirBase "out"

        New-Item -ItemType Directory -Path $TempImgIn -Force | Out-Null
        New-Item -ItemType Directory -Path $TempImgOut -Force | Out-Null

        $FilesMap = @{}
        $HasImages = $false

        try
        {
            foreach ($Match in $MatchesFound)
            {
                $Id = $Match.Groups[1].Value
                $ContentType = $Match.Groups[2].Value
                $Base64 = $Match.Groups[3].Value
                $SafeName = $Id -replace '[\\/:*?"<>|]', '_'

                $Ext = ".bin"
                if ($ContentType -match "jpeg|jpg")
                { $Ext = ".jpg" 
                } elseif ($ContentType -match "png")
                { $Ext = ".png" 
                } elseif ($ContentType -match "gif")
                { $Ext = ".gif" 
                }

                if ($Ext -match "\.(jpg|png|gif)")
                { $HasImages = $true 
                }

                $FileName = "$SafeName$Ext"
                $SavePath = Join-Path $TempImgIn $FileName

                try
                {
                    $Bytes = [System.Convert]::FromBase64String($Base64)
                    [System.IO.File]::WriteAllBytes($SavePath, $Bytes)
                    $FilesMap[$Id] = $FileName
                } catch
                {
                }
            }

            if ($HasImages)
            {
                $OptLogs = Run-ImageOptimizers -ImgDirIn $TempImgIn -ImgDirOut $TempImgOut | Out-String
                if (-not [string]::IsNullOrWhiteSpace($OptLogs))
                {
                    Log-Message $OptLogs.Trim()
                }

                $Evaluator = {
                    param($Match)
                    $Id = $Match.Groups[1].Value
                    $ContentType = $Match.Groups[2].Value

                    if ($FilesMap.ContainsKey($Id))
                    {
                        $FileName = $FilesMap[$Id]
                        $OptPath = Join-Path $TempImgOut $FileName
                        $SrcPath = Join-Path $TempImgIn $FileName

                        $TargetFile = $SrcPath
                        if (Test-Path -LiteralPath $OptPath)
                        { $TargetFile = $OptPath 
                        }

                        if (Test-Path -LiteralPath $TargetFile)
                        {
                            $NewBytes = [System.IO.File]::ReadAllBytes($TargetFile)
                            $NewBase64 = [System.Convert]::ToBase64String($NewBytes)
                            return "<binary id=`"$Id`" content-type=`"$ContentType`">$NewBase64</binary>"
                        }
                    }
                    return $Match.Value
                }
                $NewContent = $Regex.Replace($Content, $Evaluator)

                [System.IO.File]::WriteAllText($FilePath, $NewContent, $encoding)
                return $true
            }
            return $false
        } finally
        {
            if (Test-Path -LiteralPath $TempDirBase)
            { Remove-Item -LiteralPath $TempDirBase -Recurse -Force -ErrorAction SilentlyContinue 
            }
        }
    }

    # --- Основное тело параллельного блока ---

    $RelPath = $File.DirectoryName.Substring($InputPath.Length).TrimStart('\', '/')
    $DestDir = Join-Path $OutputPath $RelPath
    if (-not (Test-Path -LiteralPath $DestDir))
    {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }
    $DestFile = Join-Path $DestDir $File.Name

    Log-Message "Start: $($File.Name)"

    if ($File.Extension -eq ".fb2")
    {
        $OriginalSize = (Get-Item -LiteralPath $File.FullName).Length

        Copy-Item -LiteralPath $File.FullName -Destination $DestFile -Force
        $Res = Process-Fb2Content -FilePath $DestFile

        if ($Res)
        {
            $NewSize = (Get-Item -LiteralPath $DestFile).Length
            if ($NewSize -ge $OriginalSize)
            {
                Copy-Item -LiteralPath $File.FullName -Destination $DestFile -Force
                Log-Message "  No gain: $($File.Name) (kept original)"
            } else
            {
                Log-Message "  Saved space: $($File.Name) ($([math]::Round(($OriginalSize-$NewSize)/1KB, 1)) KB)"
            }
        } else
        {
            Log-Message "  No images: $($File.Name) (kept as is)"
        }
    } elseif ($File.Extension -eq ".zip")
    {
        $ZipTempDir = Join-Path $env:TEMP ("fb2opt_zip_" + [System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $ZipTempDir -Force | Out-Null

        try
        {
            # --- Распаковка ---
            if ($Use7z)
            {
                & 7z x "-o$ZipTempDir" $File.FullName -y *>$null
            } else
            {
                Expand-Archive -LiteralPath $File.FullName -DestinationPath $ZipTempDir -Force
            }

            $InnerFb2 = Get-ChildItem -Path $ZipTempDir -Filter "*.fb2" -Recurse
            foreach ($Fb2 in $InnerFb2)
            {
                Process-Fb2Content -FilePath $Fb2.FullName | Out-Null
            }

            $TempZipFile = Join-Path $env:TEMP ([System.Guid]::NewGuid().ToString() + ".zip")

            # --- Упаковка ---
            $CurrentDir = Get-Location
            Set-Location $ZipTempDir
            try
            {
                if ($Use7z)
                {
                    & 7z a -tzip -mx9 $TempZipFile "*" *>$null
                } else
                {
                    $ItemsToZip = Get-ChildItem -Path $ZipTempDir
                    Compress-Archive -Path $ItemsToZip.FullName -DestinationPath $TempZipFile -Force
                }
            } finally
            {
                Set-Location $CurrentDir
            }

            $OriginalSize = (Get-Item -LiteralPath $File.FullName).Length
            $NewSize = (Get-Item -LiteralPath $TempZipFile).Length

            if ($NewSize -lt $OriginalSize)
            {
                Move-Item -LiteralPath $TempZipFile -Destination $DestFile -Force
                Log-Message "  Saved space: $($File.Name) ($([math]::Round(($OriginalSize-$NewSize)/1KB, 1)) KB)"
            } else
            {
                Copy-Item -LiteralPath $File.FullName -Destination $DestFile -Force
                Remove-Item -LiteralPath $TempZipFile -Force
                Log-Message "  No gain: $($File.Name) (kept original)"
            }
        } catch
        {
            Log-Message "Error zip processing $($File.Name): $_"
        } finally
        {
            if (Test-Path -LiteralPath $ZipTempDir)
            { Remove-Item -LiteralPath $ZipTempDir -Recurse -Force -ErrorAction SilentlyContinue 
            }
        }
    }

    # АТОМАРНЫЙ ВЫВОД ВСЕГО БУФЕРА
    Write-Host $LogBuffer.ToString() -ForegroundColor Yellow
} -ThrottleLimit $Threads

Write-Host "Оптимизация завершена." -ForegroundColor Green
