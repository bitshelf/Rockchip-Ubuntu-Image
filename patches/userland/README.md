# Patch Version Management

## Structure
```
patches/userland/<package>/
  <original-version>/    # Original SDK patches (e.g. 21.1.7, 10.0.1)
  noble/                  # Adapted for Ubuntu 24.04
  questing/               # Adapted for Ubuntu 26.04
```

## When Adapting Patches for a New LTS
1. Copy the original patch to the LTS directory
2. Test apply with `--dry-run` on the target Ubuntu source
3. If it fails, fix the patch to work with the new version
4. Document changes in the patch filename or header

## Patch Application Order
Patches are applied in filename sort order within each directory.
For LTS-specific builds, use: patches/userland/<pkg>/noble/
