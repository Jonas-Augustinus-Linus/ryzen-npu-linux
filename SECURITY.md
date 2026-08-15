# Security policy

## Supported versions

Security fixes are applied to the latest release and the `main` branch.

## Reporting a vulnerability

Please use GitHub's **Security → Report a vulnerability** flow so details stay
private until a fix is ready. Do not include credentials, device serial numbers,
or personal paths in public issues. Expect an acknowledgement within seven days.

This project builds and runs native compiler/runtime code with direct NPU device
access. Review scripts before granting `sudo`, prefer the pinned versions in
`versions.lock`, and never run untrusted MLIR, VMFB, model, or shell input on a
machine containing sensitive data. The repository does not publish prebuilt
IREE, LLVM-AIE, XRT, or NPU runtime binaries.
