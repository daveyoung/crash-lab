# Answers — The panic stack

## 1. Which CPU, which task

**CPU 1, task `bash` (PID 581).**

The cheap command is `bt -p`, which asks the dump for the panic task:

```
crash> bt -p
PID: 581      TASK: ffff88807db98000  CPU/NUMA:    1/0    COMMAND: "bash"
```

The evidence is threefold, and they agree:

- the frame header says `CPU/NUMA: 1/0` and `COMMAND: "bash"`;
- `set -p` followed by `task` prints `STATE: TASK_RUNNING (PANIC)`;
- the oops line in `log` says `CPU: 1 ... PID: 581 Comm: bash`.

If `bt -p` had not worked, `bt -a` would have given the same answer a different
way: only the CPU whose stack contains `page_fault_oops`/`oops_end` took the
fault, and on CPU 1 that is PID 581. The other three CPUs are `swapper/N` in the
idle loop, with NMI backtraces from the crash path.

## 2. Faulting address and instruction

**The faulting address is 0 (`CR2`). The instruction is
`movl $0xdeadbeef,0x0` at `crashlab_trigger_write.cold+63`.**

Two different commands prove the two halves:

```
crash> log -T | grep CR2
[...] CR2: 0000000000000000 [...]

crash> dis ffffffffa00000a2
0xffffffffa00000a2 <crashlab_trigger_write.cold+63>:	movl   $0xdeadbeef,0x0
```

The `RIP` comes from the exception frame (`bt -e` shows
`RIP: ffffffffa00000a2`), and the value is `0xdeadbeef` being stored to absolute
address zero. The `#PF` line in the log adds that it was a **write** to a
not-present page.

If you quote only one of `CR2` or `RIP`, the description is wrong: `CR2` is the
address the pointer held, `RIP` is the code that used it. Here both point at the
same bug, but they are different facts.

## 3. Process or interrupt context

**Process context.**

The frames that settle it:

- `entry_SYSCALL_64_after_hwframe` at the bottom with `CS: 0033` — the task
  entered the kernel through a syscall from userspace, not through an interrupt.
- `do_syscall_64` → `ksys_write` → `vfs_write` → `full_proxy_write` — an ordinary
  call chain for a `write(2)`, all in the context of the calling task.
- The panic task is `bash`, and the same task appears in `bt -p`, in `task`, and
  in the oops line's `Comm: bash`.

An interrupt-context fault would look different: the stack would begin in the
interrupt entry code (`irqentry_*`, `asm_common_interrupt`, or an exception
stack), and `current` would name whichever task happened to be running — which
is not necessarily the task whose code faulted. The presence of a userspace
syscall frame below the fault is the strongest single signal.
