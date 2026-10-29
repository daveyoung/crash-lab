# What `crash` is, and what it needs

**A `crash` session is a conversation between two files: one holds the bytes, the other holds the meaning. Get the pairing wrong and every answer you get afterwards is fiction that reads like fact.**

The same dump, two sessions, two different `vmlinux` files. The first one is refused:

```
WARNING: could not find MAGIC_START!
crash: ~/crash-lab/build-shift/vmlinux and ~/crash-lab/vmcore do not match!
```

The second one opens, prints a single warning line, and then behaves perfectly:

```
WARNING: kernel version inconsistency between vmlinux and dumpfile

      KERNEL: ~/crash-lab/build-2/vmlinux
    DUMPFILE: ~/crash-lab/vmcore  [PARTIAL DUMP]
        CPUS: 4
        DATE: Mon Oct 26 18:58:21 CST 2026
      UPTIME: 00:03:58
LOAD AVERAGE: 0.72, 0.21, 0.07
       TASKS: 94
    NODENAME: localhost.localdomain
     RELEASE: 7.3.0+
     VERSION: #16 SMP PREEMPT_DYNAMIC Mon Oct 26 14:48:51 CST 2026
     MACHINE: x86_64  (2693 Mhz)
      MEMORY: 2 GB
       PANIC: "Oops: Oops: 0002 [#1] SMP" (check log for details)
```

`bt` below that banner is correct, `sys` is correct, the oops makes sense. The namelist is still the wrong file: it came from a different build, and the only thing standing between you and a confidently wrong conclusion is one `WARNING:` line you have already scrolled past.

Both files are real. The first was built with `CONFIG_IKCONFIG=y` added; the second from the same commit and the same `.config`, compiled a second time in a clean copy of the tree. This post is about knowing which situation you are in *before* you start reading.

![Three inputs feed crash: vmlinux for symbols and types, vmcore for memory and notes, module .ko files for module debuginfo. Below, the ELF layout of a vmcore](assets/crash-inputs.svg)

## Three inputs, one of them optional

`crash` needs two things to open a dump:

- **A namelist** — the build-tree `vmlinux`. This is where symbols, struct layouts, enum values, and source line numbers come from. The DWARF in it is the meaning.
- **A memory image** — the `vmcore`. This is where register state, task structures, slab pages, and log buffers come from. It is the bytes.

A third input is optional but decisive the moment a module appears in a stack trace: the **module's own `.ko`**, built with debug info. `vmlinux` knows the module's base address and a few module text symbols; it does not know what `struct crashlab_dir` looked like or which line of `crashlab.c` faulted. Post 17 is about that.

The **kernel build tree** is not an input to `crash` but to your reading of it: if it still exists at the path recorded in the DWARF, `bt -l` and `--src` can show source lines.

Notice what is not on the list: `bzImage`. It is a compressed boot image, not a namelist, and you will see this exact refusal if you try it:

```
crash: ~/crash-lab/bzImage: not a supported file format
```

`System.map` is not a namelist either. It maps addresses to names and nothing else, so `crash` does not even accept it as the first argument:

```
crash: namelist argument required
```

Symbols without types get you a trace of function names. They do not get you `struct task_struct`, which is what most of this series is made of.

## What is actually inside a vmcore

There are two shapes you will meet.

The dump in this lab is a **kdump-compressed** file: `makedumpfile` filtered the pages and compressed them, and the result is not an ELF file you can hand to `readelf`. `file` is the honest summary:

```
vmcore: Kdump compressed dump v6, system Linux,
node localhost.localdomain, release 7.3.0+, version #16 SMP PREEMPT_DYNAMIC
Mon Oct 26 14:48:51 CST 2026, machine x86_64, domain (none)
```

The other shape is a plain **ELF core file**, which is what `makedumpfile -E` writes, and what QEMU's monitor `dump-guest-memory` writes. Same information, no compression, and `readelf` can look inside. Here is a live QEMU dump of the same guest, taken with the monitor while the guest was stopped:

```
Elf file type is CORE (Core file)
Entry point 0x0
There are 8 program headers, starting at offset 192

Program Headers:
  Type           Offset             VirtAddr           PhysAddr
                 FileSiz            MemSiz              Flags  Align
  NOTE           0x0000000000000280 0x0000000000000000 0x0000000000000000
                 0x0000000000000cc0 0x0000000000000cc0         0x0
  LOAD           0x0000000000000f40 0x0000000000000000 0x0000000000000000
                 0x0000000000030000 0x0000000000030000         0x0
  LOAD           0x0000000000030f40 0x0000000000050000 0x0000000000050000
                 0x0000000000050000 0x0000000000050000         0x0
[...]
```

One `NOTE` segment and seven `LOAD` segments. The `LOAD` segments are physical memory, not a process address space: the first one is the 0-192 KB hole before the first megabyte, the next is the VGA/BIOS region. The guest's 2 GB of RAM is spread over the remaining segments.

The `NOTE` segment is where the interesting part lives. `readelf -n` on that dump shows four `NT_PRSTATUS` notes, one per vCPU, each carrying the registers of that CPU at the moment of the dump. That is where `bt -a` gets its four stacks. It also carries `NT_PRPSINFO` and the auxiliary vector.

For a kdump dump the notes carry one more thing that a live QEMU dump does not: **`VMCOREINFO`**, a page of key=value text the kernel writes at crash time. It is how `crash` learns the release, the build ID, the page size, `phys_base`, and the offsets it needs to turn a virtual address into an offset in the dump. Open a dump without it and `crash` tells you immediately:

```
crash: cannot read vmcoreinfo_data
      KERNEL: ~/crash-lab/linux/vmlinux
    DUMPFILE: [...]
       PANIC: ""
```

Note the consequences: the `PANIC` string is empty because there was no panic, and the session starts on `swapper/0` because there is no panic task to select. The dump is still useful — it is a perfectly good snapshot of memory — but you have to tell `crash` what it is looking at. That is what `--no_panic` and `--machdep` are for, and it is why kdump dumps are the better artifact when the machine died: the kernel fills in the context for you.

## The banner is a contract

Read the banner from top to bottom every time. It is not decoration; each line is a claim you can check.

- **`KERNEL`** — the namelist you gave it, plus `[TAINTED]` here because the kernel loaded an out-of-tree module. The taint matters: `O` means the kernel was already in a state the maintainers would refuse to debug, and it also tells you the module you are about to blame was present.
- **`DUMPFILE`** — the memory image, plus `[PARTIAL DUMP]` because this one was filtered with `makedumpfile -d 31`. Pages that were free, cache, cache-private, or user-owned were not written. You will see why that matters in the memory posts; for a panic stack it does not.
- **`CPUS`, `DATE`, `UPTIME`** — 4 CPUs, the crash timestamp, and an uptime of three minutes fifty-eight seconds: short enough that most of memory was still in its initial state.
- **`LOAD AVERAGE`, `TASKS`, `NODENAME`** — 0.72/0.21/0.07, 94 tasks, `localhost.localdomain`. A non-zero load average on a machine you thought was idle is worth a question.
- **`RELEASE` and `VERSION`** — `7.3.0+`, `#16 SMP PREEMPT_DYNAMIC Mon Oct 26 14:48:51 CST 2026`. The build number and timestamp are the kernel's own record of which build this is. Compare them with the namelist's, not just with the release string.
- **`MACHINE`** — `x86_64 (2693 Mhz)`, the CPU model and speed.
- **`MEMORY`** — 2 GB, the size of the guest.
- **`PANIC`** — `"Oops: Oops: 0002 [#1] SMP" (check log for details)`. The banner gives the category of death; the log gives the address, fault type, registers, and stack. Post 5 starts there.

## `sys` repeats the banner

`sys` prints the same block, which is convenient in a command file. One caveat from this lab: in a `-i` file where `sys` is followed by a piped `log`, the `PANIC:` line once showed unrelated early-boot lines; interactively it was correct. Treat the banner as a hint and confirm the oops with `log`.

## Proving the pair before you trust it

`crash` has four cheap commands for this, and only two of them work on a dump:

```sh
crash --osrelease <vmcore>     # the release string recorded in the dump
crash --build-id <vmcore>      # the build ID recorded in the dump
crash -g <vmlinux>             # does this namelist contain DWARF?
crash -t <vmlinux> <vmcore>    # when was the dump taken?
```

On our dump:

```
$ crash --osrelease ~/crash-lab/vmcore
7.3.0+

$ crash --build-id ~/crash-lab/vmcore
6460abf30df798ec67d2db4aae0d9a1fcdfb9f63

$ crash -g ~/crash-lab/linux/vmlinux
[... gdb banner ...]
crash: /home/you/crash-lab/linux/vmlinux: contains debugging data

$ crash -t ~/crash-lab/linux/vmlinux ~/crash-lab/vmcore
Mon Oct 26 18:58:21 CST 2026
```

`--osrelease` and `--build-id` read the dump's `VMCOREINFO`: they say what the *dump* is, nothing about the namelist. For that side, read the build ID out of the ELF note:

```sh
readelf -n ~/crash-lab/linux/vmlinux | grep -A1 'Build ID'
```

Here are the three namelists from the opening, and the dump, with their build IDs:

| file | build ID | version string |
| --- | --- | --- |
| the dump | `6460abf3…` | `7.3.0+ #16 SMP PREEMPT_DYNAMIC Mon Oct 26 14:48:51 CST 2026` |
| matching `vmlinux` | `6460abf3…` | `7.3.0+ #16 SMP PREEMPT_DYNAMIC Mon Oct 26 14:48:51 CST 2026` |
| same-config rebuild | `0a649fbb…` | `7.3.0+ #2 …` |
| shifted build (`IKCONFIG=y`) | `5d2a2a5a…` | `7.3.0+ #1 …` |

Matching build IDs are a proof. Matching release strings are a coincidence. The opening showed you a session where the release string matched, the build ID did not, and only one line of output said so.

## What the wrong namelist looks like

Four levels of wrong, from loudest to quietest:

1. **Not a namelist at all.** `bzImage` gives `not a supported file format`. Immediate and harmless.
2. **A namelist for a different layout.** The `IKCONFIG=y` build makes `crash` read a few addresses from the dump and find the wrong things there — first a warning about the embedded config, then a failed check on the banner string, and it refuses to open: `do not match!`. This is the good outcome.
3. **A namelist for the same layout, different build.** One warning, then everything appears to work. This is the dangerous one, because "appears to work" is exactly what a wrong answer looks like when the struct layouts have not moved.
4. **A `vmlinux` from a different kernel entirely.** Also refused here (`cannot read linux_banner string`), but do not rely on it: similar configs can get further than you would like.

The fix is the same in all four cases: find the build-tree `vmlinux` whose build ID matches the dump and open that. No flag makes a mismatched namelist safe; `--no_data_debug` turns off data reads, not wrongness.

## Modules are a third provider

The moment your trace has a `[module]` suffix, you are reading symbols from a table the kernel built at load time, not from `vmlinux`. That table has text symbols, and how much more depends on the config. In this lab the kernel has `CONFIG_KALLSYMS_ALL` off, so:

```
crash> sym crashlab_trigger_write.cold
ffffffffa0000063 (t) crashlab_trigger_write.cold [crashlab]

crash> sym crashlab_dir
symbol not found: crashlab_dir
possible alternatives:
  (none found)
```

The function resolves because it is in the text. The module's global `crashlab_dir` does not, because it is data. And `mod` is honest about the limit:

```
     MODULE       NAME         TEXT_BASE       SIZE  OBJECT FILE
ffffffffa0201040  crashlab  ffffffffa0000000  12288  (not loaded)  [CONFIG_KALLSYMS]
```

The module was loaded, took the fault, and its `struct module` reads `MODULE_STATE_LIVE` at `0xffffffffa0201040`. `(not loaded)` means `crash` could not complete the association without data symbols. Both the banner and the module table understate what the session can do, in ways you notice only when a command fails.

## Traps

- `bzImage` is not a namelist; the build-tree `vmlinux` is.
- `System.map` gives names, not types. It is not a substitute for DWARF.
- A namelist whose *name* does not start with `vmlinux` needs `-f`.
- A release string that matches after a rebuild proves nothing; compare build IDs. `[PARTIAL DUMP]` means pages were filtered out, so commands that touch user pages or page cache under-report rather than fail.
- A startup warning is not cosmetic. Everything after it inherits it.
- Module text symbols come from the kernel's table; module *data* symbols need `KALLSYMS_ALL`. Do not conclude a variable does not exist because `sym` cannot find it.

## Exercises

1. You have one `vmcore` and three candidate `vmlinux` files. Which one is correct, and which two commands prove it?
2. A session opens with `WARNING: kernel version inconsistency between vmlinux and dumpfile` and every command you try looks right. Why is the session still untrustworthy, and what would you do before publishing a conclusion from it?
3. Which input supplies types, and which supplies the memory contents? What do you lose if you only have `System.map`?

Answers and the reasoning are in [`answers.md`](answers.md).

## The commands in this post

| command | what question it answers |
| --- | --- |
| `crash --version`, `crash --buildinfo` | which `crash` is this, and how was it built |
| `crash --osrelease <vmcore>` | which kernel release does the dump claim |
| `crash --build-id <vmcore>` | which build does the dump claim |
| `crash -g <vmlinux>` | does this namelist contain DWARF |
| `crash -t <vmlinux> <vmcore>` | when was the dump taken |
| `sys` | the banner, as a command |
| `sym <name>` | what address does this symbol have, and where does it come from |
| `mod` | which modules were loaded, and can `crash` name their symbols |

---

**Versions.** Kernel `7be4bc52fd9e` (`7.3.0+` #16, x86_64, no KASLR, DWARF5,
`UNWINDER_ORC=y`, `KALLSYMS_ALL=n`); dump `vmcore` (kdump-compressed v6,
`makedumpfile -l -d 31`);
`crash 9.0.3++`; QEMU 10.1.2. Addresses vary between builds and runs; the
addresses here belong to this dump and its matching `vmlinux`.

Next: [Post 2 — The lab: make → KVM → vmcore → crash](../02-the-lab/index.html).
