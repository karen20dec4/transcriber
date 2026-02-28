#!/usr/bin/env python3
"""
Enhanced subtitle merger script
Versiune îmbunătățită - Sep 2025
Combină subtitrările scurte și împarte cele lungi pentru lizibilitate optimă
"""

import pysrt
import sys
import os
from datetime import datetime, timedelta
import logging

# Verificarea dependințelor critice
try:
    import pysrt
except ImportError:
    print("ERROR: pysrt library not found!")
    print("Install with: pip install pysrt")
    sys.exit(1)

# Configurare logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)

# Setări configurabile
MIN_CHARS = 80
MAX_CHARS = 120
SUBTITLE_GAP_MS = 100  # Gap minim între subtitrări în milisecunde

def check_file_permissions(input_file, output_file):
    """Verifică existența și permisiunile fișierelor"""
    
    # Verifică fișierul de input
    if not os.path.exists(input_file):
        logger.error(f"Input file '{input_file}' not found")
        return False
    
    if not os.access(input_file, os.R_OK):
        logger.error(f"No read permission for '{input_file}'")
        return False
    
    # Verifică directorul pentru output
    output_dir = os.path.dirname(output_file) or '.'
    if not os.access(output_dir, os.W_OK):
        logger.error(f"No write permission for directory '{output_dir}'")
        return False
    
    # Verifică dacă fișierul de output există și dacă poate fi suprascris
    if os.path.exists(output_file) and not os.access(output_file, os.W_OK):
        logger.error(f"No write permission for '{output_file}'")
        return False
    
    return True

def split_custom(text):
    """
    Împarte textul lung în segmente mai mici, prioritizând punctuația
    """
    length = len(text)
    if length <= MAX_CHARS:
        return [text]
    
    # Stabilește punctul de tăiere bazat pe lungime
    if 121 <= length < 150:
        preferred_cut = 70
    elif 150 <= length < 180:
        preferred_cut = 90
    else:
        preferred_cut = 100
    
    # Caută cel mai bun punct de tăiere în ordine de prioritate
    cut_positions = []
    
    # 1. Prioritate: punctuație de sfârșit de propoziție
    for punct in ['. ', '! ', '? ']:
        pos = text.rfind(punct, 0, preferred_cut + 10)
        if pos > preferred_cut - 20:  # Nu prea departe de punctul ideal
            cut_positions.append((pos + len(punct), 'sentence'))
    
    # 2. Prioritate: alte semne de punctuație
    for punct in [', ', '; ', ': ', ' - ', ' — ']:
        pos = text.rfind(punct, 0, preferred_cut + 10)
        if pos > preferred_cut - 15:
            cut_positions.append((pos + len(punct), 'punctuation'))
    
    # 3. Prioritate: spații simple
    pos = text.rfind(' ', 0, preferred_cut + 5)
    if pos > preferred_cut - 10:
        cut_positions.append((pos + 1, 'space'))
    
    # Alege cel mai bun punct de tăiere
    if cut_positions:
        # Sortează după prioritate și proximitate la punctul ideal
        cut_positions.sort(key=lambda x: (
            0 if x[1] == 'sentence' else 1 if x[1] == 'punctuation' else 2,
            abs(x[0] - preferred_cut)
        ))
        split_idx = cut_positions[0][0]
    else:
        # Fallback: tăiere forțată
        split_idx = preferred_cut
        logger.warning(f"Forced split at position {split_idx} - no good break point found")
    
    left = text[:split_idx].strip()
    right = text[split_idx:].strip()
    
    # Recursiv pentru partea dreaptă dacă încă e prea lungă
    right_parts = split_custom(right)
    
    return [left] + right_parts

def subrip_add_milliseconds(subrip_time, milliseconds):
    """Adaugă milisecunde la un timp SubRip"""
    try:
        base_dt = datetime(
            1900, 1, 1,
            subrip_time.hours,
            subrip_time.minutes,
            subrip_time.seconds,
            subrip_time.milliseconds * 1000
        )
        
        new_dt = base_dt + timedelta(milliseconds=milliseconds)
        
        return pysrt.SubRipTime(
            hours=new_dt.hour,
            minutes=new_dt.minute,
            seconds=new_dt.second,
            milliseconds=new_dt.microsecond // 1000
        )
    except Exception as e:
        logger.error(f"Error in time calculation: {e}")
        return subrip_time

def split_text_with_timing(text, start, end):
    """
    Împarte textul și redistribuie timpul proporțional, cu gap-uri între subtitrări
    """
    chunks = split_custom(text)
    if len(chunks) == 1:
        return [(chunks[0], start, end)]
    
    # Calculează durata totală disponibilă
    total_duration_ms = end.ordinal - start.ordinal
    
    # Rezervă timp pentru gap-urile dintre subtitrări
    gaps_needed = len(chunks) - 1
    total_gap_time = gaps_needed * SUBTITLE_GAP_MS
    
    if total_duration_ms <= total_gap_time:
        logger.warning("Duration too short for proper gaps, using minimal gaps")
        available_duration = total_duration_ms
        gap_time = max(50, total_duration_ms // (gaps_needed + 1)) if gaps_needed > 0 else 0
    else:
        available_duration = total_duration_ms - total_gap_time
        gap_time = SUBTITLE_GAP_MS
    
    # Calculează proporțiile bazate pe lungimea textului
    total_chars = sum(len(chunk) for chunk in chunks)
    
    result = []
    current_start = start
    
    for i, chunk in enumerate(chunks):
        proportion = len(chunk) / total_chars
        chunk_duration = int(proportion * available_duration)
        
        # Asigură-te că ultima porțiune folosește tot timpul rămas
        if i == len(chunks) - 1:
            chunk_end = end
        else:
            chunk_end = subrip_add_milliseconds(current_start, chunk_duration)
        
        result.append((chunk, current_start, chunk_end))
        
        # Adaugă gap pentru următoarea subtitrare (dacă nu e ultima)
        if i < len(chunks) - 1:
            current_start = subrip_add_milliseconds(chunk_end, gap_time)
    
    return result

def show_progress(current, total, prefix="Processing"):
    """Afișează bara de progres"""
    if total == 0:
        return
        
    percent = int(100 * current / total)
    bar_length = 30
    filled_length = int(bar_length * current / total)
    
    bar = '█' * filled_length + '░' * (bar_length - filled_length)
    
    sys.stdout.write(f'\r{prefix}: [{bar}] {percent:3d}% ({current}/{total})')
    sys.stdout.flush()
    
    if current == total:
        print()  # New line when complete

def process_subtitles(input_file, output_file):
    """Procesează fișierul de subtitrări principal"""
    
    logger.info(f"Starting subtitle processing: {input_file} -> {output_file}")
    
    try:
        # Încarcă subtitrările cu encoding explicit
        subs = pysrt.open(input_file, encoding='utf-8')
        logger.info(f"Loaded {len(subs)} subtitles from input file")
        
    except UnicodeDecodeError:
        logger.warning("UTF-8 decoding failed, trying with latin-1")
        try:
            subs = pysrt.open(input_file, encoding='latin-1')
        except Exception as e:
            logger.error(f"Failed to read subtitle file with multiple encodings: {e}")
            return False
            
    except Exception as e:
        logger.error(f"Failed to load subtitle file: {e}")
        return False
    
    if not subs:
        logger.error("No subtitles found in input file")
        return False
    
    # Procesarea principală
    merged_subs = []
    temp_text = ""
    start_time = None
    processed_count = 0
    
    logger.info("Processing subtitles...")
    
    for i, sub in enumerate(subs):
        # Progress tracking
        if i % 10 == 0 or i == len(subs) - 1:
            show_progress(i + 1, len(subs), "Processing")
        
        # Verifică dacă subtitrarea are text valid
        if not sub.text or not sub.text.strip():
            logger.debug(f"Skipping empty subtitle at index {i}")
            continue
        
        # Inițializează dacă e primul text
        if not temp_text:
            start_time = sub.start
        
        # Adaugă textul curent (curăță newline-urile)
        clean_text = sub.text.strip().replace('\n', ' ').replace('\r', '')
        temp_text += " " + clean_text if temp_text else clean_text
        
        # Decide dacă să proceseze acum
        should_process = (
            len(temp_text.strip()) >= MIN_CHARS or 
            i == len(subs) - 1 or
            len(temp_text.strip()) > MAX_CHARS * 2  # Evită acumularea excesivă
        )
        
        if should_process:
            end_time = sub.end
            full_text = temp_text.strip()
            
            if len(full_text) > MAX_CHARS:
                # Împarte textul lung
                split_segments = split_text_with_timing(full_text, start_time, end_time)
                for text_part, chunk_start, chunk_end in split_segments:
                    merged_subs.append(pysrt.SubRipItem(
                        index=len(merged_subs) + 1,
                        start=chunk_start,
                        end=chunk_end,
                        text=text_part.strip()
                    ))
                    processed_count += 1
            else:
                # Păstrează textul ca o singură subtitrare
                merged_subs.append(pysrt.SubRipItem(
                    index=len(merged_subs) + 1,
                    start=start_time,
                    end=end_time,
                    text=full_text
                ))
                processed_count += 1
            
            # Reset pentru următoarea secvență
            temp_text = ""
            start_time = None
    
    # Salvează rezultatul
    try:
        result_file = pysrt.SubRipFile(merged_subs)
        result_file.save(output_file, encoding='utf-8')
        
        logger.info(f"Successfully saved {len(merged_subs)} processed subtitles to '{output_file}'")
        logger.info(f"Compression ratio: {len(subs)} -> {len(merged_subs)} subtitles")
        
        return True
        
    except Exception as e:
        logger.error(f"Failed to save output file: {e}")
        return False

def main():
    """Funcția principală"""
    
    # Verifică argumentele
    if len(sys.argv) != 3:
        print("Usage: python3 merge_short_subs.py input.srt output.srt")
        print("Example: python3 merge_short_subs.py video_raw.srt video_merged.srt")
        sys.exit(1)
    
    input_file = sys.argv[1]
    output_file = sys.argv[2]
    
    logger.info("=== Enhanced Subtitle Merger Starting ===")
    logger.info(f"Input: {input_file}")
    logger.info(f"Output: {output_file}")
    logger.info(f"Settings: MIN_CHARS={MIN_CHARS}, MAX_CHARS={MAX_CHARS}, GAP={SUBTITLE_GAP_MS}ms")
    
    # Verifică permisiunile fișierelor
    if not check_file_permissions(input_file, output_file):
        sys.exit(1)
    
    # Procesează subtitrările
    start_time = datetime.now()
    success = process_subtitles(input_file, output_file)
    end_time = datetime.now()
    
    duration = end_time - start_time
    
    if success:
        logger.info(f"✅ Processing completed successfully in {duration.total_seconds():.1f}s")
        print(f"✅ Subtitrările au fost îmbunătățite și salvate în: {output_file}")
        sys.exit(0)
    else:
        logger.error(f"❌ Processing failed after {duration.total_seconds():.1f}s")
        print(f"❌ Eroare în procesarea fișierului {input_file}")
        sys.exit(1)

if __name__ == "__main__":
    main()