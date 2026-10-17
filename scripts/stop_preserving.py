#!/usr/bin/env python3
"""Stop one named container and its verified warmup processes; never remove it."""
import argparse
import os
from pathlib import Path
import signal
import subprocess


def matches(argv, root, container, boot_pid, pid):
    prewarm = str(root / 'scripts/prewarm.py')
    boot = str(root / 'scripts/boot_warm.py')
    return ((len(argv) >= 4 and argv[1] == prewarm and argv[3] == container)
            or (pid == boot_pid and len(argv) >= 2 and argv[1] == boot))


def stop_aux(root, container, proc=Path('/proc')):
    try:
        boot_pid = int((root / 'cache/boot_warm.pid').read_text().strip())
    except (FileNotFoundError, ValueError):
        boot_pid = None
    for entry in proc.iterdir():
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        try:
            argv = (entry / 'cmdline').read_bytes().rstrip(b'\0').decode().split('\0')
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
        if not matches(argv, root, container, boot_pid, pid):
            continue
        fd = None
        try:
            # Pin process identity before reading its argv; PID recycling cannot
            # redirect the signal. Failure is reported, not replaced by pkill.
            fd = os.pidfd_open(pid)
            argv = (entry / 'cmdline').read_bytes().rstrip(b'\0').decode().split('\0')
            if matches(argv, root, container, boot_pid, pid):
                signal.pidfd_send_signal(fd, signal.SIGTERM)
                print(f'stopped verified auxiliary PID {pid}')
        except (ProcessLookupError, FileNotFoundError):
            pass
        finally:
            if fd is not None:
                os.close(fd)


def stop_container_if_present(container):
    inspected = subprocess.run(
        ['docker', 'inspect', '--format', '{{.Id}}', container],
        capture_output=True,
        text=True,
    )
    if inspected.returncode != 0:
        stderr = inspected.stderr or ''
        normalized_stderr = stderr.lower()
        missing = any(marker in normalized_stderr for marker in ('no such object:', 'no such container:'))
        if missing and container.lower() in normalized_stderr:
            print(f'container already absent: {container}')
            return
        raise subprocess.CalledProcessError(
            inspected.returncode,
            inspected.args,
            output=inspected.stdout,
            stderr=inspected.stderr,
        )
    subprocess.run(['docker', 'stop', '--timeout', '30', container], check=True)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--root', type=Path, required=True)
    p.add_argument('--container', required=True)
    a = p.parse_args()
    if not a.root.is_absolute() or not a.container or a.container.startswith('-'):
        p.error('absolute root and explicit container name required')
    stop_aux(a.root, a.container)
    stop_container_if_present(a.container)

if __name__ == '__main__':
    main()
