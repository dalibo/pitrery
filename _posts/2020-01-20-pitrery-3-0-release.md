---
layout: post
title:  "pitrery 3.0 released"
date:   2020-01-20 12:15:00
categories: news release
---

pitrery is a set of Bash scripts to manage PITR backups for PostgreSQL.

### New feature

* Support for PostgreSQL 12

PostgreSQL in this version has changed how recovery configuration is managed.
There is be no more "recovery.conf" file:
  - The recovery configuration keys are read from the postgresql.conf file.
     Upon restoration, recovery.conf settings are written by pitrery at the
     end of the postgresql.conf file.
  - A "recovery.signal" or "standby.signal" will be used by the restored
    cluster to know what action to take
     A new option is declared: RESTORE_MODE (or the "-m" switch). For
     restoration, it must be set either to "recovery" or "standby".
  - Multiple conflicting recovery_target* specifications are not allowed.
    PostgreSQL will make the check on startup.
  - We now advance to the latest timeline by default.

* Rename "xlog" to "wal"

Since PostgreSQL version 10, "xlog" has been renamed to "wal". Make this change
in pitrery:
  - "archive_xlog" script is renamed to "archive_wal".
  - "restore_xlog" script is renamed to "restore_wal".
  - configuration key PGXLOG is renamed to PGWAL.
  - the WAL archive directory ARCHIVE_DIR is set by default to:
    "$BACKUP_DIR/archived_wal".
  - deb and rpm packages will maintain symbolic link to old "xlog" scripts.

### Getting it

Pitrery tarballs are now on [GitHub
releases](https://github.com/dalibo/pitrery/releases) and distribution packages
are now available on Dalibo Labs [YUM](https://yum.dalibo.org/labs) and
[APT](https://apt.dalibo.org/labs) repositories. Details are available in the
[downloads] page.

Pitrery is a [Dalibo Labs](https://labs.dalibo.com/) project maintained by
[Thibaut Madelaine](https://github.com/madtibo), [Étienne
Bersac](https://github.com/bersace) and [Thibaud
Walkowiak](https://github.com/tilkow).

[downloads]: {{ site.baseurl }}/downloads.html
[upgrade]: {{ site.baseurl }}/upgrade.html
