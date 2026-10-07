"""Run one `venera.exe --headless ...` command through Task Scheduler and capture its output.

Why this exists
---------------
`builds/venera/venera.exe` is a **GUI-subsystem** binary, and its `main.cpp`
unconditionally calls `::AttachConsole(ATTACH_PARENT_PROCESS)`. When it is
launched from a shell that *has* a console (Git Bash, cmd, PowerShell), that
call re-binds stdout/stderr to the console and **discards the caller's
redirection** — so `venera.exe ... > out.txt` produces an empty file even
though the command ran fine. The result: every headless failure looks like
"exit 1 with no output at all", which is indistinguishable from a crash before
Dart even starts.

A scheduled task has **no parent console**, so `AttachConsole` fails, the
`> file` redirection stands, and stdout/stderr are finally visible.

Usage
-----
    python tools/run_headless_task.py page-reconcile "gm28k//my-dragon..." --source comix_to --json builds/page_reconcile.json

Output goes to `builds/headless.out` (and is echoed to this process' stdout).

Exit status: 0 = the CLI's own closing line said `success`; 1 = it said `error`
(或压根没有收尾行); -1 = 等输出超时. 🔴 引擎退出码（`=== HL_EXIT=`）**只是信息**、
不参与判定 —— 见 `verdict()` 的注释。

🔴 不要在脚本里写死项目根：项目根目录将来会改名/搬迁。
   本脚本用自身位置推导（tools/ 的上一级）。
"""

import json
import os
import sys
import time

import win32com.client

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = os.path.join(ROOT, "builds", "venera", "venera.exe")
BAT = os.path.join(ROOT, "tools", "headless_once.bat")
OUT = os.path.join(ROOT, "builds", "headless.out")
TASK_NAME = "VeneraHeadlessOnce"


def quote(arg: str) -> str:
    return f'"{arg}"' if (" " in arg or "\t" in arg) else arg


def verdict(text: str) -> str:
    """Return 'success' | 'error' | None by reading the CLI's own closing line.

    🔴 Do NOT use the process exit code. Measured on 2026-10-07:

        edit-check (PASS, 122 checks)      -> %ERRORLEVEL% = -532265403
        project-check (bad args, status=error) -> %ERRORLEVEL% = -532265403

    Identical. `-532265403` is what the Flutter engine returns when it shuts
    down without ever getting a rendering surface (this session has none), so
    it only proves "the engine started and exited" — it carries **no**
    information about whether the command succeeded. Judging by it is worse
    than useless: it can never fail.

    The CLI is the authority. `headless.dart` prints, as its final line:

        [CLI PRINT] {"status":"success"|"error", "message": ...}

    (mid-run lines are `"status":"running"`). So the verdict is the last
    success/error line in the output.
    """
    last = None
    for line in text.splitlines():
        line = line.strip()
        if not line.startswith("[CLI PRINT]"):
            continue
        body = line[len("[CLI PRINT]"):].strip()
        try:
            payload = json.loads(body)
        except ValueError:
            # Shape changed under us — fall back to a substring probe rather
            # than silently reporting "no verdict".
            for st in ("success", "error"):
                if f'"status":"{st}"' in body or f'"status": "{st}"' in body:
                    last = st
            continue
        st = payload.get("status")
        if st in ("success", "error"):
            last = st
    return last


def run(command: list[str]) -> tuple[int, str]:
    if not command:
        raise SystemExit("usage: run_headless_task.py <headless-command> [args...]")

    args = " ".join(quote(a) for a in command)
    # 生成的批处理也用「自身位置推导根目录」（%~dp0 = tools\），
    # 这样仓库里不会留下写死的绝对路径 —— 项目根改名后依然可用。
    with open(BAT, "w", encoding="ascii", newline="\r\n") as f:
        f.write("@echo off\n")
        f.write('for %%I in ("%~dp0..") do set "ROOT=%%~fI"\n')
        f.write('cd /d "%ROOT%"\n')
        f.write(f'"%ROOT%\\builds\\venera\\venera.exe" --headless {args} > "%ROOT%\\builds\\headless.out" 2>&1\n')
        f.write('echo === HL_EXIT=%ERRORLEVEL% === >> "%ROOT%\\builds\\headless.out"\n')

    # 🔴 No `os.remove(OUT)` here. The generated batch already redirects with
    # `>`, which truncates the file, so the delete bought nothing — and a batch
    # driver that runs the app dozens of times (the S9 reverse-verification loop
    # runs it ~35 times in one turn) tripped the environment's bulk-delete guard
    # and had every run after the 50th refused with
    # `SAFE_DELETE_BULK_CONFIRM_REQUIRED`.
    #
    # 🔴🔴 But truncation **by the shell** is not sufficient on its own: the
    # batch truncates only once its `venera.exe` line starts, and this function
    # begins polling the instant the scheduled task is fired. When the previous
    # run had already left `=== HL_EXIT=` in the file, the very first poll read
    # the *previous* run's output and returned immediately — 0.6s "runs" that
    # reported a stale FAIL for a build that had actually passed (this is
    # exactly what produced the bogus `Edit check FAIL` at 17:31 in P9.7's
    # investigation). Truncating from Python **before** the task is registered
    # costs nothing, is not a delete, and removes the window entirely.
    open(OUT, "w").close()

    xml = """<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Author>WorkBuddy</Author><Description>VeneraX headless one-shot</Description></RegistrationInfo>
  <Triggers />
  <Principals>
    <Principal id="Author">
      <UserId>Administrator</UserId>
      <LogonType>S4U</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <Enabled>true</Enabled>
    <StartWhenAvailable>true</StartWhenAvailable>
    <MultipleInstancesPolicy>Parallel</MultipleInstancesPolicy>
    <ExecutionTimeLimit>PT10M</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>cmd.exe</Command>
      <Arguments>/c "%s"</Arguments>
    </Exec>
  </Actions>
</Task>
""" % BAT

    scheduler = win32com.client.Dispatch("Schedule.Service")
    scheduler.Connect()
    root = scheduler.GetFolder("\\")
    try:
        root.DeleteTask(TASK_NAME, 0)
    except Exception:
        pass
    definition = scheduler.NewTask(0)
    definition.XmlText = xml
    root.RegisterTaskDefinition(TASK_NAME, definition, 6, None, None, 0)
    root.GetTask(TASK_NAME).Run("")

    deadline = time.time() + 600
    text = ""
    while time.time() < deadline:
        if os.path.exists(OUT):
            with open(OUT, "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
            if "=== HL_EXIT=" in text:
                break
        time.sleep(1)

    print(text, flush=True)
    if "=== HL_EXIT=" not in text:
        print("[run_headless_task] timed out waiting for output", file=sys.stderr)
        return -1, text

    # The batch reaching `echo === HL_EXIT=` only proves the engine started and
    # shut down cleanly enough to return — NOT that the command succeeded.
    engine_exit = text.split("=== HL_EXIT=")[-1].split()[0]
    v = verdict(text)
    if v == "success":
        print(f"[run_headless_task] verdict=success (engine exit {engine_exit}; informational only)")
        return 0, text
    # `error` and `None` both fail: a run with no closing verdict is not
    # evidence of success (empty result ⇒ FAIL).
    print(
        f"[run_headless_task] verdict={v or 'NONE (no closing [CLI PRINT] line)'} "
        f"(engine exit {engine_exit}; informational only)",
        file=sys.stderr,
    )
    return 1, text


if __name__ == "__main__":
    # 🔴 The verdict MUST reach the caller as the process exit code.
    #
    # This used to be:
    #     subprocess.run(["cmd", "/c", "exit", str(code)])
    #     sys.exit(0)
    # `cmd /c exit N` sets the exit code of that *child* process and nothing
    # else; the script then exited 0 unconditionally. Net effect: every caller
    # saw success no matter what the command did — a permanent false green, and
    # the reason a wiped `headless.out` was indistinguishable from a pass.
    code, _ = run(sys.argv[1:])
    sys.exit(code)
