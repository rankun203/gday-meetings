#!/usr/bin/env python3
"""Measure one command and retain an explicit receipt, including failed attempts.

Run with uv run --no-project --with psutil python measure.py --help.
Receipts and logs can contain local command arguments; store them under tmp/.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import time

try:
    import psutil
except ImportError:
    psutil = None


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def write_receipt(path, data):
    temporary = path.with_suffix(path.suffix + '.partial')
    temporary.write_text(json.dumps(data, indent=2) + '\n')
    temporary.replace(path)


def directory_size(directory):
    """Measure apparent file bytes only at boundaries, excluding symbolic links."""
    total = 0
    errors = []
    for root, dirs, files in os.walk(directory, onerror=lambda error: errors.append(str(error))):
        dirs[:] = [name for name in dirs if not Path(root, name).is_symlink()]
        for name in files:
            path = Path(root, name)
            try:
                if not path.is_symlink():
                    total += path.stat().st_size
            except OSError as error:
                errors.append(str(error))
    return {'bytes': total if not errors else None, 'errors': errors[:10]}


def hardware():
    result = {'system': platform.system(), 'release': platform.release(),
              'machine': platform.machine(), 'processor': platform.processor() or None,
              'logical_cpu_count': os.cpu_count(), 'physical_cpu_count': None,
              'ram_bytes': None, 'model': None}
    if psutil:
        for field, query in [('physical_cpu_count', lambda: psutil.cpu_count(logical=False)),
                             ('ram_bytes', lambda: psutil.virtual_memory().total)]:
            try:
                result[field] = query()
            except (psutil.Error, OSError):
                pass
    if platform.system() == 'Darwin':
        for field, key in [('model', 'hw.model'), ('ram_bytes', 'hw.memsize'),
                           ('processor', 'machdep.cpu.brand_string')]:
            probe = subprocess.run(['/usr/sbin/sysctl', '-n', key], capture_output=True, text=True)
            if probe.returncode == 0:
                value = probe.stdout.strip()
                result[field] = int(value) if field == 'ram_bytes' else value
    return result


def run(args):
    output = Path(args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        raise ValueError('Receipt already exists. Use a new output path for each attempt.')
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        raise ValueError('Provide a command after --.')
    directory = Path(args.directory).resolve() if args.directory else None
    if directory is not None and not directory.is_dir():
        raise ValueError('The measured directory must already exist.')
    receipt = {'schema_version': 1, 'stage': args.stage, 'command': command,
               'cwd': os.getcwd(), 'started_at': utc_now(), 'status': 'running',
               'host': hardware(), 'sampling_interval_seconds': args.interval,
               'directory': str(directory) if directory else None,
               'directory_before': directory_size(directory) if directory else None,
               'limitations': [
                   'Sampled tree RSS is the largest observed sum of resident bytes; shared pages may be counted more than once and short-lived children may be missed.',
                   'wait4 peak RSS is the platform-reported child high-water value, not a simultaneous sum across the process tree.',
                   'CPU time comes from wait4 resource usage, including waited-for descendants. Detached or unjoined descendants may be omitted.',
                   'GPU, Neural Engine, device memory, energy, and unrelated system activity are not attributed.',
                   'Directory growth is net apparent file size at stage boundaries, not peak disk use or allocated blocks.',
                   'Wall time includes process launch and up to one memory sampling interval before completion is observed.']}
    write_receipt(output, receipt)
    process = None
    usage = None
    log = None
    interrupted = []
    previous_handlers = {}
    sample_errors = set()
    peak_tree_rss = None
    samples = 0
    readable_samples = 0
    started = time.monotonic()
    stop_deadline = None

    def reap(options):
        nonlocal usage
        if process is None or process.returncode is not None:
            return
        pid, status, measured = os.wait4(process.pid, options)
        if pid:
            process.returncode = os.waitstatus_to_exitcode(status)
            usage = measured

    def stop(signum, frame):
        nonlocal stop_deadline
        interrupted.append(signum)
        if process is not None and process.returncode is None:
            try:
                os.killpg(process.pid, signum)
                stop_deadline = time.monotonic() + 5
            except ProcessLookupError:
                pass

    try:
        if args.stdout_log:
            log_path = Path(args.stdout_log)
            log_path.parent.mkdir(parents=True, exist_ok=True)
            log = log_path.open('xb')
            receipt['stdout_log'] = str(log_path.resolve())
        for signum in (signal.SIGINT, signal.SIGTERM):
            previous_handlers[signum] = signal.signal(signum, stop)
        started = time.monotonic()
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT if log else None,
                                   start_new_session=True)
        root = None
        if psutil:
            try:
                root = psutil.Process(process.pid)
            except (psutil.Error, OSError) as error:
                sample_errors.add(f'{type(error).__name__}: {error}')
        while process.returncode is None:
            reap(os.WNOHANG)
            if process.returncode is not None:
                break
            samples += 1
            if root:
                try:
                    members = [root, *root.children(recursive=True)]
                    sizes = []
                    complete = True
                    for member in members:
                        try:
                            sizes.append(member.memory_info().rss)
                        except psutil.NoSuchProcess:
                            pass
                        except (psutil.Error, OSError) as error:
                            complete = False
                            sample_errors.add(f'{type(error).__name__}: {error}')
                    if complete and sizes:
                        readable_samples += 1
                        peak_tree_rss = max(peak_tree_rss or 0, sum(sizes))
                except (psutil.Error, OSError) as error:
                    sample_errors.add(f'{type(error).__name__}: {error}')
            if stop_deadline is not None and time.monotonic() >= stop_deadline:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                stop_deadline = None
            time.sleep(args.interval)
        receipt['exit_status'] = process.returncode
        receipt['status'] = 'interrupted' if interrupted else 'completed' if process.returncode == 0 else 'failed'
    except Exception as error:
        receipt.update(status='failed', exit_status=None)
        receipt['measurement_error' if process is not None else 'launch_error'] = f'{type(error).__name__}: {error}'
    finally:
        if process is not None and process.returncode is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            reap(0)
        if interrupted and process is not None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
        if log:
            log.close()
        receipt['wall_seconds'] = time.monotonic() - started
        receipt['finished_at'] = utc_now()
        receipt['interrupt_signals'] = interrupted
        receipt['cpu_and_process_peak'] = {
            'user_seconds': usage.ru_utime if usage else None,
            'system_seconds': usage.ru_stime if usage else None,
            'peak_rss_bytes': (usage.ru_maxrss * (1 if platform.system() == 'Darwin' else 1024)) if usage else None,
            'source': 'os.wait4 child resource usage'}
        receipt['sampled_process_tree'] = {'peak_rss_bytes': peak_tree_rss,
            'samples': samples, 'complete_memory_samples': readable_samples,
            'errors': sorted(sample_errors), 'source': 'psutil' if psutil else None}
        if not psutil:
            receipt['limitations'].append('psutil is unavailable; process-tree memory sampling is unavailable.')
        receipt['directory_after'] = directory_size(directory) if directory else None
        before, after = receipt['directory_before'], receipt['directory_after']
        receipt['directory_growth_bytes'] = (after['bytes'] - before['bytes']
            if before and after and before['bytes'] is not None and after['bytes'] is not None else None)
        write_receipt(output, receipt)
    if interrupted:
        return 128 + interrupted[0]
    code = receipt.get('exit_status')
    return (128 - code if code < 0 else code) if code is not None else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, help='New JSON receipt path for this attempt.')
    parser.add_argument('--stage', required=True)
    parser.add_argument('--stdout-log', '--log', help='New file receiving combined stdout and stderr.')
    parser.add_argument('--directory', help='Existing output directory to size before and after the command.')
    parser.add_argument('--interval', type=float, default=0.2, help='Memory sampling interval in seconds (default: 0.2).')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.interval <= 0:
        parser.error('--interval must be greater than zero.')
    try:
        return run(args)
    except ValueError as error:
        parser.error(str(error))


if __name__ == '__main__':
    raise SystemExit(main())
