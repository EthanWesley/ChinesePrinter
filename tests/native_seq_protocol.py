"""Exercise seq_writer's line protocol on regular files, without a USB device."""
import pathlib
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / '.deleted' / '2026-11-17'
ARCHIVE.mkdir(parents=True, exist_ok=True)
WORK = pathlib.Path(tempfile.mkdtemp(prefix='native-seq-', dir=ARCHIVE))
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


def launch(name, script):
    folder = WORK / name
    folder.mkdir()
    kbd, mouse = folder / 'kbd', folder / 'mouse'
    kbd.touch()
    mouse.touch()
    pause, stop = folder / 'pause', folder / 'stop'
    progress, step, error = folder / 'progress', folder / 'step', folder / 'error'
    process = subprocess.Popen([
        str(BINARY), '--kbd', str(kbd), '--mouse', str(mouse),
        '--report-delay', '1', '--stop-file', str(stop),
        '--pause-file', str(pause), '--progress-file', str(progress),
        '--step-file', str(step), '--error-file', str(error)
    ], stdin=subprocess.PIPE)
    process.stdin.write(script)
    process.stdin.close()
    return folder, process, kbd, mouse, pause, stop, progress, step, error


# ---- 1. 全协议：键盘/鼠标/等待/step 标记 ----
SCRIPT = b'''# comment line is ignored
step 0
tap 1 22
code 65
control enter
step 1
mmove 100 -50
mclick 1
wheel -3
wait 20
'''
folder, process, kbd, mouse, pause, stop, progress, step, error = launch('full', SCRIPT)
try:
    assert process.wait(timeout=10) == 0
    assert count(progress) == 9, f'progress={count(progress)}'
    assert count(step) == 1
    assert not error.read_text() if error.exists() else True

    kbd_bytes = kbd.read_bytes()
    # tap(3 报告) + code 65(Alt: 1+2*2+1=6 报告) + control enter(2 报告) + 退出释放(1 报告)
    assert len(kbd_bytes) == (3 + 6 + 2 + 1) * 8, len(kbd_bytes)
    assert kbd_bytes[0:3] == bytes([1, 0, 0x16]), 'tap ctrl+s 按下报告'
    assert kbd_bytes[24:32] == bytes([0x04, 0, 0, 0, 0, 0, 0, 0]), 'code 前 Alt 按下'
    assert kbd_bytes[72:88] == bytes([0, 0, 0x28, 0, 0, 0, 0, 0]) + bytes(8), 'enter 报告'
    assert kbd_bytes[-8:] == bytes(8), '退出前释放所有按键'

    mouse_bytes = mouse.read_bytes()
    # mmove(1) + mclick(2) + wheel(1) + 退出释放(1)
    assert len(mouse_bytes) == 5 * 4, len(mouse_bytes)
    assert mouse_bytes[0:4] == bytes([0, 100, 206, 0]), 'mmove 100,-50'
    assert mouse_bytes[4:8] == bytes([1, 0, 0, 0]), 'mclick 按下'
    assert mouse_bytes[8:12] == bytes([0, 0, 0, 0]), 'mclick 松开'
    assert mouse_bytes[12:16] == bytes([0, 0, 0, 253]), 'wheel -3'
    assert mouse_bytes[16:20] == bytes(4), '退出前释放鼠标按钮'
    print('PASS seq_writer executes the full protocol and reports progress/step')
finally:
    if process.poll() is None:
        stop.touch()
        process.wait(timeout=5)

# ---- 2. 暂停阻塞、恢复后继续 ----
script = b'tap 0 4\n' * 60
folder, process, kbd, mouse, pause, stop, progress, step, error = launch('pause', script)
try:
    until(lambda: count(progress) >= 3)
    pause.touch()
    time.sleep(0.15)
    paused_at = count(progress)
    assert 3 <= paused_at < 60, paused_at
    time.sleep(0.15)
    assert count(progress) == paused_at, 'paused writer must not advance'
    pause.unlink()
    assert process.wait(timeout=15) == 0
    assert count(progress) == 60
    assert kbd.read_bytes()[-8:] == bytes(8), '退出前必须释放按键'
    print('PASS seq_writer pauses at a line boundary and resumes')
finally:
    if process.poll() is None:
        stop.touch()
        process.wait(timeout=5)

# ---- 3. 停止：行边界退出且不继续 ----
folder, process, kbd, mouse, pause, stop, progress, step, error = launch('stop', script)
try:
    until(lambda: count(progress) >= 2)
    started = time.monotonic()
    stop.touch()
    assert process.wait(timeout=3) == 130
    assert time.monotonic() - started < 1
    assert count(progress) < 60
    assert kbd.read_bytes()[-8:] == bytes(8)
    print('PASS seq_writer stops at a line boundary')
finally:
    if process.poll() is None:
        stop.touch()
        process.wait(timeout=5)

# ---- 4. 未知指令：非零退出并写错误文件 ----
folder, process, kbd, mouse, pause, stop, progress, step, error = launch('invalid', b'bogus 1\n')
try:
    assert process.wait(timeout=5) == 3
    assert 'unknown command: bogus' in error.read_text()
    assert count(progress) == 0
    print('PASS seq_writer rejects unknown commands with an error record')
finally:
    if process.poll() is None:
        stop.touch()
        process.wait(timeout=5)

# ---- 5. 绝对模式：mabs 在未启用时被拒绝 ----
folder, process, kbd, mouse, pause, stop, progress, step, error = launch('mabs', b'mabs 100 200\n')
try:
    assert process.wait(timeout=5) == 3
    assert 'absolute' in error.read_text()
    print('PASS seq_writer rejects mabs unless absolute mode is enabled')
finally:
    if process.poll() is None:
        stop.touch()
        process.wait(timeout=5)

print('Artifacts retained:', WORK)
