#!/bin/bash
# 缺页补全接力：等上一批下载进程全部退出后，自动启动下一批。
#
# 为什么要接力而不是一次跑完：
#   `--restart-each` 每章都要新建浏览器 + 全新 profile + 45~100s 冷却，
#   7 章一轮要跑半小时以上。单条命令串起来跑，中途任何一次会话异常
#   都会带走整批；分成两批 + 接力，第一批的成果不会丢。
#
# 用法： tools/gap_fix_relay.sh <漫画目录> <hid> <group> <numbers> [site-tag]
set -u

cd "$(dirname "$0")/.." || exit 1

OUT_DIR="${1:?漫画目录必填}"
HID="${2:?hid 必填}"
GROUP="${3:?翻译组必填}"
NUMBERS="${4:?话号必填，逗号分隔}"
SITE_TAG="${5:-comix.to}"

PY=py
command -v "$PY" > /dev/null 2>&1 || PY=python

echo "[relay] 等待现有 comix 下载进程退出……"
while ps -ef | grep "comix_browser_dl.py download" | grep -v grep > /dev/null 2>&1; do
    sleep 15
done
echo "[relay] 队列空闲，启动：numbers=$NUMBERS group=$GROUP"

PYTHONUNBUFFERED=1 "$PY" -3.12 -u tools/comix_browser_dl.py download "$HID" \
    --out "$OUT_DIR" \
    --numbers "$NUMBERS" \
    --group "$GROUP" \
    --restart-each \
    --gap 45,100 \
    --cool 300 \
    --max-fail 3 \
    --site-tag "$SITE_TAG"

echo "[relay] 批次结束 rc=$?"
