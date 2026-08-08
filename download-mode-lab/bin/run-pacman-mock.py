#!/usr/bin/env python3
"""Run pacman --downloadonly against a local delayed repo, in an isolated root."""
from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path


def wait_port(path: Path, timeout: float = 5.0) -> int:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if path.exists():
            return int(path.read_text().strip())
        time.sleep(0.02)
    raise RuntimeError(f"server port file did not appear: {path}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--mode', choices=('native', 'xfer'), required=True)
    ap.add_argument('--parallel', type=int, required=True)
    ap.add_argument('--delay', type=float, default=0.6)
    ap.add_argument('--output', type=Path, required=True)
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    fixtures = root / 'fixtures'
    trial = fixtures / f"trial-{args.mode}-{args.parallel}"
    if trial.exists():
        shutil.rmtree(trial)
    (trial / 'cache').mkdir(parents=True)
    (trial / 'db').mkdir(parents=True)
    (trial / 'root').mkdir(parents=True)
    port_file = trial / 'server.port'
    server_log = trial / 'server.json'
    server = subprocess.Popen([
        sys.executable, str(root / 'bin/mock-repo-server.py'),
        '--directory', str(fixtures / 'repo'), '--port-file', str(port_file),
        '--log-file', str(server_log), '--delay', str(args.delay),
    ])
    try:
        port = wait_port(port_file)
        config = trial / 'pacman.conf'
        lines = [
            '[options]',
            'Architecture = x86_64',
            'SigLevel = Never',
            f'ParallelDownloads = {args.parallel}',
            f'CacheDir = {trial / "cache"}',
        ]
        if args.mode == 'xfer':
            wrapper = root / 'bin/xfer-curl-wrapper.sh'
            lines.append(f'XferCommand = {wrapper} %u %o')
        lines += ['[lab]', f'Server = http://127.0.0.1:{port}']
        config.write_text('\n'.join(lines) + '\n')
        env = os.environ.copy()
        if args.mode == 'xfer':
            env['DOWNLOAD_MODE_XFER_LOG'] = str(trial / 'xfer.log')
        packages = ['pacman-contrib', 'archlinux-keyring', 'coreutils']
        cmd = [
            'fakeroot', 'pacman', '--config', str(config), '--root', str(trial / 'root'),
            '--dbpath', str(trial / 'db'), '--cachedir', str(trial / 'cache'),
            '-Sddw', '--noconfirm', '--needed', *packages,
        ]
        sync_cmd = [
            'fakeroot', 'pacman', '--config', str(config), '--root', str(trial / 'root'),
            '--dbpath', str(trial / 'db'), '--cachedir', str(trial / 'cache'),
            '-Sy', '--noconfirm',
        ]
        sync_started = time.monotonic()
        sync_cp = subprocess.run(sync_cmd, text=True, capture_output=True, env=env, check=False)
        sync_elapsed = time.monotonic() - sync_started
        started = time.monotonic()
        cp = subprocess.run(cmd, text=True, capture_output=True, env=env, check=False)
        elapsed = time.monotonic() - started
        # Stop server so it writes its final event summary.
        server.send_signal(signal.SIGINT)
        server.wait(timeout=5)
        server_data = json.loads(server_log.read_text()) if server_log.exists() else {'server_log': 'UNAVAILABLE'}
        result = {
            'mode': args.mode,
            'parallel': args.parallel,
            'delay_seconds': args.delay,
            'command': cmd,
            'sync_exit_code': sync_cp.returncode,
            'sync_elapsed_seconds': round(sync_elapsed, 3),
            'exit_code': cp.returncode,
            'elapsed_seconds': round(elapsed, 3),
            'server': server_data,
            'xfer_log_present': (trial / 'xfer.log').exists(),
            'stdout_tail': cp.stdout[-4000:],
            'sync_stderr_tail': sync_cp.stderr[-2000:],
            'stderr_tail': cp.stderr[-4000:],
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps({k: result[k] for k in ('mode', 'parallel', 'exit_code', 'elapsed_seconds', 'xfer_log_present')}, ensure_ascii=False))
        return cp.returncode
    finally:
        if server.poll() is None:
            server.terminate()
            try:
                server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()


if __name__ == '__main__':
    raise SystemExit(main())
