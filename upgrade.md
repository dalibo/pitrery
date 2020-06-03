---
layout: default
title: pitrery - Upgrade
---

Upgrade to 3.1
==============

Nothing to do.

Upgrade to 3.0
==============

* Rename *xlog to *wal in helper scripts and configuration keys:
  - move file archive_xlog to archive_wal
  - move file restore_xlog to restore_wal
  - rename configuration key PGXLOG to PGWAL
  - Note that ARCHIVE_DIR default configuration changed:
      "$BACKUP_DIR/archived_xlog" -> "$BACKUP_DIR/archived_wal"

* New configuration key for PostgreSQL 12: `RESTORE_MODE`, set by default to
  "recovery". Can be set to "recovery" or "standby".

Upgrade to 2.5
==============

Nothing to do.

Upgrade to 2.4
==============

Nothing to do.

Upgrade to 2.3
==============

Nothing to do.

Upgrade to 2.2
==============

* Modify calls of `pitrery -c` to `pitrery -f` where needed.

Upgrade to 2.1
==============

Nothing to do.


Upgrade to 2.0
==============

* Command line switches and options to specify if the backup is local,
  the user, host and target directory, are now merged into a SSH style
  syntax: `[[user@]host:]/path`. Not providing a host tells pitrery
  the backups are local.

* Remove the BACKUP_LABEL option, subdirectory and -l switch. They
  were not used a lot. Please change the backup directory to include
  the label.

* Remove BACKUP_IS_LOCAL and ARCHIVE_LOCAL options. Backup or
  WAL archiving are local when BACKUP_HOST or ARCHIVE_HOST are empty.

* Rename the default configuration file from `pitr.conf` to
  `pitrery.conf`


Upgrade to 1.13
===============

Nothing to do.


Upgrade to 1.12
===============

Ensure the new name of archiving compression parameters are used, older
names are no longer supported. See 1.9 upgrade instructions.


Upgrade to 1.11
===============

Nothing to do.


Upgrade to 1.10
===============

Nothing to do.


Upgrade to 1.9
==============

WAL files archiving and restoring
---------------------------------

The following configuration parameters have been renamed :

* `COMPRESS_BIN` -> `ARCHIVE_COMPRESS_BIN`
* `COMPRESS_SUFFIX` -> `ARCHIVE_COMPRESS_SUFFIX`
* `UNCOMPRESS_BIN` -> `ARCHIVE_UNCOMPRESS_BIN`

The safest way to update the configuration file on a running system is to :

- Add the renamed parameters in the configuration file without
  touching the old ones
- Perform the upgrade
- Remove the old parameters from the configuration file


Restore
-------

When they differ from the configuration file, options to restore_xlog
must be passed using a full custom restore command, with the `-r`
option.


Upgrade to 1.8
==============

Backup
------

When using the "rsync" storage method, the directory tree of the
previous backup is duplicated using hardlinks for files, before
rsync'ing over the new tree. The duplication can be done using `cp
-rl` or `pax -rwl`. This make pitrery more portable on non-GNU
systems. The tool can be chosen at build time, GNU cp staying the
default.

When using this method over SSH, `pax` may be required on the target host.


Upgrade to 1.7
==============

Usage
-----

* Calling `pitrery` by using `pitr_mgr` is no longer possible. The
  symlink has been removed after keeping backward compatibility for
  two versions.

* The post backup hook script, configurable using
  `POST_BACKUP_COMMAND`, is now run after the pre backup hook, even if
  the backup fails. The new `PITRERY_EXIT_CODE` environment variable
  is set to the exit code of the backup.

Configuration
-------------

The following new configuration variables may be used, here are their
defaults:

* `BACKUP_COMPRESS_BIN` (gzip -4). `BACKUP_UNCOMPRESS_BIN`
  (gunzip). Commands to use when compressing and uncompressing backed
  up files with tar.

* `BACKUP_COMPRESS_SUFFIX` (gz). Suffix of the files produces by the
  previous commands.


Upgrade to 1.6
==============

RPM Package
-----------

* Configuration files have been moved from `/etc/sysconfig/pgsql` to
  `/etc/pitrery`


Upgrade to 1.5
==============

Configuration
-------------

The following new configuration variables may be used, here are their
defaults:

* `PGXLOG` (empty). Path to put pg_xlog outside of PGDATA when
  restoring.
* `PRE_BACKUP_COMMAND` (empty) and `POST_BACKUP_COMMAND`. Command to
  run before and after the base backup.
* `STORAGE` (tar). Storage method, "tar" or "rsync".
* `COMPRESS_BIN`, `COMPRESS_SUFFIX` and `UNCOMPRESS_BIN`. Controls to
  tool used to compress archived WAL files.


Archiving
---------

Compression options are only available in the configuration file,
customising this forces to use `-C` option of `archive_xlog`.


Upgrade to 1.4
==============

Archiving
---------

As of 1.4, the archive_xlog.conf files is no longer used to configure
archive_xlog. All parameter are now in pitr.conf.

To upgrade, you need to merge your configuration into a pitr.conf
file. The default one is available in DOCDIR
(/usr/local/share/doc/pitrery by default), comments should be enough
to help you reconfigure archive_xlog.

The archive_command should be updated to have archive_xlog search for
the configuration file, -C option accept the basename of the
configuration file name and searches in the configuration directory, a
full path is also accepted:

    archive_command = 'archive_xlog -C mypitr %p'



Upgrade to 1.3
==============

Archiving
---------

As of 1.3, pitrery no longer archive more than one file. Thus
archive_nodes.conf file has been removed. The archive_xlog script now
archives only one file.

If you are archiving more than one time, you have to chain archiving
in the archive_command parameter of postgresql.conf:

    archive_command = 'archive_xlog -C archive_xlog %p && rsync -az %p standby:/path/to/archives/%f'

Of course you can chain archive_xlog to archive multiple times.


Backup and restore
------------------

As of 1.3, the best backup is found by storing the stop time of the
backup as an offset from the Unix Epoch in the backup_timestamp file
inside each backup directory. The files can be created from the
backup_label files using this shell script:

    BACKUP_DIR=/path/to/backup/dir
    LABEL=pitr
    
    for x in ${BACKUP_DIR}/${LABEL}/[0-9]*/backup_label; do
        psql -At -c "select extract(epoch from timestamp with time zone '`awk '/^STOP TIME:/ { print $3" "$4" "$5 }' $x`');" > `dirname $x`/backup_timestamp
    done


