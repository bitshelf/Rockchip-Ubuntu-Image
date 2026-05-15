# Ubuntu Official Test Suite

Based on Ubuntu testing methodology:
- `checkbox` — Canonical hardware certification
- `autopkgtest` — Package testing
- `dpkg` integrity checks — Package file integrity
- `systemd` validation — Service and timer state

## Directory Structure

```
tests/
  unit/           # Unit tests (shell function tests)
  integration/    # Integration tests (build pipeline)
  validation/     # Validation tests (image correctness)
  fixtures/       # Test fixtures (mock configs, expected outputs)
  qemu-test.sh    # Rootfs test suite (runs in chroot via QEMU)
```
