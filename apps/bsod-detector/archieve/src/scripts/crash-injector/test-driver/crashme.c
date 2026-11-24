#ifdef _NTDDK_SHIM
#include "ntddk-shim.h"
#else
#include <ntddk.h>
#endif

#define CRASHME_IOCTL CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define CRASHME_WRMSR_IOCTL CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_ANY_ACCESS)

typedef struct _CRASHME_INPUT {
    ULONG BugCheckCode;
    ULONG_PTR Param1;
    ULONG_PTR Param2;
    ULONG_PTR Param3;
    ULONG_PTR Param4;
} CRASHME_INPUT, *PCRASHME_INPUT;

typedef struct _CRASHME_MSR_INPUT {
    ULONG MsrIndex;
    ULONG Reserved;
    ULONG_PTR Value;
} CRASHME_MSR_INPUT, *PCRASHME_MSR_INPUT;

/* Execute WRMSR instruction directly; caller must be at IRQL <= DISPATCH_LEVEL */
static __inline void CrashMeWriteMsr(ULONG msr, ULONG_PTR value)
{
    __asm__ __volatile__("wrmsr" : : "c"(msr),
        "a"((ULONG)(value & 0xFFFFFFFF)),
        "d"((ULONG)(value >> 32)));
}

static UNICODE_STRING DeviceName = RTL_CONSTANT_STRING(L"\\Device\\CrashMe");
static UNICODE_STRING SymlinkName = RTL_CONSTANT_STRING(L"\\DosDevices\\CrashMe");

/* Complete IRP immediately with SUCCESS; used for CREATE and CLOSE */
static NTSTATUS CrashMeDispatchPassthrough(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    Irp->IoStatus.Status = STATUS_SUCCESS;
    Irp->IoStatus.Information = 0;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return STATUS_SUCCESS;
}

/* Dispatch IOCTL: triggers KeBugCheckEx or writes an MSR based on control code */
static NTSTATUS CrashMeDispatchDeviceControl(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    PIO_STACK_LOCATION stack = IoGetCurrentIrpStackLocation(Irp);
    NTSTATUS status = STATUS_INVALID_DEVICE_REQUEST;

    if (stack->Parameters.DeviceIoControl.IoControlCode == CRASHME_IOCTL &&
        stack->Parameters.DeviceIoControl.InputBufferLength >= sizeof(CRASHME_INPUT))
    {
        PCRASHME_INPUT input = (PCRASHME_INPUT)Irp->AssociatedIrp.SystemBuffer;
        KeBugCheckEx(input->BugCheckCode, input->Param1, input->Param2, input->Param3, input->Param4);
    }
    else if (stack->Parameters.DeviceIoControl.IoControlCode == CRASHME_WRMSR_IOCTL &&
             stack->Parameters.DeviceIoControl.InputBufferLength >= sizeof(CRASHME_MSR_INPUT))
    {
        PCRASHME_MSR_INPUT msrInput = (PCRASHME_MSR_INPUT)Irp->AssociatedIrp.SystemBuffer;
        CrashMeWriteMsr(msrInput->MsrIndex, msrInput->Value);
        status = STATUS_SUCCESS;
    }

    Irp->IoStatus.Status = status;
    Irp->IoStatus.Information = 0;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return status;
}

/* Remove symlink and device object on driver unload */
static VOID CrashMeUnload(PDRIVER_OBJECT DriverObject)
{
    IoDeleteSymbolicLink(&SymlinkName);
    IoDeleteDevice(DriverObject->DeviceObject);
}

/* Create \Device\CrashMe, expose via \DosDevices symlink, wire up dispatch table */
NTSTATUS DriverEntry(PDRIVER_OBJECT DriverObject, PUNICODE_STRING RegistryPath)
{
    UNREFERENCED_PARAMETER(RegistryPath);
    PDEVICE_OBJECT deviceObject;

    NTSTATUS status = IoCreateDevice(DriverObject, 0, &DeviceName,
                                     FILE_DEVICE_UNKNOWN, 0, FALSE, &deviceObject);
    if (!NT_SUCCESS(status))
        return status;

    status = IoCreateSymbolicLink(&SymlinkName, &DeviceName);
    if (!NT_SUCCESS(status)) {
        IoDeleteDevice(deviceObject);
        return status;
    }

    DriverObject->MajorFunction[IRP_MJ_CREATE] = CrashMeDispatchPassthrough;
    DriverObject->MajorFunction[IRP_MJ_CLOSE] = CrashMeDispatchPassthrough;
    DriverObject->MajorFunction[IRP_MJ_DEVICE_CONTROL] = CrashMeDispatchDeviceControl;
    DriverObject->DriverUnload = CrashMeUnload;

    return STATUS_SUCCESS;
}
