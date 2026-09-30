# LCVEX difftest 插件构建。
# 依赖已构建的 QEMU（../qemu/build）与 glib 头文件。

QEMU_DIR ?= $(abspath ../../../qemu)
CC ?= gcc
CFLAGS ?= -O2 -g -Wall -Wextra -fPIC -shared -fvisibility=hidden
PLUGIN = lcvex_difftest.so

.PHONY: all clean

all: $(PLUGIN)

$(PLUGIN): lcvex_difftest.c
	$(CC) $(CFLAGS) -I$(QEMU_DIR)/include/plugins \
		$(shell pkg-config --cflags glib-2.0) -o $@ $<

clean:
	rm -f $(PLUGIN)
