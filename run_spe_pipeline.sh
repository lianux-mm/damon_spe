#!/bin/bash
# run_spe_pipeline.sh - 联动 workload + damon_spe_ctl.sh 的一键脚本
#
# 用法:
#   sudo ./run_spe_pipeline.sh sparse_8g
#   sudo ./run_spe_pipeline.sh hot_workload
#
# 前提: 已编译 spe_hist, pfn_to_va; THP=always

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKLOAD="$1"
INTERVAL="${2:-10}"
THRESHOLD="${3:-30}"

[ -n "$WORKLOAD" ] || { echo "Usage: $0 {sparse_8g|hot_workload} [interval] [threshold]"; exit 1; }

info() { echo "[$(date +%H:%M:%S)] $*"; }
die()  { echo "FAIL: $*" >&2; exit 1; }

DAMON=/sys/kernel/mm/damon/admin
[ -d "$DAMON" ] || die "DAMON sysfs not available"

# ===== 1. 编译 workload（如需要）=====
if [ "$WORKLOAD" = "hot_workload" ]; then
    info "编译 hot_workload..."
    gcc -O2 -o /tmp/hot_workload "$SCRIPT_DIR/hot_workload.c" || die "compile failed"
    WL_BIN=/tmp/hot_workload
    WL_STDERR=/tmp/hot_workload.log
    # hot_workload 输出 pid/addr/size 到 stdout
elif [ "$WORKLOAD" = "sparse_8g" ]; then
    WL_BIN=/data/mm/sparse_8g
    WL_STDERR=/tmp/sparse_8g.log
    [ -x "$WL_BIN" ] || die "sparse_8g not found at $WL_BIN"
else
    die "unknown workload: $WORKLOAD (use sparse_8g or hot_workload)"
fi

# ===== 2. 停止旧 DAMON，设 THP=always =====
echo 0 > "$DAMON/kdamonds/nr_kdamonds" 2>/dev/null || true
echo always > /sys/kernel/mm/transparent_hugepage/enabled

# ===== 3. 启动 workload =====
info "启动 workload: $WORKLOAD"
if [ "$WORKLOAD" = "hot_workload" ]; then
    # hot_workload 直接输出 pid/addr/size 到 stdout
    $WL_BIN 300 "$THRESHOLD" > /tmp/wl_stdout.txt &
    WL_PID=$!
    # 等待它输出 pid/addr/size
    for i in $(seq 1 20); do
        if grep -q '^pid=' /tmp/wl_stdout.txt 2>/dev/null; then
            break
        fi
        sleep 1
    done
    eval $(sed 's/ /\n/g' /tmp/wl_stdout.txt | grep -E '^(pid|addr|size)=')
    WL_PID=$pid
    REGION_START=$addr
    REGION_END=$(printf "0x%lx" $((addr + size)))
else
    # sparse_8g 输出进度到 stderr，PID=xxx 标志进入稀疏阶段
    $WL_BIN 2>"$WL_STDERR" &
    WL_PID=$!
    info "等待 workload 进入稀疏访问阶段（populate + THP collapse ~15s）..."
    for i in $(seq 1 30); do
        if grep -q '^PID=' "$WL_STDERR" 2>/dev/null; then
            break
        fi
        echo -n "."
        sleep 2
    done
    echo ""
    WL_PID=$(grep '^PID=' "$WL_STDERR" | tail -1 | cut -d= -f2)
    [ -n "$WL_PID" ] || die "workload 启动失败，未能获取 PID"

    # 从 /proc/<pid>/maps 取最大匿名区域
    eval $(awk '/rw-p.*00:00 0 /{
        split($1,a,"-"); s=strtonum("0x"a[1]); e=strtonum("0x"a[2]);
        if(e-s > m){m=e-s; vs=s; ve=e}
    } END{printf "REGION_START=0x%x REGION_END=0x%x", vs, ve}' /proc/$WL_PID/maps)
fi

# 等待 THP collapse
sleep 3
AH=$(awk '/AnonHugePages:/{s+=$2}END{print s}' /proc/$WL_PID/smaps 2>/dev/null || echo 0)
info "workload: PID=$WL_PID  region=$REGION_START-$REGION_END  AnonHugePages=${AH}kB"

# ===== 4. 运行 SPE 流水线 =====
# Default to --no-spe smaps mode: ARM SPE phys_addr → pfn_to_va
# reverse mapping can be unreliable (0 matches on some hardware),
# and the merge step combining adjacent THP ranges into one big
# filter triggers a DAMON address filter boundary condition where
# sz_tried=0.  smaps-based THP range discovery is simpler and
# proven reliable.  Remove --no-spe for SPE-based sparse detection.
info "启动 split 流水线（${INTERVAL}s smaps scan, threshold=${THRESHOLD}%）..."
"$SCRIPT_DIR/damon_spe_ctl.sh" \
    --no-spe \
    --pid "$WL_PID" \
    --start "$REGION_START" \
    --end "$REGION_END" \
    --interval "$INTERVAL" \
    --threshold "$THRESHOLD"

# ===== 5. 清理 =====
info "流水线完成"
kill $WL_PID 2>/dev/null || true
