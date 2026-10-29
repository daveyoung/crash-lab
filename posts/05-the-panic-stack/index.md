# The panic stack

**The first frames of a panic trace tell you how the kernel died, not why. The reason is in the middle, at the exception frame, and the story that led there is below it.**

Open the `null` dump and run `bt`:

```
crash> bt
PID: 581      TASK: ffff88807db98000  CPU/NUMA:    1/0    COMMAND: "bash"
 #0 [ffffc90000e6bb98] machine_kexec at ffffffff810e5a8d
 #1 [ffffc90000e6bba8] __crash_kexec at ffffffff81191acc
 #2 [ffffc90000e6bc60] crash_kexec at ffffffff81191ffb
 #3 [ffffc90000e6bc70] oops_end at ffffffff810c4973
 #4 [ffffc90000e6bc90] page_fault_oops at ffffffff810ecdc7
 #5 [ffffc90000e6bd10] exc_page_fault at ffffffff8166d18c
 #6 [ffffc90000e6bd60] asm_exc_page_fault at ffffffff810011b6
    [exception RIP: crashlab_trigger_write.cold+63]
    RIP: ffffffffa00000a2  RSP: ffffc90000e6be18  RFLAGS: 00010286
    RAX: 0000000000000005  RBX: 0000000000000005  RCX: ffffffff81bfbff8
    RDX: ffffc9000003f1c8  RSI: 0000000000000001  RDI: ffffc9000003d2c0
    RBP: ffff888002ec6180   R8: 3fffffffffffbfff   R9: ffffffff81b87288
    R10: bfffffffffffc000  R11: 3fffffffffffc000  R12: 000055698282ffa0
    R13: 0000000000000005  R14: ffffc90000e6bf00  R15: ffff88800331d300
    ORIG_RAX: ffffffffffffffff  CS: 0010  SS: 0018
 #7 [ffffc90000e6be30] full_proxy_write at ffffffff8136ec89
 #8 [ffffc90000e6be68] vfs_write at ffffffff81250f1d
 #9 [ffffc90000e6bee8] ksys_write at ffffffff812513e6
#10 [ffffc90000e6bf18] do_syscall_64 at ffffffff816690c6
#11 [ffffc90000e6bf40] entry_SYSCALL_64_after_hwframe at ffffffff810000b0
    RIP: 00007f2e8955022e  RSP: 00007ffe3f258bf0  RFLAGS: 00000202
    ORIG_RAX: 0000000000000001  CS: 0033  SS: 002b
```

Frames 0 to 6 are not the fault. They are the kernel's death procedure: the page fault was reported, the oops handler decided the kernel had to die, and `kexec` handed the machine to the crash kernel. Every panic has some version of these frames; they are the same on a NULL deref, a BUG() and a deliberate `panic()`.

The reason is the exception frame: the kernel was executing `crashlab_trigger_write.cold+63` when it touched memory it should not have. Frames 7 to 11 are how it got there: a `write(2)` system call went through the generic write path into the module.

## Start with the log

The banner gives a one-line summary, but `log` has the full text, and it is the authority:

```
crash> log -T | grep -E 'BUG:|#PF|Oops:|RIP: 0010|CR2|CPU:' | head
[Mon Oct 26 18:55:15 CST 2026] BUG: kernel NULL pointer dereference, address: 0000000000000000
[Mon Oct 26 18:55:15 CST 2026] #PF: supervisor write access in kernel mode
[Mon Oct 26 18:55:15 CST 2026] #PF: error_code(0x0002) - not-present page
[Mon Oct 26 18:55:15 CST 2026] Oops: Oops: 0002 [#1] SMP
[Mon Oct 26 18:55:15 CST 2026] CPU: 1 UID: 0 PID: 581 Comm: bash Kdump: loaded Tainted: G           O         7.3.0+ #16 PREEMPT(full)
[Mon Oct 26 18:55:15 CST 2026] RIP: 0010:crashlab_trigger_write.cold+0x3f/0x5d [crashlab]
[Mon Oct 26 18:55:15 CST 2026] CR2: 0000000000000000 CR3: 000000007dae6006 CR4: 0000000000172eb0
```

Four facts are already enough to describe the crash: it was a write, it was in process context (`Comm: bash`, not an interrupt), it happened on CPU 1, and the faulting address was zero. `Kdump: loaded` says the crash kernel was armed, which is the only reason there is a dump at all.

`CR2` is the faulting address. Do not confuse it with `RIP`: `CR2` says *where the pointer pointed*, `RIP` says *which instruction did the dereference*. Here `CR2 = 0` and `RIP` is inside the module.

## Find the panicking task

`bt -p` asks for the panic task directly, and it is the cheapest way to get the right CPU:

```
crash> bt -p
PID: 581      TASK: ffff88807db98000  CPU/NUMA:    1/0    COMMAND: "bash"
 #0 [ffffc90000e6bb98] machine_kexec at ffffffff810e5a8d
 [...]
```

If that fails — a dump without panic notes, such as a QEMU monitor dump — fall back to `bt -a`, where the CPU that died is the one whose stack has the oops path:

```
crash> bt -a
PID: 581      TASK: ffff88807db98000  CPU/NUMA:    1/0    COMMAND: "bash"
 #0 [ffffc90000e6bb98] machine_kexec at ffffffff810e5a8d
 [...]
PID: 0        TASK: ffffffff81a0a680  CPU/NUMA:    0/0    COMMAND: "swapper/0"
 #0 [fffffe000000dea8] crash_nmi_callback at ffffffff810dd0ef
 #1 [fffffe000000deb0] default_do_nmi at ffffffff8166bff9
 [...]
```

The other CPUs were idle, parked in `pv_native_safe_halt`, and their "stack" is an NMI backtrace: the crash path used an NMI to stop them. That shape — one CPU with an oops path, the rest in the idle loop — is what you expect from a single-threaded fault in process context.

## Read the stack in both directions

Top-down, the numbers tell you the death path. Bottom-up, they tell you the story.

- **#11 `entry_SYSCALL_64_after_hwframe`** — the syscall entry. Everything below is userspace (`CS: 0033`).
- **#10 `do_syscall_64` → #9 `ksys_write` → #8 `vfs_write`** — the generic write path. The task really did call `write()`.
- **#7 `full_proxy_write`** — debugfs's proxy, the layer that forwards a write to the file's own `write` handler.
- **#6 `asm_exc_page_fault` → #4 `page_fault_oops` → #3 `oops_end`** — the fault was taken and judged fatal.
- **#2 `crash_kexec` → #1 `__crash_kexec` → #0 `machine_kexec`** — the kernel left for the crash kernel.

The exception frame sits between #6 and #7, and its `RIP` is the instruction that failed:

```
crash> dis ffffffffa00000a2
0xffffffffa00000a2 <crashlab_trigger_write.cold+63>:	movl   $0xdeadbeef,0x0
```

That is the whole crash in one line: store `0xdeadbeef` to absolute address zero. The `$0x0` is a 32-bit absolute addressing form, which is why the faulting address is `CR2 = 0` rather than some variable that happened to be NULL.

Note the symbol: `crashlab_trigger_write.cold`. GCC splits a function into a hot part and an out-of-line cold part when it judges a branch unlikely; the NULL store landed in the cold fragment, which starts 0xbd bytes after the function. `bt` naming `.cold` is normal, not a sign of corruption. Post 4's `dis` covers the mechanics.

## The `?` frames in the log

The kernel's own Call Trace is not the same list as `crash bt`. In this oops it
contains entries like:

```
 ? filp_flush+0x4b/0x80
 ? filp_close+0x20/0x30
 ? do_dup2+0xa9/0x140
 ? ksys_dup3+0x62/0xe0
```

The leading `?` marks a frame the unwinder could not confirm. These are leftover
return addresses from earlier calls that happened to still be on the stack — the
shell had just done file-descriptor work — not part of this call chain. Treat
them as noise: the confirmed chain is the short one, entry to syscall to write
to proxy to module.

## The exception frame is a structure you can read

`bt -e` prints every exception frame the unwinder can find:

```
crash> bt -e
  KERNEL-MODE EXCEPTION FRAME AT: ffffc90000e6bbb8
    [exception RIP: crashlab_trigger_write.cold+63]
    RIP: ffffffffa00000a2  RSP: ffffc90000e6be18  RFLAGS: 00010286
    RAX: 0000000000000005  RBX: 0000000000000005  [...]
    ORIG_RAX: ffffffffffffffff  CS: 0010  SS: 0018

  KERNEL-MODE EXCEPTION FRAME AT: ffffc90000e6bd68
    [exception RIP: crashlab_trigger_write.cold+63]
    [...]

  USER-MODE EXCEPTION FRAME AT: ffffc90000e6bf48
    [...]
```

Two kernel-mode frames with the same `RIP` are normal here: the oops path records the same register set at more than one point on the stack, and the unwinder reports each place it finds the signature. The user-mode frame at the bottom is the syscall's return frame, not a second fault.

The frame is a `struct pt_regs` in memory, so you can read it like any other structure:

```
crash> px ((struct pt_regs *)0xffffc90000e6bbb8)->ip
$1 = 0xffffffffa00000a2
crash> px ((struct pt_regs *)0xffffc90000e6bbb8)->sp
$2 = 0xffffc90000e6be18
crash> px ((struct pt_regs *)0xffffc90000e6bbb8)->ax
$3 = 0x5
```

`ip` matches the faulting instruction and `sp` matches the frame's `RSP`. That is how you check that the unwinder is pointing at the frame you think it is, rather than at a stale copy.

### The five bytes in the registers

The exception frame's registers are not decoration. `RAX` and `RBX` both hold
`5`, and that is the length of what the task wrote: `echo null` sends
`"null\n"`, five bytes. The write path copied those five bytes into the
module's 16-byte buffer, the string compared equal, and the fault followed.

```
crash> px ((struct pt_regs *)0xffffc90000e6bbb8)->ax
$3 = 0x5
```

A register value matching an obvious user-space input is a cheap way to tie a
kernel frame to the command someone typed. It is also a reminder that the module
trusted its input: five bytes were enough.

## The stack as data

`bt -f` prints the raw words alongside each frame. One of them is the saved return address:

```
crash> bt -f
 #0 [ffffc90000e6bb98] machine_kexec at ffffffff810e5a8d
    ffffc90000e6bba0: ffffc90000e6bd68 ffffffff81191acc
 [...]
    ffffc90000e6bc30: ffffffffffffffff ffffffffa00000a2
```

`ffffffffa00000a2` on the stack is the same value as the exception `RIP`; `ffffffff81191acc` is `__crash_kexec`, the return address into the caller. When symbols are missing or wrong, these raw words are what you fall back to: `sym <address>` names them, and the pattern of return addresses still outlines the call chain.

## Source lines

`bt -l` inserts the source location for each frame:

```
crash> bt -l
 #0 [ffffc90000e6bb98] machine_kexec at ffffffff810e5a8d
    /home/you/git/private/ai/linux/arch/x86/kernel/machine_kexec_64.c: 454
 #1 [ffffc90000e6bba8] __crash_kexec at ffffffff81191acc
    /home/you/git/private/ai/linux/kernel/crash_core.c: 145
 #3 [ffffc90000e6bc70] oops_end at ffffffff810c4973
    /home/you/git/private/ai/linux/arch/x86/kernel/dumpstack.c: 378
 #4 [ffffc90000e6bc90] page_fault_oops at ffffffff810ecdc7
    /home/you/git/private/ai/linux/arch/x86/mm/fault.c: 724
```

Module frames get lines only when the module's debug info is loaded (`mod -S`); without it you get the symbol and the offset, which is still enough to disassemble.

## Process context, not interrupt context

The shape of the stack answers the question before you reason about it:

- the bottom is `entry_SYSCALL_64_after_hwframe` with `CS: 0033`, so the task entered from userspace;
- the faulting frame is a normal function, not `irqentry_*` or an exception stack;
- the panicking task is `bash`, and `current` on that CPU is that same task.

An interrupt-context fault looks different: the stack starts with the entry code for the interrupt, there may be no `pt_regs` from userspace at all, and `current` names whichever task was unlucky enough to be running. Confusing the two leads to blaming the wrong task.

Confirm the task itself rather than assuming it:

```
crash> set -p
crash> task
    PID: 581
COMMAND: "bash"
   TASK: ffff88807db98000  [THREAD_INFO: ffff88807db98000]
    CPU/NUMA:    1/0
  STATE: TASK_RUNNING (PANIC)
```

`STATE: TASK_RUNNING (PANIC)` is `crash` agreeing with the stack: this is the task the kernel selected as the panic task, and it was running on the CPU that faulted.

## Symptom and cause

Sort the frames into two piles before writing anything down.

**How it died:** `asm_exc_page_fault`, `page_fault_oops`, `oops_end`, `crash_kexec`, `machine_kexec`. These appear on every fatal fault and tell you nothing specific.

**Why it died:** `full_proxy_write` called into the module, and the module executed a store to address zero. The `write()` path explains how the module was reached; the exception `RIP` and `CR2` explain what went wrong there.

A useful test: if you replaced the module frame with a different bug, would the "cause" pile change? If it would not, you are still reading the death procedure.

| frame | pile | what it tells you |
| --- | --- | --- |
| `asm_exc_page_fault` | how it died | a page fault reached the entry code |
| `page_fault_oops` | how it died | the fault was in kernel mode and fatal |
| `oops_end` | how it died | the kernel decided to stop |
| `crash_kexec`, `machine_kexec` | how it died | the crash kernel took over |
| `full_proxy_write` | why it died | debugfs forwarded the write to the module |
| `crashlab_trigger_write.cold+63` | why it died | the module stored to address 0 |

If the top frame had been `panic` called from a lock validator, or `BUG()` in a
list function, the split would look different: the same "how it died" pile, a
different reason, and the reason is what the rest of this series keeps chasing.

## Traps

- The top frame is where it died, not necessarily why. Read past `oops_end` and `crash_kexec`.
- `bt -p` needs panic notes. A QEMU monitor dump has none; say so and use `bt -a`.
- A `?` in a trace marks an unreliable frame (the unwinder guessed). Do not build a conclusion on one.
- Inlining and optimisation move code: `crashlab_trigger_write.cold` is the same function, not a different one.
- `CR2` is the address that was touched; `RIP` is the instruction that touched it. Quoting one as the other is a classic mistake.
- An interrupt-context fault has a different stack shape; `current` is not necessarily the victim.
- The panic string can name a secondary failure — a lock warning that panicked, or a BUG() on a corrupted list — rather than the first error.

## Exercises

1. Which CPU panicked, and which task was running on it? State the evidence, not just the answer.
2. What is the faulting address, and which instruction dereferenced it? Show the command that proves both.
3. Was the fault in process or interrupt context? Which frames prove it?

Answers are in [`answers.md`](answers.md).

## Cheat sheet

| question | command |
| --- | --- |
| panic task only | `bt -p` |
| every CPU | `bt -a` |
| one CPU | `bt -c N` |
| stack plus raw words | `bt -f` |
| with source lines | `bt -l` |
| exception frames | `bt -e` |
| the panic text | `log -T` (or `log`) |
| full oops header | `log` around `BUG:` / `RIP:` |
| instruction at an address | `dis <address> [count]` (a bare address prints one) |
| read the saved frame | `p *(struct pt_regs *)<addr>` |
| select the panic task | `set -p` |
| what task is that | `task` |

---

**Versions.** `crash 9.0.3++` (gdb 16.2); kernel `7.3.0+` (x86_64, DWARF5,
`UNWINDER_ORC=y`, `KALLSYMS_ALL=n`, no KASLR); dump `vmcore` from
`makedumpfile -l -d 31`; panic produced by a NULL store with
`panic_on_oops=1`. Addresses and PIDs come from one run.

Previous: [Symbols, types, addresses](../04-symbols-types-addresses/index.html) · Index: [all posts](../../index.html).
