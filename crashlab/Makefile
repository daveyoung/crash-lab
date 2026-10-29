# Build crashlab.ko against the kernel tree you are testing.
#
#   make KDIR=~/crash-lab/linux
#   make clean KDIR=~/crash-lab/linux
#
# KDIR defaults to the running kernel's build directory, which is almost
# always the wrong kernel for a lab. Pass it explicitly.

KDIR ?= /lib/modules/$(shell uname -r)/build

obj-m := crashlab.o

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean

.PHONY: all clean
