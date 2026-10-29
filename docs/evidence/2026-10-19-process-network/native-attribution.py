#!/usr/bin/python3
"""Two bounded production-C attribution controls; no remote write/upload."""
import sys
sys.dont_write_bytecode = True
import argparse
import http.server
import json
import socketserver
import subprocess
import threading
import time
from pathlib import Path
from probe import clash_state

ROOT = Path(__file__).resolve().parent
HARNESS = "/private/tmp/ftop-native-attribution"
LIMIT = 2 * 1048576


def run(label, arguments, body=None, connect_timeout=5, total_timeout=25):
    observer = subprocess.Popen([HARNESS], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    if observer.stdout.readline().strip() != "ready":
        raise RuntimeError("The read-only observer could not warm up")
    core = subprocess.run(["/usr/bin/pgrep", "-x", "verge-mihomo"], capture_output=True, text=True, timeout=2).stdout.split()
    core_pid = int(core[0]) if len(core) == 1 else 0
    child = subprocess.Popen([
        "/usr/bin/curl", "-q", "--silent", "--fail", "--noproxy", "*", "--max-redirs", "0",
        "--max-time", str(total_timeout), "--connect-timeout", str(connect_timeout), "--max-filesize", str(LIMIT), "--limit-rate", "256k",
        "--output", "/dev/null", "--write-out", "%{size_download},%{size_upload},%{time_total},%{http_code}"
    ] + arguments, stdin=subprocess.PIPE if body else subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    observer.stdin.write("%d %d\n" % (child.pid, core_pid)); observer.stdin.flush()
    output, _ = child.communicate(input=body, timeout=total_timeout + 3)
    time.sleep(3)
    try:
        observer.stdin.write("q\n"); observer.stdin.flush()
    except BrokenPipeError:
        pass
    observer.stdin.close()
    result = observer.stdout.read(8192)
    observer.wait(timeout=5)
    values = output.decode().strip().split(",")
    report = {
        "experiment": label, "curl_exit": child.returncode, "observer_exit": observer.returncode,
        "download_body_bytes": int(float(values[0])) if len(values) == 4 else None,
        "upload_body_bytes": int(float(values[1])) if len(values) == 4 else None,
        "transfer_seconds": float(values[2]) if len(values) == 4 else None,
        "http_status": int(values[3]) if len(values) == 4 else None,
        "observation": json.loads(result), "role_order": ["original_client", "clash_core_concurrent"],
    }
    print(json.dumps(report, sort_keys=True), flush=True)
    return report


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def do_POST(self):
        remaining = min(LIMIT, int(self.headers.get("Content-Length", "0")))
        while remaining:
            value = self.rfile.read(min(65536, remaining))
            if not value:
                break
            remaining -= len(value)
            time.sleep(0.25)
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(LIMIT))
        self.end_headers()
        for _ in range(LIMIT // 65536):
            self.wfile.write(b"x" * 65536)
            time.sleep(0.25)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--retry-get", action="store_true", help="One IPv4 public GET, with local GET fallback only if it fails")
    options = parser.parse_args()
    before, digest = clash_state()
    if options.retry_get:
        reports = [run("public_https_get_2mib_retry_ipv4", ["-4", "https://speed.cloudflare.com/__down?bytes=2097152"], connect_timeout=12, total_timeout=35)]
    else:
        reports = [run("public_https_get_2mib", ["https://speed.cloudflare.com/__down?bytes=2097152"])]
    if not options.retry_get or reports[0]["curl_exit"] != 0:
        server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            url = "http://127.0.0.1:%d/" % server.server_address[1]
            if options.retry_get:
                reports.append(run("local_tcp_get_2mib_fallback", [url]))
            else:
                reports.append(run("local_tcp_post_2mib", ["--data-binary", "@-", url], b"x" * LIMIT))
        finally:
            server.shutdown(); server.server_close()
    after, after_digest = clash_state()
    result = {
        "before": before, "after": after, "runtime_configuration_unchanged": digest == after_digest,
        "public_get_body_limit_bytes_this_run": LIMIT,
        "public_get_body_bytes_across_probe_runs": 2 * 1048576 + sum(item["download_body_bytes"] or 0 for item in reports if item["experiment"].startswith("public_https")),
        "experiments": reports,
        "scope": "Production C socket counters only. First observations/short-lived sources can be missed. Proxy activity is concurrent background-inclusive, never deduplicated or physical throughput.",
    }
    filename = "native-download-retry.json" if options.retry_get else "native-attribution.json"
    (ROOT / filename).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
