Introduction
============

pitrery is a set of Bash scripts to manage Point In Time Recovery
(PITR) backups for PostgreSQL. This is the user manual of pitrery
which, hopefully, will guide you in the process of setting up the
tools to perform you backups.


Point In Time Recovery
======================

This section introduces the principles of point in time recovery in
PostgreSQL.

Firstly, it is necessary to know that PostgreSQL always write data
twice.  Every transaction is written to the Write Ahead Log (or WAL)
and the corresponding file is synchronized to disk before PostgreSQL
answers to the user when it is committed.

The Write Ahead Log is divided in segments: these are files of 16MB
each, which names are hex numbers keeping them ordered.  Once
PostgreSQL has filled a number of WAL files, when a timeout occurs or
when a superuser asks it, the engine starts a checkpoint.  The
checkpoint consists of writing all the modification of the data to the
database files.  So data is first written to the WAL, then to the data
files.  The checkpoint permits PostgreSQL to recycle the WAL files.

The purpose of this is to permit crash recovery without losing data.
If PostgreSQL detects that the cluster was not cleanly shut down at
startup, then it enters recovery.  Recovery is applying missing
changes to the database files by reading transactions from the WAL.

Point In Time Recovery is based on those principles: since all the
data changes are always stored in the WAL, it means that we could have
PostgreSQL apply the changes they contain to the database files to let
it know about not yet applied transactions, even if the cluster
database files are in an inconsistent state.  To perform PITR backups,
we need to store the WAL files in a safe place, this is called WAL
archiving, PostgreSQL is able to execute an arbitrary command to
archive a WAL segment.  Then, we need a copy of the database files
along with the position in the WAL where recovery must start, this is
called the base backup.  Finally, the recovery phase is configurable,
allowing to stop at a user defined date and time.  The name, Point In
Time Recovery, comes from this feature of PostgreSQL.

Finally, these features of PostgreSQL are used to create standby
servers. When the WAL files are applied to another server, created
from a base base backup, as soon as they are archived, we get a
replicated server.  While it is possible to setup replication with
pitrery, it is not its purpose. One can do both: backups with pitrery
and replication with other tools.



How pitrery works
=================

The purpose of pitrery is to manage the archiving of WAL segments and
automate the base backup along with restoring the files and preparing
the recovery to a date and time.  Those two job are independent in the
design of pitrery. This means that you can decide not to use the
archiving script to put WAL files in a safe place, which can be
interesting if you already have WAL based replication set up and you
do not want to replace you archiving script with the one provided by
pitrery.

The `archive_xlog` script takes care of WAL archiving.  It can use a
configuration file to find where to archive WAL files.  As of version
1.3, `archive_xlog` no longer try to archive to many places.  Instead,
the user has to integrate it in a already existing archiving script or
simply modify the `archive_command` parameter of `postgresql.conf` to make
it archive the WAL files.  `archive_xlog` can copy and compress WAL
files locally or to another server reachable using SSH.  A
configuration file can be used to reduce the size of the command line
defined in the configuration file of PostgreSQL.

As of version 1.4, options of `archive_xlog.conf` have been merged to
the configuration file of pitrery.

The management of base backups is divided in four parts, each one using
a standalone script to perform an action: `backup`, `restore`, `purge` and
`list`.  These action can then be called by `pitrery`, a wrapper around
those scripts that uses a configuration file to define the backup
options.  The purpose of `pitrery` and its configuration file is reduce
and simplify the commands needed to perform a particular action.  If
it is well configured, then restore is possible from a simple command
with a few switchs, because the pressure on the person running it can
be high at a time when end-users cannot access the database.

The storage place can be a remote server or the local machine. If is a
remote server, it must accessible using SSH in batch mode (One needs
the setup passphraseless SSH keys to do so).  Using the local machine
as storage space can be useful to backup on a filer, whose filesystems
are mounted locally.

On the backup host, pitrery organizes backed up files the following
way:

* A backup root directory is used to store everything

* The backups are then grouped in a directory named with a tag, or
  label. This enables to store backups for different servers in the same
  backup root directory without mixing them.

* In the "label" subdirectory, each backup is in a directory named
  after the date when it was started, this name is used by the restore
  script to find the best candidate for a target date.

Please note that the archived WAL files can be stored in a directory
inside the label subdirectory as long as its name does not start with
a number, to avoid confusing the restore with a non backup directory.


Installation
============

Prerequisites
-------------

pitrery is a set of bash scripts, so bash is needed. Apart from bash,
standard tools found on any Linux server are needed: `grep`, `sed`, `awk`,
`tar`, `gzip`, `ssh`, `scp`...

`rsync` is needed to archive WAL files over the network on *both* hosts.

GNU make is also needed to install from the source tarball.


Installation from the sources
-----------------------------

The latest version of can be downloaded from:

https://dl.dalibo.com/public/pitrery/

First unpack the tarball:

    tar xzf pitrery-x.y.tar.gz


Then, go to the `pitrery-x.y` directory and edit `config.mk` to fit your
system. Once done run `make` (or `gmake`) to replace the interpreter and
paths in the scripts:

    make


Finally, install it, as root if needed: 

    make install


By default, the files are installed in `/usr/local`:

* scripts are installed in `/usr/local/bin`

* actions used by pitrery are installed in `/usr/local/lib/pitrery`

* configuration samples are installed in `/usr/local/etc/pitrery`


WAL Archiving
=============

Every time PostgreSQL fills a WAL segment, it can run a command to
archive it.  It is an arbitrary command used as the value of the
`archive_command` parameter in `postgresql.conf`. PostgreSQL only checks
the return code of the command to know whether it worked or not.

pitrery provides the `archive_xlog` script to copy and possibly compress
WAL segments either on the local machine or on a remote server
reachable using an SSH connection. It is not mandatory to use it, any
script can be used: the only requirement is to provide a mean for the
restore script to get archived segments.

`archive_xlog` can use the configuration file named `pitr.conf`,
which sets up defaults. By default, its location is
`/usr/local/etc/pitrery/pitr.conf`, which can be overridden on
the command line with `-C` option. The following parameters can be
configured:

* `ARCHIVE_DIR` is the target directory where to put files.

* `ARCHIVE_LOCAL` controls whether local copy is performed. When this parameter
  is set to "yes", archive_xlog uses cp to copy the file on a local
  path. This path maybe a local filesystem or a remote filesystem mounted
  locally.  This parameter can be overridden on the command line with
  the `-L` option.

* `ARCHIVE_HOST` is the target hostname or IP address used when copying over
  an SSH connection.

* `ARCHIVE_USER` can be used to specify a username for the SSH
  connection. When not set, the username is the system user used by
  PostgreSQL.

* `ARCHIVE_COMPRESS` controls if the segment is compressed using
  gzip. Compression is enabled by default, it can be disabled on busy
  server doing a lot write transaction, this can avoid contention on
  archiving.

* `SYSLOG` can be set to "yes" to log messages to syslog, otherwise
  stderr is used for messages.  `SYSLOG_FACILITY` and `SYSLOG_IDENT` can
  then by used to store messages in the log file of PostgreSQL when it
  is configured to use syslog.

If archiving is set up to a remote host, this host must be accessible
using SSH in batch mode, meaning that passphraseless access using keys
is to be configured for the system user running PostgreSQL to the
remote host.

Once `archive_xlog` is configured, PostgreSQL must be setup to use it by
modifying the `archive_command` parameter in postgresql.conf and
dependent parameters:

    # If using PostgreSQL >= 9.0, wal_level must be set to archive or hot_standby
    # Changing this requires a restart
    wal_level = archive
    
    # If using PostgreSQL >= 8.3, archiving must be enabled
    # Changing this requires a restart
    archive_mode = on
    
    # The archive command using the defaults
    archive_command = '/usr/local/bin/archive_xlog %p'
    
    # The archive command with parameters
    #archive_command = '/usr/local/bin/archive_xlog -C /path/to/pitr.conf %p'
    # or to search /usr/local/etc/pitrery for the configuration:
    #archive_command = '/usr/local/bin/archive_xlog -C pitr %p'



Depending on the version of PostgreSQL, restart the server if
`wal_level` or `archive_mode` were changed, otherwise reload it.


Tuning WAL files compression
============================

By default, `archive_xlog` uses `gzip -4` to compress the WAL files
when configured to do so (`ARCHIVE_COMPRESS="yes"`). It is possible to
compress more and/or faster by using other compression tools, like
`bzip2`, `pigz`, the prerequisites are that the compression program
must accept the `-c` option to output on stdout and the data to
compress from stdin. The compression program can be configured by
setting `COMPRESS_BIN` in the configuration file. The output filename
has a suffix depending on the program used (e.g. "gz" or "bz2", etc),
it must be configured using `COMPRESS_SUFFIX` (without the leading dot),
this suffix is most of the time mandatory for decompression. The
decompression program is then configured using `UNCOMPRESS_BIN`, this
command must accept a compressed file as its first argument.

For example, the fastest compression is achived with `pigz`, a
multithreaded implementation of gzip:

    COMPRESS_BIN="pigz"
    UNCOMPRESS_BIN="pigz -d"

Or maximum, but slow, compression with the standard `bzip2`:

    COMPRESS_BIN="bzip2 -9"
    COMPRESS_SUFFIX="bz2"
    UNCOMPRESS_BIN="bunzip"

These three parameters can be configured only inside the configuration
file, not from the command line of `archive_xlog` and `restore_xlog`.


Using pitrery to manage backups
================================

Configuration
-------------

Once the WAL archiving is setup and properly working, pitrery can
create, restore and manage base backups of the __local__ PostgreSQL
cluster. pitrery command syntax is:

    pitrery [options] action [action-specific options]


Each action that can be performed by pitr_migr executes the
corresponding script stored by default in
`/usr/local/lib/pitrery`. These scripts are standalone, they perform the
action based on the options given on the command line at execution
time.  The purpose of `pitrery` is to wrap there scripts and provide
them with their command line options based on a configuration file.
This reduces the command line size and try to avoid mistakes at
runtime.

Before using `pitrery` to backup and manage backups for a specific
PostgreSQL cluster, a configuration file shall be created in the
configuration directory, `/usr/local/etc/pitrery` by default. This
configuration holds all the information necessary to manage backups for
this cluster. The default configuration file is `pitr.conf`, containing
all the default parameters.

The easiest way to configure pitrery is to copy the default
configuration file to new name meaningful to our setup:

    cd /usr/local/etc/pitrery
    cp pitr.conf prod.conf


We will create a configuration file for the backup of our critical
production server. We edit this file to define the specific
parameters for this PostgreSQL server.

The first parameters configure how to connect to the PostgreSQL server to
backup.  It is needed to run `pg_start_backup()` and `pg_stop_backup()` to
let us tell PostgreSQL a backup is being run. `pitrery` uses the same
variables as the tools of PostgreSQL :

* `PGDATA` is the path to the directory storing the cluster

* `PGPSQL` is the path to the psql program

* PostgreSQL access configuration: `PGUSER`, `PGPORT`, `PGHOST` and
  `PGDATABASE` are the well known variables to reach the server.

If `psql` is in the PATH, the variable can be commented out to use the
one found in the PATH. If other variables are defined in the
environment, they can be commented out in the file to have pitrery use
them.

The following parameters control the different actions accessible
through pitrery :

* `PGOWNER` is the system user which owns the files of the cluster, it
  is useful when restoring as root if the user want to restore as
  another user.

* `PGXLOG` is a path where transaction logs can be stored on restore,
  pg_xlog would then be a symbolic link to this path, like `initdb -X`

* `BACKUP_IS_LOCAL` tells pitrery that the backups are stored on the
  local machine. When set to "yes", the target host is no longer
  needed.

* `BACKUP_DIR` is the path to the directory where to store the backups.

* `BACKUP_LABEL` is the name of the set of backups, all backups will be
  stored in a subdirectory named with this value to let the user store
  backups for different servers in the same BACKUP_DIR. This value is
  also used in the call to pg_start_backup() with the date appended.

* `BACKUP_HOST` is the IP address of the host where backups shall be
  stored. `BACKUP_USER` is the username to use for SSH login, if empty,
  the username is the one running pitrery.

* `RESTORE_COMMAND` can be used to define the command run by PostgreSQL
  when it needs to retrieve a WAL file before applying it in recovery
  mode. It is useful when WAL archiving is not performed by
  pitrery. When archive_xlog is used, e.g. `RESTORE_COMMAND` is left
  empty, it defaults to a call to `restore_xlog` and it is not necessary
  to set it up here, unless archived WAL files are stored on a
  different host than `BACKUP_HOST`.

* `PURGE_KEEP_COUNT` controls how many backups must be kept when purging
  old backups.

* `PURGE_OLDER_THAN` controls how many __days__ backups are kept when
  purging. If `PURGE_KEEP_COUNT` is also set, age based purge will
  always leave at least `PURGE_KEEP_COUNT` backups.

* `ARCHIVE_*` and `SYSLOG_*` are passed to `restore_xlog` when
  `RESTORE_COMMAND` is empty. They define the location (either local or
  through SSH) where the WAL files are stored.


Hooks
-----

Some user defined commands can be executed, they are given in the
following configuration variables:

* `PRE_BACKUP_COMMAND` is run before the backup is started.

* `POST_BACKUP_COMMAND` is run after the backup is finished. Starting
  with version 1.7, the command is run even if the backup fails, but
  not if the backup fails because of the `PRE_BACKUP_COMMAND` or
  earlier (e.g. the order "pre -- base backup -- post" is ensured).

The following variables are then available, to access the PostgreSQL
or the current backup:

* `PITRERY_HOOK` is the name of the hook being run

* `PITRERY_PSQL` is the psql command line to run SQL statement on the
  saved PostgreSQL server

* `PITRERY_DATABASE` is the name of the connection database

* `PITRERY_BACKUP_DIR` is the full path to the directory of the backup

* `PITRERY_BACKUP_LOCAL` can be used to know is SSH is required to access the backup directory

* `PITRERY_SSH_TARGET` the user@host part needed to access to backup server

* `PITRERY_EXIT_CODE` is the exit code of the backup. 0 for success, 1 for failure


Backup storage
--------------

As of version 1.5, pitrery offers two storage technics for the base backup.

The first, and historical, is `tar`, where it creates one compressed
tarball (with `gzip` by default) for `PGDATA` and each tablespace. The
`tar` method is quite slow and can become difficult to use with bigger
database clusters, however the compression saves a lot of space.

The second is `rsync`. It synchronizes PGDATA and each tablespace to a
directory inside the backup, and try to optimize data transfer by
hardlinking the files of the previous backup (provided it was done
with the "rsync" method). This method should offer the best speed for
the base backup, and is recommanded for big databases clusters (more
than several hundreds of gigabytes).

The default method is `tar`. It can be configured by setting the
`STORAGE` variable to either `tar` or `rsync` in the configuration
file.


Usage
-----

Note: all commands have a `-?` switch to show their usage details.

The help for `pitrery` is available by running it with the `-h` option :

    $ pitrery -?
    usage: pitrery [options] action [args]
    options:
        -c file      Path to the configuration file
        -n           Show the command instead of executing it
        -?           Print help
    
    actions:
        list
        backup
        restore
        purge
    

If we want to backup our example production server, the name of the
configuration must given to pitrery with the `-c` option. The name of
the configuration file, if it is not a path, is searched in the
configuration directory, any file ending with `.conf` is then taken, for
example :

    $ pitrery -c prod action


This will use the file `/usr/local/etc/pitrery/prod.conf`. When adding
the `-?` switch after the action name, pitrery outputs the help of the
action, for example :

    $ pitrery backup -?
    backup_pitr performs a PITR base backup
    
    Usage:
        backup_pitr [options] [hostname]
    
    Backup options:
        -L              Perform a local backup
        -b dir          Backup directory
        -l label        Backup label, it will be suffixed with the date and time
        -u username     Username for SSH login
        -D dir          Path to $PGDATA
        -s mode         Storage method, tar or rsync
    
    Connection options:
        -P PSQL         path to the psql command
        -h HOSTNAME     database server host or socket directory
        -p PORT         database server port number
        -U NAME         connect as specified database user
        -d DATABASE     database to use for connection
    
        -?              Print help
    

The `-n` option of `pitrery` can be used to show the action script
command line that would be runned, but without running it. It is
useful to check if the parameters configured in a particular
configuration file are correct. For example, with the default
configuration file `pitr.conf` :

    $ pitrery -n backup 192.168.0.50
    /usr/local/lib/pitrery/backup_pitr -b /var/lib/pgsql/backups \
      -l pitr -D /var/lib/pgsql/data -P psql -h /tmp -p 5432 \
      -U postgres -d postgres 192.168.0.50


Finally, every configuration parameter defined in the configuration
file can be overridden on the command line by adding the corresponding
switch after the action. For example, if the port of the PostgreSQL is
5433 :

    $ pitrery -n backup -p 5433 192.168.0.50
    /usr/local/lib/pitrery/backup_pitr -b /var/lib/pgsql/backups \
      -l pitr -D /var/lib/pgsql/data -P psql -h /tmp -p 5433 \
      -U postgres -d postgres 192.168.0.50


Note: the `BACKUP_HOST` is not defined in the configuration file used
for the example, this is why the IP address was added after the
"backup" action.


Backup
------

**Beware that the backup must run on the PostgreSQL server host**,
SSH login is used to __push__ data to a backup server, and PostgreSQL
connection options to run SQL __locally__.

To run a backup with pitrery, either a configuration file is needed
or the options must be put on the commandline. The usage of the backup
action is:

    $ pitrery backup -?
    backup_pitr performs a PITR base backup
    
    Usage:
        backup_pitr [options] [hostname]
    
    Backup options:
        -L              Perform a local backup
        -b dir          Backup base directory
        -l label        Backup label
        -u username     Username for SSH login
        -D dir          Path to $PGDATA
        -s mode         Storage method, tar or rsync
    
    Connection options:
        -P PSQL         path to the psql command
        -h HOSTNAME     database server host or socket directory
        -p PORT         database server port number
        -U NAME         connect as specified database user
        -d DATABASE     database to use for connection
    
        -?              Print help
    

For example, the configuration file for our example production server
is the following:

    PGDATA="/home/postgres/postgresql-9.2.4/data"
    PGPSQL="/home/postgres/postgresql-9.2.4/bin/psql"
    PGUSER="postgres"
    PGPORT=5432
    PGHOST="/tmp"
    PGDATABASE="postgres"
    PGOWNER=$PGUSER
    BACKUP_IS_LOCAL="no"
    BACKUP_DIR="/home/postgres/backups"
    BACKUP_LABEL="prod"
    BACKUP_HOST=10.100.0.16
    BACKUP_USER=
    RESTORE_COMMAND=
    PURGE_KEEP_COUNT=2
    PURGE_OLDER_THAN=
    PRE_BACKUP_COMMAND=
    POST_BACKUP_COMMAND=
    STORAGE="tar"
    ARCHIVE_LOCAL="no"
    ARCHIVE_HOST=10.100.0.16
    ARCHIVE_USER=
    ARCHIVE_DIR="/home/postgres/backups/prod/xlog"
    ARCHIVE_COMPRESS="yes"
    SYSLOG="no"
    SYSLOG_FACILITY="local0"
    SYSLOG_IDENT="postgres"
    STORAGE="tar"


With those options, pitrery can run a backup:

    $ pitrery -c prod backup
    INFO: preparing directories in 10.100.0.16:/home/postgres/backups/prod
    INFO: listing tablespaces
    INFO: starting the backup process
    INFO: backing up PGDATA with tar
    INFO: archiving /home/postgres/postgresql-9.0.4/data
    INFO: backup of PGDATA successful
    INFO: backing up tablespace "ts2" with tar
    INFO: archiving /home/postgres/postgresql-9.0.4/ts2
    INFO: backup of tablespace "ts2" successful
    INFO: stopping the backup process
    NOTICE:  pg_stop_backup complete, all required WAL segments have been archived
    INFO: copying the backup history file
    INFO: copying the tablespaces list
    INFO: backup directory is 10.100.0.16:/home/postgres/backups/prod/2013.08.28-11.16.30
    INFO: done



If we have a look at the contents of the `/home/postgres/backups`
directory on the backup host:

    /home/postgres/backups
    └── prod
        ├── 2013.08.28-11.16.30
        │   ├── backup_label
        │   ├── backup_timestamp
        │   ├── pgdata.tar.gz
        │   ├── tblspc
        │   │   └── t2.tar.gz
        │   └── tblspc_list
        └── xlog
            ├── 000000010000000000000036.gz
            ├── 000000010000000000000037.gz
            ├── 000000010000000000000038.gz
            ├── 000000010000000000000039.gz
            ├── 00000001000000000000003A.gz
            ├── 00000001000000000000003B.gz
            ├── 00000001000000000000003C.00000078.backup.gz
            ├── 00000001000000000000003C.gz
            └── 00000001000000000000003D.gz


The backup is stored in the `prod/2013.08.28-11.16.30` diretory of
`BACKUP_DIR`, "prod" being the label defined by `BACKUP_LABEL`. The backup
directory is named with the start date and time of the backup. The
`backup_timestamp` file contains the timestamp value of the stop time
of the backup, which is used by the restore action to find the best
candidate when restoring to a specific date and time and by the purge
action. The directory stores the backup label file of PostgreSQL, a
tarball of the PGDATA directory, tarballs for each tablespace and the
tablespace list with their path. Finally, but not shown in the example,
a `conf` directory can be created to store configuration files of the
database cluster (`postgresql.conf`, `pg_hba.conf` and
`pg_ident.conf`) when they are not located inside `PGDATA`.

Notes:
* Here we have configured `archive_xlog` to store the WAL files in
  `prod/xlog` to have them close to the base backups.
* When using the `rsync` storage method, tarballs are replaced with
  directory with the same base name.


Listing backups
---------------

The list action allow to find the backups for a particular label on
the backup host. By default, it prints a parsable list of backups, with
one backups on each line:

    $ pitrery -c pitr15_local93 list
    List of local backups
    /home/pgsql/postgresql-9.3.2/pitr/pitr15/2014.01.21_17.05.04	19M	  2014-01-21 17:05:04 CET
    /home/pgsql/postgresql-9.3.2/pitr/pitr15/2014.01.21_17.20.30	365M	  2014-01-21 17:20:30 CET

The `-v` switch display more information on each backups, like needed space
for each tablespace:

    $ pitrery -c pitr15_local93 list -v
    List of local backups
    ----------------------------------------------------------------------
    Directory:
      /home/pgsql/postgresql-9.3.2/pitr/pitr15/2014.01.21_17.05.04
      space used: 19M
    Minimum recovery target time:
      2014-01-21 17:05:04 CET
    PGDATA:
      pg_default 18 MB
      pg_global 437 kB
    Tablespaces:
    
    ----------------------------------------------------------------------
    Directory:
      /home/pgsql/postgresql-9.3.2/pitr/pitr15/2014.01.21_17.20.30
      space used: 365M
    Minimum recovery target time:
      2014-01-21 17:20:30 CET
    PGDATA:
      pg_default 18 MB
      pg_global 437 kB
    Tablespaces:
      "ts1" /home/pgsql/postgresql-9.3.2/ts1 (16395) 346 MB
    

Like the other commands, the options of the list action can be display
by adding the -? option after the action:

    $ pitrery list -?
    usage: list_pitr [options] [hostname]
    options:
        -L              List from local storage
        -u username     Username for SSH login
        -b dir          Backup storage directory
        -l label        Label used when backup was performed
        -v              Display details of the backup
    
        -?              Print help
    

Restore
-------

The restore action takes a backup and prepares the recovery to restore
to a particular point in time. The target date must be given on the
command line using the -d option. Its format is the one expected by
PostgreSQL: `YYYY-mm-DD HH:MM:SS [+-]TZTZ`. The `'[+-]TZTZ'` is the
timezone offset, it must given as `HHMM`, .e.g +2h30 would be +0230 and
-7h would be -0700.

This action perform the following steps:

* Find the newest possible backup from the store.

* Retrieve and extract the contents of PGDATA and the tablespaces.

* Create a `recovery.conf` file for PostgreSQL.

* Optionally, restore the saved configuration files in
  `PGDATA/restored_config_files` if they were outside PGDATA at the time
  of the backup.

* Optinally, create a script to update the catalog when paths to
  tablespaces have changed, for PostgreSQL <= 9.1.

The restore will only work if the target destination directory (PGDATA
in the configuration file of pitrery) and the directories used by
tablespaces exist or can be created, are writable and empty. It is
important to prepare those directories before running the restore.

When specifiying a target date, it will be used in the
`$PGDATA/recovery.conf` file as value for the `recovery_target_time`
parameter.

Unless `RESTORE_COMMAND` is defined to something else, the `restore_xlog`
script will be used by PostgreSQL to retrieve archived WAL files. The
purpose of this script is to find, copy on PostgreSQL server, and
uncompress the archived WAL file asked by PostgreSQL.  its behavior is
controlled from its command line options, for example:

    restore_xlog -h HOST -d ARCHIVE_DIR %f %p

The restore script uses options values from the configuration, which
can be tweaked on the command line. Beware that some options have
different names between `restore_xlog` and the restore action.

Let's say the target directories are ready for a restore run by the
`postgres` user, the restore can be started with pitrery on an example
production server:

    $ pitrery -c prod restore -d '2013-06-01 13:00:00 +0200'
    INFO: searching backup directory
    INFO: searching for tablespaces information
    INFO: 
    INFO: backup directory:
    INFO:   /home/pgsql/postgresql-9.1.9/pitr/prod/2013.06.01_12.15.38
    INFO: 
    INFO: destinations directories:
    INFO:   PGDATA -> /home/pgsql/postgresql-9.1.9/data
    INFO:   tablespace "ts1" -> /home/pgsql/postgresql-9.1.9/ts1 (relocated: no)
    INFO:   tablespace "ts2" -> /home/pgsql/postgresql-9.1.9/ts2 (relocated: no)
    INFO: 
    INFO: recovery configuration:
    INFO:   target owner of the restored files: postgres
    INFO:   restore_command = '/usr/local/bin/restore_xlog -L -d /home/pgsql/postgresql-9.1.9/archives %f %p'
    INFO:   recovery_target_time = '2013-06-01 13:00:00 +0200'
    INFO: 
    INFO: checking if /home/pgsql/postgresql-9.1.9/data is empty
    INFO: checking if /home/pgsql/postgresql-9.1.9/ts1 is empty
    INFO: checking if /home/pgsql/postgresql-9.1.9/ts2 is empty
    INFO: extracting PGDATA to /home/pgsql/postgresql-9.1.9/data
    INFO: extracting tablespace "ts1" to /home/pgsql/postgresql-9.1.9/ts1
    INFO: extracting tablespace "ts2" to /home/pgsql/postgresql-9.1.9/ts2
    INFO: preparing pg_xlog directory
    INFO: preparing recovery.conf file
    INFO: done
    INFO: 
    INFO: please check directories and recovery.conf before starting the cluster
    INFO: and do not forget to update the configuration of pitrery if needed
    INFO:


The restore script finds that the backup to be restored is located in
`/home/pgsql/postgresql-9.1.9/pitr/prod/2013.06.01_12.15.38` on our backup
server. It then extracts everything, including the tablespaces
and prepares the `recovery.conf` at the root of `$PGDATA`. The script asks
the user to check everything before starting the PostgreSQL cluster:
This behavior is intentionnal, it allows the user to modify parameters
of PostgreSQL or change how the recovery is configured in
`recovery.conf`.

When everything is fine, the PostgreSQL can be started, it will apply
the archived WAL files until the target date is reached or until all
archived WAL files are consumed if no target date was specified.

If unsure about the options to give for a restore, use the `-n` switch
of the restore action to make it stop after showing the informations.

Furthermore, it possible choose the target directories when restoring,
use `-D` switch to set the target directory for PGDATA, and one to many
`-t` switches to relocate the tablespaces to other directories. The
format of the value of a `-t` option is `tablespace_name_or_oid:new_directory`.

One `-t` option apply to one tablespace. For example:

    $ pitrery -c prod restore -d '2013-06-01 13:00:00 +0200' \
      -D /home/pgsql/postgresql-9.1.9/data_restore \
      -t ts1:/home/pgsql/postgresql-9.1.9/ts1_restore 
    INFO: searching backup directory
    INFO: searching for tablespaces information
    INFO: 
    INFO: backup directory:
    INFO:   /home/pgsql/postgresql-9.1.9/pitr/pitr13/2013.06.01_12.15.38
    INFO: 
    INFO: destinations directories:
    INFO:   PGDATA -> /home/pgsql/postgresql-9.1.9/data_restore
    INFO:   tablespace "ts1" -> /home/pgsql/postgresql-9.1.9/ts1_restore (relocated: yes)
    INFO:   tablespace "ts2" -> /home/pgsql/postgresql-9.1.9/ts2 (relocated: no)
    INFO: 
    INFO: recovery configuration:
    INFO:   target owner of the restored files: orgrim
    INFO:   restore_command = '/usr/local/bin/restore_xlog -L -d /home/pgsql/postgresql-9.1.9/archives %f %p'
    INFO:   recovery_target_time = '2013-06-01 13:00:00 +0200'
    INFO: 
    INFO: creating /home/pgsql/postgresql-9.1.9/data_restore
    INFO: setting permissions of /home/pgsql/postgresql-9.1.9/data_restore
    INFO: creating /home/pgsql/postgresql-9.1.9/ts1_restore
    INFO: setting permissions of /home/pgsql/postgresql-9.1.9/ts1_restore
    INFO: checking if /home/pgsql/postgresql-9.1.9/ts2 is empty
    INFO: extracting PGDATA to /home/pgsql/postgresql-9.1.9/data_restore
    INFO: extracting tablespace "ts1" to /home/pgsql/postgresql-9.1.9/ts1_restore
    INFO: extracting tablespace "ts2" to /home/pgsql/postgresql-9.1.9/ts2
    INFO: preparing pg_xlog directory
    INFO: preparing recovery.conf file
    INFO: done
    INFO: 
    INFO: please check directories and recovery.conf before starting the cluster
    INFO: and do not forget to update the configuration of pitrery if needed
    INFO: 
    WARNING: locations of tablespaces have changed, after recovery update the catalog with:
    WARNING:   /home/pgsql/postgresql-9.1.9/data_restore/update_catalog_tablespaces.sql

In the above example, the PGDATA has been changed along with the path
of the ts1 tablespace. Since the version of PostgreSQL is 9.1, pitrery
creates a SQL file with the `UPDATE` statements needed to change the
`spclocation` column of `pg_tablespace` (this columns has been removed
as of 9.2). This script must be run as a superuser role on the
restored cluster after the recovery.

Again, if unsure, run the restore action with the `-n` switch to display
what would be done. The options of restore are:

    $ pitrery restore -?
    restore_pitr performs a PITR restore
    
    Usage:
        restore_pitr [options] [hostname]
    
    Restore options:
        -L              Restore from local storage
        -u username     Username for SSH login to the backup host
        -b dir          Backup storage directory
        -l label        Label used when backup was performed
        -D dir          Path to target $PGDATA
        -x dir          Path to the xlog directory (only if outside $PGDATA)
        -d date         Restore until this date
        -O user         If run by root, owner of the files
        -t tblspc:dir   Change the target directory of tablespace "ts"
                          this switch can be used many times
        -n              Dry run: show restore information only
    
    Archived WAL files options:
        -A              Force the use of local archives
        -h host         Host storing WAL files
        -U username     Username for SSH login to WAL storage host
        -X dir          Path to the archived xlog directory
        -r cli          Command line to use in restore_command
        -C              Do not uncompress WAL files
        -S              Send messages to syslog
        -f facility     Syslog facility
        -i ident        Syslog ident
    
        -?              Print help
    


Removing old backups
--------------------

The purge action can remove old backups according to a policy based on
the number of backups to keep and/or their age in days. If the maximum
number of backups and the maximum age are set, the number is always
respected: it prevents the user from removing all backups if all of
them are too old. The purge script will also try to remove unnecessary
archived WAL files, provided it can reach the location where they are
stored.

The `-m` on the command line or `PURGE_KEEP_COUNT` in the
configuration file define the maximum number of backups to keep. The
`-d` on the command line or `PURGE_OLDER_THAN` in the configuration
file is used to define the maximum age in days.

For example, we have two backups on the store and we want to keep only
one, while `PURGE_KEEP_COUNT=2`:

    $ pitrery -c prod purge -m 1
    INFO: searching backups
    INFO: purging /home/postgres/backups/prod/2011.08.17-11.16.30
    INFO: purging WAL files older than 000000020000000000000060
    INFO: 75 old WAL file(s) removed
    INFO: done

Note that if there are no backups but archived WAL files, the purge
action will not remove those WAL files.
