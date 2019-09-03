# Contributing to pitrery

Pitrery is an open project. Thanks for your interest in contributing to it.


## Code Style

Some code style is enforced by [EditorConfig](https://editorconfig.org/), please
setup your editor to follow it.


## Release process

- [Draft new GitHub Release](https://github.com/dalibo/pitrery/releases/new). A
  version is composed of only two number like `2.3`. There is no patch-release.
- Checkout latest master.
- Update CHANGELOG, config.mk, pitrery, archive\_xlog and restore\_xlog. `make
  checkversion VERSION=X.Y` should help.
- Commit, tag and push with `make disttag`.
- Build source tarball and sign it with `make distsign`.
- Attach tar.gz and .tar.gz.asc to GitHub release.
- Update rpm/pitrery.spec, build and push with `make -C rpm/ build push`.
- [Update debian/changelog, build and push debs](./debian).
- Update website in `gh-pages` branch.
  - Create news entry.
  - Update download and documentation page.
- Announce: pgsql-announce, blog.dalibo.com and social media.
