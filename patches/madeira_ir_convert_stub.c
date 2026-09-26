/* CI-only stand-in for research/madeira-d3d12/src/unix/madeira_ir_unix.mm,
 * linked when Apple's Metal Shader Converter package is not supplied (its
 * headers are not in the repository). winemetal_unix.c references this symbol
 * unconditionally; returning STATUS_NOT_IMPLEMENTED makes the native D3D12
 * runtime's shader conversion fail cleanly instead of the app failing to link. */
int madeira_ir_convert(void *args)
{
    (void)args;
    return (int)0xC0000002; /* STATUS_NOT_IMPLEMENTED */
}
