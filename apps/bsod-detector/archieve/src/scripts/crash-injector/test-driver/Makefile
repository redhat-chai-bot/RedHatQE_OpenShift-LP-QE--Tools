CC = x86_64-w64-mingw32-gcc

# Driver build requires WDK headers; set WDK_INCLUDE to their location.
# ntddk-shim.h provides minimal type stubs for IDE autocompletion when
# cross-compiling with MinGW on a non-Windows host. It is NOT used for
# production builds. Structure layouts in the shim are approximate and
# must be verified against real WDK headers before any ABI-sensitive use.
WDK_INCLUDE ?= /usr/x86_64-w64-mingw32/sys-root/mingw/include/ddk

CFLAGS_USER = -Wall -Wextra -O2
CFLAGS_KERN = -Wall -Wextra -O2 -I$(WDK_INCLUDE) \
	-D_WIN64 -D_AMD64_ -DNTDDI_VERSION=0x0A000000 -D_NTDDK_ -D_NTDDK_SHIM

LDFLAGS_KERN = -nostdlib -nostartfiles -shared \
	-Wl,--subsystem,native \
	-Wl,--entry,DriverEntry \
	-L. -lntoskrnl

.PHONY: all ctl driver clean

all: ctl driver

ctl: crashme-ctl.exe

driver: crashme.sys

crashme-ctl.exe: crashme-ctl.c
	$(CC) $(CFLAGS_USER) -o $@ $<

crashme.sys: crashme.c libntoskrnl.a
	$(CC) $(CFLAGS_KERN) -nostdlib -nostartfiles -shared -Wl,--subsystem,native -Wl,--entry,DriverEntry -o $@ $< -L. -lntoskrnl

libntoskrnl.a: ntoskrnl.def
	x86_64-w64-mingw32-dlltool -d $< -l $@ -k

clean:
	rm -f crashme-ctl.exe crashme.sys
