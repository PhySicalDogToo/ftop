#!/usr/bin/python3
"""Bounded, non-root nettop probes. Never persist connection addresses or secrets."""
import argparse
import csv
import ctypes
import hashlib
import http.server
import io
import json
import os
import pty
from pathlib import Path
import resource
import socketserver
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parent
RUNTIME = Path.home() / "Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/clash-verge.yaml"
NETTOP = ["/usr/bin/nettop", "-n", "-P", "-J", "bytes_in,bytes_out", "-x", "-L", "0", "-d"]
LIBPROC = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)


class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_ubyte * 16)] + [(name, ctypes.c_uint64) for name in (
        "user", "system", "idle", "interrupt", "pageins", "wired", "resident", "footprint", "start", "exit")]


def rss(pid):
    value = Usage()
    return value.resident if LIBPROC.proc_pid_rusage(pid, 0, ctypes.byref(value)) == 0 else None


def cpu(who):
    value = resource.getrusage(who)
    return value.ru_utime + value.ru_stime


class Capture:
    def __init__(self, interval, interface=None, gentle=False, keep_stdin=False, use_pty=False):
        command = NETTOP + ["-s", str(interval)]
        if gentle:
            command.append("-c")
        if interface:
            command += ["-t", interface]
        self.frames = []
        self.lock = threading.Lock()
        self.error = ""
        if use_pty:
            master, slave = pty.openpty()
            self.process = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=subprocess.PIPE, text=True, bufsize=1)
            os.close(slave)
            self.output = os.fdopen(master, "r", errors="replace")
        else:
            self.process = subprocess.Popen(command, stdin=subprocess.PIPE if keep_stdin else None, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
            self.output = self.process.stdout
        self.thread = threading.Thread(target=self.consume, daemon=True)
        self.thread.start()

    def consume(self):
        frame = None
        try:
            for row in csv.reader(self.output):
                if row and row[0] == "time":
                    if frame is not None:
                        with self.lock:
                            self.frames.append(frame)
                    frame = {"at": time.monotonic(), "rows": {}}
                elif frame is not None and len(row) >= 4:
                    try:
                        name, pid = row[1].rsplit(".", 1)
                        frame["rows"][int(pid)] = (name, int(row[2]), int(row[3]))
                    except (ValueError, IndexError):
                        continue
        except OSError:
            pass  # A PTY returns EIO after its child exits.
        if frame is not None:
            with self.lock:
                self.frames.append(frame)

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=3)
        self.thread.join(timeout=3)
        self.output.close()
        if self.process.stdin:
            self.process.stdin.close()
        self.error = self.process.stderr.read(2048)


def write(name, value):
    (ROOT / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def performance(seconds, gentle=False, intervals=(2, 1), keep_stdin=False, use_pty=False):
    reports = []
    for interval in intervals:
        own_before = cpu(resource.RUSAGE_SELF)
        children_before = cpu(resource.RUSAGE_CHILDREN)
        started = time.monotonic()
        capture = Capture(interval, gentle=gentle, keep_stdin=keep_stdin, use_pty=use_pty)
        child_rss, wrapper_rss = [], []
        try:
            while time.monotonic() - started < seconds and capture.process.poll() is None:
                for pid, result in ((capture.process.pid, child_rss), (os.getpid(), wrapper_rss)):
                    value = rss(pid)
                    if value is not None:
                        result.append(value)
                time.sleep(0.25)
        finally:
            capture.stop()
        elapsed = time.monotonic() - started
        child_cpu = cpu(resource.RUSAGE_CHILDREN) - children_before
        own_cpu = cpu(resource.RUSAGE_SELF) - own_before
        report = {
            "pty": use_pty, "stdin_kept_open": keep_stdin, "gentle": gentle, "interval_seconds": interval, "wall_seconds": round(elapsed, 3), "csv_frames": len(capture.frames),
            "nettop_cpu_seconds": round(child_cpu, 5), "nettop_cpu_percent_one_core": round(child_cpu / elapsed * 100, 3),
            "wrapper_cpu_seconds": round(own_cpu, 5), "wrapper_cpu_percent_one_core": round(own_cpu / elapsed * 100, 3),
            "collector_total_cpu_percent_one_core": round((child_cpu + own_cpu) / elapsed * 100, 3),
            "nettop_rss_mean_mib": round(sum(child_rss) / max(1, len(child_rss)) / 1048576, 3),
            "nettop_rss_peak_mib": round(max(child_rss, default=0) / 1048576, 3),
            "wrapper_rss_peak_mib": round(max(wrapper_rss, default=0) / 1048576, 3),
        }
        reports.append(report)
        filename = "performance" + ("-gentle" if gentle else "") + ("-open-stdin" if keep_stdin else "") + ("-pty" if use_pty else "") + ".json"
        write(filename, {"method": "one persistent nettop, child CPU includes startup and shutdown; Python wrapper separately counted", "runs": reports})
        print(json.dumps(report, sort_keys=True), flush=True)
        if interval == 2 and capture.frames:
            sanitized_sample(capture.frames)


def sanitized_sample(frames):
    # Preserve CSV shape and measured counters, replacing all process names/PIDs.
    selected = sorted(frames[0]["rows"])[:2]
    output = io.StringIO()
    writer = csv.writer(output, lineterminator="\n")
    for index, frame in enumerate(frames[:2]):
        writer.writerow(["time", "", "bytes_in", "bytes_out", ""])
        for number, pid in enumerate(selected):
            if pid in frame["rows"]:
                _, received, sent = frame["rows"][pid]
                writer.writerow(["00:00:%02d.000000" % (index * 2), "renamed-process-%d.%d" % (number + 1, 101 + number), received, sent, ""])
    (ROOT / "sample-sanitized.csv").write_text(output.getvalue())


def clash_state():
    before = hashlib.sha256(RUNTIME.read_bytes()).digest()
    script = """require 'yaml'; require 'json'; v=YAML.safe_load(File.read(ARGV[0]),[],[],true); STDOUT.write(JSON.generate({'secret'=>v['secret'],'tun'=>v.dig('tun','enable'),'dns_mode'=>v.dig('dns','enhanced-mode')}))"""
    selected = json.loads(subprocess.run(["/usr/bin/ruby", "-e", script, str(RUNTIME)], capture_output=True, timeout=4, check=True).stdout)
    token = selected.get("secret") or ""
    if any(ord(c) < 32 for c in token):
        raise RuntimeError("Unsupported local control credential")
    def request(path):
        # Credentials stay in stdin/memory, never argv, logs or evidence.
        config = 'url = "http://localhost%s"\n' % path
        if token:
            config += 'header = %s\n' % json.dumps("Authorization: Bearer " + token)
        data = subprocess.run([
            "/usr/bin/curl", "-q", "--silent", "--fail", "--unix-socket", "/tmp/verge/verge-mihomo.sock",
            "--noproxy", "*", "--max-redirs", "0", "--max-time", "3", "--max-filesize", "1048576", "--config", "-"
        ], input=config.encode(), capture_output=True, timeout=4, check=True).stdout
        return json.loads(data)
    active = request("/configs")
    version = request("/version")
    return {
        "saved_tun_enabled": selected.get("tun"), "active_tun_enabled": active.get("tun", {}).get("enable"),
        "saved_dns_mode": selected.get("dns_mode"), "mihomo_confirmed": version.get("meta") is True,
        "configuration_unchanged_during_read": before == hashlib.sha256(RUNTIME.read_bytes()).digest(),
    }, before


def curl_download(url, limit):
    return subprocess.Popen([
        "/usr/bin/curl", "-q", "--silent", "--fail", "--noproxy", "*", "--max-redirs", "0",
        "--max-time", "25", "--connect-timeout", "5", "--max-filesize", str(limit),
        "--limit-rate", "256k", "--output", "/dev/null", "--write-out", "%{size_download},%{time_total},%{http_code}", url
    ], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)


def observed(frames, pid, start, end):
    rows = [(frame["at"], frame["rows"].get(pid)) for frame in frames[1:] if start <= frame["at"] <= end]
    present = [(at, value) for at, value in rows if value is not None]
    return {
        "observed_frames": len(present), "missing_frames": sum(value is None for _, value in rows),
        "download_bytes_in_observed_deltas": sum(value[1] for _, value in present),
        "upload_bytes_in_observed_deltas": sum(value[2] for _, value in present),
        "peak_download_delta_bytes": max((value[1] for _, value in present), default=0),
    }


def traffic():
    before_state, before_hash = clash_state()
    pids = subprocess.run(["/usr/bin/pgrep", "-x", "verge-mihomo"], capture_output=True, text=True, timeout=2).stdout.split()
    clash_pid = int(pids[0]) if len(pids) == 1 else None
    capture = Capture(1)
    payload_size = 4 * 1048576
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Length", str(payload_size))
            self.end_headers()
            try:
                for _ in range(payload_size // 65536):
                    self.wfile.write(b"x" * 65536)
            except (BrokenPipeError, ConnectionResetError):
                pass
    server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    experiments = []
    try:
        time.sleep(3)
        for label, url, limit in (
            ("local_tcp_control", "http://127.0.0.1:%d/" % server.server_address[1], payload_size),
            ("public_https_with_existing_tun", "https://speed.cloudflare.com/__down?bytes=2097152", 2 * 1048576),
        ):
            start = time.monotonic()
            child = curl_download(url, limit)
            output, _ = child.communicate(timeout=28)
            time.sleep(2)
            end = time.monotonic()
            fields = output.strip().split(",")
            report = {
                "experiment": label, "curl_exit": child.returncode,
                "body_bytes": int(float(fields[0])) if len(fields) == 3 else None,
                "transfer_seconds": float(fields[1]) if len(fields) == 3 else None,
                "http_status": int(fields[2]) if len(fields) == 3 else None,
                "start": start, "end": end, "client_pid": child.pid,
            }
            experiments.append(report)
            print(json.dumps({key: value for key, value in report.items() if key not in ("start", "end", "client_pid")}), flush=True)
            time.sleep(2)
    finally:
        server.shutdown()
        server.server_close()
        capture.stop()
    if not capture.frames:
        raise RuntimeError("nettop supplied no CSV frames; the execution sandbox may block NStat")
    for report in experiments:
        report["original_client"] = observed(capture.frames, report.pop("client_pid"), report["start"], report["end"])
        report["local_server"] = observed(capture.frames, os.getpid(), report["start"], report["end"]) if report["experiment"] == "local_tcp_control" else None
        report["clash_core_concurrent"] = observed(capture.frames, clash_pid, report["start"], report["end"]) if clash_pid else None
        del report["start"], report["end"]
    after_state, after_hash = clash_state()
    result = {
        "before": before_state, "after": after_state, "runtime_configuration_unchanged": before_hash == after_hash,
        "public_get_body_limit_bytes": 2 * 1048576, "experiments": experiments,
        "interpretation": "Socket/process activity only. Concurrent Clash traffic is not causally deduplicated or divided by physical-interface traffic.",
    }
    write("attribution.json", result)
    print(json.dumps(result, sort_keys=True), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("performance", "traffic"))
    parser.add_argument("--seconds", type=int, default=20)
    parser.add_argument("--gentle", action="store_true")
    parser.add_argument("--intervals", default="2,1")
    parser.add_argument("--keep-stdin", action="store_true")
    parser.add_argument("--pty", action="store_true")
    options = parser.parse_args()
    if not 5 <= options.seconds <= 60:
        parser.error("--seconds must be between 5 and 60")
    if options.mode == "performance":
        intervals = tuple(int(value) for value in options.intervals.split(","))
        if any(value not in (1, 2) for value in intervals) or not intervals:
            parser.error("--intervals accepts 1 and/or 2")
        performance(options.seconds, options.gentle, intervals, options.keep_stdin, options.pty)
    else:
        traffic()
