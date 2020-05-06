# Contributing to pitrery

Pitrery is an open project. Thanks for your interest in contributing to it.


## Code Style

Some code style is enforced by [EditorConfig](https://editorconfig.org/), please
setup your editor to follow it.


## Release process

- Checkout latest master.
- Update CHANGELOG, config.mk, pitrery, archive\_wal, restore\_wal and
  rpm/pitrery.spec. `make checkversion VERSION=X.Y` should help.
- Commit, tag and push with `make disttag`.
- Build source tarball and sign it with `make distsign`.
- Update the created GitHub Release: it was created when the tag was created.
  Address is of the form: <https://github.com/dalibo/pitrery/releases/tag/vX.Y>.
  There is no patch-release.
- Attach tar.gz and .tar.gz.asc to GitHub release.
- Build and push rpm with `make -C rpm/ build push`.
- Build and push deb with `make -C debian/ build push`.
- Push these commits.
- Update website in `gh-pages` branch.
  - Create news entry.
  - Update download and documentation page.
- Announce: pgsql-announce, blog.dalibo.com and social media.
