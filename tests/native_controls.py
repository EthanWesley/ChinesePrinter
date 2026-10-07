"""Exercise the actual native writer on a regular file, without a USB device."""
import os
import pathlib
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / '.deleted' / '2026-10-07'
ARCHIVE.mkdir(parents=True, exist_ok=True)
WORK = pathlib.Path(tempfile.mkdtemp(prefix='native-controls-', dir=ARCHIVE))
BINARY = pathlib.Path(sys.argv[1]).resolve()


def count(file):
    try:
        return int(file.read_text().strip())
    except (ValueError, FileNotFoundError):
        return -1


def until(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError('condition timed out')


def launch(name):
    folder = WORK / name
    folder.mkdir()
    device, pause, stop, progress = [folder / value for value in ['device', 'pause', 'stop', 'progress']]
    device.touch()
    process = subprocess.Popen([
        str(BINARY), '--device', str(device), '--report-delay', '5',
        '--pause-file', str(pause), '--stop-file', str(stop), '--progress-file', str(progress)
    ], stdin=subprocess.PIPE)
    process.stdin.write(b'code 19913\ncontrol enter\ncode 933\n' * 4)
    process.stdin.close()
    return folder, process, device, pause, stop, progress


def decode_reports(data):
    digits = {0x62: '0', **{0x59 + n: str(n + 1) for n in range(9)}}
    result, current = [], ''
    for offset in range(0, len(data), 8):
        report = data[offset:offset + 8]
        assert len(report) == 8
        if report[0] == 4 and report[2] in digits:
            current += digits[report[2]]
        elif report[0] == 0 and report[2] == 0 and current:
            result.append('code ' + current)
            current = ''
        elif report[0] == 0 and report[2] == 0x28:
            result.append('control enter')
    assert not current, 'Alt sequence must be complete'
    return result


folder, process, device, pause, stop, progress = launch('resume')
try:
    until(lambda: count(progress) >= 2)
    pause.touch()
    time.sleep(0.15)  # finish the current character, then acknowledge the pause
    paused_at = count(progress)
    assert 2 <= paused_at < 12
    assert device.read_bytes()[-8:] == bytes(8), 'Alt must be released while paused'
    time.sleep(0.15)
    assert count(progress) == paused_at, 'progress must remain fixed while paused'
    os.replace(pause, folder / 'pause.retained')
    assert process.wait(timeout=5) == 0
    assert count(progress) == 12
    assert decode_reports(device.read_bytes()) == ['code 19913', 'control enter', 'code 933'] * 4
    print('PASS native pause/resume preserves every character and releases Alt')
finally:
    if process.poll() is None:
        stop.touch()
        process.wait(timeout=5)

folder, process, device, pause, stop, progress = launch('stop')
try:
    until(lambda: count(progress) >= 2)
    pause.touch()
    time.sleep(0.15)
    paused_at = count(progress)
    started = time.monotonic()
    stop.touch()
    assert process.wait(timeout=2) == 0
    assert time.monotonic() - started < 1
    assert count(progress) == paused_at < 12
    assert device.read_bytes()[-8:] == bytes(8)
    assert len(decode_reports(device.read_bytes())) == paused_at
    print('PASS native stop responds while paused and sends no later characters')
finally:
    if process.poll() is None:
        stop.touch()
        process.wait(timeout=5)

print('Artifacts retained:', WORK)
