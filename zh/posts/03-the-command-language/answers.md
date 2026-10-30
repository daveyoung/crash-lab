# 答案：命令语言

## 1. 可中断任务与空闲任务写进同一个文件

```crash
foreach IN bt > in.txt
foreach ID bt >> id.txt
```

这份 dump 命中 46 个可中断任务、43 个空闲任务。写命令之前 `ps -S` 就会给出数字：

```
crash> ps -S
  RU: 5
  IN: 46
  ID: 43
```

`UN` 不在其中，是因为崩溃时没有处于 `TASK_UNINTERRUPTIBLE`（`ps(1)` 里的 `D`）的任务。文件系统或驱动卡死时才会出现 `UN`，第 7 篇会用到；这份 dump 上它什么也选不中，空文件就是正确结果。

第二条用 `>>`，因为 `>` 会截断。两次都用 `>`，`in.txt` 里只剩空闲任务。

每个任务的输出是头部加自己的栈：

```
PID: 1        TASK: ffff888002949c00  CPU/NUMA:    3/0    COMMAND: "systemd"
 #0 [ffffc900000b3d48] __schedule at ffffffff816708b8
```

## 2. 不知道 PID，切到 panic 任务

```crash
set -p
task
```

`task` 打出的状态能证明选对了：

```
    PID: 581
COMMAND: "bash"
   TASK: ffff88807db98000  [THREAD_INFO: ffff88807db98000]
    CPU/NUMA:    1/0
  STATE: TASK_RUNNING (PANIC)
```

`(PANIC)` 表示 `crash` 选中的是内核死时正在运行的任务。dump 里没有 panic 任务时（例如 QEMU monitor 抓的），启动时用 `--no_panic`，上下文落在 `swapper/0` 上。

只看状态成员：

```
crash> task -R __state
PID: 581      TASK: ffff88807db98000  CPU/NUMA:    1/0    COMMAND: "bash"
  __state = 0,
```

这个内核的成员叫 `__state`，不是 `state`，所以 `task -R state` 会失败。

## 3. 能干净退出的命令文件

```
# triage.crash
set scroll off
sys
bt -a
ps -S
log -T
kmem -i
mod
exit
```

```sh
crash -s --no_scroll -i triage.crash ~/crash-lab/linux/vmlinux ~/crash-lab/vmcore > report.txt
echo $?
```

末尾必须写 `exit`。不写也能结束，但返回码是 1：

```
$ crash -s --no_scroll -i noexit.crash vmlinux vmcore > /dev/null; echo $?
1
$ crash -s --no_scroll -i triage.crash vmlinux vmcore > /dev/null; echo $?
0
```

`-s --no_scroll` 关掉分页器和横幅，报告里只留数据。两次运行行数相同、结构相同，只有地址随 dump 变。
