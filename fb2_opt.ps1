<#
.SYNOPSIS
    Оптимизатор FB2 и FB2.ZIP файлов.
    Извлекает изображения, оптимизирует их выборочно и упаковывает обратно с проверкой размера.
    Поддерживает многопоточность.

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
    [switch]$AsciiTempMode # Оставлен для совместимости, но логика внутри изменена
)

# --- Настройка путей к скриптам ---
$ScriptDir = $PSScriptRoot
$ScriptJpeg = Join-Path $ScriptDir "jpg_opt_losless.ps1"
$ScriptPng  = Join-Path $ScriptDir "png_opt.ps1"
$ScriptGif  = Join-Path $ScriptDir "gif_opt_losless.ps1"

# Проверка наличия
if (-not (Test-Path $ScriptJpeg) -or -not (Test-Path $ScriptPng) -or -not (Test-Path $ScriptGif)) {
    Write-Error "Не найдены скрипты оптимизации в папке $ScriptDir"
    exit 1
}

# --- Логика потоков ---
# Вычисляем количество потоков для ForEach-Object -Parallel
if ($j -eq 0) {
    $Threads = (Get-CimInstance Win32_Processor).NumberOfCores
} else {
    $Threads = $j
}

# Вычисляем аргумент j для под-скриптов
# Если мы обрабатываем файлы параллельно ($Threads > 1), то под-скрипты должны работать в 1 поток.
# Если мы обрабатываем файлы по одному ($Threads == 1), отдаем все ресурсы под-скрипту (-j 0).
$SubScriptJ = if ($Threads -gt 1) { 1 } else { 0 }

# Создаем выходную директорию
if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# Получаем список файлов
Write-Host "Сканирование папки: $InputPath" -ForegroundColor Green
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

    # -- БУФЕР ЛОГОВ --
    $LogBuffer = [System.Text.StringBuilder]::new()
    function Log-Message { param($Msg) [void]$LogBuffer.AppendLine($Msg) }
    
    # Функция определения кодировки файла
    function Get-FileEncoding {
        param([string]$FilePath)
        
        # Читаем первые 4 байта для определения BOM
        $bytes = [System.IO.File]::ReadAllBytes($FilePath) | Select-Object -First 4
        
        # Определяем кодировку по BOM
        if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            return [System.Text.Encoding]::UTF8  # UTF-8 с BOM
        }
        if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            return [System.Text.Encoding]::Unicode  # UTF-16LE
        }
        if ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
            return [System.Text.Encoding]::BigEndianUnicode  # UTF-16BE
        }
        
        # Если BOM нет, пытаемся определить кодировку из заголовка XML
        try {
            # Читаем первые 1024 байта файла
            $bytes = [System.IO.File]::ReadAllBytes($FilePath) | Select-Object -First 1024
            $text = [System.Text.Encoding]::ASCII.GetString($bytes)
            
            # Ищем объявление XML с указанием кодировки
            $match = [regex]::Match($text, 'encoding\s*=\s*["'']([^"'']+)["'']')
            if ($match.Success) {
                $encodingName = $match.Groups[1].Value
                try {
                    return [System.Text.Encoding]::GetEncoding($encodingName)
                } catch {
                    Log-Message "Не удалось получить кодировку '$encodingName'. Используется UTF-8."
                }
            }
        } catch {
            # Если не удалось прочитать, продолжаем с UTF-8
        }
        
        # По умолчанию возвращаем UTF-8 без BOM
        return [System.Text.UTF8Encoding]::new($false)
    }

    # Функция оптимизации (определена внутри, т.к. runspace изолирован)
    function Run-ImageOptimizers {
        param($ImgDirIn, $ImgDirOut)

        if (-not (Test-Path -LiteralPath $ImgDirOut)) { New-Item -ItemType Directory -Path $ImgDirOut -Force | Out-Null }

        # Проверка пути на ASCII символы
        # Если путь состоит только из ASCII (код < 128), то AsciiTempMode НЕ нужен
        $IsPathAscii = ($ImgDirIn -match "^[\x00-\x7F]*$") -and ($ImgDirOut -match "^[\x00-\x7F]*$")
        $UseAsciiMode = $GlobalAscii -or (-not $IsPathAscii)

        # 1. JPG
        if ($true -in (Test-Path (Join-Path $ImgDirIn "*.jpg"), (Join-Path $ImgDirIn "*.jpeg") -PathType Leaf)) {
            $res = & $ScriptJpeg -InputPath $ImgDirIn -OutputPath $ImgDirOut -j $SubScriptJ -AsciiTempMode:$UseAsciiMode *>&1 | Out-String
            if ($res) { Write-Output $res.Trim() }
        }
        # 2. PNG
        if (Test-Path (Join-Path $ImgDirIn "*.png") -PathType Leaf) {
            $res = & $ScriptPng -InputPath $ImgDirIn -OutputPath $ImgDirOut -j $SubScriptJ -AsciiTempMode:$UseAsciiMode *>&1 | Out-String
            if ($res) { Write-Output $res.Trim() }
        }
        # 3. GIF
        if (Test-Path (Join-Path $ImgDirIn "*.gif") -PathType Leaf) {
            $res = & $ScriptGif -InputPath $ImgDirIn -OutputPath $ImgDirOut -j $SubScriptJ -AsciiTempMode:$UseAsciiMode *>&1 | Out-String
            if ($res) { Write-Output $res.Trim() }
        }
    }

    # Функция обработки FB2 контента
    function Process-Fb2Content {
        param($FilePath)
        
        # Определяем исходную кодировку файла
        $encoding = Get-FileEncoding -FilePath $FilePath
        
        # Читаем файл в исходной кодировке
        $Content = [System.IO.File]::ReadAllText($FilePath, $encoding)
        $Regex = [regex]'(?si)<binary\s+id="([^"]+)"\s+content-type="([^"]+)">\s*(.*?)\s*<\/binary>'
        $MatchesFound = $Regex.Matches($Content)

        if ($MatchesFound.Count -eq 0) { return $false }

        $TempSessionId = [System.IO.Path]::GetRandomFileName()
        $TempDirBase = Join-Path $env:TEMP "fb2opt_$TempSessionId"
        $TempImgIn   = Join-Path $TempDirBase "in"
        $TempImgOut  = Join-Path $TempDirBase "out"

        New-Item -ItemType Directory -Path $TempImgIn -Force | Out-Null
        New-Item -ItemType Directory -Path $TempImgOut -Force | Out-Null
        
        $FilesMap = @{}
        $HasImages = $false

        try {
            # Извлечение
            foreach ($Match in $MatchesFound) {
                $Id = $Match.Groups[1].Value
                $ContentType = $Match.Groups[2].Value
                $Base64 = $Match.Groups[3].Value
                $SafeName = $Id -replace '[\\/:*?"<>|]', '_'
                
                $Ext = ".bin"
                if ($ContentType -match "jpeg|jpg") { $Ext = ".jpg" }
                elseif ($ContentType -match "png") { $Ext = ".png" }
                elseif ($ContentType -match "gif") { $Ext = ".gif" }

                # Если это не картинка которую мы умеем жать, можно не извлекать, но для целостности лучше оставить как есть
                # Но флаг ставим только если это валидные форматы
                if ($Ext -match "\.(jpg|png|gif)") { $HasImages = $true }

                $FileName = "$SafeName$Ext"
                $SavePath = Join-Path $TempImgIn $FileName
                
                try {
                    $Bytes = [System.Convert]::FromBase64String($Base64)
                    [System.IO.File]::WriteAllBytes($SavePath, $Bytes)
                    $FilesMap[$Id] = $FileName
                } catch {}
            }

            if ($HasImages) {
                # Оптимизация
                $OptLogs = Run-ImageOptimizers -ImgDirIn $TempImgIn -ImgDirOut $TempImgOut | Out-String
                if (-not [string]::IsNullOrWhiteSpace($OptLogs)) {
                    Log-Message $OptLogs.Trim()
                }

                # Сборка
                $Evaluator = {
                    param($Match)
                    $Id = $Match.Groups[1].Value
                    $ContentType = $Match.Groups[2].Value
                    
                    if ($FilesMap.ContainsKey($Id)) {
                        $FileName = $FilesMap[$Id]
                        $OptPath = Join-Path $TempImgOut $FileName
                        $SrcPath = Join-Path $TempImgIn $FileName
                        
                        $TargetFile = $SrcPath
                        if (Test-Path -LiteralPath $OptPath) { $TargetFile = $OptPath }

                        if (Test-Path -LiteralPath $TargetFile) {
                            $NewBytes = [System.IO.File]::ReadAllBytes($TargetFile)
                            $NewBase64 = [System.Convert]::ToBase64String($NewBytes)
                            return "<binary id=`"$Id`" content-type=`"$ContentType`">$NewBase64</binary>"
                        }
                    }
                    return $Match.Value
                }
                $NewContent = $Regex.Replace($Content, $Evaluator)
                
                # Сохраняем файл в исходной кодировке
                [System.IO.File]::WriteAllText($FilePath, $NewContent, $encoding)
                return $true
            }
            return $false
        }
        finally {
            if (Test-Path -LiteralPath $TempDirBase) { Remove-Item -LiteralPath $TempDirBase -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    # --- Основное тело параллельного блока ---
    
    # Пути
    $RelPath = $File.DirectoryName.Substring($InputPath.Length).TrimStart('\', '/')
    $DestDir = Join-Path $OutputPath $RelPath
    if (-not (Test-Path -LiteralPath $DestDir)) { 
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null 
    }
    $DestFile = Join-Path $DestDir $File.Name

    Log-Message "Start: $($File.Name)"

    if ($File.Extension -eq ".fb2") {
        # Сохраняем оригинальный размер
        $OriginalSize = (Get-Item -LiteralPath $File.FullName).Length
        
        # Копируем и обрабатываем
        Copy-Item -LiteralPath $File.FullName -Destination $DestFile -Force
        $Res = Process-Fb2Content -FilePath $DestFile
        
        # Сравниваем размеры только если файл был изменен
        if ($Res) {
            $NewSize = (Get-Item -LiteralPath $DestFile).Length
            
            if ($NewSize -ge $OriginalSize) {
                # Если размер не уменьшился или стал больше, возвращаем оригинал
                Copy-Item -LiteralPath $File.FullName -Destination $DestFile -Force
                Log-Message "  No gain: $($File.Name) (kept original)"
            } else {
                Log-Message "  Saved space: $($File.Name) ($([math]::Round(($OriginalSize-$NewSize)/1KB, 1)) KB)"
            }
        } else {
            # Если изображений не было, все равно сообщаем
            Log-Message "  No images: $($File.Name) (kept as is)"
        }
    }
    elseif ($File.Extension -eq ".zip") {
        $ZipTempDir = Join-Path $env:TEMP ("fb2opt_zip_" + [System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $ZipTempDir -Force | Out-Null
        
        try {
            # Распаковка
            Expand-Archive -LiteralPath $File.FullName -DestinationPath $ZipTempDir -Force
            
            # Обработка внутри
            $InnerFb2 = Get-ChildItem -Path $ZipTempDir -Filter "*.fb2" -Recurse
            foreach ($Fb2 in $InnerFb2) {
                Process-Fb2Content -FilePath $Fb2.FullName | Out-Null
            }

            # Всегда пытаемся перепаковать во временный файл
            $TempZipFile = Join-Path $env:TEMP ([System.Guid]::NewGuid().ToString() + ".zip")

            $ItemsToZip = Get-ChildItem -Path $ZipTempDir
            Compress-Archive -Path $ItemsToZip.FullName -DestinationPath $TempZipFile -Force

            # Сравнение размеров
            $OriginalSize = (Get-Item -LiteralPath $File.FullName).Length
            $NewSize = (Get-Item -LiteralPath $TempZipFile).Length

            if ($NewSize -lt $OriginalSize) {
                Move-Item -LiteralPath $TempZipFile -Destination $DestFile -Force
                Log-Message "  Saved space: $($File.Name) ($([math]::Round(($OriginalSize-$NewSize)/1KB, 1)) KB)"
            } else {
                Copy-Item -LiteralPath $File.FullName -Destination $DestFile -Force
                Remove-Item -LiteralPath $TempZipFile -Force
                Log-Message "  No gain: $($File.Name) (kept original)"
            }
        }
        catch {
            Log-Message "Error zip processing $($File.Name): $_"
        }
        finally {
            if (Test-Path -LiteralPath $ZipTempDir) { Remove-Item -LiteralPath $ZipTempDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    # АТОМАРНЫЙ ВЫВОД ВСЕГО БУФЕРА
    Write-Host $LogBuffer.ToString() -ForegroundColor Yellow
} -ThrottleLimit $Threads

Write-Host "Оптимизация завершена." -ForegroundColor Green