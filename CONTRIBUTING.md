# Contributing

## Reporting Issues

Open a GitHub issue with:
- A clear description of the problem
- Raspberry Pi model and OS version
- Relevant log output

## Submitting Changes

1. Fork the repository
2. Create a feature branch (`git checkout -b my-feature`)
3. Make your changes
4. Run `shellcheck` on all modified scripts
5. Test on a Raspberry Pi if possible
6. Commit with a clear message and open a pull request against `main`

## Development Notes

- **Language:** Bash
- Scripts are designed for Raspberry Pi OS (Debian-based) — test with `shellcheck`
- Use POSIX-compatible syntax where possible
- VLC is the expected media player; don't introduce alternative player dependencies
- Keep scripts simple and well-commented

## Code Style

- Use `#!/bin/bash` shebang
- Quote all variables (`"$var"` not `$var`)
- Prefer long-form flags (`--option` over `-o`) for readability

## License

By contributing, you agree that your contributions will be licensed under the project's existing license.
