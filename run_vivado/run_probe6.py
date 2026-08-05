import subprocess
import os
import re
import time
import sys
import concurrent.futures

REPO_ROOT = r"C:\Users\wanlinc\Desktop\Me\Loogn cpu v1\func_test\soc_verify"
TCL_SCRIPT = os.path.join(REPO_ROOT, "run_vivado", "run_ooc_probe.tcl")
OUT_ROOT = os.path.join(REPO_ROOT, "run_vivado", "probe_results")
# Toolchain selection: override with the VIVADO_BIN environment variable,
# e.g.  PowerShell:  $env:VIVADO_BIN="D:\wanlinc\Xilinx_Vivado_2019.2_1106_2127\Vivado\2019.2\bin\vivado.bat"
#       git-bash:    VIVADO_BIN=... python run_probe6.py
# or pass it as the first command-line argument:  python run_probe6.py <path-to-vivado.bat>
_DEFAULT_VIVADO_BIN = r"D:\vavido\Vivado\2023.2\bin\vivado.bat"
VIVADO_BIN = (
    os.environ.get("VIVADO_BIN")
    or (sys.argv[1] if len(sys.argv) > 1 else None)
    or _DEFAULT_VIVADO_BIN
)
print(f"=== Probe toolchain: {VIVADO_BIN} ===", flush=True)

MODULES_OOC_80 = [
    ("DispatchQueue", "dispatch_queue_80"),
    ("StoreQueue", "store_queue_80"),
    ("Frontend", "frontend_80"),
    ("LoadStoreUnit", "load_store_unit_80"),
    ("Scheduler", "scheduler_80"),
]

FULL_PROBES_80 = [
    ("mycpu_top", "mycpu_top_full_80", "full"),
]

def run_single_probe(top, tag, is_full="ooc"):
    print(f"[START] Synthesis Probe: {top} (tag={tag}, mode={is_full})...", flush=True)
    t0 = time.time()
    cmd = [
        VIVADO_BIN,
        "-mode", "batch",
        "-source", TCL_SCRIPT,
        "-tclargs", top, tag, is_full
    ]
    try:
        proc = subprocess.run(
            cmd,
            cwd=os.path.join(REPO_ROOT, "run_vivado"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=1800
        )
        elapsed = time.time() - t0
        if proc.returncode == 0:
            print(f"[SUCCESS] {top} completed in {elapsed:.1f}s", flush=True)
            return top, tag, is_full, elapsed, True, proc.stdout
        else:
            print(f"[ERROR] {top} failed with code {proc.returncode} in {elapsed:.1f}s", flush=True)
            return top, tag, is_full, elapsed, False, proc.stderr
    except Exception as e:
        elapsed = time.time() - t0
        print(f"[EXCEPTION] {top} failed: {e}", flush=True)
        return top, tag, is_full, elapsed, False, str(e)

def parse_probe_results(tag):
    out_dir = os.path.join(OUT_ROOT, tag)
    timing_paths_file = os.path.join(out_dir, "timing_paths.rpt")
    timing_summary_file = os.path.join(out_dir, "timing_summary.rpt")
    util_file = os.path.join(out_dir, "utilization.rpt")

    res = {
        "wns": "N/A",
        "data_path_delay": "N/A",
        "startpoint": "N/A",
        "endpoint": "N/A",
        "slack": "N/A",
        "luts": "N/A",
        "ffs": "N/A",
        "bram": "N/A",
        "dsp": "N/A",
        "path_details": []
    }

    if os.path.exists(util_file):
        with open(util_file, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
            lut_m = re.search(r"CLB LUTs\s*\|\s*(\d+)", content) or re.search(r"Slice LUTs\s*\|\s*(\d+)", content)
            if lut_m: res["luts"] = lut_m.group(1)
            ff_m = re.search(r"Register as Flip Flop\s*\|\s*(\d+)", content) or re.search(r"Slice Registers\s*\|\s*(\d+)", content)
            if ff_m: res["ffs"] = ff_m.group(1)
            bram_m = re.search(r"Block RAM Tile\s*\|\s*([\d\.]+)", content)
            if bram_m: res["bram"] = bram_m.group(1)
            dsp_m = re.search(r"DSPs\s*\|\s*(\d+)", content)
            if dsp_m: res["dsp"] = dsp_m.group(1)

    if os.path.exists(timing_paths_file):
        with open(timing_paths_file, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()

            # Extract Critical Path Info
            sp_m = re.search(r"Source:\s+(\S+)", content)
            ep_m = re.search(r"Destination:\s+(\S+)", content)
            delay_m = re.search(r"Data Path Delay:\s+([\d\.]+)\s*ns", content)
            slack_m = re.search(r"Slack\s*\(([A-Z]+)\)\s*:\s*(-?[\d\.]+)\s*ns", content)

            if sp_m: res["startpoint"] = sp_m.group(1)
            if ep_m: res["endpoint"] = ep_m.group(1)
            if delay_m: res["data_path_delay"] = delay_m.group(1)
            if slack_m: res["slack"] = slack_m.group(2)

    if os.path.exists(timing_summary_file):
        with open(timing_summary_file, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
            wns_m = re.search(r"WNS\(ns\)\s+TNS\(ns\).*\n\s*(-?[\d\.]+)", content)
            if wns_m: res["wns"] = wns_m.group(1)

    return res

def main():
    print("=== Starting Parallel 80MHz Probes (6 modules) ===", flush=True)
    os.makedirs(OUT_ROOT, exist_ok=True)

    tasks = []
    for top, tag in MODULES_OOC_80:
        tasks.append((top, tag, "ooc"))
    for top, tag, mode in FULL_PROBES_80:
        tasks.append((top, tag, mode))

    # Run in parallel with max 4 workers
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        futures = [executor.submit(run_single_probe, t[0], t[1], t[2]) for t in tasks]
        for future in concurrent.futures.as_completed(futures):
            results.append(future.result())

    print("\n=== Synthesis Probes Completed. Parsing Reports... ===", flush=True)
    summary_data = []
    for top, tag, mode, elapsed, success, _ in results:
        parsed = parse_probe_results(tag)
        parsed["top"] = top
        parsed["tag"] = tag
        parsed["mode"] = mode
        parsed["elapsed"] = f"{elapsed:.1f}s"
        parsed["success"] = success
        summary_data.append(parsed)

    # Save aggregated report
    report_file = os.path.join(REPO_ROOT, "run_vivado", "timing_probe6_summary.txt")
    with open(report_file, "w", encoding="utf-8") as f:
        f.write("=== TIMING PROBE6 SUMMARY REPORT (80MHz) ===\n\n")
        for item in summary_data:
            f.write(f"Module: {item['top']} ({item['mode']})\n")
            f.write(f"  Success: {item['success']} | Elapsed: {item['elapsed']}\n")
            f.write(f"  Max Data Path Delay: {item['data_path_delay']} ns | Slack: {item['slack']} ns | WNS: {item['wns']} ns\n")
            f.write(f"  LUTs: {item['luts']} | FFs: {item['ffs']} | BRAM: {item['bram']} | DSP: {item['dsp']}\n")
            f.write(f"  Startpoint: {item['startpoint']}\n")
            f.write(f"  Endpoint:   {item['endpoint']}\n")
            f.write("-" * 60 + "\n")

    print(f"Aggregated summary written to {report_file}", flush=True)

if __name__ == "__main__":
    main()
