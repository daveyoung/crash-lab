# The command language

**`crash` is a small language, not a menu. Once you can steer context, output, and iteration, the same six or seven commands answer questions that would otherwise take a hundred.**

The first attempt at triage was the obvious one:

```
crash> foreach bt | wc -l
1014
```

One thousand and fourteen lines, ninety-four tasks, and the task that matters —
the `bash` that wrote to the trigger file — is somewhere in the middle. Scrolling
is not a plan. Filtering is:

```
crash> foreach 581 bt
PID: 581      TASK: ffff88807db98000  CPU/NUMA:    1/0    COMMAND: "bash"
 #0 [ffffc90000e6bb98] machine_kexec at ffffffff810e5a8d
 #1 [ffffc90000e6bba8] __crash_kexec at ffffffff81191acc
 #2 [ffffc90000e6bc60] crash_kexec at ffffffff81191ffb
 #3 [ffffc90000e6bc70] oops_end at ffffffff810c4973
 #4 [ffffc90000e6bc90] page_fault_oops at ffffffff810ecdc7
 #5 [ffffc90000e6bd10] exc_page_fault at ffffffff8166d18c
 #6 [ffffc90000e6bd60] asm_exc_page_fault at ffffffff810011b6
    [exception RIP: crashlab_trigger_write.cold+63]
```

Nothing in that output is new. What is new is knowing that `foreach` takes a
selector, and that the selector can be a PID, a task pointer, a name, or a state.

## The grammar is small

Every line is `command [options] [arguments]`. The interesting part is the
argument: most commands accept a symbol, a hexadecimal address, a PID, or a
`task_struct` pointer in the same slot.

```
crash> bt 581
crash> bt ffff88807db98000
```

are the same request. So are these:

```
crash> sym ffffffffa0000063
ffffffffa0000063 (t) crashlab_trigger_write.cold [crashlab]
```

That is the address from the exception frame, turned back into a symbol with one
command. Post 4 is entirely about that trick; here it is enough to know the
argument slot is not picky.

## Context is state

`set` with no arguments prints where you are:

```
crash> set
    PID: 581
COMMAND: "bash"
   TASK: ffff88807db98000  [THREAD_INFO: ffff88807db98000]
    CPU/NUMA:    1/0
  STATE: TASK_RUNNING (PANIC)
```

That is the panic task, because `crash` picked it from the dump. Losing the
panic task is common enough that there is a command to get it back:

```
crash> set -p
```

and a command to pin the context to a CPU instead:

```
crash> set -c 2
crash> bt
    PID: 0
COMMAND: "swapper/2"
   TASK: ffff88800294e200  (1 of 4)  [THREAD_INFO: ffff88800294e200]
    CPU/NUMA:    2/0
  STATE: TASK_RUNNING (ACTIVE)
```

Context persists. Every later context-sensitive command — `bt`, `files`, `vm`,
`task` — silently uses whatever `set` left behind. That is useful in a command
file and dangerous in a long interactive session where you forget what you did
three commands ago. `ps` marks the current task with `>` so you can check:

```
      PID    PPID  CPU/NUMA       TASK        ST  %MEM      VSZ      RSS  COMM
        1       0    3/0    ffff888002949c00  IN   0.7    25896    15300  systemd
>     581     516    1/0    ffff88807db98000  RU   0.3   234244     5492  bash
```

## Variables worth setting

`set -v` prints the whole variable table. The ones that matter in a dump:

```
        scroll: off (none)
[...]
         radix: 10 (decimal)
     print_max: 256
   print_array: off
        silent: on
        unwind: off
[...]
```

That sample came from a `-s` run, which is why scrolling is off and `silent` is
on; an interactive session shows `scroll: on (/usr/bin/less)` instead.

`radix` changes how gdb-backed output is printed. Here it starts in decimal,
which is not the default everywhere:

```
crash> p jiffies
jiffies = $1 = 4294905494
crash> set radix 16
output radix: 16 (hex)
crash> p jiffies
jiffies = $2 = 0xffff0e96
```

`print_max` and `print_array` decide whether arrays print whole or truncated.
For a dump you are reading once, defaults are fine. For a report you are about
to diff against another one, they are part of reproducibility.

## Output: pager, pipes, files

By default `crash` pipes output through `less`. In a script that is a hang
waiting to happen, so the usual invocation carries `-s` (`--silent`) and
`--no_scroll`, and inside a session `set scroll off` does the same for the
current run.

Pipes and redirection are standard shell syntax and apply to crash output:

```
crash> log | grep -i crashlab
[   52.971995] CRASHLAB: null deref triggered by pid 581 (bash)
[   52.982059] RIP: 0010:crashlab_trigger_write.cold+0x3f/0x5d [crashlab]
[   53.016379] Modules linked in: crashlab(O)

crash> ps -S > ps-states.txt        # truncates
crash> foreach UN bt >> un.txt      # appends
```

## Input: files

Three ways to feed commands, and they differ at the edges:

```sh
crash -s -i triage.crash vmlinux vmcore   # command file
crash -s vmlinux vmcore < triage.crash    # stdin
crash> ps -p < pidlist                    # per-line arguments to one command
```

`-i` reads the file, executes it, and exits at end of file. Include `exit`
anyway: a file that ends without it still terminates, but `crash` returns 1,
which a wrapper script will read as failure.

The third form is the underused one. A file with one PID per line becomes an
argument list:

```
crash> ps -p < pids.txt
PID: 0        TASK: ffffffff81a0a680  CPU/NUMA:    0/0    COMMAND: "swapper/0"
 PID: 1        TASK: ffff888002949c00  CPU/NUMA:    3/0    COMMAND: "systemd"
  PID: 516      TASK: ffff88807df78000  CPU/NUMA:    2/0    COMMAND: "login"
   PID: 581      TASK: ffff88807db98000  CPU/NUMA:    1/0    COMMAND: "bash"
```

## `foreach` is the loop

`foreach` runs one command against many tasks. The selector is positional:

| selector | meaning |
| --- | --- |
| `pid` | one PID |
| `taskp` | a `task_struct` address |
| `name` | task name; `'regex'` for a POSIX extended regex |
| `kernel` | kernel threads only |
| `user` | user threads only |
| `gleader` | user thread group leaders |
| `active` | the active task on each CPU |
| `state` | one of `RU IN UN ST ZO TR SW DE WA PA ID NE` |
| *(none)* | every task |

The state letters are crash's own and do not match `ps(1)`'s. On this dump:

```
crash> ps -S
  RU: 5
  IN: 46
  ID: 43
```

so `foreach UN bt` — the classic "who is stuck in D state" query — prints
nothing at all, because there are no uninterruptible tasks in this crash. That
is not a failure; it is the answer. The same selector on a hung filesystem
looks very different.

Some selectors in use:

```
crash> foreach kernel bt | head -12          # kernel threads only
crash> foreach active bt                     # one task per CPU
crash> foreach systemd task -R __state       # every "systemd", one member
crash> foreach 'systemd|bash' ps             # regex on the task name
```

`foreach` passes the rest of the line to the inner command, flags included:

```
crash> foreach 581 bt -r
```

means "run `bt -r` on PID 581", not "run `bt` with `foreach`'s `-r`". When a
command name collides with a selector word, escape the name (`\kernel`).

## Aliases, arithmetic, and ASCII

Long-lived session? Name the commands you retype:

```
crash> alias mytask task
ORIGIN   ALIAS    COMMAND
runtime  mytask   task
```

`eval` does address arithmetic and shows every base at once, which is handy when
a frame gives you an offset and you want the symbol it belongs to:

```
crash> eval (0xffffffff81000000 + 0x1000)
hexadecimal: ffffffff81001000  (18014398507401220KB)
    decimal: 18446744071578849280  (-2130702336)
      octal: 1777777777760100010000
     binary: 1111111111111111111111111111111110000001000000000001000000000000

crash> eval -b 0x800
hexadecimal: 800  (2KB)
[...]
   bits set: 11

crash> eval 2g
hexadecimal: 80000000  (2GB)
```

`ascii` turns a number into the bytes it represents, little-endian, which is
exactly what you want when a register or a word in memory looks like text:

```
crash> ascii 6c6c756e
000000006c6c756e: null<NUL><NUL><NUL><NUL>
```

That is the string the module compares against, four bytes in memory order.

`repeat` is the one to avoid. It is usually a live-system tool.

## `.crashrc`

`crash` reads `.crashrc` from the current directory first, then `$HOME`, and
applies any `set` commands there. A stray `set radix 10` changes the numbers in
a report; command files and command-line options override it.

## The file is the unit of triage

Everything above exists so that a triage run is one file and one command line.
The first version is short on purpose:

```
# triage.crash - first pass over an unknown dump
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
```

`report.txt` is 578 lines. The same input file and the same `vmlinux` produce
the same structure, only addresses vary. Post 19 grows this file into a report;
the shape does not change.

## Traps

- `>` truncates, `>>` appends. The wrong one silently destroys yesterday's evidence.
- The pager will swallow output in scripts. `-s` and `--no_scroll`, or `set scroll off` inside the file.
- `set scroll on` is a no-op when crash was started with `-s`; it reports `scroll: off (none)` and you cannot turn it back on for that session.
- Context persists across commands. A `set -c` three commands ago can silently change what `bt` means now.
- `foreach` parsing is positional, and flags belong to the inner command.
- State letters are crash-specific (`UN`, `DE`, `ID`); do not read them as `ps(1)` letters.
- A `-i` file without `exit` exits with status 1.
- `!` runs a shell command, and `!` alone escapes to a shell. Do not feed it untrusted input.
- A `.crashrc` in the current directory or `$HOME` can silently change `set` variables; the command file is what makes the run reproducible.

## Exercises

1. Write the backtraces of all interruptible tasks to `in.txt`, then append the backtraces of all idle tasks to the same file. How many tasks did each selector match, and why is `UN` not one of them here?
2. Put the context on the panic task without knowing its PID, then show its command name and state. Which command proves you got the right task?
3. Turn a three-command triage into `crash -i triage.crash` that runs without a pager and exits with status 0. What do you have to put at the end, and what happens if you forget it?

Answers are in [`answers.md`](answers.md).

## Cheat sheet

| what | how |
| --- | --- |
| run a file | `crash -s --no_scroll -i cmds vmlinux vmcore` |
| feed stdin | `crash -s vmlinux vmcore < cmds` |
| per-line arguments | `ps -p < pids.txt` |
| no pager | `-s --no_scroll`, or `set scroll off` |
| decimal output | `set radix 10` |
| current context | `set` |
| panic task | `set -p` |
| a CPU | `set -c N` |
| one member | `task -R __state` |
| filter a command | `log \| grep -i oops` |
| save / append | `> file`, `>> file` |
| loop over tasks | `foreach [sel] cmd` |
| states | `RU IN UN ST ZO TR SW DE WA PA ID NE` |
| name a command | `alias mytask task` |
| address math | `eval (a + b)` |
| bytes to text | `ascii <hex>` |
| exit | `exit` (and use it in files) |

---

**Versions.** `crash 9.0.3++` (gdb 16.2); kernel `7.3.0+` (x86_64, DWARF5,
`UNWINDER_ORC=y`, `KALLSYMS_ALL=n`); dump `vmcore` from `makedumpfile -l -d 31`
(kdump-compressed v6, `[PARTIAL DUMP]`). Addresses and PIDs come from one run.

Previous: [Post 2 — The lab](../02-the-lab/index.html) · Next: [Post 4 — Symbols, types, addresses](../04-symbols-types-addresses/index.html) · Index: [all posts](../../index.html).
