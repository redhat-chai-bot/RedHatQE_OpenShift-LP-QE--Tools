#ifndef _NTDDK_SHIM_H
#define _NTDDK_SHIM_H

/*
 * Minimal WDK type stubs for MinGW cross-compilation on non-Windows hosts.
 *
 * Required because MinGW does not ship ntddk.h or full WDK headers. This
 * shim provides just enough type definitions for IDE autocompletion and
 * syntax checking of crashme.c. It is NOT used in production driver builds:
 * the Makefile no longer defines _NTDDK_SHIM, so crashme.c always includes
 * <ntddk.h> from the real WDK.
 *
 * WARNING: These layouts are NOT ABI-accurate. Structure sizes, alignment,
 * and field offsets have not been verified against the official WDK headers.
 * Never link a driver binary built with this shim; always cross-check
 * against the WDK definitions for any layout-sensitive code.
 */
#include <stdint.h>
#include <stddef.h>

typedef long NTSTATUS;
typedef unsigned long ULONG;
typedef unsigned short USHORT;
typedef unsigned char UCHAR;
typedef uint64_t ULONG_PTR;
typedef void VOID;
typedef int BOOLEAN;
typedef wchar_t WCHAR;

#define TRUE 1
#define FALSE 0

#define NT_SUCCESS(s) ((s) >= 0)
#define STATUS_SUCCESS ((NTSTATUS)0x00000000)
#define STATUS_INVALID_DEVICE_REQUEST ((NTSTATUS)0xC0000010)

#define FILE_DEVICE_UNKNOWN 0x00000022
#define METHOD_BUFFERED 0
#define FILE_ANY_ACCESS 0
#define CTL_CODE(t,f,m,a) (((t)<<16)|((a)<<14)|((f)<<2)|(m))

#define IO_NO_INCREMENT 0
#define IRP_MJ_CREATE 0x00
#define IRP_MJ_CLOSE 0x02
#define IRP_MJ_DEVICE_CONTROL 0x0E
#define IRP_MJ_MAXIMUM_FUNCTION 0x1B

#define UNREFERENCED_PARAMETER(p) (void)(p)

typedef struct _UNICODE_STRING {
    USHORT Length;
    USHORT MaximumLength;
    WCHAR *Buffer;
} UNICODE_STRING, *PUNICODE_STRING;

#define RTL_CONSTANT_STRING(s) { sizeof(s) - sizeof(WCHAR), sizeof(s), (WCHAR*)(s) }

typedef struct _DEVICE_OBJECT DEVICE_OBJECT, *PDEVICE_OBJECT;
typedef struct _DRIVER_OBJECT DRIVER_OBJECT, *PDRIVER_OBJECT;
typedef struct _IRP IRP, *PIRP;
typedef struct _IO_STACK_LOCATION IO_STACK_LOCATION, *PIO_STACK_LOCATION;

typedef NTSTATUS (*PDRIVER_DISPATCH)(PDEVICE_OBJECT, PIRP);
typedef VOID (*PDRIVER_UNLOAD)(PDRIVER_OBJECT);

struct _DRIVER_OBJECT {
    PDEVICE_OBJECT DeviceObject;
    PDRIVER_DISPATCH MajorFunction[IRP_MJ_MAXIMUM_FUNCTION + 1];
    PDRIVER_UNLOAD DriverUnload;
};

typedef struct _IO_STATUS_BLOCK {
    NTSTATUS Status;
    ULONG_PTR Information;
} IO_STATUS_BLOCK;

struct _DEVICE_OBJECT {
    void *padding;
};

typedef struct {
    ULONG IoControlCode;
    ULONG InputBufferLength;
    ULONG OutputBufferLength;
} DEVCTL_PARAMS;

struct _IO_STACK_LOCATION {
    UCHAR MajorFunction;
    UCHAR MinorFunction;
    UCHAR padding[6];
    union {
        DEVCTL_PARAMS DeviceIoControl;
    } Parameters;
};

struct _IRP {
    IO_STATUS_BLOCK IoStatus;
    union {
        void *SystemBuffer;
    } AssociatedIrp;
    PIO_STACK_LOCATION CurrentStackLocation;
};

static inline PIO_STACK_LOCATION IoGetCurrentIrpStackLocation(PIRP Irp) {
    return Irp->CurrentStackLocation;
}

__declspec(dllimport) NTSTATUS IoCreateDevice(PDRIVER_OBJECT, ULONG, PUNICODE_STRING, ULONG, ULONG, BOOLEAN, PDEVICE_OBJECT*);
__declspec(dllimport) VOID IoDeleteDevice(PDEVICE_OBJECT);
__declspec(dllimport) NTSTATUS IoCreateSymbolicLink(PUNICODE_STRING, PUNICODE_STRING);
__declspec(dllimport) NTSTATUS IoDeleteSymbolicLink(PUNICODE_STRING);
__declspec(dllimport) VOID IoCompleteRequest(PIRP, UCHAR);
__declspec(dllimport) VOID KeBugCheckEx(ULONG, ULONG_PTR, ULONG_PTR, ULONG_PTR, ULONG_PTR);

#endif
