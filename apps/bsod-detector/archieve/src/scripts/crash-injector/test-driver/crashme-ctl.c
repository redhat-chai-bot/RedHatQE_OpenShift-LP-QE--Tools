#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>

#define CRASHME_IOCTL CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define CRASHME_WRMSR_IOCTL CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_ANY_ACCESS)

typedef struct _CRASHME_INPUT {
    ULONG BugCheckCode;
    ULONG_PTR Param1;
    ULONG_PTR Param2;
    ULONG_PTR Param3;
    ULONG_PTR Param4;
} CRASHME_INPUT;

typedef struct _CRASHME_MSR_INPUT {
    ULONG MsrIndex;
    ULONG Reserved;
    ULONG_PTR Value;
} CRASHME_MSR_INPUT;

/* Print usage and exit with error */
static void usage(const char *prog)
{
    fprintf(stderr, "Usage: %s <hex-bugcheck-code> [p1] [p2] [p3] [p4]\n", prog);
    fprintf(stderr, "       %s --wrmsr <hex-msr-index> <hex-value>\n", prog);
    fprintf(stderr, "All values in hex (0x prefix optional).\n");
    exit(1);
}

/* Parse hex string into 32-bit value; exits on overflow or invalid input */
static ULONG parse_ulong_hex(const char *s, const char *name)
{
    char *end;
    errno = 0;
    unsigned long val = strtoul(s, &end, 16);
    if (*end != '\0' || end == s || errno == ERANGE) {
        fprintf(stderr, "Invalid hex value for %s: '%s'\n", name, s);
        exit(1);
    }
    if (val > 0xFFFFFFFF) {
        fprintf(stderr, "%s value 0x%lX exceeds ULONG range\n", name, val);
        exit(1);
    }
    return (ULONG)val;
}

/* Parse hex string into pointer-width value; exits on invalid input */
static ULONG_PTR parse_ulongptr_hex(const char *s, const char *name)
{
    char *end;
    errno = 0;
    unsigned long long val = strtoull(s, &end, 16);
    if (*end != '\0' || end == s || errno == ERANGE) {
        fprintf(stderr, "Invalid hex value for %s: '%s'\n", name, s);
        exit(1);
    }
    return (ULONG_PTR)val;
}

/* Open \\.\CrashMe device handle; prints diagnostic if driver isn't loaded */
static HANDLE open_crashme_device(void)
{
    HANDLE h = CreateFileA("\\\\.\\CrashMe", GENERIC_READ | GENERIC_WRITE,
                           0, NULL, OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) {
        fprintf(stderr, "Failed to open \\\\.\\CrashMe (error %lu).\n", GetLastError());
        fprintf(stderr, "Is the CrashMe driver loaded? Run: sc start CrashMe\n");
    }
    return h;
}

/* Handle --wrmsr subcommand: validate args, send WRMSR IOCTL to driver */
static int do_wrmsr(int argc, char *argv[])
{
    if (argc != 4)
        usage(argv[0]);

    CRASHME_MSR_INPUT msr = {0};
    msr.MsrIndex = parse_ulong_hex(argv[2], "MsrIndex");
    msr.Value = parse_ulongptr_hex(argv[3], "Value");

    printf("Writing MSR 0x%lX = 0x%llX\n", msr.MsrIndex, (unsigned long long)msr.Value);

    HANDLE hDevice = open_crashme_device();
    if (hDevice == INVALID_HANDLE_VALUE)
        return 1;

    DWORD bytesReturned;
    BOOL ok = DeviceIoControl(hDevice, CRASHME_WRMSR_IOCTL, &msr, sizeof(msr),
                              NULL, 0, &bytesReturned, NULL);
    if (!ok)
        fprintf(stderr, "DeviceIoControl WRMSR failed (error %lu).\n", GetLastError());
    else
        printf("MSR write succeeded.\n");

    CloseHandle(hDevice);
    return ok ? 0 : 1;
}

/* Route to --wrmsr subcommand or send bugcheck IOCTL with up to 4 params */
int main(int argc, char *argv[])
{
    if (argc < 2)
        usage(argv[0]);

    if (strcmp(argv[1], "--wrmsr") == 0)
        return do_wrmsr(argc, argv);

    if (argc > 6)
        usage(argv[0]);

    CRASHME_INPUT input = {0};
    input.BugCheckCode = (ULONG)strtoul(argv[1], NULL, 16);
    if (argc > 2) input.Param1 = (ULONG_PTR)strtoull(argv[2], NULL, 16);
    if (argc > 3) input.Param2 = (ULONG_PTR)strtoull(argv[3], NULL, 16);
    if (argc > 4) input.Param3 = (ULONG_PTR)strtoull(argv[4], NULL, 16);
    if (argc > 5) input.Param4 = (ULONG_PTR)strtoull(argv[5], NULL, 16);

    printf("Triggering BugCheck 0x%lX (P1=0x%llX P2=0x%llX P3=0x%llX P4=0x%llX)\n",
           input.BugCheckCode, (unsigned long long)input.Param1,
           (unsigned long long)input.Param2, (unsigned long long)input.Param3,
           (unsigned long long)input.Param4);

    HANDLE hDevice = open_crashme_device();
    if (hDevice == INVALID_HANDLE_VALUE)
        return 1;

    DWORD bytesReturned;
    BOOL ok = DeviceIoControl(hDevice, CRASHME_IOCTL, &input, sizeof(input),
                              NULL, 0, &bytesReturned, NULL);
    if (!ok)
        fprintf(stderr, "DeviceIoControl failed (error %lu).\n", GetLastError());

    CloseHandle(hDevice);
    return ok ? 0 : 1;
}
