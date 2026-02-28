<#
.SYNOPSIS
    Transcriber PowerShell - Audio/Video to SRT subtitle generator
.DESCRIPTION
    Transcribes audio and video files to SRT subtitles using OpenAI Whisper.
    Supports: .mp3, .mp4, .mov, .mkv, .avi, .wmv
    Features: model selection, Romanian-to-English translation, SRT optimization.
.NOTES
    Version: v1.0-ps1
    Requires: Python 3, openai-whisper, ffmpeg
#>

[CmdletBinding()]
param(
    [string]$ConfigFile = "config.yaml",
    [switch]$ShowVersion,
    [switch]$Init
)

# ============================================================
# CONFIGURATION
# ============================================================
$script:VERSION = "v1.0-ps1"
$script:RECOVERY_FILE = "recovery.json"

$script:SUPPORTED_AUDIO_EXTENSIONS = @(".mp3")
$script:SUPPORTED_VIDEO_EXTENSIONS = @(".mp4", ".mov", ".mkv", ".avi", ".wmv")
$script:SUPPORTED_EXTENSIONS = $script:SUPPORTED_AUDIO_EXTENSIONS + $script:SUPPORTED_VIDEO_EXTENSIONS

$script:MODEL_LIST = @(
    "tiny",
    "base",
    "small",
    "medium",
    "large-v1",
    "large-v2",
    "large-v3",
    "large-v3-turbo"
)

$script:MODEL_MAPPING = @{
    "tiny"           = "tiny"
    "base"           = "base"
    "small"          = "small"
    "medium"         = "medium"
    "large-v1"       = "large-v1"
    "large-v2"       = "large-v2"
    "large-v3"       = "large-v3"
    "large-v3-turbo" = "turbo"
}

# SRT post-processing defaults
$script:DEFAULT_MIN_CHARS       = 80
$script:DEFAULT_MAX_CHARS       = 120
$script:DEFAULT_SUBTITLE_GAP_MS = 100

# ============================================================
# UI HELPERS
# ============================================================

function Show-Banner {
    Clear-Host
    $bannerLines = @(
        "",
        "  +==============================================================+",
        "  |                                                              |",
        "  |        [~] TRANSCRIBER PowerShell $script:VERSION                |",
        "  |                                                              |",
        "  |   Audio & Video  -->  Subtitles (.srt)                       |",
        "  |   Powered by OpenAI Whisper + FFmpeg                         |",
        "  |                                                              |",
        "  +==============================================================+",
        ""
    )
    foreach ($line in $bannerLines) {
        Write-Host $line -ForegroundColor Cyan
    }
}

function Write-Info {
    param([string]$Message)
    Write-Host "  [INFO] " -ForegroundColor Blue -NoNewline
    Write-Host $Message
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK]   " -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [WARN] " -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

function Write-Err {
    param([string]$Message)
    Write-Host "  [ERR]  " -ForegroundColor Red -NoNewline
    Write-Host $Message
}

function Write-Step {
    param([string]$StepNumber, [string]$Message)
    Write-Host ""
    Write-Host "  -- Step $StepNumber -------------------------------------------" -ForegroundColor DarkCyan
    Write-Host "  $Message" -ForegroundColor White
    Write-Host ""
}

function Write-Separator {
    Write-Host "  ----------------------------------------------------------" -ForegroundColor DarkGray
}

function Show-Progress {
    param(
        [int]$Current,
        [int]$Total,
        [string]$FileName
    )
    if ($Total -eq 0) { return }
    $percent = [math]::Floor(($Current / $Total) * 100)
    $barLength = 30
    $filled = [math]::Floor(($Current / $Total) * $barLength)
    $empty = $barLength - $filled
    $bar = ("#" * $filled) + ("-" * $empty)
    Write-Host "`r  [$bar] $percent% ($Current/$Total) $FileName   " -ForegroundColor Cyan -NoNewline
    if ($Current -eq $Total) { Write-Host "" }
}

# ============================================================
# DEPENDENCY CHECKS
# ============================================================

function Test-Dependencies {
    Write-Step "0" "Verificare dependente (Checking dependencies)..."

    # Check Python
    $pythonCmd = $null
    foreach ($cmd in @("python", "python3", "py")) {
        try {
            $result = & $cmd --version 2>&1
            if ($LASTEXITCODE -eq 0 -and $result -match "Python 3") {
                $pythonCmd = $cmd
                break
            }
        }
        catch { }
    }
    if (-not $pythonCmd) {
        Write-Err "Python 3 nu a fost gasit. Instaleaza Python 3.8+ de la https://python.org"
        return $false
    }
    Write-Success "Python: $( & $pythonCmd --version 2>&1 )"

    # Check whisper CLI
    $whisperCmd = $null
    foreach ($cmd in @("whisper", "whisper.exe")) {
        try {
            $result = & $cmd --help 2>&1
            if ($?) {
                $whisperCmd = $cmd
                break
            }
        }
        catch { }
    }
    if (-not $whisperCmd) {
        # Try python -m whisper
        try {
            $result = & $pythonCmd -m whisper --help 2>&1
            if ($?) {
                $whisperCmd = "$pythonCmd -m whisper"
            }
        }
        catch { }
    }
    if (-not $whisperCmd) {
        Write-Err "Whisper nu a fost gasit. Instaleaza cu: pip install openai-whisper"
        return $false
    }
    Write-Success "Whisper CLI: disponibil"
    $script:WhisperCommand = $whisperCmd

    # Check ffmpeg
    try {
        $result = & ffmpeg -version 2>&1
        if ($LASTEXITCODE -ne 0 -and -not ($result -match "ffmpeg version")) {
            throw "ffmpeg not found"
        }
        $versionLine = ($result | Select-Object -First 1)
        Write-Success "FFmpeg: $versionLine"
    }
    catch {
        Write-Err "FFmpeg nu a fost gasit. Instaleaza FFmpeg de la https://ffmpeg.org"
        return $false
    }

    Write-Success "Toate dependentele sunt disponibile!"
    return $true
}

# ============================================================
# CONFIG & RECOVERY
# ============================================================

function Get-DefaultConfig {
    return @{
        language       = "ro"
        model_type     = "small"
        temp_dir       = "temp_transcription"
        postprocess    = @{
            min_chars       = $script:DEFAULT_MIN_CHARS
            max_chars       = $script:DEFAULT_MAX_CHARS
            subtitle_gap_ms = $script:DEFAULT_SUBTITLE_GAP_MS
        }
    }
}

function Save-ConfigYaml {
    param([hashtable]$Config, [string]$Path)
    # Simple YAML writer (no external dependency needed)
    $lines = @(
        "language: $($Config.language)",
        "model_type: $($Config.model_type)",
        "temp_dir: $($Config.temp_dir)",
        "postprocess:",
        "  min_chars: $($Config.postprocess.min_chars)",
        "  max_chars: $($Config.postprocess.max_chars)",
        "  subtitle_gap_ms: $($Config.postprocess.subtitle_gap_ms)"
    )
    $lines -join "`n" | Set-Content -Path $Path -Encoding UTF8
}

function Load-Config {
    param([string]$Path)
    $default = Get-DefaultConfig
    if (-not (Test-Path $Path)) {
        Write-Warn "Fisierul de configurare '$Path' nu exista. Se creeaza cu valori implicite."
        Save-ConfigYaml -Config $default -Path $Path
        return $default
    }
    try {
        $content = Get-Content -Path $Path -Raw -Encoding UTF8
        $cfg = @{}
        foreach ($line in ($content -split "`n")) {
            $line = $line.Trim()
            if ($line -eq "" -or $line.StartsWith("#")) { continue }
            if ($line -match "^\s*(\w[\w_]*):\s*(.+)$") {
                $key = $Matches[1]
                $val = $Matches[2].Trim()
                if ($val -match "^\d+$") { $val = [int]$val }
                $cfg[$key] = $val
            }
        }
        # Merge with defaults
        foreach ($key in $default.Keys) {
            if (-not $cfg.ContainsKey($key)) {
                $cfg[$key] = $default[$key]
            }
        }
        if (-not $cfg.ContainsKey("postprocess")) {
            $cfg["postprocess"] = $default.postprocess
        }
        elseif ($cfg["postprocess"] -isnot [hashtable]) {
            $cfg["postprocess"] = $default.postprocess
        }
        # Ensure postprocess sub-keys
        foreach ($subKey in $default.postprocess.Keys) {
            if (-not $cfg.postprocess.ContainsKey($subKey)) {
                $cfg.postprocess[$subKey] = $default.postprocess[$subKey]
            }
        }
        return $cfg
    }
    catch {
        Write-Warn "Eroare la citirea configurarii: $($_.Exception.Message). Se folosesc valorile implicite."
        return $default
    }
}

function Load-Recovery {
    if (Test-Path $script:RECOVERY_FILE) {
        try {
            return (Get-Content -Path $script:RECOVERY_FILE -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
        catch {
            return @{}
        }
    }
    return @{}
}

function Save-Recovery {
    param($State)
    try {
        $State | ConvertTo-Json -Depth 5 | Set-Content -Path $script:RECOVERY_FILE -Encoding UTF8
    }
    catch {
        Write-Err "Nu pot salva recovery: $_"
    }
}

# ============================================================
# INTERACTIVE MENUS
# ============================================================

function Select-WorkingDirectory {
    Write-Step "1" "Selecteaza directorul cu fisierele media"

    $currentDir = Get-Location
    Write-Host "  Director curent: " -NoNewline
    Write-Host "$currentDir" -ForegroundColor Yellow
    Write-Host ""

    Write-Host "  [1] " -ForegroundColor Cyan -NoNewline
    Write-Host "Foloseste directorul curent"
    Write-Host "  [2] " -ForegroundColor Cyan -NoNewline
    Write-Host "Introdu o cale diferita"
    Write-Host ""

    $choice = Read-Host "  Alege optiunea (1/2)"
    switch ($choice) {
        "2" {
            $path = Read-Host "  Introdu calea directorului"
            if (Test-Path $path -PathType Container) {
                return $path
            }
            else {
                Write-Err "Directorul '$path' nu exista. Se foloseste directorul curent."
                return $currentDir.Path
            }
        }
        default {
            return $currentDir.Path
        }
    }
}

function Select-WhisperModel {
    Write-Step "2" "Selecteaza modelul Whisper"

    Write-Host "  Modele disponibile:" -ForegroundColor White
    Write-Host ""
    Write-Host "  [1] " -ForegroundColor Cyan -NoNewline
    Write-Host "tiny          " -ForegroundColor White -NoNewline
    Write-Host "- Cel mai rapid, acuratete scazuta (~75 MB)" -ForegroundColor DarkGray
    Write-Host "  [2] " -ForegroundColor Cyan -NoNewline
    Write-Host "base          " -ForegroundColor White -NoNewline
    Write-Host "- Rapid, acuratete moderata (~142 MB)" -ForegroundColor DarkGray
    Write-Host "  [3] " -ForegroundColor Cyan -NoNewline
    Write-Host "small         " -ForegroundColor White -NoNewline
    Write-Host "- Echilibrat viteza/acuratete (~466 MB) [RECOMANDAT]" -ForegroundColor Green
    Write-Host "  [4] " -ForegroundColor Cyan -NoNewline
    Write-Host "medium        " -ForegroundColor White -NoNewline
    Write-Host "- Buna acuratete, mai lent (~1.5 GB)" -ForegroundColor DarkGray
    Write-Host "  [5] " -ForegroundColor Cyan -NoNewline
    Write-Host "large-v1      " -ForegroundColor White -NoNewline
    Write-Host "- Acuratete mare (~2.9 GB)" -ForegroundColor DarkGray
    Write-Host "  [6] " -ForegroundColor Cyan -NoNewline
    Write-Host "large-v2      " -ForegroundColor White -NoNewline
    Write-Host "- Acuratete mare imbunatatita (~2.9 GB)" -ForegroundColor DarkGray
    Write-Host "  [7] " -ForegroundColor Cyan -NoNewline
    Write-Host "large-v3      " -ForegroundColor White -NoNewline
    Write-Host "- Cea mai buna acuratete (~2.9 GB)" -ForegroundColor DarkGray
    Write-Host "  [8] " -ForegroundColor Cyan -NoNewline
    Write-Host "large-v3-turbo" -ForegroundColor White -NoNewline
    Write-Host "- Acuratete mare + viteza buna (~1.5 GB)" -ForegroundColor DarkGray
    Write-Host ""

    $choice = Read-Host "  Alege modelul (1-8, implicit=3 small)"
    switch ($choice) {
        "1" { return "tiny" }
        "2" { return "base" }
        "3" { return "small" }
        "4" { return "medium" }
        "5" { return "large-v1" }
        "6" { return "large-v2" }
        "7" { return "large-v3" }
        "8" { return "large-v3-turbo" }
        default { return "small" }
    }
}

function Select-TranslationOption {
    Write-Step "3" "Optiuni de traducere"

    Write-Host "  Limba sursa a fisierelor: " -NoNewline
    Write-Host "Romana (RO)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  [1] " -ForegroundColor Cyan -NoNewline
    Write-Host "Doar transcriere (subtitrari in romana)"
    Write-Host "  [2] " -ForegroundColor Cyan -NoNewline
    Write-Host "Transcriere + Traducere in engleza"
    Write-Host "  [3] " -ForegroundColor Cyan -NoNewline
    Write-Host "Doar traducere in engleza (fara subtitrare in romana)"
    Write-Host ""

    $choice = Read-Host "  Alege optiunea (1-3, implicit=1)"
    switch ($choice) {
        "2" { return "both" }
        "3" { return "translate_only" }
        default { return "transcribe" }
    }
}

function Show-FileList {
    param([string[]]$Files)

    Write-Host "  Fisiere gasite:" -ForegroundColor White
    Write-Separator
    $index = 1
    foreach ($file in $Files) {
        $ext = [System.IO.Path]::GetExtension($file).ToLower()
        $name = [System.IO.Path]::GetFileName($file)
        $size = (Get-Item $file).Length / 1MB
        $sizeStr = "{0:N1} MB" -f $size

        if ($ext -in $script:SUPPORTED_VIDEO_EXTENSIONS) {
            $icon = "[V]"
            $color = "Magenta"
        }
        else {
            $icon = "[A]"
            $color = "Green"
        }
        Write-Host "  $icon " -NoNewline
        Write-Host "[$index] " -ForegroundColor DarkGray -NoNewline
        Write-Host "$name" -ForegroundColor $color -NoNewline
        Write-Host " ($sizeStr)" -ForegroundColor DarkGray
        $index++
    }
    Write-Separator
    Write-Host "  Total: $($Files.Count) fisier(e)" -ForegroundColor Yellow
    Write-Host ""
}

function Confirm-Start {
    param(
        [string]$Model,
        [string]$TranslateOption,
        [int]$FileCount
    )

    Write-Step "4" "Confirmare si start"

    Write-Host "  Configurare finala:" -ForegroundColor White
    Write-Host "  * Model Whisper:  " -NoNewline
    Write-Host "$Model" -ForegroundColor Cyan
    Write-Host "  * Fisiere:        " -NoNewline
    Write-Host "$FileCount" -ForegroundColor Cyan
    Write-Host "  * Limba sursa:    " -NoNewline
    Write-Host "Romana (RO)" -ForegroundColor Yellow
    Write-Host "  * Actiune:        " -NoNewline
    switch ($TranslateOption) {
        "transcribe"     { Write-Host "Transcriere (subtitrari RO)" -ForegroundColor Green }
        "both"           { Write-Host "Transcriere RO + Traducere EN" -ForegroundColor Green }
        "translate_only" { Write-Host "Doar traducere in engleza" -ForegroundColor Green }
    }
    Write-Host ""

    $confirm = Read-Host "  Doresti sa incepi? (D/n)"
    return ($confirm -ne "n" -and $confirm -ne "N")
}

# ============================================================
# SRT POST-PROCESSING
# ============================================================

function Split-CustomText {
    param(
        [string]$Text,
        [int]$MaxChars
    )

    if ($Text.Length -le $MaxChars) {
        Write-Output $Text
        return
    }

    # Determine preferred cut point
    if ($Text.Length -lt 150) {
        $pref = 70
    }
    elseif ($Text.Length -lt 180) {
        $pref = 90
    }
    else {
        $pref = 100
    }

    $cuts = [System.Collections.ArrayList]::new()

    # Priority 1: Sentence-ending punctuation
    foreach ($punct in @(". ", "! ", "? ")) {
        $searchEnd = [math]::Min($pref + 10, $Text.Length - 1)
        $pos = $Text.LastIndexOf($punct, $searchEnd)
        if ($pos -ge 0 -and $pos -gt ($pref - 20)) {
            [void]$cuts.Add(@{ Index = $pos + $punct.Length; Type = "sentence" })
        }
    }

    # Priority 2: Other punctuation
    foreach ($punct in @(", ", "; ", ": ", " - ")) {
        $searchEnd = [math]::Min($pref + 10, $Text.Length - 1)
        $pos = $Text.LastIndexOf($punct, $searchEnd)
        if ($pos -ge 0 -and $pos -gt ($pref - 15)) {
            [void]$cuts.Add(@{ Index = $pos + $punct.Length; Type = "punctuation" })
        }
    }

    # Priority 3: Spaces
    $searchEnd = [math]::Min($pref + 5, $Text.Length - 1)
    $pos = $Text.LastIndexOf(" ", $searchEnd)
    if ($pos -ge 0 -and $pos -gt ($pref - 10)) {
        [void]$cuts.Add(@{ Index = $pos + 1; Type = "space" })
    }

    if ($cuts.Count -gt 0) {
        # Sort by priority then proximity to preferred point
        $sorted = @($cuts | Sort-Object @{
            Expression = {
                $priority = switch ($_.Type) {
                    "sentence"    { 0 }
                    "punctuation" { 1 }
                    "space"       { 2 }
                    default       { 3 }
                }
                $distance = [math]::Abs($_.Index - $pref)
                $priority * 1000 + $distance
            }
        })
        $splitIdx = [int]$sorted[0].Index
    }
    else {
        $splitIdx = $pref
    }

    # Safety: ensure splitIdx is valid
    if ($splitIdx -le 0 -or $splitIdx -ge $Text.Length) { $splitIdx = $pref }

    $left  = $Text.Substring(0, $splitIdx).Trim()
    $right = $Text.Substring($splitIdx).Trim()

    if ($left -eq "" -or $right -eq "") {
        # Avoid infinite recursion - return as-is
        Write-Output $Text
        return
    }

    Write-Output $left
    Split-CustomText -Text $right -MaxChars $MaxChars
}

function ConvertTo-Milliseconds {
    param([TimeSpan]$Time)
    return [long]$Time.TotalMilliseconds
}

function ConvertFrom-SrtTimestamp {
    param([string]$Timestamp)
    # Parse "HH:MM:SS,mmm" format
    $Timestamp = $Timestamp.Trim()
    if ($Timestamp -match "^(\d{2}):(\d{2}):(\d{2})[,.](\d{3})$") {
        $h   = [int]$Matches[1]
        $m   = [int]$Matches[2]
        $s   = [int]$Matches[3]
        $ms  = [int]$Matches[4]
        return New-TimeSpan -Hours $h -Minutes $m -Seconds $s -Milliseconds $ms
    }
    return [TimeSpan]::Zero
}

function ConvertTo-SrtTimestamp {
    param([TimeSpan]$Time)
    $totalMs = [long]$Time.TotalMilliseconds
    if ($totalMs -lt 0) { $totalMs = 0 }
    $h  = [math]::Floor($totalMs / 3600000)
    $totalMs -= $h * 3600000
    $m  = [math]::Floor($totalMs / 60000)
    $totalMs -= $m * 60000
    $s  = [math]::Floor($totalMs / 1000)
    $ms = $totalMs - ($s * 1000)
    return "{0:D2}:{1:D2}:{2:D2},{3:D3}" -f [int]$h, [int]$m, [int]$s, [int]$ms
}

function Split-TextWithTiming {
    param(
        [string]$Text,
        [TimeSpan]$Start,
        [TimeSpan]$End,
        [int]$MaxChars,
        [int]$GapMs
    )

    $chunks = Split-CustomText -Text $Text -MaxChars $MaxChars
    if ($chunks.Count -le 1) {
        return @(@{ Text = $Text; Start = $Start; End = $End })
    }

    [long]$totalMs   = [long](ConvertTo-Milliseconds $End) - [long](ConvertTo-Milliseconds $Start)
    [int]$gaps       = $chunks.Count - 1
    [long]$totalGap  = [long]$GapMs * [long]$gaps

    if ($totalMs -le $totalGap) {
        [long]$avail = $totalMs
        [long]$gap   = if ($gaps -gt 0) { [math]::Max(50, [math]::Floor($totalMs / ($gaps + 1))) } else { 0 }
    }
    else {
        [long]$avail = $totalMs - $totalGap
        [long]$gap   = $GapMs
    }

    [long]$totalChars = ($chunks | ForEach-Object { $_.Length } | Measure-Object -Sum).Sum
    if ($totalChars -eq 0) { $totalChars = 1 }
    [long]$curStartMs = [long](ConvertTo-Milliseconds $Start)
    [long]$endMs      = [long](ConvertTo-Milliseconds $End)

    $result = @()
    for ($i = 0; $i -lt $chunks.Count; $i++) {
        $chunk = $chunks[$i]
        if ($i -lt ($chunks.Count - 1)) {
            [long]$dur = [math]::Floor(([double]$avail * [double]$chunk.Length) / [double]$totalChars)
            [long]$chunkEndMs = $curStartMs + $dur
        }
        else {
            [long]$chunkEndMs = $endMs
        }

        $result += @{
            Text  = $chunk
            Start = [TimeSpan]::FromMilliseconds([double]$curStartMs)
            End   = [TimeSpan]::FromMilliseconds([double]$chunkEndMs)
        }

        if ($i -lt ($chunks.Count - 1)) {
            [long]$curStartMs = $chunkEndMs + $gap
        }
    }
    return $result
}

function Parse-SrtFile {
    param([string]$Path)

    $content = Get-Content -Path $Path -Raw -Encoding UTF8
    # Use non-capturing group to avoid extra entries from -split
    $blocks = $content -split '(?:\r?\n){2,}'
    $subs   = @()

    foreach ($block in $blocks) {
        $block = $block.Trim()
        if ($block -eq "") { continue }

        $lines = $block -split "`n" | ForEach-Object { $_.Trim() }
        # Filter out empty lines
        $lines = @($lines | Where-Object { $_ -ne "" })
        if ($lines.Count -lt 3) { continue }

        # First line: index (must be a number)
        if ($lines[0] -notmatch '^\d+$') { continue }
        $index = [int]$lines[0]

        # Second line: timestamps
        if ($lines[1] -match '^(.+?)\s*-->\s*(.+)$') {
            $start = ConvertFrom-SrtTimestamp $Matches[1]
            $end   = ConvertFrom-SrtTimestamp $Matches[2]
        }
        else { continue }

        # Remaining lines: text content
        $text = ($lines[2..($lines.Count - 1)]) -join " "
        $text = $text.Trim()
        if ($text -eq "") { continue }

        $subs += @{
            Index = $index
            Start = $start
            End   = $end
            Text  = $text
        }
    }
    return $subs
}

function Write-SrtFile {
    param(
        [array]$Subtitles,
        [string]$Path
    )

    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Subtitles.Count; $i++) {
        $sub = $Subtitles[$i]
        [void]$sb.AppendLine(($i + 1).ToString())
        $startTs = ConvertTo-SrtTimestamp $sub.Start
        $endTs   = ConvertTo-SrtTimestamp $sub.End
        [void]$sb.AppendLine("$startTs --> $endTs")
        [void]$sb.AppendLine($sub.Text)
        [void]$sb.AppendLine("")
    }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), [System.Text.Encoding]::UTF8)
}

function Optimize-SrtFile {
    param(
        [string]$InputPath,
        [string]$OutputPath,
        [int]$MinChars       = $script:DEFAULT_MIN_CHARS,
        [int]$MaxChars       = $script:DEFAULT_MAX_CHARS,
        [int]$SubtitleGapMs  = $script:DEFAULT_SUBTITLE_GAP_MS
    )

    Write-Info "Post-procesare SRT: $(Split-Path $InputPath -Leaf)"

    $subs = Parse-SrtFile -Path $InputPath
    if ($subs.Count -eq 0) {
        Write-Warn "Fisierul SRT este gol sau invalid: $InputPath"
        Copy-Item -Path $InputPath -Destination $OutputPath -Force
        return
    }

    $merged   = @()
    $bufText  = ""
    $bufStart = $null

    for ($i = 0; $i -lt $subs.Count; $i++) {
        $sub   = $subs[$i]
        $clean = $sub.Text -replace "`n", " "
        $clean = $clean.Trim()
        if ($clean -eq "") { continue }

        if ($bufText -eq "") {
            $bufStart = $sub.Start
        }
        $bufText = ("$bufText $clean").Trim()

        $flush = (
            ($bufText.Length -ge $MinChars) -or
            ($i -eq $subs.Count - 1) -or
            ($bufText.Length -gt $MaxChars * 2)
        )

        if ($flush) {
            $endTime = $sub.End

            if ($bufText.Length -gt $MaxChars) {
                $parts = Split-TextWithTiming -Text $bufText -Start $bufStart -End $endTime `
                    -MaxChars $MaxChars -GapMs $SubtitleGapMs
                foreach ($part in $parts) {
                    $merged += @{
                        Index = $merged.Count + 1
                        Start = $part.Start
                        End   = $part.End
                        Text  = $part.Text.Trim()
                    }
                }
            }
            else {
                $merged += @{
                    Index = $merged.Count + 1
                    Start = $bufStart
                    End   = $endTime
                    Text  = $bufText
                }
            }
            $bufText  = ""
            $bufStart = $null
        }
    }

    # Re-index
    for ($i = 0; $i -lt $merged.Count; $i++) {
        $merged[$i].Index = $i + 1
    }

    Write-SrtFile -Subtitles $merged -Path $OutputPath
    Write-Success "Salvat $($merged.Count) subtitrari optimizate in $(Split-Path $OutputPath -Leaf)"
}

# ============================================================
# CORE PROCESSING
# ============================================================

function Convert-MediaToWav {
    param(
        [string]$InputFile,
        [string]$OutputWav
    )

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
    Write-Info "Conversie audio: $baseName -> WAV (16kHz mono)"

    try {
        $process = Start-Process -FilePath "ffmpeg" `
            -ArgumentList @("-y", "-i", $InputFile, "-ar", "16000", "-ac", "1", $OutputWav) `
            -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput "$env:TEMP\ffmpeg_out.tmp" `
            -RedirectStandardError "$env:TEMP\ffmpeg_err.tmp" 2>$null

        if ($process.ExitCode -ne 0) {
            $errContent = ""
            if (Test-Path "$env:TEMP\ffmpeg_err.tmp") {
                $errContent = Get-Content "$env:TEMP\ffmpeg_err.tmp" -Raw
            }
            Write-Err "FFmpeg a esuat pentru $baseName : $errContent"
            return $false
        }

        if (-not (Test-Path $OutputWav) -or (Get-Item $OutputWav).Length -eq 0) {
            Write-Err "Fisierul WAV nu a fost creat corect: $OutputWav"
            return $false
        }

        Write-Success "Conversie completata: $baseName"
        return $true
    }
    catch {
        Write-Err "Eroare FFmpeg: $_"
        return $false
    }
    finally {
        # Clean up temp files
        Remove-Item "$env:TEMP\ffmpeg_out.tmp" -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\ffmpeg_err.tmp" -ErrorAction SilentlyContinue
    }
}

function Invoke-WhisperTranscription {
    param(
        [string]$WavFile,
        [string]$OutputDir,
        [string]$ModelName,
        [string]$Language = "ro",
        [string]$Task = "transcribe"
    )

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($WavFile)
    $whisperModelName = $script:MODEL_MAPPING[$ModelName]
    if (-not $whisperModelName) { $whisperModelName = $ModelName }

    $taskDesc = if ($Task -eq "translate") { "Traducere (RO->EN)" } else { "Transcriere (RO)" }
    Write-Info "$taskDesc : $baseName (model: $whisperModelName)"

    $argList = @(
        $WavFile
        "--model", $whisperModelName
        "--language", $Language
        "--task", $Task
        "--output_format", "srt"
        "--output_dir", $OutputDir
    )

    try {
        if ($script:WhisperCommand -match " ") {
            # e.g., "python -m whisper"
            $parts = $script:WhisperCommand -split " ", 2
            $exe = $parts[0]
            $preArgs = $parts[1] -split " "
            $fullArgs = $preArgs + $argList
            $process = Start-Process -FilePath $exe -ArgumentList $fullArgs `
                -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput "$env:TEMP\whisper_out.tmp" `
                -RedirectStandardError "$env:TEMP\whisper_err.tmp" 2>$null
        }
        else {
            $process = Start-Process -FilePath $script:WhisperCommand -ArgumentList $argList `
                -NoNewWindow -Wait -PassThru `
                -RedirectStandardOutput "$env:TEMP\whisper_out.tmp" `
                -RedirectStandardError "$env:TEMP\whisper_err.tmp" 2>$null
        }

        $expectedSrt = Join-Path $OutputDir "$baseName.srt"
        if (Test-Path $expectedSrt) {
            Write-Success "$taskDesc completata: $baseName"
            return $expectedSrt
        }
        else {
            $errContent = ""
            if (Test-Path "$env:TEMP\whisper_err.tmp") {
                $errContent = Get-Content "$env:TEMP\whisper_err.tmp" -Raw -ErrorAction SilentlyContinue
            }
            Write-Err "Whisper nu a generat SRT pentru $baseName"
            if ($errContent -and $errContent.Length -gt 0) {
                Write-Err "Detalii: $($errContent.Substring(0, [math]::Min(500, $errContent.Length)))"
            }
            return $null
        }
    }
    catch {
        Write-Err "Eroare Whisper: $_"
        return $null
    }
    finally {
        Remove-Item "$env:TEMP\whisper_out.tmp" -ErrorAction SilentlyContinue
        Remove-Item "$env:TEMP\whisper_err.tmp" -ErrorAction SilentlyContinue
    }
}

function Process-SingleFile {
    param(
        [string]$InputFile,
        [string]$TempDir,
        [string]$ModelName,
        [string]$TranslateOption,
        [hashtable]$PostprocessConfig
    )

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
    $ext      = [System.IO.Path]::GetExtension($InputFile).ToLower()
    $wavFile  = Join-Path $TempDir "$baseName.wav"

    Write-Host ""
    Write-Separator
    Write-Host "  Procesare: " -NoNewline
    Write-Host "$baseName$ext" -ForegroundColor Yellow
    Write-Separator

    # Step 1: Convert to WAV
    $convOk = Convert-MediaToWav -InputFile $InputFile -OutputWav $wavFile
    if (-not $convOk) {
        return @{ Status = "failed"; File = $InputFile; Reason = "Conversie audio esuata" }
    }

    $results = @()

    # Step 2a: Transcribe (Romanian subtitles)
    if ($TranslateOption -eq "transcribe" -or $TranslateOption -eq "both") {
        $rawSrt = Invoke-WhisperTranscription -WavFile $wavFile -OutputDir $TempDir `
            -ModelName $ModelName -Language "ro" -Task "transcribe"

        if ($rawSrt -and (Test-Path $rawSrt)) {
            $finalSrt = Join-Path (Split-Path $InputFile -Parent) "$baseName.srt"
            try {
                Optimize-SrtFile -InputPath $rawSrt -OutputPath $finalSrt `
                    -MinChars $PostprocessConfig.min_chars `
                    -MaxChars $PostprocessConfig.max_chars `
                    -SubtitleGapMs $PostprocessConfig.subtitle_gap_ms
                $results += "RO: $finalSrt"
            }
            catch {
                Write-Warn "Post-procesare esuata, se copiaza SRT raw: $_"
                Copy-Item -Path $rawSrt -Destination $finalSrt -Force
                $results += "RO (raw): $finalSrt"
            }
            Remove-Item $rawSrt -ErrorAction SilentlyContinue
        }
        else {
            Remove-Item $wavFile -ErrorAction SilentlyContinue
            return @{ Status = "failed"; File = $InputFile; Reason = "Transcriere esuata" }
        }
    }

    # Step 2b: Translate to English
    if ($TranslateOption -eq "translate_only" -or $TranslateOption -eq "both") {
        $rawSrtEn = Invoke-WhisperTranscription -WavFile $wavFile -OutputDir $TempDir `
            -ModelName $ModelName -Language "ro" -Task "translate"

        if ($rawSrtEn -and (Test-Path $rawSrtEn)) {
            $finalSrtEn = Join-Path (Split-Path $InputFile -Parent) "${baseName}_EN.srt"
            try {
                Optimize-SrtFile -InputPath $rawSrtEn -OutputPath $finalSrtEn `
                    -MinChars $PostprocessConfig.min_chars `
                    -MaxChars $PostprocessConfig.max_chars `
                    -SubtitleGapMs $PostprocessConfig.subtitle_gap_ms
                $results += "EN: $finalSrtEn"
            }
            catch {
                Write-Warn "Post-procesare traducere esuata: $_"
                Copy-Item -Path $rawSrtEn -Destination $finalSrtEn -Force
                $results += "EN (raw): $finalSrtEn"
            }
            Remove-Item $rawSrtEn -ErrorAction SilentlyContinue
        }
        else {
            if ($TranslateOption -eq "translate_only") {
                Remove-Item $wavFile -ErrorAction SilentlyContinue
                return @{ Status = "failed"; File = $InputFile; Reason = "Traducere esuata" }
            }
            else {
                Write-Warn "Traducerea in engleza a esuat pentru $baseName"
            }
        }
    }

    # Cleanup
    Remove-Item $wavFile -ErrorAction SilentlyContinue

    $reasonText = $results -join " | "
    return @{ Status = "completed"; File = $InputFile; Reason = "Succes ($reasonText)" }
}

# ============================================================
# MAIN WORKFLOW
# ============================================================

function Start-Transcription {
    Show-Banner

    # Version flag
    if ($ShowVersion) {
        Write-Host "  Transcriber PowerShell $script:VERSION" -ForegroundColor Cyan
        return
    }

    # Init flag
    if ($Init) {
        $cfg = Get-DefaultConfig
        Save-ConfigYaml -Config $cfg -Path $ConfigFile
        Write-Success "Fisierul '$ConfigFile' a fost creat cu valori implicite."
        return
    }

    # Check dependencies
    if (-not (Test-Dependencies)) {
        Write-Host ""
        Write-Err "Dependente lipsa. Rezolva problemele de mai sus si reincearca."
        return
    }

    # Load config
    $config = Load-Config -Path $ConfigFile

    # Step 1: Select directory
    $workDir = Select-WorkingDirectory
    Write-Success "Director selectat: $workDir"

    # Find media files
    $mediaFiles = @()
    foreach ($ext in $script:SUPPORTED_EXTENSIONS) {
        $pattern = Join-Path $workDir "*$ext"
        $found = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue
        if ($found) {
            $mediaFiles += $found.FullName
        }
    }

    if ($mediaFiles.Count -eq 0) {
        Write-Host ""
        Write-Err "Nu s-au gasit fisiere media in directorul selectat."
        Write-Host "  Formate suportate: " -NoNewline
        Write-Host ($script:SUPPORTED_EXTENSIONS -join ", ") -ForegroundColor Yellow
        return
    }

    # Show found files
    Write-Host ""
    Show-FileList -Files $mediaFiles

    # Step 2: Select model
    $model = Select-WhisperModel
    Write-Success "Model selectat: $model"

    # Step 3: Translation option
    $translateOption = Select-TranslationOption
    Write-Success "Optiune selectata: $translateOption"

    # Step 4: Confirm
    if (-not (Confirm-Start -Model $model -TranslateOption $translateOption -FileCount $mediaFiles.Count)) {
        Write-Warn "Operatiune anulata de utilizator."
        return
    }

    # Setup temp directory
    $tempDir = Join-Path $workDir $config.temp_dir
    if (-not (Test-Path $tempDir)) {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }

    # Load recovery
    $recovery = Load-Recovery

    # Filter already completed
    $toProcess = @()
    foreach ($file in $mediaFiles) {
        $recoveryProp = $file -replace "\\", "/" # Normalize path for JSON
        $recoveryStatus = $null
        if ($recovery.PSObject.Properties.Name -contains $recoveryProp) {
            $recoveryStatus = $recovery.$recoveryProp
        }
        if ($recoveryStatus -ne "completed") {
            $toProcess += $file
        }
    }

    if ($toProcess.Count -eq 0) {
        Write-Success "Toate fisierele au fost deja procesate!"
        Write-Host "  Sterge '$($script:RECOVERY_FILE)' pentru a reprocesa." -ForegroundColor DarkGray
        return
    }

    if ($toProcess.Count -lt $mediaFiles.Count) {
        $skip = $mediaFiles.Count - $toProcess.Count
        Write-Info "Se sar $skip fisier(e) deja procesate. $($toProcess.Count) de procesat."
    }

    # Processing
    Write-Host ""
    Write-Host "  +==============================================================+" -ForegroundColor Green
    Write-Host "  |              PROCESARE IN CURS...                           |" -ForegroundColor Green
    Write-Host "  +==============================================================+" -ForegroundColor Green
    Write-Host ""

    $startTime = Get-Date
    $completed = 0
    $failed    = 0

    for ($idx = 0; $idx -lt $toProcess.Count; $idx++) {
        $file = $toProcess[$idx]
        Show-Progress -Current ($idx) -Total $toProcess.Count -FileName (Split-Path $file -Leaf)

        $result = Process-SingleFile -InputFile $file -TempDir $tempDir `
            -ModelName $model -TranslateOption $translateOption `
            -PostprocessConfig $config.postprocess

        if ($result.Status -eq "completed") {
            $completed++
            Write-Host ""
            Write-Host "  [OK] " -ForegroundColor Green -NoNewline
            Write-Host "Finalizat: $(Split-Path $result.File -Leaf)" -NoNewline
            Write-Host " ($($result.Reason))" -ForegroundColor DarkGray
        }
        else {
            $failed++
            Write-Host ""
            Write-Host "  [X] " -ForegroundColor Red -NoNewline
            Write-Host "Esuat: $(Split-Path $result.File -Leaf)" -NoNewline
            Write-Host " ($($result.Reason))" -ForegroundColor DarkGray
        }

        # Update recovery
        $recoveryProp = $file -replace "\\", "/"
        $recovery | Add-Member -NotePropertyName $recoveryProp -NotePropertyValue $result.Status -Force
        Save-Recovery -State $recovery

        Show-Progress -Current ($idx + 1) -Total $toProcess.Count -FileName ""
    }

    # Cleanup temp dir
    if (Test-Path $tempDir) {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Cleanup recovery if all succeeded
    if ($failed -eq 0 -and (Test-Path $script:RECOVERY_FILE)) {
        Remove-Item $script:RECOVERY_FILE -Force -ErrorAction SilentlyContinue
        Write-Info "Recovery file sters (toate fisierele procesate cu succes)."
    }

    # Summary
    $elapsed = (Get-Date) - $startTime
    $elapsedStr = "{0:hh\:mm\:ss}" -f $elapsed

    Write-Host ""
    Write-Host ""
    Write-Host "  +==============================================================+" -ForegroundColor Cyan
    Write-Host "  |                     REZUMAT PROCESARE                       |" -ForegroundColor Cyan
    Write-Host "  +==============================================================+" -ForegroundColor Cyan
    Write-Host "  |  Total fisiere:      " -ForegroundColor Cyan -NoNewline
    Write-Host ("{0,-38}" -f $toProcess.Count) -NoNewline
    Write-Host "|" -ForegroundColor Cyan
    Write-Host "  |  Finalizate:         " -ForegroundColor Cyan -NoNewline
    Write-Host ("{0,-38}" -f $completed) -ForegroundColor Green -NoNewline
    Write-Host "|" -ForegroundColor Cyan
    Write-Host "  |  Esuate:             " -ForegroundColor Cyan -NoNewline
    $failColor = if ($failed -gt 0) { "Red" } else { "Green" }
    Write-Host ("{0,-38}" -f $failed) -ForegroundColor $failColor -NoNewline
    Write-Host "|" -ForegroundColor Cyan
    Write-Host "  |  Durata:             " -ForegroundColor Cyan -NoNewline
    Write-Host ("{0,-38}" -f $elapsedStr) -ForegroundColor Yellow -NoNewline
    Write-Host "|" -ForegroundColor Cyan
    Write-Host "  +==============================================================+" -ForegroundColor Cyan
    Write-Host ""

    if ($completed -gt 0) {
        Write-Success "Fisierele .srt au fost salvate in directorul: $workDir"
    }
    Write-Host ""
}

# ============================================================
# ENTRY POINT
# ============================================================
Start-Transcription
