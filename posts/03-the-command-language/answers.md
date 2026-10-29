# Answers — The command language

## 1. Interruptible and idle tasks to one file

```crash
foreach IN bt > in.txt
foreach ID bt >> id.txt
```

**Counts on this dump:** 46 interruptible tasks, 43 idle tasks. `ps -S` is the
command that tells you so before you write the loop:

```
crash> ps -S
  RU: 5
  IN: 46
  ID: 43
```

**Why `UN` is not in that list:** the letters come from the task state at the
moment of the crash, and nothing was in `TASK_UNINTERRUPTIBLE` (`D` in `ps(1)`
terms) when this machine died. `UN` is the letter to reach for when a
filesystem or a driver is stuck — Post 7 — but on this dump it selects nothing,
and an empty file is the correct output, not a broken command.

**Why `>>` for the second one:** `>` truncates. Using it twice would leave only
the idle tasks in `in.txt`, which is exactly the mistake the exercise is
designed to make memorable.

**What the output looks like:** each task gets a header and its own stack:

```
PID: 1        TASK: ffff888002949c00  CPU/NUMA:    3/0    COMMAND: "systemd"
 #0 [ffffc900000b3d48] __schedule at ffffffff816708b8
 ...
```

## 2. Panic task without its PID

```crash
set -p
task
```

`task` is the proof. It prints the task's identity and its state, and the state
line is what distinguishes the panic task from every other sleeping task:

```
    PID: 581
COMMAND: "bash"
   TASK: ffff88807db98000  [THREAD_INFO: ffff88807db98000]
    CPU/NUMA:    1/0
  STATE: TASK_RUNNING (PANIC)
```

`(PANIC)` is `crash` saying it selected the task that was running when the
kernel died, rather than guessing. If the dump had no panic task — a QEMU
monitor dump, for example — `set -p` cannot invent one, and the honest answer is
`--no_panic` at startup, which puts you on `swapper/0` instead.

For a narrower check, `task -R __state` prints only the state member:

```
crash> task -R __state
PID: 581      TASK: ffff88807db98000  CPU/NUMA:    1/0    COMMAND: "bash"
  __state = 0,
```

`__state = 0` is `TASK_RUNNING`, consistent with the panic task being the task
that was executing on the CPU. Note the member name: this kernel's field is
`__state`, not `state`, so `task -R state` fails and the error is the hint.

## 3. A command file that exits cleanly

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

**What you have to put at the end:** `exit`.

**What happens if you forget it:** `crash` still terminates at end of file, so
the run does not hang — but it exits with status **1**, and any wrapper that
checks `$?` will record the triage as failed. That is worse than a hang,
because it is silent:

```
$ crash -s --no_scroll -i noexit.crash vmlinux vmcore > /dev/null; echo $?
1
$ crash -s --no_scroll -i triage.crash vmlinux vmcore > /dev/null; echo $?
0
```

**Why `-s --no_scroll`:** without them the pager can consume the output in a
non-interactive run, and `set scroll off` inside the file may be too late.
`-s` also sets `silent`, which keeps the report to data rather than banners.

**Determinism:** two runs produce the same line count and the same structure.
Addresses, PIDs, and timestamps vary with the dump; nothing else should.
