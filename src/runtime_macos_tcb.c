/* macOS x86_64: the guest thread-control-block pages live in the low 32-bit space (the LDT
 * descriptor base is only 32 bits wide). -pagezero_size,0x4000 frees [0x4000,4GiB) and this
 * segment, placed by -segaddr,TCB_SPACE,0x4000, reserves it so the loader maps into it. */
#if defined(__APPLE__) && defined(__x86_64__)
__asm__(".zerofill TCB_SPACE,TCB_SPACE,__tcb_space,0x3FC000");
#else
typedef int bb_macos_tcb_unused;
#endif
