# Contributing to Browser

Thank you for contributing! Please check existing issues and pull requests before creating new ones.

## Setup

Browser requires macOS 26 or later, Xcode 26 or later, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and [just](https://github.com/casey/just).

```sh
just
```

Run the tests with:

```sh
just test
```

## Before Submitting

1. The app builds and the tests pass
2. Rebase on main: `git rebase origin/main`
3. Squash commits into logical units
4. Update the README if behavior or shortcuts change
5. Read and agree to the [Contributor License Agreement](CONTRIBUTOR_LICENSE_AGREEMENT.md) by checking the box in the pull request

## Contributor License Agreement

Browser is licensed under the AGPL-3.0, and Athas also distributes it under other terms, such as through the Mac App Store. The Contributor License Agreement gives Athas the rights to include your contribution in both. You keep the copyright in your work. Pull requests without the agreement checked can't be merged.

## Guidelines

- Follow the existing code style
- Use descriptive commit messages (e.g., "Add tab shortcuts")
- One logical change per commit
