# The lab: build a kernel you can crash, and a dump you can read

**A postmortem is only as good as the kernel that produced it. Before the first crash you need three things: debug info that includes struct layouts, symbols for the code that will fail, and a kernel that can hand its memory to a second kernel. After that, the crash itself is four commands.**

The first attempt at this lab ended in one line:

```
$ crash -s ~/crash-lab/linux/arch/x86/boot/bzImage ~/crash-lab/vmcore
crash: /home/you/crash-lab/linux/arch/x86/boot/bzImage: not a supported file format
```

`bzImage` is what the machine boots. `vmlinux` is what `crash` reads. Everything in this post is arranged so that the next person builds a kernel where that distinction is the only trap left.

Paths in the transcripts are shortened to `~/crash-lab`. Addresses, build numbers, and sizes come from one specific build; yours will differ.

## What the kernel must have

A kernel can be perfectly healthy and useless for postmortem work. These are the options that matter:

| option | value | why |
| --- | --- | --- |
| `CONFIG_DEBUG_INFO` | `y` | the DWARF that `crash` reads types from |
| `CONFIG_DEBUG_INFO_DWARF5` | `y` | modern default; `DWARF4` is the fallback if a tool chokes |
| `CONFIG_DEBUG_INFO_REDUCED` | `n` | reduced DWARF drops struct members; `ps` and `struct` degrade |
| `CONFIG_DEBUG_INFO_SPLIT` | `n` | split DWARF puts types in `.dwo` files, not in `vmlinux` |
| `CONFIG_KALLSYMS` | `y` | the symbol table, including module text |
| `CONFIG_KALLSYMS_ALL` | `n` | data symbols; off here, and the cost is visible |
| `CONFIG_UNWINDER_ORC` | `y` | no frame pointers; `bt` depends on this |
| `CONFIG_RANDOMIZE_BASE` | `n` | no KASLR, so runtime addresses match the file |
| `CONFIG_KEXEC`, `CONFIG_CRASH_DUMP`, `CONFIG_PROC_VMCORE` | `y` | the kdump path |
| `CONFIG_DEBUG_FS` | `y` | the module's trigger file |
| `CONFIG_MODULES` | `y` | `crashlab.ko` |

The two that "look like debug info" and are not are `REDUCED` and `SPLIT`. Both must be off. A `ps` that prints task names but cannot walk `task_struct` is worse than a clear failure.

`KALLSYMS_ALL` is the interesting one. With it off, function symbols still resolve and data symbols do not; this lab runs with it off so that the limitation is something you can see rather than read about. Post 17 comes back to it.

The debug information is real, not a stripped stub:

```
$ readelf -S vmlinux | grep -E 'debug_info|debug_abbrev|debug_line'
  [41] .debug_info       PROGBITS         0000000000000000  011acac0
  [42] .debug_abbrev     PROGBITS         0000000000000000  077525b5
  [43] .debug_line       PROGBITS         0000000000000000  07abb198
```

## Build it

```sh
cd ~/crash-lab/linux
make -j"$(nproc)" bzImage modules
```

Three outputs matter, and only one of them is a namelist:

| file | what it is |
| --- | --- |
| `vmlinux` | ELF with DWARF — the namelist |
| `arch/x86/boot/bzImage` | compressed boot image — what the machine boots |
| `System.map` | text: addresses and names, no types |

The build reports its own identity, which you will need later:

```
Kernel: arch/x86/boot/bzImage is ready  (#16)
```

`#16 SMP PREEMPT_DYNAMIC ...` is the version string that appears in the `crash` banner. It is not a build ID; Post 1 explains why the difference matters.

## The export trap

The module failed to link the first time:

```
ERROR: modpost: crashlab.ko: symbol 'debugfs_create_dir' undefined!
ERROR: modpost: crashlab.ko: symbol 'debugfs_create_file_full' undefined!
ERROR: modpost: crashlab.ko: symbol 'debugfs_remove' undefined!
ERROR: modpost: crashlab.ko: symbol 'strim' undefined!
ERROR: modpost: crashlab.ko: symbol 'sysfs_streq' undefined!
make[4]: *** [scripts/Makefile.modpost:147: Module.symvers] Error 1
```

The symbols exist in `vmlinux`, so this is confusing until you look at why they are not exported. `CONFIG_TRIM_UNUSED_KSYMS=y` removes exported symbols that no in-tree module uses. If your config has very few `=m` entries, almost everything gets trimmed, and an out-of-tree module cannot resolve what it needs.

Two ways out: turn trimming off, or keep it and name the exceptions. Keeping trimming is the better default — a lean `vmlinux` is the point of the option — so keep a whitelist file with the lab:

```
debugfs_create_dir
debugfs_create_file_full
debugfs_remove
strim
sysfs_streq
```

and one config line pointing at it (an absolute path, or one relative to the
kernel tree — `~` is not expanded here):

```
CONFIG_TRIM_UNUSED_KSYMS=y
CONFIG_UNUSED_KSYMS_WHITELIST="/home/you/crash-lab/ksym-whitelist.txt"
```

After `make olddefconfig` and a rebuild, the export exists again:

```
$ nm vmlinux | grep __ksymtab_debugfs_create_dir
ffffffff819c71f4 r __ksymtab_debugfs_create_dir
```

The whitelist is part of the lab and grows as later posts add module modes. Each addition means a rebuild and a new dump.

## Build the module

`crashlab.ko` is the deliberately buggy module from [`crashlab/`](../../crashlab/). Its `null` mode writes to address zero from the debugfs write path, so the faulting task is your shell and the stack is short:

```c
if (sysfs_streq(buf, "null")) {
	volatile u32 *p = (volatile u32 *)0;

	pr_info("CRASHLAB: null deref triggered by pid %d (%s)\n",
		current->pid, current->comm);

	*p = 0xdeadbeef;
	return count;	/* not reached */
}
```

Build it against the tree you just built:

```sh
cd ~/crash-lab/crashlab
make KDIR=~/crash-lab/linux
```

The first build against `7.3.0+` failed on one line:

```
crashlab.c:54:19: error: ‘no_llseek’ undeclared here (not in a function); did you mean ‘noop_llseek’?
   54 |         .llseek = no_llseek,
```

`no_llseek` was removed from the kernel; the module uses `noop_llseek`. That is the only change it needed. The result is a normal out-of-tree module:

```
$ modinfo crashlab.ko
author:         Crash Lab
description:    Crash Lab deliberately buggy test module
license:        GPL
name:           crashlab
vermagic:       7.3.0+ SMP preempt mod_unload
```

## Boot it and get a shell

Boot the kernel you built, in a virtual machine or on a machine you are willing to lose. Note the console you get a shell on, and make sure `debugfs` is mounted:

```
# mount -t debugfs none /sys/kernel/debug
```

Everything from here happens in that guest. It needs the module, a copy of the same `bzImage`, and both `kexec-tools` and `makedumpfile` installed — a minimal rescue image often has neither. How you get them in is your business — a shared directory, a scp, an initramfs, a disk image. The one rule is below.

Two command line arguments do the real work: `console=` for a console you can read, and `crashkernel=256M` for the reservation. How big the reservation must be depends on your userspace; 256 MB is enough for a text-mode rescue environment and is what this lab uses. If the kernel cannot find the reservation at panic time, it has nowhere to put the crash kernel and the machine just reboots.

## Arm the crash kernel

`crashkernel=` on the kernel command line reserves memory for a second kernel. `--reuse-cmdline` carries that reservation into the kernel that will take over:

```
# grep -i crash /proc/iomem
  6a000000-79ffffff : Crash kernel

# kexec -p /path/to/bzImage --reuse-cmdline; echo "kexec rc=$?"
kexec rc=0

# cat /sys/kernel/kexec_crash_loaded
1
# cat /sys/kernel/kexec_crash_size
268435456
```

`kexec -p` takes a `bzImage`, not a `vmlinux`, and it must be the **same build** as the kernel that is running. If those two differ, the crash kernel is a different kernel from the one it is dumping, and the dump loses symbols. Verify:

```sh
sha256sum bzImage            # the one the machine booted
sha256sum /path/to/bzImage   # the one kexec will load
```

Check `kexec_crash_loaded` every time. `kexec -p` returning 0 and a crash kernel actually being armed are two different facts, and only the second one helps you after the panic.

## Die on purpose

A NULL dereference in the kernel oopses and, by default, the machine keeps running. That is the opposite of what this lab needs, so make oopses fatal first:

```
# echo 1 > /proc/sys/kernel/panic_on_oops
# insmod crashlab.ko
crashlab: loading out-of-tree module taints kernel.
CRASHLAB: loaded; write 'null' to /sys/kernel/debug/crashlab/trigger
```

Then trigger it:

```
# echo null > /sys/kernel/debug/crashlab/trigger
```

and the kernel's last words:

```
BUG: kernel NULL pointer dereference, address: 0000000000000000
#PF: supervisor write access in kernel mode
#PF: error_code(0x0002) - not-present page
PGD 0 P4D 0
Oops: Oops: 0002 [#1] SMP
CPU: 1 UID: 0 PID: 581 Comm: bash Kdump: loaded Tainted: G           O         7.3.0+ #16 PREEMPT(full)
Tainted: [O]=OOT_MODULE
```

`Kdump: loaded` is the line to look for: it is the kernel confirming that the crash kernel was armed when it died. Without it, the machine reboots and you get nothing.

## The kdump boot and the capture

The crash kernel boots with an extra argument that points at the state the dying kernel left behind:

```
Command line: elfcorehdr=0x6a000000 rw ... console=ttyS0 crashkernel=256M
```

and it recognises what it is looking at:

```
vmcore: dump is from kernel 7.3.0+
```

Log in, then write the dump out of `/proc/vmcore`:

```
# makedumpfile -l -d 31 /proc/vmcore /root/vmcore
The kernel version is not supported.
The makedumpfile operation may be incomplete.
[... progress bars ...]

The dumpfile is saved to /root/vmcore.

makedumpfile Completed.
```

Two details hide in that output.

`The kernel version is not supported` is `makedumpfile 1.7.9++` not knowing `7.3.0+`. The dump is fine — the kdump kernel says so, and `crash` reads it without complaint. Do not chase this warning; it is version-table lag.

`-d 31` filters page types: zero, cache, cache-private, user, and free pages are not written. That is why every session on this dump says `[PARTIAL DUMP]`. For stacks, tasks, slab, and the log it is enough. For anything that needs user pages, switch to `-d 17` or a fuller level, and keep Post 1's warning in mind about what a partial dump can support.

If you land in the crash kernel but cannot log in, the dump is still sitting in `/proc/vmcore` — until the machine is reset. Fix the login problem, do not reboot.

Get the file to the machine where you run `crash`.

## What the dump can and cannot answer

`-d` is a level, and the level decides which questions survive:

| flag | pages written | what it costs you |
| --- | --- | --- |
| `-d 31` | no zero, cache, cache-private, user, free | user stacks and page-cache contents are gone |
| `-d 17` | keeps user pages, drops zero/cache/free | larger, but user memory is readable |
| `-d 0` | everything | 2 GB of guest RAM becomes a 2 GB file |

For the first arc of this series, `-d 31` is enough: kernel stacks, task
structures, slab, and the log are all in the dump. The moment a post asks about
a userspace buffer or a page-cache page, the same crash has to be re-captured at
a lower level. Decide the level from the question, not from habit.

## Open it

With the matching `vmlinux`:

```sh
crash -s --no_scroll ~/crash-lab/linux/vmlinux ~/crash-lab/vmcore
```

The banner is Post 1's. The smoke test is the point of this post:

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
    [...]
 #7 [ffffc90000e6be30] full_proxy_write at ffffffff8136ec89
 #8 [ffffc90000e6be68] vfs_write at ffffffff81250f1d
 #9 [ffffc90000e6bee8] ksys_write at ffffffff812513e6
#10 [ffffc90000e6bf18] do_syscall_64 at ffffffff816690c6
#11 [ffffc90000e6bf40] entry_SYSCALL_64_after_hwframe at ffffffff810000b0
```

```
crash> kmem -i
                 PAGES        TOTAL      PERCENTAGE
    TOTAL MEM   440931       1.7 GB         ----
         FREE   409488       1.6 GB   92% of TOTAL MEM
         USED    31443     122.8 MB    7% of TOTAL MEM
      BUFFERS        0            0    0% of TOTAL MEM
       CACHED    16567      64.7 MB    3% of TOTAL MEM
         SLAB     3365      13.1 MB    0% of TOTAL MEM
```

Those numbers are computed from whatever page structures survived `-d 31`, so
they are not the machine's real memory usage: this dump reports 92% free on a
booted systemd guest, and `crash` 9.0.2 reported 97% for the same file. On a
partial dump, read `kmem -i` as a shape, not a ledger. `kmem -s` lists slab caches and their object counts, which is a
different question from total memory use.

The stack is complete under ORC with no frame pointers, which matters for Post 6, and the module frame is symbolized even though the module's data symbols are not. The `-s` flag is what makes it scriptable: without it the pager waits for you.

## The QEMU monitor fallback

kdump can fail: not armed, no reserved memory, the crash kernel panics too. Inside QEMU there is always another way, and it is worth knowing the shape of what you get:

```
(qemu) stop
(qemu) dump-guest-memory /path/vmcore.elf
warning: guest note is not present
(qemu) cont
```

The `warning: guest note is not present` is the honest part. This dump has `NOTE` and `LOAD` segments and per-CPU registers, but no `VMCOREINFO`, because a live guest never wrote one. `crash` opens it and tells you:

```
crash: cannot read vmcoreinfo_data
       PANIC: ""
```

No panic task, no panic string, and the dump is a snapshot of a running machine rather than a dying one. Useful, but strictly less than a kdump dump. Stop the guest before dumping, or the pages are inconsistent.

## KASLR, briefly

`CONFIG_RANDOMIZE_BASE` is off in this lab, so the addresses in `vmlinux` are the addresses in the dump, and you never touch `--kaslr`. If a dump has KASLR on, the load offset is in the notes and `crash` can find it with `--kaslr auto`; a dump that lost its notes needs `--kaslr <offset>` from the panic log's `Kernel Offset:` line. When KASLR is on, every address you read is base-relative, and the first thing to check is that `crash` found the offset.

## Traps

- `bzImage` is not a namelist; the build-tree `vmlinux` is.
- `CONFIG_TRIM_UNUSED_KSYMS` will silently un-export what your module needs. Keep the whitelist with the lab.
- `DEBUG_INFO_REDUCED` and `DEBUG_INFO_SPLIT` produce kernels that build and boot and cannot be debugged properly.
- A rebuild after a config change is a different namelist even if the release string matches.
- The `bzImage` your machine boots and the one `kexec -p` loads must be the same build, byte for byte.
- `kexec -p` before the panic, always, and check `/sys/kernel/kexec_crash_loaded` after.
- A plain NULL deref only oopses. Without `panic_on_oops=1` the guest survives and kdump never runs.
- `--reuse-cmdline` must carry `crashkernel=256M`; without a reservation there is nowhere to put the crash kernel.
- `makedumpfile -d 31` loses user pages and page cache. Choose the level for the question you are going to ask.
- `makedumpfile`'s version warning on a newer kernel is cosmetic; the kdump boot log is the authority on whether the dump is valid.
- If `make defconfig` fails with `gcc: unknown assembler invoked`, look at your compiler wrapper before your toolchain: a ccache that cannot write its cache directory produces exactly that message.

## Exercises

1. Why must the `bzImage` loaded by `kexec -p` match the one the machine booted?
2. Which config options make `struct task_struct` usable in `crash` even though the kernel has "debug info"?
3. What does `--no_panic` change, and when is it the right flag?
4. `kexec -p` returns 0, so you crash the machine. It reboots instead of entering kdump. What are the first two things you check?

Answers, with the evidence for each, are in [`answers.md`](answers.md).

## The commands in this post

| where | command | what it proves |
| --- | --- | --- |
| build | `make -j"$(nproc)" bzImage modules` | the artifacts exist and match the config |
| build | `modinfo crashlab.ko` | vermagic matches the kernel |
| host | `sha256sum` on both `bzImage` copies | the boot and kexec images are the same |
| guest | `insmod`, `echo 1 > /proc/sys/kernel/panic_on_oops` | the trigger is armed and fatal |
| guest | `kexec -p`, `cat /sys/kernel/kexec_crash_loaded` | the crash kernel is really armed |
| guest | `echo null > /sys/kernel/debug/crashlab/trigger` | the oops |
| kdump | `makedumpfile -l -d 31 /proc/vmcore /root/vmcore` | the dump, filtered |
| host | `crash -s vmlinux vmcore` | the session |
| host | monitor `dump-guest-memory` | the fallback dump, without kdump |

## Fidelity checklist

Before you believe a session, the answers to these should all be yes:

- the `vmlinux` build ID matches the dump's `crash --build-id`;
- the machine type and CPU count in the banner match the machine you crashed;
- `[TAINTED]` and `[PARTIAL DUMP]`, if present, are explained rather than ignored;
- the kernel config in `vmlinux` is the one you think you built (`DEBUG_INFO`,
  no `REDUCED`, no `SPLIT`);
- module symbols resolve, or you know why they do not;
- the first command you ran did not print a warning you skipped past.

None of that requires a particular VM, rootfs, or hypervisor. It only requires
that the two files came from the same build.

---

**Versions.** Kernel `7.3.0+` (x86_64, no KASLR, DWARF5, `UNWINDER_ORC=y`,
`KALLSYMS_ALL=n`); `crash 9.0.3++`; `makedumpfile 1.7.9++`; QEMU 10.1.2;
GCC 15.2.1. Addresses and build numbers vary between builds and runs.

Previous: [Post 1 — What crash is, and what it needs](../01-what-crash-is/).
