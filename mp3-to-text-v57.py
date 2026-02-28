#!/usr/bin/env python3

import os
import sys
import json
import yaml
import subprocess
import shutil
import datetime
import threading
import warnings
import logging
import time

from pathlib import Path
from multiprocessing import Queue
from typing import Callable, Dict, Optional, Any, List

# GUI imports
import tkinter as tk
from tkinter import filedialog, ttk
from tkinter.scrolledtext import ScrolledText

# Core dependencies
try:
    import whisper
    import srt
    from rich import print as rprint
except ImportError as e:
    print(f"Eroare: lipsește o bibliotecă esențială: {e}")
    sys.exit(1)

# Suppress whisper warnings
warnings.filterwarnings(
    "ignore",
    message="FP16 is not supported on CPU",
    category=UserWarning,
    module="whisper.transcribe"
)

VERSION = "v57"
CONFIG_FILE = "config.yaml"
RECOVERY_FILE = "recovery.json"

log_queue: Optional[Queue] = None

# ----- Model Mapping (central) -----
MODEL_MAPPING = {
    "tiny": "tiny",
    "base": "base",
    "small": "small",
    "medium": "medium",
    "large-v1": "large-v1",
    "large-v2": "large-v2",
    "large-v3": "large-v3",
    "large-v3-turbo": "turbo"
}
VALID_LANGUAGES = ["ro","en","fr","de","ru","es","it","pt","pl","nl"]

# ----- Logging Setup -----
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)]
)
logger = logging.getLogger(__name__)

def log_msg(msg: str):
    """Log to queue if available, else to logger."""
    if log_queue is not None:
        log_queue.put(msg)
    else:
        logger.info(msg)

# ----- Config & Recovery -----
def get_default_config() -> Dict[str, Any]:
    return {
        "language": "ro",
        "model_type": "small",
        "max_parallel_jobs": 1,
        "temp_dir": "temp_transcription",
        "postprocess": {
            "min_chars":       80,
            "max_chars":      120,
            "subtitle_gap_ms": 100
        }
    }

def validate_config(cfg: Dict[str, Any]) -> Dict[str, Any]:
    default = get_default_config()
    for k, v in default.items():
        if k not in cfg or cfg[k] is None:
            cfg[k] = v
        elif isinstance(v, dict):
            for sk, sv in v.items():
                cfg[k].setdefault(sk, sv)
    # Validate language and model_type
    if cfg["language"] not in VALID_LANGUAGES:
        log_msg(f"[yellow]Atenție: Limba invalidă '{cfg['language']}', resetat la 'ro'")
        cfg["language"] = "ro"
    if cfg["model_type"] not in MODEL_MAPPING:
        log_msg(f"[yellow]Atenție: Model invalid '{cfg['model_type']}', resetat la 'small'")
        cfg["model_type"] = "small"
    return cfg

def load_config() -> Dict[str, Any]:
    p = Path(CONFIG_FILE)
    if not p.exists():
        p.write_text(yaml.dump(get_default_config(), sort_keys=False), encoding="utf-8")
        return get_default_config()
    try:
        cfg = yaml.safe_load(p.read_text(encoding="utf-8")) or {}
    except yaml.YAMLError as e:
        rprint(f"[red]Eroare la parsarea '{CONFIG_FILE}': {e}")
        sys.exit(1)
    return validate_config(cfg)

def load_recovery() -> Dict[str, str]:
    p = Path(RECOVERY_FILE)
    if p.exists():
        try:
            return json.loads(p.read_text(encoding="utf-8"))
        except:
            return {}
    return {}

def save_recovery(state: Dict[str, str]):
    try:
        Path(RECOVERY_FILE).write_text(
            json.dumps(state, indent=2, ensure_ascii=False),
            encoding="utf-8"
        )
    except Exception as e:
        log_msg(f"[red]ERROR:[/] Nu pot salva recovery: {e}")

# ----- Whisper Model Cache -----
def get_whisper_cache_dir() -> Path:
    return Path.home() / ".cache" / "whisper"

def clean_corrupted_models(log_cb: Callable[[str], None]):
    cache_dir = get_whisper_cache_dir()
    if not cache_dir.exists():
        return
    for model_file in cache_dir.glob("*.pt"):
        if model_file.stat().st_size == 0:
            log_cb(f"[yellow]WARNING:[/] Șterge model corupt: {model_file.name}")
            try:
                model_file.unlink()
            except Exception as e:
                log_cb(f"[red]ERROR:[/] Nu pot șterge {model_file.name}: {e}")

def download_model_robust(model_type: str, log_cb: Callable[[str], None], max_retries: int = 3) -> Optional[str]:
    if model_type not in MODEL_MAPPING:
        valid_models = list(MODEL_MAPPING.keys())
        log_cb(f"[red]Eroare:[/] Model invalid '{model_type}'. Disponibile: {valid_models}")
        return None
    whisper_model_name = MODEL_MAPPING[model_type]
    clean_corrupted_models(log_cb)
    cache_dir = get_whisper_cache_dir()
    possible_files = [
        cache_dir / f"{model_type}.pt",
        cache_dir / f"{whisper_model_name}.pt"
    ]
    for attempt in range(max_retries):
        try:
            model_file = next((pf for pf in possible_files if pf.exists() and pf.stat().st_size > 1000), None)
            if model_file:
                size_mb = model_file.stat().st_size / (1024 * 1024)
                log_cb(f"[green]INFO:[/] Model {model_type} găsit în cache ({size_mb:.1f} MB)")
            else:
                for pf in possible_files:
                    if pf.exists():
                        log_cb(f"[yellow]WARNING:[/] Model corupt găsit, se șterge: {pf}")
                        pf.unlink()
                log_cb(f"[blue]INFO:[/] Descărcare model {model_type}... (încercarea {attempt + 1}/{max_retries})")
            model = whisper.load_model(whisper_model_name, download_root=str(cache_dir))
            if model is None:
                raise Exception("Modelul returnat de whisper este None")
            model_file = next((pf for pf in possible_files if pf.exists() and pf.stat().st_size > 1000), None)
            if model_file:
                size_mb = model_file.stat().st_size / (1024 * 1024)
                log_cb(f"[green]Succes:[/] Model {model_type} încărcat corect ({size_mb:.1f} MB)")
                return whisper_model_name
            else:
                raise Exception("Modelul nu s-a descărcat corect în cache")
        except Exception as e:
            log_cb(f"[red]Eroare încercarea {attempt + 1}:[/] {str(e)}")
            for name in [model_type, whisper_model_name]:
                model_file = cache_dir / f"{name}.pt"
                if model_file.exists():
                    try:
                        model_file.unlink()
                        log_cb(f"[yellow]INFO:[/] Model corupt șters: {name}.pt")
                    except Exception:
                        pass
            if attempt == max_retries - 1:
                log_cb(f"[red]Eroare finală:[/] Nu pot descărca modelul {model_type} după {max_retries} încercări")
                if model_type.startswith("large"):
                    log_cb(f"[yellow]Sugestie:[/] Încearcă un model mai mic: 'medium' sau 'small'")
                return None
            time.sleep(3 if "large" in model_type else 2)
    return None

# ----- Post-procesare helpers -----
def check_file_permissions(inp: str, outp: str) -> bool:
    if not os.path.exists(inp) or not os.access(inp, os.R_OK):
        logger.error(f"Cannot read '{inp}'"); return False
    d = os.path.dirname(outp) or '.'
    if not os.path.exists(d):
        try:
            os.makedirs(d)
        except Exception:
            logger.error(f"Cannot create output directory '{d}'"); return False
    if not os.access(d, os.W_OK):
        logger.error(f"No write-permission in '{d}'"); return False
    if os.path.exists(outp) and not os.access(outp, os.W_OK):
        logger.error(f"No write-permission for '{outp}'"); return False
    return True

def split_custom(text: str, max_chars: int) -> List[str]:
    if len(text) <= max_chars:
        return [text]
    pref = 70 if len(text) < 150 else 90 if len(text) < 180 else 100
    cuts = []
    for punct in ['. ', '! ', '? ']:
        pos = text.rfind(punct, 0, pref+10)
        if pos > pref-20:
            cuts.append((pos+len(punct), 'sentence'))
    for punct in [', ', '; ', ': ', ' - ', ' – ']:
        pos = text.rfind(punct, 0, pref+10)
        if pos > pref-15:
            cuts.append((pos+len(punct), 'punctuation'))
    pos = text.rfind(' ', 0, pref+5)
    if pos > pref-10:
        cuts.append((pos+1, 'space'))
    if cuts:
        cuts.sort(key=lambda x: (0 if x[1]=='sentence' else 1 if x[1]=='punctuation' else 2, abs(x[0]-pref)))
        idx = cuts[0][0]
    else:
        idx = pref
        logger.warning(f"Forced split at {idx}")
    left, right = text[:idx].strip(), text[idx:].strip()
    return [left] + split_custom(right, max_chars)

def subrip_add_milliseconds(sr: datetime.timedelta, ms: int) -> datetime.timedelta:
    return sr + datetime.timedelta(milliseconds=ms)

def split_text_with_timing(
    text: str, start: datetime.timedelta, end: datetime.timedelta,
    max_chars: int, gap_ms: int
) -> List[Any]:
    chunks = split_custom(text, max_chars)
    if len(chunks) == 1:
        return [(text, start, end)]
    total_ms = int((end - start).total_seconds() * 1000)
    gaps = len(chunks)-1
    total_gap = gap_ms * gaps
    avail = max(total_ms - total_gap, 0)
    gap = gap_ms if total_ms > total_gap else max(50, total_ms//max(1, gaps+1))
    total_chars = sum(len(c) for c in chunks)
    cur_start = start
    out = []
    for i, chunk in enumerate(chunks):
        if i < len(chunks)-1:
            dur = int((avail * len(chunk)) // total_chars)
            chunk_end = subrip_add_milliseconds(cur_start, dur)
        else:
            chunk_end = end
        out.append((chunk, cur_start, chunk_end))
        if i < len(chunks)-1:
            cur_start = subrip_add_milliseconds(chunk_end, gap)
    return out

def advanced_srt_postprocess(raw_srt: Path, final_srt: Path, cfg_pp: Dict[str, int]):
    if not check_file_permissions(str(raw_srt), str(final_srt)):
        raise PermissionError("Cannot access SRT files")
    logger.info(f"Post-procesare SRT: {raw_srt.name}")
    text = raw_srt.read_text(encoding="utf-8")
    subs = list(srt.parse(text))
    merged, buf_txt, buf_start = [], "", None
    for i, sub in enumerate(subs):
        clean = sub.content.replace("\n"," ").strip()
        if not clean: continue
        if buf_txt == "":
            buf_start = sub.start
        buf_txt = (buf_txt + " " + clean).strip()
        flush = (
            len(buf_txt) >= cfg_pp["min_chars"] or
            i == len(subs)-1 or
            len(buf_txt) > cfg_pp["max_chars"]*2
        )
        if flush:
            end_time = sub.end
            if len(buf_txt) > cfg_pp["max_chars"]:
                parts = split_text_with_timing(
                    buf_txt, buf_start, end_time,
                    cfg_pp["max_chars"], cfg_pp["subtitle_gap_ms"]
                )
                for txt, st, en in parts:
                    merged.append(srt.Subtitle(
                        index=len(merged)+1, start=st, end=en, content=txt.strip()
                    ))
            else:
                merged.append(srt.Subtitle(
                    index=len(merged)+1, start=buf_start,
                    end=end_time, content=buf_txt
                ))
            buf_txt, buf_start = "", None
    for idx, sub in enumerate(merged, start=1):
        sub.index = idx
    final_srt.write_text(srt.compose(merged), encoding="utf-8")
    logger.info(f"Saved {len(merged)} subtitles to {final_srt.name}")

# ----- Procesare fișier MP3 -----
def process_single_file(
    mp3_file: str, tmp_dir: Path, cfg: Dict[str, Any], verbose: bool, stop_event: threading.Event
) -> Dict[str, Any]:
    if stop_event.is_set():
        return {"status":"aborted","file":mp3_file,"reason":"Interrupted"}

    base_name = Path(mp3_file).stem
    wav_file = tmp_dir / f"{base_name}.wav"
    raw_srt = tmp_dir / f"{base_name}.srt"
    final_srt = Path(f"{base_name}.srt")

    # 1) MP3→WAV cu verificări
    output_redirect = None if verbose else subprocess.DEVNULL
    try:
        log_msg(f"[blue]INFO:[/] Conversie MP3→WAV: {base_name}")
        result = subprocess.run(
            ["ffmpeg", "-y", "-i", mp3_file, "-ar", "16000", "-ac", "1", str(wav_file)],
            stdout=output_redirect,
            stderr=output_redirect,
            check=True,
            timeout=300
        )
        if not wav_file.exists() or wav_file.stat().st_size == 0:
            return {"status":"failed","file":mp3_file,"reason":"Fișier WAV invalid după conversie"}
    except subprocess.TimeoutExpired:
        return {"status":"failed","file":mp3_file,"reason":"Timeout la conversie FFmpeg"}
    except Exception as e:
        return {"status":"failed","file":mp3_file,"reason":f"FFmpeg error: {e}"}

    # 2) Transcription cu numele corect de model
    try:
        log_msg(f"[blue]INFO:[/] Transcription: {base_name}")
        whisper_model_name = MODEL_MAPPING[cfg["model_type"]]
        model = whisper.load_model(whisper_model_name)
        if model is None:
            wav_file.unlink(missing_ok=True)
            return {"status":"failed","file":mp3_file,"reason":"Model whisper invalid"}
        # Redirect stdout/stderr
        original_stdout, original_stderr = sys.stdout, sys.stderr
        with open(os.devnull, 'w') as devnull:
            sys.stdout = devnull
            sys.stderr = devnull
            try:
                result = model.transcribe(
                    str(wav_file),
                    language=cfg["language"],
                    verbose=False,
                    temperature=0.0,
                    word_timestamps=False
                )
            finally:
                sys.stdout = original_stdout
                sys.stderr = original_stderr

        if not result or 'segments' not in result:
            wav_file.unlink(missing_ok=True)
            return {"status":"failed","file":mp3_file,"reason":"Whisper nu a returnat rezultate"}
        # Creăm SRT-ul
        subtitles = []
        for idx, segment in enumerate(result["segments"], start=1):
            start_time = datetime.timedelta(seconds=segment["start"])
            end_time = datetime.timedelta(seconds=segment["end"])
            text = segment["text"].strip()
            if text:
                subtitles.append(srt.Subtitle(idx, start_time, end_time, text))
        if not subtitles:
            wav_file.unlink(missing_ok=True)
            return {"status":"failed","file":mp3_file,"reason":"Nu s-a detectat text în audio"}
        raw_srt.write_text(srt.compose(subtitles), encoding="utf-8")
    except Exception as e:
        wav_file.unlink(missing_ok=True)
        return {"status":"failed","file":mp3_file,"reason":f"Whisper API error: {str(e)}"}

    if not raw_srt.exists() or raw_srt.stat().st_size == 0:
        wav_file.unlink(missing_ok=True)
        return {"status":"failed","file":mp3_file,"reason":"SRT raw nu s-a creat"}

    # 3) Post-procesare
    try:
        advanced_srt_postprocess(raw_srt, final_srt, cfg["postprocess"])
        log_msg(f"[green]INFO:[/] Post-procesare completă: {base_name}")
    except Exception as e:
        log_msg(f"[yellow]WARNING:[/] Post-procesare eșuată pentru {base_name}: {e}")
        shutil.copy2(raw_srt, final_srt)

    # Curățenie
    wav_file.unlink(missing_ok=True)
    raw_srt.unlink(missing_ok=True)
    return {"status":"completed","file":mp3_file,"reason":"Succes"}

# ----- Run transcription -----
def run_transcription(
    files: List[str], cfg: Dict[str, Any],
    progress_cb: Callable[[int], None], log_cb: Callable[[str], None],
    queue: Queue, stop_event: threading.Event
):
    tmp = Path(cfg["temp_dir"]).resolve()
    tmp.mkdir(exist_ok=True)
    recovery = load_recovery()
    to_process = [f for f in files if recovery.get(f) != "completed"]

    if not to_process:
        log_cb("Toate fișierele sunt deja procesate.")
        return

    log_cb(f"{len(files)} găsite, {len(to_process)} de procesat. Model: {cfg['model_type'].upper()}")

    # Verificăm și descărcăm modelul robust
    model_name = download_model_robust(cfg["model_type"], log_cb)
    if not model_name:
        log_cb("[red]Eroare:[/] Nu se poate continua fără model valid.")
        return

    comp = fail = 0
    for mp3_file in to_process:
        if stop_event.is_set():
            log_cb("[red]INFO:[/] Procesare întreruptă de utilizator")
            break
        while not queue.empty():
            try:
                log_cb(queue.get_nowait())
            except Exception:
                break
        try:
            result = process_single_file(mp3_file, tmp, cfg, False, stop_event)
            if result["status"] == "completed":
                comp += 1
                log_cb(f"✓ Finalizat: {result['file']} ({result['reason']})")
            else:
                fail += 1
                log_cb(f"✗ Eșuat: {result['file']} ({result['reason']})")
            recovery[result['file']] = result["status"]
            save_recovery(recovery)
            progress_cb(int((comp + fail) / len(to_process) * 100))
        except Exception as e:
            fail += 1
            log_cb(f"✗ Eroare critică: {mp3_file} ({str(e)})")
            recovery[mp3_file] = "failed"
            save_recovery(recovery)
            progress_cb(int((comp + fail) / len(to_process) * 100))
    if fail == 0 and Path(RECOVERY_FILE).exists():
        Path(RECOVERY_FILE).unlink()
        log_cb("Recovery file șters.")
    log_cb(f"Procesare completă: {comp} succes, {fail} eșuate")

# ----- GUI -----
class App:
    def __init__(self, master, queue: Queue):
        self.master = master
        self.log_queue = queue
        self.thread = None
        self.stop_event = threading.Event()
        self.config = load_config()
        master.title(f"MP3 Transcriber {VERSION}")
        master.geometry("600x450")
        self.create_widgets()
        master.after(100, self.check_queue)

    def create_widgets(self):
        frm = ttk.Frame(self.master, padding="10")
        frm.pack(fill=tk.BOTH, expand=True)
        # folder selector
        dfrm = ttk.Frame(frm); dfrm.pack(fill=tk.X, pady=5)
        ttk.Label(dfrm, text="Director:").pack(side=tk.LEFT)
        self.dir_entry = ttk.Entry(dfrm, width=50)
        self.dir_entry.insert(0, os.getcwd())
        self.dir_entry.pack(side=tk.LEFT, padx=5, expand=True)
        ttk.Button(dfrm, text="Alege", command=self.select_dir).pack(side=tk.LEFT)
        # options
        ofrm = ttk.Frame(frm); ofrm.pack(fill=tk.X, pady=5)
        ttk.Label(ofrm, text="Model:").pack(side=tk.LEFT)
        self.model_var = tk.StringVar(value=self.config["model_type"])
        ttk.Combobox(ofrm, values=list(MODEL_MAPPING.keys()),
                     textvariable=self.model_var, state="readonly").pack(side=tk.LEFT, padx=5)
        ttk.Label(ofrm, text="Limbă:").pack(side=tk.LEFT, padx=(10,0))
        self.lang_var = tk.StringVar(value=self.config["language"])
        ttk.Combobox(ofrm, values=VALID_LANGUAGES, textvariable=self.lang_var,
                     state="readonly").pack(side=tk.LEFT, padx=5)
        # buttons
        bfrm = ttk.Frame(frm); bfrm.pack(fill=tk.X, pady=10)
        style = ttk.Style()
        style.configure("Green.TButton", background="#90ee90"); style.map("Green.TButton", background=[("active","#76c876")])
        style.configure("Red.TButton", background="#ff6347");  style.map("Red.TButton", background=[("active","#e0543c")])
        self.start_btn = ttk.Button(bfrm, text="Start Transcriere", command=self.start, style="Green.TButton")
        self.start_btn.pack(side=tk.LEFT, expand=True, fill=tk.X, padx=(0,5))
        self.exit_btn  = ttk.Button(bfrm, text="Ieșire", command=self.master.quit, style="Red.TButton", width=10)
        self.exit_btn.pack(side=tk.LEFT, padx=(5,0))
        # progress
        self.pbar = ttk.Progressbar(frm, mode="determinate", length=400); self.pbar.pack(pady=5)
        self.plbl = ttk.Label(frm, text="Progres: 0%"); self.plbl.pack()
        # log
        lfrm = ttk.LabelFrame(frm, text="Log-uri", padding=5); lfrm.pack(fill=tk.BOTH, expand=True, pady=10)
        self.log_area = ScrolledText(lfrm, state="disabled", wrap="word"); self.log_area.pack(fill=tk.BOTH, expand=True)

    def select_dir(self):
        d = filedialog.askdirectory()
        if d: self.dir_entry.delete(0, tk.END); self.dir_entry.insert(0, d)

    def start(self):
        d = self.dir_entry.get()
        if not Path(d).is_dir():
            self.log("[red]ERROR:[/] Director invalid."); return
        self.start_btn.config(state=tk.DISABLED)
        self.exit_btn.config(text="STOP", command=self.stop)
        self.pbar["value"] = 0; self.plbl.config(text="Progres: 0%")
        self.log("--- Sesiune nouă ---")
        self.config["model_type"] = self.model_var.get()
        self.config["language"]   = self.lang_var.get()
        files = [str(f) for f in Path(d).glob("*.mp3")]
        if not files:
            self.log("[red]ERROR:[/] Niciun MP3 găsit."); self.reset(); return
        self.stop_event.clear()
        self.thread = threading.Thread(
            target=run_transcription,
            args=(files, self.config, self.update_progress, self.log, self.log_queue, self.stop_event)
        )
        self.thread.daemon = True
        self.thread.start()

    def stop(self):
        self.log("[red]INFO:[/] Oprire solicitată..."); self.stop_event.set()

    def reset(self):
        self.start_btn.config(state=tk.NORMAL); self.exit_btn.config(text="Ieșire", command=self.master.quit)

    def update_progress(self, v: int):
        self.pbar["value"] = v; self.plbl.config(text=f"Progres: {v}%")

    def log(self, msg: str):
        self.log_area.config(state="normal")
        self.log_area.insert(tk.END, msg + "\n")
        self.log_area.see(tk.END)
        self.log_area.config(state="disabled")

    def check_queue(self):
        while not self.log_queue.empty():
            try:
                self.log(self.log_queue.get_nowait())
            except Exception:
                break
        if self.thread and not self.thread.is_alive():
            self.reset(); self.thread = None
        self.master.after(100, self.check_queue)

def main():
    log_q = Queue()
    root = tk.Tk()
    App(root, log_q)
    root.mainloop()

if __name__ == "__main__":
    main()