// SPDX-License-Identifier: GPL-2.0
/*
 * crashlab - a deliberately buggy, deliberately inspectable module for the
 * Crash Lab series.
 *
 * Mode "null" is the first case: writing "null" to the debugfs trigger
 * dereferences a NULL pointer in the write path.
 *
 * At load time the module also builds a small doubly-linked list, so that a
 * dump contains a data structure worth walking by hand: a head embedded in a
 * root object, followed by three ordinary objects.
 */

#include <linux/debugfs.h>
#include <linux/fs.h>
#include <linux/kernel.h>
#include <linux/list.h>
#include <linux/module.h>
#include <linux/sched.h>
#include <linux/stddef.h>
#include <linux/string.h>
#include <linux/uaccess.h>

#define CRASHLAB_MAGIC	0x434c4142U	/* "CLAB" */
#define CRASHLAB_OBJECTS 3

/*
 * The list linkage lives at the end of the object on purpose: the offset from
 * a list_head back to its container is not zero, which is the whole point of
 * container_of().
 */
struct crashlab_obj {
	u32 magic;
	char name[16];
	unsigned long value;
	struct list_head node;
};

static struct crashlab_obj crashlab_objs[CRASHLAB_OBJECTS];

static struct crashlab_obj crashlab_root = {
	.magic = CRASHLAB_MAGIC,
	.name = "root",
	.value = 0,
	.node = LIST_HEAD_INIT(crashlab_root.node),
};

static struct dentry *crashlab_dir;

static void crashlab_set_name(struct crashlab_obj *obj, const char *name)
{
	size_t i;

	for (i = 0; i + 1 < sizeof(obj->name) && name[i]; i++)
		obj->name[i] = name[i];
	obj->name[i] = '\0';
}

static void crashlab_build_list(void)
{
	static const char *const names[CRASHLAB_OBJECTS] = {
		"alpha", "beta", "gamma",
	};
	int i;

	for (i = 0; i < CRASHLAB_OBJECTS; i++) {
		struct crashlab_obj *obj = &crashlab_objs[i];

		obj->magic = CRASHLAB_MAGIC;
		crashlab_set_name(obj, names[i]);
		obj->value = 0x1000UL * (i + 1);
		list_add_tail(&obj->node, &crashlab_root.node);
	}
}

static void crashlab_free_list(void)
{
	struct crashlab_obj *obj, *tmp;

	list_for_each_entry_safe(obj, tmp, &crashlab_root.node, node) {
		if (obj == &crashlab_root)
			continue;
		list_del(&obj->node);
	}
}

static ssize_t crashlab_trigger_write(struct file *file,
				      const char __user *ubuf,
				      size_t count, loff_t *ppos)
{
	char buf[16];

	if (count == 0)
		return 0;
	if (count >= sizeof(buf))
		return -EINVAL;
	if (copy_from_user(buf, ubuf, count))
		return -EFAULT;

	buf[count] = '\0';
	strim(buf);

	if (sysfs_streq(buf, "null")) {
		volatile u32 *p = (volatile u32 *)0;

		pr_info("CRASHLAB: null deref triggered by pid %d (%s)\n",
			current->pid, current->comm);

		/* The point of the exercise: fault at address 0. */
		*p = 0xdeadbeef;

		return count;	/* not reached */
	}

	pr_info("CRASHLAB: unknown mode '%s'\n", buf);
	return -EINVAL;
}

static const struct file_operations crashlab_trigger_fops = {
	.owner = THIS_MODULE,
	.write = crashlab_trigger_write,
	.llseek = noop_llseek,
};

static int __init crashlab_init(void)
{
	crashlab_build_list();

	crashlab_dir = debugfs_create_dir("crashlab", NULL);
	if (IS_ERR(crashlab_dir)) {
		crashlab_free_list();
		return PTR_ERR(crashlab_dir);
	}

	debugfs_create_file("trigger", 0600, crashlab_dir, NULL,
			    &crashlab_trigger_fops);

	pr_info("CRASHLAB: loaded %d objects; list head at %px (node offset %zu)\n",
		CRASHLAB_OBJECTS + 1, &crashlab_root.node,
		offsetof(struct crashlab_obj, node));
	pr_info("CRASHLAB: write 'null' to /sys/kernel/debug/crashlab/trigger\n");
	return 0;
}

static void __exit crashlab_exit(void)
{
	debugfs_remove_recursive(crashlab_dir);
	crashlab_free_list();
	pr_info("CRASHLAB: unloaded\n");
}

module_init(crashlab_init);
module_exit(crashlab_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Crash Lab deliberately buggy test module");
MODULE_AUTHOR("Crash Lab");
