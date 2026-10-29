# Answers — The lab: build a kernel you can crash, and a dump you can read

## 1. Why must the `bzImage` loaded by `kexec -p` match the one the machine booted?

**Answer:** because the crash kernel is the environment that captures the dump, and every difference is a variable you did not intend to introduce.

The strict requirement is on the *crashed* kernel: the dump is its memory, so the `vmlinux` you analyze with must be its exact build. The `kexec -p` image is the second kernel that boots after the panic. It is the one that exposes `/proc/vmcore` and runs `makedumpfile`, so it needs `CONFIG_PROC_VMCORE` and the drivers to write your dump. A stale image from an earlier build may lack either.

There is also a quieter failure: when the stale image *does* work, nothing tells you that the machine you are capturing from is not the machine you tested. The lab keeps both copies identical and checks with `sha256sum`, because the check is one command.

**Related trap:** `--reuse-cmdline` is what carries `crashkernel=256M` into the crash kernel. If the reused command line lacks that reservation, the crash kernel has nowhere to live and kdump cannot start.

## 2. Which config options make `struct task_struct` usable?

**Answer:** `CONFIG_DEBUG_INFO=y` with a full DWARF variant
(`CONFIG_DEBUG_INFO_DWARF5=y` here), and specifically *not*
`CONFIG_DEBUG_INFO_REDUCED` or `CONFIG_DEBUG_INFO_SPLIT`.

`CONFIG_DEBUG_INFO` alone means "emit DWARF". The two options that quietly break `crash` are:

- `DEBUG_INFO_REDUCED`: drops struct members and other detail to shrink the image. `struct task_struct` still exists, but members you ask for may be missing, so `ps` and every pointer chase through a task become unreliable.
- `DEBUG_INFO_SPLIT`: moves type information into `.dwo` files beside the object files. `vmlinux` alone then does not contain the types `crash` needs, and the usual symptom is a session that opens and then fails on structs.

Symbols come from `CONFIG_KALLSYMS`, which is separate: it gives names and addresses, and `KALLSYMS_ALL` extends that to data symbols. Symbols are not types.

**Proof in this lab:** `struct task_struct` prints in full, ending with `SIZE: 2624`, and `ps -S` walks all 94 tasks.

## 3. What does `--no_panic` change?

**Answer:** it stops `crash` from trying to identify the task that was running when the kernel died, and sets the initial context to the `swapper` task on CPU 0 instead.

That matters when the dump has no panic task to find: a QEMU monitor `dump-guest-memory` of a running guest, a dump taken after `panic_on_oops=0` where nothing panicked, or a kdump whose notes did not survive. In the live QEMU dump from this lab, `crash` says so and defaults there anyway:

```
crash: cannot read vmcoreinfo_data
       PANIC: ""
PID: 0        TASK: ffffffff81a0a680  CPU: 0    COMMAND: "swapper/0"
```

**When it is the right flag:** when you know there is no panic context and you want a deterministic starting point for commands that are context-sensitive (`bt` without `-a`, `files`, `vm`).

**When it is the wrong tool:** never use it to silence a warning caused by a mismatched `vmlinux` or missing symbols. It changes which task you start on, not whether the namelist is correct.

## 4. `kexec -p` returned 0, but the machine rebooted instead of entering kdump

**Answer:** the first two checks are that a crash kernel was actually armed, and that the reservation existed and was carried into it.

1. **Was it armed, not just loaded?** `kexec -p` succeeding and `/sys/kernel/kexec_crash_loaded` reading `1` are two different facts:

   ```sh
   cat /sys/kernel/kexec_crash_loaded
   ```

   If this was not `1` before the panic, kdump could not have run. A second signal is in the oops header itself: `Kdump: loaded` appears only when the kernel knew a crash kernel was armed.

2. **Was there memory reserved for it?** The reservation comes from `crashkernel=` on the command line, and `--reuse-cmdline` has to carry it:

   ```sh
   grep -i crash /proc/iomem
   ```

   No `Crash kernel` range means the crash kernel had nowhere to live, whatever `kexec -p` reported.

If both are fine, the next suspects are that the oops never became a panic (no `panic_on_oops=1`, or an oops that the kernel recovered from) and that the crash kernel started but died before it could write anything. The serial console of the second boot — not the first — is where that story is.
