#!/usr/bin/env python3
# ==============================
# Versiune v39 – Afișare status proces
# ==============================

import os
import sys
import json
import time
import argparse
import yaml
import subprocess
import shutil
import multiprocessing
import warnings
import datetime
from multiprocessing import Queue

from pathlib import Path
from concurrent.futures import ProcessPoolExecutor, as_completed

# Importuri principale la nivel de modul, pentru a asigura scopul global
try:
    import whisper
    import srt
    from rich import print as rprint
    from rich.progress import Progress, BarColumn, TextColumn, TimeElapsedColumn
    from rich.live import Live
    from rich.table import Table
except ImportError as e:
    print(f"Eroare: O bibliotecă esențială lipsește. Detalii: {e}")
    sys.exit(1)

# Suprimă avertismentele specifice de la Whisper
warnings.filterwarnings("ignore", category=UserWarning, module="whisper")

# -------------------------------
# Versiune & fișiere
# -------------------------------
VERSION = "v39"
CONFIG_FILE = "config.yaml"
RECOVERY_FILE = "recovery.json"

# Coada globală pentru mesaje, creată în procesul principal
log_queue = None

# Funcția de inițializare pentru fiecare proces din ProcessPoolExecutor
def worker_initializer(queue):
    global log_queue
    log_queue = queue

# -------------------------------
# Verificare dependențe
# -------------------------------
def check_dependencies():
    missing = []
    if 'whisper' not in sys.modules:
        missing.append("whisper")
    if 'srt' not in sys.modules:
        missing.append("srt")
    if 'rich' not in sys.modules:
        missing.append("rich")

    if missing:
        rprint("[red]ERROR:[/] Următoarele biblioteci lipsesc. Instalează-le cu 'pip install [bold]nume_bibliotecă[/bold]'")
        for lib in missing:
            rprint(f" - {lib}")
        sys.exit(1)

    if not shutil.which("ffmpeg"):
        rprint("[red]ERROR:[/] Lipsă 'ffmpeg'. Instalează-l pentru conversie audio.[/red]")
        sys.exit(1)

# -------------------------------
# Config implicită
# -------------------------------
def get_default_config():
    return {
        "language": "ro",
        "model_type": "small",
        "max_parallel_jobs": 2,
        "temp_dir": "temp_transcription",
        "postprocess": {
            "min_chars": 80,
            "max_chars": 120,
            "subtitle_gap_ms": 100
        }
    }

# -------------------------------
# Load sau create config
# -------------------------------
def load_config():
    p = Path(CONFIG_FILE)
    if not p.exists():
        rprint(f"[yellow]Atenție:[/] '{CONFIG_FILE}' lipsește; se va crea un fișier implicit.")
        p.write_text(yaml.dump(get_default_config(), sort_keys=False), encoding="utf-8")
        sys.exit(0)
    
    try:
        cfg = yaml.safe_load(p.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError as e:
        rprint(f"[red]Eroare la parsarea '{CONFIG_FILE}': {e}[/red]")
        sys.exit(1)

    default_cfg = get_default_config()
    for k, v in default_cfg.items():
        if k not in cfg:
            cfg[k] = v
        elif isinstance(v, dict):
            for sub_k, sub_v in v.items():
                if sub_k not in cfg[k]:
                    cfg[k][sub_k] = sub_v
    
    return cfg

# -------------------------------
# Recovery I/O
# -------------------------------
def load_recovery():
    p = Path(RECOVERY_FILE)
    if p.exists():
        try:
            return json.loads(p.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, FileNotFoundError):
            rprint("[yellow]WARNING:[/] Recovery corupt; încep de la zero.")
    return {}

def save_recovery(state):
    try:
        Path(RECOVERY_FILE).write_text(
            json.dumps(state, indent=2, ensure_ascii=False),
            encoding="utf-8"
        )
    except Exception as e:
        rprint(f"[red]ERROR:[/] Nu pot salva recovery: {e}")

# -------------------------------
# Helpers post-procesare
# -------------------------------
def check_file_permissions(input_file, output_file):
    if not os.path.exists(input_file) or not os.access(input_file, os.R_OK):
        log_queue.put(f"[red]Eroare:[/] Nu se poate citi '{input_file}'")
        return False
    out_dir = os.path.dirname(output_file) or '.'
    if not os.access(out_dir, os.W_OK):
        log_queue.put(f"[red]Eroare:[/] Fără permisiuni de scriere în '{out_dir}'")
        return False
    if os.path.exists(output_file) and not os.access(output_file, os.W_OK):
        log_queue.put(f"[red]Eroare:[/] Fără permisiuni de scriere pentru '{output_file}'")
        return False
    return True

def split_custom(text, max_chars):
    length = len(text)
    if length <= max_chars:
        return [text]
    if 121 <= length < 150:
        pref = 70
    elif 150 <= length < 180:
        pref = 90
    else:
        pref = 100

    cuts = []
    for punct in ['. ', '! ', '? ']:
        pos = text.rfind(punct, 0, pref+10)
        if pos > pref-20:
            cuts.append((pos+len(punct), 'sentence'))
    for punct in [', ', '; ', ': ', ' - ', ' — ']:
        pos = text.rfind(punct, 0, pref+10)
        if pos > pref-15:
            cuts.append((pos+len(punct), 'punctuation'))
    pos = text.rfind(' ', 0, pref+5)
    if pos > pref-10:
        cuts.append((pos+1, 'space'))

    if cuts:
        cuts.sort(key=lambda x: (
            0 if x[1]=='sentence' else 1 if x[1]=='punctuation' else 2,
            abs(x[0]-pref)
        ))
        idx = cuts[0][0]
    else:
        idx = pref
        log_queue.put(f"[yellow]Atenție:[/] Tăiere forțată la {idx}")

    left, right = text[:idx].strip(), text[idx:].strip()
    return [left] + split_custom(right, max_chars)

def subrip_add_milliseconds(sr_time, ms):
    base = datetime.datetime(1900,1,1,
                             sr_time.hours,
                             sr_time.minutes,
                             sr_time.seconds,
                             sr_time.milliseconds*1000)
    new = base + datetime.timedelta(milliseconds=ms)
    return srt.SubtitleTime(new.hour, new.minute, new.second, new.microsecond//1000)

def split_text_with_timing(text, start, end, max_chars, subtitle_gap_ms):
    chunks = split_custom(text, max_chars)
    if len(chunks) == 1:
        return [(text, start, end)]

    total_ms = end.ordinal - start.ordinal
    gaps = len(chunks)-1
    gap_time = subtitle_gap_ms * gaps
    if total_ms <= gap_time:
        avail = total_ms
        gap = max(50, total_ms//(gaps+1)) if gaps>0 else 0
    else:
        avail = total_ms - gap_time
        gap = subtitle_gap_ms

    total_chars = sum(len(c) for c in chunks)
    current_start = start
    res = []

    for i, chunk in enumerate(chunks):
        if i < len(chunks)-1:
            dur = (avail * len(chunk)) // total_chars
            chunk_end = subrip_add_milliseconds(current_start, dur)
        else:
            chunk_end = end

        res.append((chunk, current_start, chunk_end))

        if i < len(chunks)-1:
            current_start = subrip_add_milliseconds(chunk_end, gap)

    return res

def advanced_srt_postprocess(raw_srt: Path, final_srt: Path, postprocess_cfg):
    if not check_file_permissions(str(raw_srt), str(final_srt)):
        raise PermissionError("Cannot access SRT files")

    log_queue.put(f"[blue]INFO:[/] Post-procesare SRT: {raw_srt.name}")
    text = raw_srt.read_text(encoding="utf-8")
    subs = list(srt.parse(text))
    merged = []
    buffer_text = ""
    buffer_start = None

    for i, sub in enumerate(subs):
        clean = sub.content.replace('\n',' ').strip()
        if not clean:
            continue

        if buffer_text == "":
            buffer_start = sub.start

        buffer_text = (buffer_text + " " + clean).strip()
        should_flush = (
            len(buffer_text) >= postprocess_cfg["min_chars"] or
            i == len(subs)-1 or
            len(buffer_text) > postprocess_cfg["max_chars"]*2
        )

        if should_flush:
            end_time = sub.end
            if len(buffer_text) > postprocess_cfg["max_chars"]:
                parts = split_text_with_timing(
                    buffer_text, buffer_start, end_time,
                    postprocess_cfg["max_chars"],
                    postprocess_cfg["subtitle_gap_ms"]
                )
                for txt, st, en in parts:
                    merged.append(srt.Subtitle(index=len(merged)+1,
                                                 start=st, end=en,
                                                 content=txt.strip()))
            else:
                merged.append(srt.Subtitle(index=len(merged)+1,
                                             start=buffer_start,
                                             end=end_time,
                                             content=buffer_text))
            buffer_text = ""
            buffer_start = None

    for idx, sub in enumerate(merged, start=1):
        sub.index = idx

    final_srt.write_text(srt.compose(merged), encoding="utf-8")
    log_queue.put(f"[green]Succes:[/] Am salvat {len(merged)} subtitrări în {final_srt.name}")

def process_single_file(mp3_file, tmp_dir, cfg, verbose):
    base = Path(mp3_file).stem
    wav = tmp_dir / f"{base}.wav"
    raw_srt = tmp_dir / f"{base}.srt"
    final_srt = Path(f"{base}.srt")

    # 1) Convert MP3 → WAV
    log_queue.put(f"[blue]INFO:[/] Conversie: {mp3_file} → WAV...")
    try:
        out = None if verbose else subprocess.DEVNULL
        subprocess.run(["ffmpeg","-y","-i", mp3_file, str(wav)],
                       stdout=out, stderr=out, check=True)
    except Exception as e:
        return {"status":"failed","file":mp3_file,"reason":f"FFmpeg: {e}"}

    # 2) Whisper API transcribe
    log_queue.put(f"[blue]INFO:[/] Transcriere: {mp3_file}...")
    try:
        model = whisper.load_model(cfg["model_type"])
        res = model.transcribe(str(wav), language=cfg["language"])
        subs = []
        for idx, seg in enumerate(res["segments"], start=1):
            st = datetime.timedelta(seconds=seg["start"])
            en = datetime.timedelta(seconds=seg["end"])
            subs.append(srt.Subtitle(idx, st, en, seg["text"].strip()))
        raw_srt.write_text(srt.compose(subs), encoding="utf-8")
    except Exception as e:
        wav.unlink(missing_ok=True)
        return {"status":"failed","file":mp3_file,"reason":f"Whisper API: {e}"}

    if not raw_srt.exists():
        wav.unlink(missing_ok=True)
        return {"status":"failed","file":mp3_file,"reason":"Raw .srt missing"}

    # 3) Post-procesare avansată
    log_queue.put(f"[blue]INFO:[/] Post-procesare: {raw_srt.name}...")
    try:
        advanced_srt_postprocess(raw_srt, final_srt, cfg["postprocess"])
    except Exception as e:
        raw_srt.replace(final_srt)
        wav.unlink(missing_ok=True)
        return {"status":"completed","file":mp3_file,
                "reason":f"Succes cu avertisment: postprocess error ({e})"}

    wav.unlink(missing_ok=True)
    return {"status":"completed","file":mp3_file,"reason":"Succes"}

def main():
    check_dependencies()
    
    parser = argparse.ArgumentParser(description="mp3-to-text v39")
    parser.add_argument("--force", action="store_true", help="Ignoră recovery și reprocesează tot")
    parser.add_argument("--version", action="store_true", help="Afișează versiunea")
    parser.add_argument("--init", action="store_true", help="Crează config.yaml și iese")
    parser.add_argument("--verbose","-v", action="store_true", help="Afișează log-uri detaliate")
    args = parser.parse_args()

    if args.version:
        rprint(f"mp3-to-text.py version {VERSION}")
        sys.exit(0)

    if args.init:
        if Path(CONFIG_FILE).exists():
            rprint(f"[yellow]'{CONFIG_FILE}' există deja.[/yellow]")
        else:
            Path(CONFIG_FILE).write_text(
                yaml.dump(get_default_config(), sort_keys=False),
                encoding="utf-8"
            )
            rprint(f"[green]'{CONFIG_FILE}' creat cu valorile implicite.[/green]")
        sys.exit(0)

    cfg = load_config()
    tmp = Path(cfg["temp_dir"]).resolve()
    tmp.mkdir(parents=True, exist_ok=True)

    recovery = {} if args.force else load_recovery()
    mp3s = sorted(Path(".").glob("*.mp3"))
    files = [f.name for f in mp3s]
    to_do = [f for f in files if recovery.get(f) != "completed"]

    if not files:
        rprint("[red]ERROR:[/] Niciun fișier MP3 găsit.")
        sys.exit(1)
    if not to_do:
        rprint("[green]SUCCESS:[/] Toate fișierele sunt deja procesate.")
        sys.exit(0)

    rprint(f"[blue]INFO:[/] {len(files)} găsite, {len(to_do)} de procesat. [bold]MODEL:[/] [bold cyan]{cfg['model_type'].upper()}[/bold cyan]")
    
    completed = failed = 0
    start = time.time()

    progress = Progress(
        TextColumn("[bold blue]Progres:[/]"),
        BarColumn(style="bright_blue", finished_style="green"),
        TextColumn("[progress.completed]/[progress.total]"),
        TextColumn("[bold]{task.percentage:>3.0f}%"),
        TimeElapsedColumn()
    )

    log_queue = Queue()

    with Live(progress, refresh_per_second=5):
        task = progress.add_task("Transcriere", total=len(to_do))
        with ProcessPoolExecutor(max_workers=cfg["max_parallel_jobs"],
                                 initializer=worker_initializer,
                                 initargs=(log_queue,)) as pool:
            futures = {
                pool.submit(
                    process_single_file,
                    mp3, tmp,
                    cfg,
                    args.verbose
                ): mp3
                for mp3 in to_do
            }
            for fut in as_completed(futures):
                while not log_queue.empty():
                    message = log_queue.get()
                    rprint(message)
                
                res = fut.result()
                progress.advance(task)
                name = res["file"]
                if res["status"] == "completed":
                    completed += 1
                    rprint(f"[green]✓ Finalizat:[/] {name} ({res['reason']})")
                else:
                    failed += 1
                    rprint(f"[red]✗ Eșuat:[/] {name} ({res['reason']})")
                recovery[name] = res["status"]
                save_recovery(recovery)

    elapsed = time.time() - start
    rprint(f"[blue]INFO:[/] Procesare completă în {elapsed:.2f}s")

    table = Table(title="Rezumat")
    table.add_column("Total", style="cyan")
    table.add_column("Finalizate", style="green")
    table.add_column("Eșuate", style="red")
    table.add_column("Durată", style="yellow")
    table.add_row(str(len(files)), str(completed), str(failed), f"{elapsed:.2f}s")
    rprint(table)

    if failed == 0 and Path(RECOVERY_FILE).exists():
        Path(RECOVERY_FILE).unlink()
        rprint("[blue]INFO:[/] Recovery file șters.")

if __name__ == "__main__":
    multiprocessing.freeze_support()
    main()