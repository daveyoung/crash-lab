# crashlab

A deliberately buggy kernel module for the Crash Lab series. It exists to
produce a specific, reproducible crash that a postmortem dump can explain.

**It panics the machine it runs on. Use a disposable VM, never a host you care
about.**

## What it does

At load time the module builds a small circular list: a head embedded in a root
object, followed by three objects named `alpha`, `beta` and `gamma`. The list
linkage sits at the end of each object, so walking it back to a container needs
a real offset. The module prints the head address and the offset to `dmesg`, so
a dump can be explored even when module data symbols are not in kallsyms.

The `null` mode writes to a NULL pointer from the debugfs write path:

```c
if (sysfs_streq(buf, "null")) {
	volatile u32 *p = (volatile u32 *)0;

	pr_info("CRASHLAB: null deref triggered by pid %d (%s)\n",
		current->pid, current->comm);

	*p = 0xdeadbeef;
	return count;	/* not reached */
}
```

The write comes from a normal `write(2)` to
`/sys/kernel/debug/crashlab/trigger`, so the faulting task is your shell and the
stack is short and readable.

## Build

Against the kernel tree you are actually testing:

```sh
make KDIR=~/crash-lab/linux
```

`KDIR` defaults to `/lib/modules/$(uname -r)/build`, which is the running
distro kernel and almost never what you want.

The module needs the kernel's exported symbols for debugfs and the string
helpers. If `modpost` reports `symbol 'debugfs_create_dir' undefined`, your
kernel is trimming unused exports (`CONFIG_TRIM_UNUSED_KSYMS=y` without a
whitelist) — see the second post for the fix.

## Use

```sh
insmod crashlab.ko
echo null > /sys/kernel/debug/crashlab/trigger
```

If the kernel is not configured to panic on an oops, this dereference is
survivable and the machine keeps running. Arm the crash capture first, or set
`panic_on_oops=1` before the write. Either way, make sure `debugfs` is mounted:

```sh
mount -t debugfs none /sys/kernel/debug
```

Unload with `rmmod crashlab` as long as you have not triggered it yet.

## Licence

GPL-2.0, like the kernel it is built against.
