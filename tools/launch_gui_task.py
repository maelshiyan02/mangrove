"""在**用户交互桌面**上拉起 mangrove.exe（供 Agent 做 GUI 截图核验）。

为什么要这个
------------
`run_headless_task.py` 用 `<LogonType>S4U</LogonType>`：任务跑在**没有桌面**的
会话里，Flutter 引擎拿不到渲染表面 ——

    EGL Error: Context Lost (12302) Surface creation failed.
    Failed to create platform view rendering surface

headless 命令不在乎这个（它不画界面），但**GUI 窗口会直接不出现**，进程十几秒
后自己退出（日志停在 `SystemFonts scanned 139 faces` 就没了）。同理，从 Agent
沙盒里直接 `cmd /c start mangrove.exe` 也起不来 —— 沙盒进程没有可用的图形表面。

`<LogonType>InteractiveToken</LogonType>` 让任务挂在**当前登录用户**的会话里跑，
窗口就出现在用户桌面上；之后 `builds/winshot_mangrove.py`（PrintWindow）即便
窗口被其他程序挡住也能截到图。

前提：目标用户**必须处于登录状态**（InteractiveToken 不保存密码，只借用
现有登录会话）。本机 Administrator 常驻登录，满足。

用法
----
    python tools/launch_gui_task.py            # 拉起，等窗口出现
    python tools/launch_gui_task.py --kill     # 先杀掉现有实例再拉
"""

import os
import sys
import time

import win32com.client

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = os.path.join(ROOT, "builds", "mangrove", "mangrove.exe")
BAT = os.path.join(ROOT, "tools", "gui_once.bat")
TASK_NAME = "MangroveGuiOnce"

# 0 = TASK_LOGON_NONE（由 XML 里的 LogonType 决定）
# 3 = TASK_LOGON_INTERACTIVE_TOKEN
# 6 = TASK_CREATE_OR_UPDATE
TASK_CREATE_OR_UPDATE = 6
TASK_LOGON_INTERACTIVE_TOKEN = 3

XML = """<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>WorkBuddy</Author>
    <Description>Mangrove GUI launch on the interactive desktop</Description>
  </RegistrationInfo>
  <Triggers />
  <Principals>
    <Principal id="Author">
      <UserId>Administrator</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <Enabled>true</Enabled>
    <StartWhenAvailable>true</StartWhenAvailable>
    <MultipleInstancesPolicy>Parallel</MultipleInstancesPolicy>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>cmd.exe</Command>
      <Arguments>/c "%s"</Arguments>
    </Exec>
  </Actions>
</Task>
"""


def write_bat() -> None:
    """生成的批处理也用「自身位置推导根目录」，仓库里不留绝对路径。"""
    with open(BAT, "w", encoding="ascii", newline="\r\n") as f:
        f.write("@echo off\n")
        f.write('for %%I in ("%~dp0..") do set "ROOT=%%~fI"\n')
        f.write('cd /d "%ROOT%\\builds\\mangrove"\n')
        f.write('start "" "%ROOT%\\builds\\mangrove\\mangrove.exe"\n')


def kill_existing() -> None:
    os.system('taskkill /IM mangrove.exe /F >nul 2>&1')


def main() -> int:
    if "--kill" in sys.argv:
        kill_existing()
        # 等句柄释放，避免新实例去抢还被占用的 db/wal。
        time.sleep(3)

    if not os.path.exists(EXE):
        print(f"missing exe: {EXE}", file=sys.stderr)
        return 2

    write_bat()

    scheduler = win32com.client.Dispatch("Schedule.Service")
    scheduler.Connect()
    root = scheduler.GetFolder("\\")
    try:
        root.DeleteTask(TASK_NAME, 0)
    except Exception:
        pass
    definition = scheduler.NewTask(0)
    definition.XmlText = XML % BAT
    root.RegisterTaskDefinition(
        TASK_NAME, definition, TASK_CREATE_OR_UPDATE, None, None,
        TASK_LOGON_INTERACTIVE_TOKEN,
    )
    root.GetTask(TASK_NAME).Run("")

    # 等窗口出现（最多 40s）。窗口没出来就是真的没起来，不要假装成功。
    import win32gui
    import win32process

    deadline = time.time() + 40
    hwnd = 0
    while time.time() < deadline:
        found = []

        def cb(h, _):
            try:
                if win32gui.GetClassName(h) != "FLUTTER_RUNNER_WIN32_WINDOW":
                    return True
                if not win32gui.IsWindowVisible(h):
                    return True
                found.append(h)
                return False
            except Exception:
                return True

        win32gui.EnumWindows(cb, None)
        if found:
            hwnd = found[0]
            break
        time.sleep(1)

    if not hwnd:
        print("NO_WINDOW (app did not reach the interactive desktop)", file=sys.stderr)
        return 3

    _, pid = win32process.GetWindowThreadProcessId(hwnd)
    print(f"window hwnd={hwnd} pid={pid}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
