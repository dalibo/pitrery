pitrery: Point-In-Time Recovery (PITR) tools for PostgreSQL
===========================================================

WARNING : PITRERY IS DEPRECATED
-------------------------------

As of january 2022, pitrery development is stopped. Please move to another
backup solution like pgBackrest or barman for example.


FEATURES
--------

pitrery is set of tools to ease the management of PITR backups and
restores:

- Management of WAL segments archiving with compression to a host
  reachable with SSH or on the local machine

- Automation of the base backup procedure

- Restore to a particular date

- Management of backup retention


QUICK SETUP
-----------

1. Get the source

2. Edit the `config.mk`

3. Run `make` and `make install`

4. Run `pitrery configure -o pitrery -f [[user@]host:]/path/to/backups` (user@host being optional)

5. Configure WAL archiving (`archive_command = 'archive_wal %p'`) in PostgreSQL

6. Run `pitrery` to perform your backups and restores

The full documentation is available in man pages, INSTALL.md or the website :

http://dalibo.github.io/pitrery/


DEVELOPMENT
-----------

The source code is available on Github: https://github.com/dalibo/pitrery

pitrery is developed by Dalibo under a classic 2 clauses BSD license. See
license block in the scripts or the COPYRIGHT file.

HOW TO CONTRIBUTE
-----------------

Any contribution is welcome. If you have any idea, feature request,
question or patch, please contact us on Github:

https://github.com/dalibo/pitrery/issues
