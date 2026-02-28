<#
.SYNOPSIS
    Transcriber PowerShell - Audio/Video to SRT subtitle generator
.DESCRIPTION
    Transcribes audio and video files to SRT subtitles using OpenAI Whisper.
    Supports: .mp3, .mp4, .mov, .mkv, .avi, .wmv
    Features: model selection, Romanian-to-English translation, SRT optimization.
    GUI mode using Windows Forms.
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
# LOG BUFFER
# ============================================================
$script:LogBuffer = [System.Collections.ArrayList]::new()

function Add-LogMessage {
    param([string]$Message)
    $ts = (Get-Date).ToString("HH:mm:ss")
    [void]$script:LogBuffer.Add("[$ts] $Message")
}

# ============================================================
# DEPENDENCY CHECKS
# ============================================================

function Test-Dependencies {
    Add-LogMessage "Verificare dependente (Checking dependencies)..."

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
        Add-LogMessage "[ERR] Python 3 nu a fost gasit. Instaleaza Python 3.8+ de la https://python.org"
        return $false
    }
    Add-LogMessage "[OK] Python: $( & $pythonCmd --version 2>&1 )"
    $script:PythonCommand = $pythonCmd

    # Check whisper CLI
    $script:WhisperExe = $null
    $script:WhisperArgs = @()

    # Method 1: Try whisper directly in PATH
    foreach ($cmd in @("whisper", "whisper.exe")) {
        try {
            $result = & $cmd --help 2>&1
            if ($?) {
                $script:WhisperExe = $cmd
                Add-LogMessage "[OK] Whisper gasit in PATH: $cmd"
                break
            }
        }
        catch { }
    }

    # Method 2: Try python -m whisper
    if (-not $script:WhisperExe) {
        try {
            $result = & $pythonCmd -m whisper --help 2>&1
            if ($?) {
                $script:WhisperExe = $pythonCmd
                $script:WhisperArgs = @("-m", "whisper")
                Add-LogMessage "[OK] Whisper disponibil ca: $pythonCmd -m whisper"
            }
        }
        catch { }
    }

    # Method 3: Search Python Scripts directories
    if (-not $script:WhisperExe) {
        Add-LogMessage "[INFO] Cautare whisper in directoarele Scripts Python..."
        try {
            $pyFinderPath = Join-Path $env:TEMP "transcriber_find_scripts.py"
            $pyLines = @(
                "import sys, os, sysconfig, site",
                "dirs = []",
                "dirs.append(os.path.join(os.path.dirname(sys.executable), 'Scripts'))",
                "dirs.append(sysconfig.get_path('scripts'))",
                "try:",
                "    usp = site.getusersitepackages()",
                "    if usp:",
                "        dirs.append(os.path.join(os.path.dirname(usp), 'Scripts'))",
                "except Exception:",
                "    pass",
                "seen = set()",
                "for d in dirs:",
                "    if d and os.path.isdir(d) and d not in seen:",
                "        seen.add(d)",
                "        print(d)"
            )
            [System.IO.File]::WriteAllText($pyFinderPath, ($pyLines -join [Environment]::NewLine))
            $scriptDirs = & $pythonCmd $pyFinderPath 2>&1
            Remove-Item $pyFinderPath -ErrorAction SilentlyContinue

            if ($scriptDirs) {
                foreach ($dir in $scriptDirs) {
                    $dir = "$dir".Trim()
                    if ($dir -eq "") { continue }
                    $whisperExePath = Join-Path $dir "whisper.exe"
                    if (Test-Path $whisperExePath) {
                        $script:WhisperExe = $whisperExePath
                        Add-LogMessage "[OK] Whisper gasit in Scripts: $dir"
                        break
                    }
                    $whisperNoExt = Join-Path $dir "whisper"
                    if (Test-Path $whisperNoExt) {
                        $script:WhisperExe = $whisperNoExt
                        Add-LogMessage "[OK] Whisper gasit in Scripts: $dir"
                        break
                    }
                }
            }
        }
        catch {
            Add-LogMessage "[WARN] Eroare la cautarea in Scripts: $_"
        }
    }

    # Method 4: Fallback - create whisper_runner.py wrapper
    if (-not $script:WhisperExe) {
        Add-LogMessage "[INFO] Se incearca fallback cu whisper_runner.py..."
        try {
            $importCheck = & $pythonCmd -c "import whisper" 2>&1
            if ($?) {
                $runnerPath = Join-Path $env:TEMP "whisper_runner.py"
                $runnerLines = @(
                    "from whisper.cli import cli",
                    "cli()"
                )
                [System.IO.File]::WriteAllText($runnerPath, ($runnerLines -join [Environment]::NewLine))
                $script:WhisperExe = $pythonCmd
                $script:WhisperArgs = @("`"$runnerPath`"")
                Add-LogMessage "[OK] Whisper runner creat: $runnerPath"
            }
        }
        catch { }
    }

    if (-not $script:WhisperExe) {
        Add-LogMessage "[ERR] Whisper nu a fost gasit. Instaleaza cu: pip install openai-whisper"
        return $false
    }
    Add-LogMessage "[OK] Whisper CLI: disponibil"

    # Check ffmpeg
    try {
        $result = & ffmpeg -version 2>&1
        if ($LASTEXITCODE -ne 0 -and -not ($result -match "ffmpeg version")) {
            throw "ffmpeg not found"
        }
        $versionLine = ($result | Select-Object -First 1)
        Add-LogMessage "[OK] FFmpeg: $versionLine"
    }
    catch {
        Add-LogMessage "[ERR] FFmpeg nu a fost gasit. Instaleaza FFmpeg de la https://ffmpeg.org"
        return $false
    }

    Add-LogMessage "[OK] Toate dependentele sunt disponibile!"
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
        Add-LogMessage "[WARN] Fisierul '$Path' nu exista. Se creeaza cu valori implicite."
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
        foreach ($subKey in $default.postprocess.Keys) {
            if (-not $cfg.postprocess.ContainsKey($subKey)) {
                $cfg.postprocess[$subKey] = $default.postprocess[$subKey]
            }
        }
        return $cfg
    }
    catch {
        Add-LogMessage "[WARN] Eroare la citirea configurarii: $($_.Exception.Message)"
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
        Add-LogMessage "[ERR] Nu pot salva recovery: $_"
    }
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

    Add-LogMessage "Post-procesare SRT: $(Split-Path $InputPath -Leaf)"

    $subs = Parse-SrtFile -Path $InputPath
    if ($subs.Count -eq 0) {
        Add-LogMessage "[WARN] Fisierul SRT este gol sau invalid: $InputPath"
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
    Add-LogMessage "[OK] Salvat $($merged.Count) subtitrari optimizate in $(Split-Path $OutputPath -Leaf)"
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
    Add-LogMessage "Conversie audio: $baseName -> WAV (16kHz mono)"

    $outTmp = $null
    $errTmp = $null
    try {
        $outTmp = Join-Path $env:TEMP "ffmpeg_out_$([System.IO.Path]::GetRandomFileName()).tmp"
        $errTmp = Join-Path $env:TEMP "ffmpeg_err_$([System.IO.Path]::GetRandomFileName()).tmp"

        $proc = Start-Process -FilePath "ffmpeg" `
            -ArgumentList @("-y", "-i", "`"$InputFile`"", "-ar", "16000", "-ac", "1", "`"$OutputWav`"") `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $outTmp `
            -RedirectStandardError $errTmp 2>$null

        while (-not $proc.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }

        if ($proc.ExitCode -ne 0) {
            $errContent = ""
            if (Test-Path $errTmp) {
                $errContent = Get-Content $errTmp -Raw -ErrorAction SilentlyContinue
            }
            Add-LogMessage "[ERR] FFmpeg a esuat pentru $baseName : $errContent"
            return $false
        }

        if (-not (Test-Path $OutputWav) -or (Get-Item $OutputWav).Length -eq 0) {
            Add-LogMessage "[ERR] Fisierul WAV nu a fost creat corect: $OutputWav"
            return $false
        }

        Add-LogMessage "[OK] Conversie completata: $baseName"
        return $true
    }
    catch {
        Add-LogMessage "[ERR] Eroare FFmpeg: $_"
        return $false
    }
    finally {
        if ($outTmp) { Remove-Item $outTmp -ErrorAction SilentlyContinue }
        if ($errTmp) { Remove-Item $errTmp -ErrorAction SilentlyContinue }
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
    Add-LogMessage "$taskDesc : $baseName (model: $whisperModelName)"

    $argList = @(
        "`"$WavFile`""
        "--model", $whisperModelName
        "--language", $Language
        "--task", $Task
        "--output_format", "srt"
        "--output_dir", "`"$OutputDir`""
    )

    $outTmp = $null
    $errTmp = $null
    try {
        $outTmp = Join-Path $env:TEMP "whisper_out_$([System.IO.Path]::GetRandomFileName()).tmp"
        $errTmp = Join-Path $env:TEMP "whisper_err_$([System.IO.Path]::GetRandomFileName()).tmp"

        $fullArgs = $script:WhisperArgs + $argList
        $proc = Start-Process -FilePath $script:WhisperExe -ArgumentList $fullArgs `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $outTmp `
            -RedirectStandardError $errTmp 2>$null

        while (-not $proc.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }

        $expectedSrt = Join-Path $OutputDir "$baseName.srt"
        if (Test-Path $expectedSrt) {
            Add-LogMessage "[OK] $taskDesc completata: $baseName"
            return $expectedSrt
        }
        else {
            $errContent = ""
            if (Test-Path $errTmp) {
                $errContent = Get-Content $errTmp -Raw -ErrorAction SilentlyContinue
            }
            Add-LogMessage "[ERR] Whisper nu a generat SRT pentru $baseName"
            if ($errContent -and $errContent.Length -gt 0) {
                $snippet = $errContent.Substring(0, [math]::Min(500, $errContent.Length))
                Add-LogMessage "[ERR] Detalii: $snippet"
            }
            return $null
        }
    }
    catch {
        Add-LogMessage "[ERR] Eroare Whisper: $_"
        return $null
    }
    finally {
        if ($outTmp) { Remove-Item $outTmp -ErrorAction SilentlyContinue }
        if ($errTmp) { Remove-Item $errTmp -ErrorAction SilentlyContinue }
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

    Add-LogMessage "--- Procesare: $baseName$ext ---"

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
                Add-LogMessage "[WARN] Post-procesare esuata, se copiaza SRT raw: $_"
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
                Add-LogMessage "[WARN] Post-procesare traducere esuata: $_"
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
                Add-LogMessage "[WARN] Traducerea in engleza a esuat pentru $baseName"
            }
        }
    }

    # Cleanup
    Remove-Item $wavFile -ErrorAction SilentlyContinue

    $reasonText = $results -join " | "
    return @{ Status = "completed"; File = $InputFile; Reason = "Succes ($reasonText)" }
}

# ============================================================
# GUI
# ============================================================

function Show-MainForm {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    [System.Windows.Forms.Application]::EnableVisualStyles()

    # --- Main Form ---
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Transcriber PowerShell $script:VERSION"
    $form.Size = New-Object System.Drawing.Size(870, 820)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedSingle"
    $form.MaximizeBox = $false

    # --- Title Label ---
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "TRANSCRIBER PowerShell $script:VERSION - Audio & Video -> Subtitles (.srt)"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = [System.Drawing.Color]::DarkCyan
    $lblTitle.AutoSize = $true
    $lblTitle.Location = New-Object System.Drawing.Point(15, 12)
    $form.Controls.Add($lblTitle)

    # --- Configuration GroupBox ---
    $grpConfig = New-Object System.Windows.Forms.GroupBox
    $grpConfig.Text = "Configurare"
    $grpConfig.Location = New-Object System.Drawing.Point(15, 48)
    $grpConfig.Size = New-Object System.Drawing.Size(822, 155)
    $form.Controls.Add($grpConfig)

    # Directory row
    $lblDir = New-Object System.Windows.Forms.Label
    $lblDir.Text = "Director:"
    $lblDir.Location = New-Object System.Drawing.Point(12, 28)
    $lblDir.AutoSize = $true
    $grpConfig.Controls.Add($lblDir)

    $txtDir = New-Object System.Windows.Forms.TextBox
    $txtDir.Location = New-Object System.Drawing.Point(90, 25)
    $txtDir.Size = New-Object System.Drawing.Size(610, 22)
    $txtDir.Text = (Get-Location).Path
    $grpConfig.Controls.Add($txtDir)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = "Alege..."
    $btnBrowse.Location = New-Object System.Drawing.Point(710, 23)
    $btnBrowse.Size = New-Object System.Drawing.Size(100, 26)
    $grpConfig.Controls.Add($btnBrowse)

    $btnBrowse.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "Selecteaza directorul cu fisiere media"
        $fbd.SelectedPath = $txtDir.Text
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtDir.Text = $fbd.SelectedPath
        }
    })

    # Model row
    $lblModel = New-Object System.Windows.Forms.Label
    $lblModel.Text = "Model Whisper:"
    $lblModel.Location = New-Object System.Drawing.Point(12, 63)
    $lblModel.AutoSize = $true
    $grpConfig.Controls.Add($lblModel)

    $cmbModel = New-Object System.Windows.Forms.ComboBox
    $cmbModel.DropDownStyle = "DropDownList"
    $cmbModel.Location = New-Object System.Drawing.Point(120, 60)
    $cmbModel.Size = New-Object System.Drawing.Size(180, 22)
    foreach ($m in $script:MODEL_LIST) {
        [void]$cmbModel.Items.Add($m)
    }
    $cmbModel.SelectedItem = "small"
    $grpConfig.Controls.Add($cmbModel)

    # Action row
    $lblAction = New-Object System.Windows.Forms.Label
    $lblAction.Text = "Actiune:"
    $lblAction.Location = New-Object System.Drawing.Point(340, 63)
    $lblAction.AutoSize = $true
    $grpConfig.Controls.Add($lblAction)

    $cmbAction = New-Object System.Windows.Forms.ComboBox
    $cmbAction.DropDownStyle = "DropDownList"
    $cmbAction.Location = New-Object System.Drawing.Point(410, 60)
    $cmbAction.Size = New-Object System.Drawing.Size(250, 22)
    [void]$cmbAction.Items.Add("Doar transcriere (RO)")
    [void]$cmbAction.Items.Add("Transcriere RO + Traducere EN")
    [void]$cmbAction.Items.Add("Doar traducere EN")
    $cmbAction.SelectedIndex = 0
    $grpConfig.Controls.Add($cmbAction)

    # Scan button
    $btnScan = New-Object System.Windows.Forms.Button
    $btnScan.Text = "Scaneaza Fisiere"
    $btnScan.Location = New-Object System.Drawing.Point(12, 100)
    $btnScan.Size = New-Object System.Drawing.Size(150, 30)
    $grpConfig.Controls.Add($btnScan)

    # --- Found Files GroupBox ---
    $grpFiles = New-Object System.Windows.Forms.GroupBox
    $grpFiles.Text = "Fisiere gasite"
    $grpFiles.Location = New-Object System.Drawing.Point(15, 210)
    $grpFiles.Size = New-Object System.Drawing.Size(822, 170)
    $form.Controls.Add($grpFiles)

    $lstFiles = New-Object System.Windows.Forms.ListBox
    $lstFiles.Location = New-Object System.Drawing.Point(12, 20)
    $lstFiles.Size = New-Object System.Drawing.Size(798, 140)
    $lstFiles.HorizontalScrollbar = $true
    $grpFiles.Controls.Add($lstFiles)

    # --- Buttons Row ---
    $btnStart = New-Object System.Windows.Forms.Button
    $btnStart.Text = "Start Transcriere"
    $btnStart.Location = New-Object System.Drawing.Point(15, 390)
    $btnStart.Size = New-Object System.Drawing.Size(150, 35)
    $btnStart.Enabled = $false
    $form.Controls.Add($btnStart)

    $btnExit = New-Object System.Windows.Forms.Button
    $btnExit.Text = "Iesire"
    $btnExit.Location = New-Object System.Drawing.Point(737, 390)
    $btnExit.Size = New-Object System.Drawing.Size(100, 35)
    $form.Controls.Add($btnExit)

    $btnExit.Add_Click({ $form.Close() })

    # --- Progress ---
    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(15, 435)
    $progressBar.Size = New-Object System.Drawing.Size(700, 22)
    $progressBar.Minimum = 0
    $progressBar.Maximum = 100
    $progressBar.Value = 0
    $form.Controls.Add($progressBar)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Gata."
    $lblStatus.Location = New-Object System.Drawing.Point(722, 437)
    $lblStatus.Size = New-Object System.Drawing.Size(115, 20)
    $lblStatus.AutoSize = $false
    $form.Controls.Add($lblStatus)

    # --- Log GroupBox ---
    $grpLog = New-Object System.Windows.Forms.GroupBox
    $grpLog.Text = "Jurnal"
    $grpLog.Location = New-Object System.Drawing.Point(15, 465)
    $grpLog.Size = New-Object System.Drawing.Size(822, 300)
    $form.Controls.Add($grpLog)

    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Multiline = $true
    $txtLog.ReadOnly = $true
    $txtLog.ScrollBars = "Both"
    $txtLog.WordWrap = $false
    $txtLog.Location = New-Object System.Drawing.Point(12, 20)
    $txtLog.Size = New-Object System.Drawing.Size(798, 270)
    $txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
    $grpLog.Controls.Add($txtLog)

    # --- Timer for log buffer ---
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.Add_Tick({
        if ($script:LogBuffer.Count -gt 0) {
            $snapshot = $script:LogBuffer.ToArray()
            $script:LogBuffer.Clear()
            foreach ($line in $snapshot) {
                $txtLog.AppendText("$line`r`n")
            }
        }
    })
    $timer.Start()

    # --- Scan logic ---
    $script:MediaFiles = @()

    $btnScan.Add_Click({
        $lstFiles.Items.Clear()
        $script:MediaFiles = @()
        $dir = $txtDir.Text
        if (-not (Test-Path $dir -PathType Container)) {
            [System.Windows.Forms.MessageBox]::Show(
                "Directorul nu exista: $dir",
                "Eroare",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
            return
        }
        Add-LogMessage "Scanare director: $dir"
        foreach ($ext in $script:SUPPORTED_EXTENSIONS) {
            $pattern = Join-Path $dir "*$ext"
            $found = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue
            if ($found) {
                $script:MediaFiles += $found.FullName
            }
        }
        if ($script:MediaFiles.Count -eq 0) {
            Add-LogMessage "[WARN] Nu s-au gasit fisiere media."
            $btnStart.Enabled = $false
            [System.Windows.Forms.MessageBox]::Show(
                "Nu s-au gasit fisiere media in directorul selectat.`nFormate: $($script:SUPPORTED_EXTENSIONS -join ', ')",
                "Niciun fisier",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            return
        }
        foreach ($f in $script:MediaFiles) {
            $fName = [System.IO.Path]::GetFileName($f)
            $fExt  = [System.IO.Path]::GetExtension($f).ToLower()
            $sz = 0
            try { $sz = (Get-Item $f).Length / 1MB } catch { Add-LogMessage "[WARN] Nu pot citi marimea: $f" }
            $sizeStr = "{0:N1} MB" -f $sz
            $tag = if ($fExt -in $script:SUPPORTED_VIDEO_EXTENSIONS) { "[V]" } else { "[A]" }
            [void]$lstFiles.Items.Add("$tag $fName ($sizeStr)")
        }
        Add-LogMessage "[OK] Gasite $($script:MediaFiles.Count) fisier(e)."
        $btnStart.Enabled = $true
    })

    # --- Start transcription logic ---
    $btnStart.Add_Click({
        # Disable controls during processing
        $btnStart.Enabled  = $false
        $btnScan.Enabled   = $false
        $cmbModel.Enabled  = $false
        $cmbAction.Enabled = $false
        $txtDir.Enabled    = $false
        $btnBrowse.Enabled = $false
        $progressBar.Value = 0

        $model = $cmbModel.SelectedItem.ToString()
        $actionIdx = $cmbAction.SelectedIndex
        $translateOption = switch ($actionIdx) {
            0 { "transcribe" }
            1 { "both" }
            2 { "translate_only" }
            default { "transcribe" }
        }

        Add-LogMessage "=== Start transcriere ==="
        Add-LogMessage "Model: $model | Actiune: $($cmbAction.SelectedItem) | Fisiere: $($script:MediaFiles.Count)"

        # Check dependencies
        $lblStatus.Text = "Verificare..."
        [System.Windows.Forms.Application]::DoEvents()

        if (-not (Test-Dependencies)) {
            [System.Windows.Forms.MessageBox]::Show(
                "Dependente lipsa. Verificati jurnalul.",
                "Eroare dependente",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
            $btnStart.Enabled  = $true
            $btnScan.Enabled   = $true
            $cmbModel.Enabled  = $true
            $cmbAction.Enabled = $true
            $txtDir.Enabled    = $true
            $btnBrowse.Enabled = $true
            $lblStatus.Text    = "Eroare."
            return
        }

        $config  = Load-Config -Path $ConfigFile
        $workDir = $txtDir.Text
        $tempDir = Join-Path $workDir $config.temp_dir
        if (-not (Test-Path $tempDir)) {
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        }

        # Load recovery state
        $recovery  = Load-Recovery
        $toProcess = @()
        foreach ($file in $script:MediaFiles) {
            $recoveryProp = $file -replace "\\", "/"
            $recoveryStatus = $null
            if ($recovery.PSObject.Properties.Name -contains $recoveryProp) {
                $recoveryStatus = $recovery.$recoveryProp
            }
            if ($recoveryStatus -ne "completed") {
                $toProcess += $file
            }
        }

        if ($toProcess.Count -eq 0) {
            Add-LogMessage "[OK] Toate fisierele au fost deja procesate!"
            Add-LogMessage "Sterge '$($script:RECOVERY_FILE)' pentru a reprocesa."
            $lblStatus.Text    = "Finalizat."
            $btnStart.Enabled  = $true
            $btnScan.Enabled   = $true
            $cmbModel.Enabled  = $true
            $cmbAction.Enabled = $true
            $txtDir.Enabled    = $true
            $btnBrowse.Enabled = $true
            return
        }

        if ($toProcess.Count -lt $script:MediaFiles.Count) {
            $skip = $script:MediaFiles.Count - $toProcess.Count
            Add-LogMessage "[INFO] Se sar $skip fisier(e) deja procesate."
        }

        $progressBar.Maximum = $toProcess.Count
        $progressBar.Value   = 0

        $startTime = Get-Date
        $completed = 0
        $failed    = 0

        for ($idx = 0; $idx -lt $toProcess.Count; $idx++) {
            $file  = $toProcess[$idx]
            $fname = Split-Path $file -Leaf
            $lblStatus.Text = "$($idx + 1)/$($toProcess.Count)"
            [System.Windows.Forms.Application]::DoEvents()

            $result = Process-SingleFile -InputFile $file -TempDir $tempDir `
                -ModelName $model -TranslateOption $translateOption `
                -PostprocessConfig $config.postprocess

            if ($result.Status -eq "completed") {
                $completed++
                Add-LogMessage "[OK] Finalizat: $fname ($($result.Reason))"
            }
            else {
                $failed++
                Add-LogMessage "[ERR] Esuat: $fname ($($result.Reason))"
            }

            # Update recovery
            $recoveryProp = $file -replace "\\", "/"
            $recovery | Add-Member -NotePropertyName $recoveryProp -NotePropertyValue $result.Status -Force
            Save-Recovery -State $recovery

            $progressBar.Value = $idx + 1
            [System.Windows.Forms.Application]::DoEvents()
        }

        # Cleanup temp dir
        if (Test-Path $tempDir) {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Cleanup recovery if all succeeded
        if ($failed -eq 0 -and (Test-Path $script:RECOVERY_FILE)) {
            Remove-Item $script:RECOVERY_FILE -Force -ErrorAction SilentlyContinue
            Add-LogMessage "[INFO] Recovery file sters (toate procesate cu succes)."
        }

        # Summary
        $elapsed    = (Get-Date) - $startTime
        $elapsedStr = "{0:hh\:mm\:ss}" -f $elapsed

        Add-LogMessage "=== REZUMAT ==="
        Add-LogMessage "Total: $($toProcess.Count) | Finalizate: $completed | Esuate: $failed | Durata: $elapsedStr"
        if ($completed -gt 0) {
            Add-LogMessage "[OK] Fisierele .srt au fost salvate in: $workDir"
        }

        $lblStatus.Text    = "Finalizat."
        $btnStart.Enabled  = $true
        $btnScan.Enabled   = $true
        $cmbModel.Enabled  = $true
        $cmbAction.Enabled = $true
        $txtDir.Enabled    = $true
        $btnBrowse.Enabled = $true

        [System.Windows.Forms.MessageBox]::Show(
            "Procesare completa!`nFinalizate: $completed`nEsuate: $failed`nDurata: $elapsedStr",
            "Rezumat",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
    })

    # Show form
    [void]$form.ShowDialog()
    $timer.Stop()
    $timer.Dispose()
    $form.Dispose()
}

# ============================================================
# ENTRY POINT
# ============================================================

if ($ShowVersion) {
    Write-Host "Transcriber PowerShell $script:VERSION"
}
elseif ($Init) {
    $cfg = Get-DefaultConfig
    Save-ConfigYaml -Config $cfg -Path $ConfigFile
    Write-Host "[OK] Fisierul '$ConfigFile' a fost creat cu valori implicite."
}
else {
    Show-MainForm
}
