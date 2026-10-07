import os
import time

import win32com.client

# 🔴 不要在脚本里写死项目根：项目根目录将来会改名/搬迁。
#    本脚本位于 tools/ 下，用自身位置推导根目录。
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TASK_NAME = "VeneraBuild"
BAT = os.path.join(ROOT, "tools", "build_venera_with_log.bat")
LOG = os.path.join(ROOT, "builds", "build.log")

# Ensure the log exists so the polling below has something to read early.
open(LOG, "w").close()

xml = f"""<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>WorkBuddy</Author>
    <Description>VeneraX release build</Description>
  </RegistrationInfo>
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
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>cmd.exe</Command>
      <Arguments>/c "{BAT}"</Arguments>
    </Exec>
  </Actions>
</Task>
"""

scheduler = win32com.client.Dispatch("Schedule.Service")
scheduler.Connect()
root = scheduler.GetFolder("\\")
try:
    root.DeleteTask(TASK_NAME, 0)
except Exception:
    pass

task_def = scheduler.NewTask(0)
task_def.XmlText = xml

root.RegisterTaskDefinition(
    TASK_NAME,
    task_def,
    6,  # TASK_CREATE_OR_UPDATE
    None,
    None,
    0,  # logon type already in XML
)

running = root.GetTask(TASK_NAME)
running.Run("")
print("task started")

# Poll the build log until it clearly finished.
deadline = time.time() + 900
result = None
while time.time() < deadline:
    try:
        with open(LOG, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    except FileNotFoundError:
        time.sleep(2)
        continue
    if "BUILD_OK" in text:
        result = "BUILD_OK"
        break
    if "BUILD_FAIL" in text:
        result = "BUILD_FAIL"
        break
    time.sleep(3)

if result is None:
    result = "TIMEOUT"

print("=== RESULT:", result, "===")
try:
    with open(LOG, "r", encoding="utf-8", errors="replace") as f:
        tail = f.read()[-4000:]
    print("--- build.log tail ---")
    print(tail)
except Exception as e:
    print("no log:", e)
