# Contributing to pitrery

Pitrery is an open project. Thanks for your interest in contributing to it.


## Code Style

Some code style is enforced by [EditorConfig](https://editorconfig.org/), please
setup your editor to follow it.


## Run test locally

You can run [bats tests](https://github.com/sstephenson/bats) locally by
running the following command:

`PGVERSION=12 ./script/funcenv`

A dedicated cluster will be created, make sure that port 5432 is available
(i.e. make sure to stop any running cluster using the default PostgreSQL port).

## Release process

- Checkout latest master.
- Update CHANGELOG, config.mk, pitrery, archive\_wal and restore\_wal. `make
  checkversion VERSION=X.Y` should help.
- Commit, tag and push with `make disttag`.
- Build source tarball and sign it with `make distsign`.
- GitHub created a release for the new tag. Update it to your need. Find it in
  the [Releases page](https://github.com/dalibo/pitrery/releases).
- Attach tar.gz and .tar.gz.asc to the GitHub release.
- Build and push deb with `make -C debian/ build push`.
- Update and commit rpm/pitrery.spec. Build and push with `make -C rpm/ build
  push`.
- Push these commits.
- Update website in `gh-pages` branch.
  - Create news entry.
  - Update download and documentation page.
- Announce: pgsql-announce, blog.dalibo.com and social media.
