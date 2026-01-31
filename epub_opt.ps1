<#
.SYNOPSIS
    Оптимизатор EPUB файлов.
    Многопоточная версия.

.PARAMETER InputPath
    Путь к папке с исходными EPUB файлами.
.PARAMETER OutputPath
    Путь к папке для сохранения оптимизированных EPUB файлов.
.PARAMETER j
    0 - Использовать все ядра (параллельная обработка файлов).
    1 - Последовательно.
    >1 - Заданное число потоков.
#>

param(
    [Parameter(Mandatory=$true, Position=0)][string]$InputPath,
    [Parameter(Mandatory=$true, Position=1)][string]$OutputPath,
    [int]$j = 0,
    [switch]$AsciiTempMode
)

if (-not (Test-Path $InputPath)) { Write-Error "Входной путь не найден: $InputPath"; exit 1 }
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

$ScriptDir = $PSScriptRoot
$PngOptScript = Join-Path $ScriptDir "png_opt.ps1"
$JpgOptScript = Join-Path $ScriptDir "jpg_opt_losless.ps1"
$GifOptScript = Join-Path $ScriptDir "gif_opt_losless.ps1"

foreach ($s in @($PngOptScript, $JpgOptScript, $GifOptScript)) {
    if (-not (Test-Path $s)) { Write-Error "Не найден скрипт: $s"; exit 1 }
}

# Логика потоков
if ($j -eq 0) {
    $Threads = (Get-CimInstance Win32_Processor).NumberOfCores
} else {
    $Threads = $j
}
# Если потоков много, скрипты сжатия запускаем в 1 поток
$SubScriptJ = if ($Threads -gt 1) { 1 } else { 0 }

Write-Host "Поиск EPUB..." -ForegroundColor Cyan
$EpubFiles = Get-ChildItem -LiteralPath $InputPath -Filter "*.epub" -Recurse -File
Write-Host "Найдено: $($EpubFiles.Count). Потоков: $Threads" -ForegroundColor Cyan

$EpubFiles = $EpubFiles | Sort-Object -Property Length -Descending

$EpubFiles | ForEach-Object -Parallel {
    $EpubFile = $_
    
    # Проброс переменных
    $InputPath    = $using:InputPath
    $OutputPath   = $using:OutputPath
    $PngOptScript = $using:PngOptScript
    $JpgOptScript = $using:JpgOptScript
    $GifOptScript = $using:GifOptScript
    $SubScriptJ   = $using:SubScriptJ
    $GlobalAscii  = $using:AsciiTempMode

    # -- БУФЕР ЛОГОВ --
    $LogBuffer = [System.Text.StringBuilder]::new()
    function Log-Message { param($Msg) [void]$LogBuffer.AppendLine($Msg) }

    # Пути
    $RelPath = $EpubFile.DirectoryName.Substring($InputPath.Length).TrimStart('\', '/')
    $TargetDir = Join-Path $OutputPath $RelPath
    if (-not (Test-Path $TargetDir)) { New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null }
    
    $FinalEpubPath = Join-Path $TargetDir $EpubFile.Name

    # Временная папка
    $TempDirName = "epub_opt_" + [System.Guid]::NewGuid().ToString()
    $TempDir = Join-Path $env:TEMP $TempDirName
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

    try {
        Log-Message "Processing: $($EpubFile.Name)"
        Expand-Archive -LiteralPath $EpubFile.FullName -DestinationPath $TempDir -Force

        # --- Оптимизация ---
        
        # Проверка пути на ASCII
        $IsPathAscii = ($TempDir -match "^[\x00-\x7F]*$")
        $UseAsciiMode = $GlobalAscii -or (-not $IsPathAscii)

        # Функция для запуска и захвата
        function Run-Opt {
            param($Script, $ArgsDict)
            # *>&1 перехватывает Write-Host, Write-Error и т.д.
            $res = & $Script @ArgsDict *>&1 | Out-String
            if (-not [string]::IsNullOrWhiteSpace($res)) { Log-Message $res.Trim() }
        }

        # Запускаем только если файлы существуют
        if ([bool](Get-ChildItem -Path $TempDir -Include "*.png" -File -Recurse -ErrorAction SilentlyContinue)) {
            Run-Opt -Script $PngOptScript -ArgsDict @{InputPath=$TempDir; OutputPath=$TempDir; j=$SubScriptJ; AsciiTempMode=$UseAsciiMode}
        }

        if ([bool](Get-ChildItem -Path $TempDir -Include "*.jpg", "*.jpeg" -File -Recurse -ErrorAction SilentlyContinue)) {
            Run-Opt -Script $JpgOptScript -ArgsDict @{InputPath=$TempDir; OutputPath=$TempDir; j=$SubScriptJ; AsciiTempMode=$UseAsciiMode}
        }

        if ([bool](Get-ChildItem -Path $TempDir -Include "*.gif" -File -Recurse -ErrorAction SilentlyContinue)) {
            Run-Opt -Script $GifOptScript -ArgsDict @{InputPath=$TempDir; OutputPath=$TempDir; j=$SubScriptJ; AsciiTempMode=$UseAsciiMode}
        }

        # --- Сборка во временный файл для проверки размера ---
        $TempEpubBuild = Join-Path $env:TEMP ("build_" + [System.Guid]::NewGuid().ToString() + ".epub")

        $CurrentDir = Get-Location
        Set-Location $TempDir
        try {
            if (Test-Path "mimetype") {
                Compress-Archive -Path ".\mimetype" -DestinationPath $TempEpubBuild -CompressionLevel NoCompression -Force
            }
            $Content = Get-ChildItem -LiteralPath $TempDir | Where-Object { $_.Name -ne 'mimetype' }
            if ($Content) {
                Compress-Archive -Path $Content -DestinationPath $TempEpubBuild -Update -CompressionLevel Optimal
            }
        }
        finally {
            Set-Location $CurrentDir
        }

        # --- Проверка размера ---
        $OrigSize = $EpubFile.Length
        $NewSize = (Get-Item $TempEpubBuild).Length

        if ($NewSize -lt $OrigSize) {
            Move-Item -LiteralPath $TempEpubBuild -Destination $FinalEpubPath -Force
            Log-Message "  Success: $($EpubFile.Name) ($([math]::Round(($OrigSize-$NewSize)/1KB)) KB saved)"
        } else {
            Copy-Item -LiteralPath $EpubFile.FullName -Destination $FinalEpubPath -Force
            Remove-Item -LiteralPath $TempEpubBuild -Force
            Log-Message "  No gain: $($EpubFile.Name) (kept original)"
        }

    }
    catch {
        Log-Message "Error $($EpubFile.Name): $_"
    }
    finally {
        if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # АТОМАРНЫЙ ВЫВОД
    Write-Host $LogBuffer.ToString() -ForegroundColor Cyan
} -ThrottleLimit $Threads

Write-Host "Все операции завершены." -ForegroundColor Cyan