Introduction
============

pitrery is a tool to manage Point In Time Recovery (PITR) backups for
PostgreSQL. This is the user manual of pitrery which, hopefully, will
guide you in the process of setting it up to perform your backups.


Point In Time Recovery
======================

This section introduces the principles of point in time recovery in
PostgreSQL.

Firstly, it is necessary to know that PostgreSQL always write data
twice.  Every transaction is written to the Write Ahead Log (or WAL)
and the corresponding file is synchronised to disk before PostgreSQL
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
changes to the database files by reading transactions from the WAL,
starting from the last known checkpoint.

Point In Time Recovery is based on those principles: since all the
data changes are always stored in the WAL, it means that we could have
PostgreSQL apply the changes they contain to the database files to let
it know about not yet applied transactions, even if the cluster
database files are in an inconsistent state.  To perform PITR backups,
we need to store the WAL files in a safe place, this is called WAL
archiving: PostgreSQL is able to execute an arbitrary command to
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
the recovery to a date and time.  Those two jobs are independent in
the design of pitrery. This means that you can decide not to use
pitrery to put WAL files in a safe place, which can be interesting if
you already have WAL based replication set up and you do not want to
replace your archiving script with the one provided by pitrery.

The `pitrery` script takes an action as argument to perform a specific
task. Each task has its set of options that can be controlled by
commandline switches. A configuration file can reduce the size of the
commandline. Adding commandline switches override what is defined in
the configuration file. If it is well configured, then restore is
possible from a simple command with a few switches, because the
pressure on the person running it can be high at a time when end-users
cannot access the database. On the other side, adding command line
switches at run time will easily modify the behaviour of the action to
avoid modifying the configuration all the time.

The management of WAL files is done by two scripts, `archive_wal` and
`restore_wal`. The `archive_wal` script takes care of WAL archiving.
If you need to archive WAL to many places, you can integrate it with
an already existing archiving script or simply modify the
`archive_command` parameter of `postgresql.conf`.  The `archive_wal`
script can copy and compress WAL files locally or to another server
reachable using SSH.  A configuration file can be used to reduce the
size of the command line defined in the configuration file of
PostgreSQL.

The management of base backups is divided in four actions: `backup`,
`restore`, `purge` and `list`.  Two more actions are available to ease
the administration : `check` can be used to ensure the configuration
file is correct and PostgreSQL properly configured. `configure` can be
used to easily create a configuration file from the command line.

The storage place can be a remote server or the local machine. If it
is a remote server, it must be accessible by SSH in batch mode (Eg:
by using a passphraseless SSH keys). Using the local machine as
storage space can be useful to backup on a filer, whose filesystems
are mounted locally.

On the backup host, pitrery organises backed up files the following
way:

* A backup root directory is used to store everything

* Each backup is stored in a directory whose name is a date and time
  when it was started, this name is used by the restore
  action to find the best candidate for a target date.

Please note that the archived WAL files can be stored in a directory
inside the backup root directory as long as its name does not start
with a number, to avoid confusing the restore with a non backup
directory. This is the case by default.


Installation
============

Prerequisites
-------------

pitrery is a set of bash scripts, so bash is required. Apart from bash,
standard tools found on any Linux server are needed: `grep`, `sed`, `awk`,
`tar`, `gzip`, `ssh`, `scp`...

`rsync` is needed to archive WAL files over the network on *both* hosts, and
for backups using the rsync storage method.

GNU make is also needed to install manpages from the source tarball.


Installation from the sources
-----------------------------

The latest version of can be downloaded from:

https://github.com/dalibo/pitrery/releases

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

* configuration samples are installed in `/usr/local/etc/pitrery`

* manual pages are installed in `/usr/local/share/man`

You can use the script directly without running `make install`, when
doing so the default configuration directory is `/etc/pitrery`.


Installation from a package
---------------------------

A Debian package and a RPM package are available from:

https://apt.dalibo.org/labs/

Use the suitable tool to install it.


Command invocation and syntax
=============================

Since pitrery is action based, the execution uses the following syntax:

    pitrery [options] action [action-specific options]


Each action that can be performed by `pitrery` reads its parameters
from the configuration file. It's possible to override the default
configuration file with the -f flag, this flag should be defined
before* the action.

It's always possible to get some information about the available
actions and paramaters by using -? flag:

    $ pitrery -?
    pitrery 3.0 - PostgreSQL Point In Time Recovery made easy

    usage: pitrery [options] action [args]

    options:
        -f file      Path to the configuration file
        -l           List configuration files in the default directory
        -V           Display the version and exit
        -?           Print help

    actions:
        list - Display information about backups
        backup - Perform a base backup
        restore - Restore a base backup and prepare PITR
        purge - Clean old base backups and archived WAL files
        check - Verify configuration and backups integrity
        configure - Create a configuration file from the command line
        help - Print help, optionnally for an action

The help or usage of each action listed in the general help message
can be shown by invoking:

    $ pitrery action -?

or using the `help` action:

    $ pitrery help [action]

For WAL file archiving and restoring, the two light weight
scripts `archive_wal` and `restore_wal` do not have any action, the
usage is straight forward:

    $ archive_wal -?
    archive_wal Archive a WAL segment

    usage: archive_wal [options] walfile

    options:
        -C conf        configuration file
        -a [[user@]host:]/dir  Place to store the archive
        -X             do not compress
        -O             do not overwrite the destination file
        -H             check the hash of the destination file (remote only)
        -F             flush the destination file to disk
        -c command     compression command
        -s suffix      compressed file suffix (ex: gz)

        -E             encrypt the file using gpg
        -r keys:...    colon separated list of recipients for GPG encryption

        -S             send messages to syslog
        -f facility    syslog facility
        -t ident       syslog ident
        -m mode        destination file permission mode in octal (e.g. chmod)
        -T             Timestamp log messages

        -V             Display the version and exit
        -?             print help

and `restore_wal`:

    $ restore_wal -?
    restore_wal - Restore a WAL segment

    usage: restore_wal [options] walfile destination
    options:
        -C conf                Configuration file
        -a [[user@]host:]/dir  Place to get the archive
        -X                     Do not uncompress
        -c command             Uncompression command
        -s suffix              Compressed file suffix (ex: gz)
        -S                     Send messages to syslog
        -f facility            Syslog facility
        -t ident               Syslog ident
        -T                     Timestamp log messages

        -V                     Display the version and exit
        -?                     Print help


Configuration
=============

It is not mandatory to use a configuration file, most parameters
can be read from commandline. However, using a configuration file is
recommended to reduce the size of the commanline.  Values from the
commandline take precedence over the configuration file at execution time.

The default configuration file is `/usr/local/etc/pitrery/pitrery.conf`,
(`/etc/pitrery/pitrery.conf` when installed from packages) containing all
the default parameters.

The same configuration file is used by `pitrery`, `archive_wal` and
`restore_wal`.


Configuring pitrery from the command line
-----------------------------------------

Use the `configure` action to create a configuration file. It needs a
destination of the form `[[user@]host:]/path` to know where backups
shall be stored. If a host is not provided, the backup is considered
local.  Some options are available to create a configuration :


    $ pitrery configure -?
    pitrery configure - Create a configuration file from the command line

    usage: pitrery configure [options] [[user@]host:]/path/to/backups

    options:
        -o config_file         Output configuration file
        -f                     Overwrite the destination file
        -C                     Do not connect to PostgreSQL

        -s mode                Storage method, tar or rsync
        -m count               Number of backups to keep when purging
        -g days                Remove backups older than this number of days
        -D dir                 Path to $PGDATA
        -a [[user@]host:]/dir  Place to store WAL archives
        -E                     Encrypt tar backups with GPG
        -r keys:...            Colon separated list of recipients for GPG encryption

        -P psql                Path to the psql command
        -h hostname            Database server host or socket directory
        -p port                Database server port number
        -U name                Connect as specified database user
        -d database            Database to use for connection

        -?                     Print help


Not all possible configuration options are provided, the purpose is to
quickly generate a basic configuration file for further tuning.
It is worth noting that `-C` avoids making pitrery connect to PostgreSQL,
otherwise it tries to guess the correct parameters for WAL archiving.
`-o` writes the configuration files if it does not exists, if only a
keyword is given, the file is created in the default configuration
directory, with the .conf suffix.

When the `-a` is not provided, the place where WAL files would be
stored is deduced from the location of backups: WAL are archived in
the `archived_wal` subdirectory in the backup directory.

All parameters to access PostgreSQL are inherited from the environment
if not given on the commandline.

For example, create the configuration needed to backup the cluster on
port 5962:

    $ sudo mkdir /var/backups/postgresql
    $ sudo chown postgres:postgres /var/backups/postgresql

    $ pitrery configure -p 5962 /var/backups/postgresql
    INFO: ==> checking access to PostgreSQL
    INFO: PostgreSQL version is: 12.1
    INFO: connection role can run backup functions
    INFO: current configuration:
    INFO:   wal_level = minimal
    INFO:   archive_mode = off
    INFO:   archive_command = '(disabled)'
    ERROR: wal_level must be set at least to replica
    ERROR: archive_mode must be set to on
    INFO: please ensure archive_command includes a call to archive_wal
    INFO: ==> checking $PGDATA
    INFO: access to the contents of PGDATA ok
    INFO: ==> contents of the configuration file

    PGDATA="/var/lib/postgresql/12/main"
    PGPORT="5433"
    BACKUP_DIR="/var/backups/postgresql"
    PURGE_KEEP_COUNT="2"
    STORAGE="tar"
    ARCHIVE_DIR="/var/backups/postgresql/archived_wal"


Since PostgreSQL is not configured to perform WAL archiving, some
errors are displayed indicating what parameters to change. When
PostgreSQL is configured, use the `check` action to test if everything
looks good.


WAL Archiving
-------------

Every time PostgreSQL fills a WAL segment, it can run a command to
archive it.  It is an arbitrary command used as the value of the
`archive_command` parameter in `postgresql.conf`. PostgreSQL only checks
the return code of the command to know whether it worked or not.

pitrery provides the `archive_wal` script to copy and possibly compress
WAL segments either on the local machine or on a remote server
reachable using an SSH connection. It is not mandatory to use it, any
script can be used: the only requirement is to provide a mean for the
restore action to get archived segments.

The `archive_wal` script uses the configuration file named `pitrery.conf`.
By default the location of the configuration file is :
`/usr/local/etc/pitrery/pitrery.conf`, which can be overridden on
the command line with `-C` option. The following parameters can be
configured:

* `ARCHIVE_DIR` is the target directory where to put files.

* `ARCHIVE_HOST` is the target hostname or IP address used when
  copying over an SSH connection. Leave it empty to archive on the
  local host.

* `ARCHIVE_USER` can be used to specify a username for the SSH
  connection. When not set, the username is the system user used by
  PostgreSQL.

* `ARCHIVE_COMPRESS` controls if the segment is compressed. Compression
  is enabled by default, it can be disabled on busy servers doing a
  lot write transactions, this can avoid contention on archiving.

* `ARCHIVE_COMPRESS_BIN` holds the command to commpress a segment.

* `ARCHIVE_UNCOMPRESS_BIN` holds the command to uncompress a segment,
  it is the reverse of `ARCHIVE_COMPRESS_BIN`.

* `ARCHIVE_COMPRESS_SUFFIX` configure the suffix of the compressed
  file, without a starting dot. Eg `gz` or `bz2`.

* `ARCHIVE_OVERWRITE` can be set to "no" to check if the file to
  archive already exists in the destination directory. Since it
  reduces performance when archiving over SSH, it is set to "yes" by
  default.

* `ARCHIVE_CHECK` can be set to "yes" to compare the md5 of the archived
  file to the md5 of the original WAL file. It is useful when the
  storage or the network is not reliable. If overwriting is
  disabled, the md5 check enabled and the archive already exists, the
  archiving returns success if the md5 check is successful. This
  option does not apply on local archiving.

* `ARCHIVE_FLUSH` can be set to "yes" to force an immediate flush of
  the archived file to disk before returning success. It may slow down
  the archiving process but ensure archives are not corrupted in case of
  a power loss on the destination.

* `ARCHIVE_FILE_CHMOD` can be used to configure the permission of the
  archived file. The value must be in octal form as understood by
  `chmod`. It can help with uid/gid issues on NFS shares used by
  different hosts, and should not be necessary in most of the cases.

* `SYSLOG` can be set to "yes" to log messages to syslog, otherwise
  stderr is used for messages.  `SYSLOG_FACILITY` and `SYSLOG_IDENT`
  can then by used to store messages in the log file of PostgreSQL
  when it is configured to use syslog. This should match the
  configuration of PostgreSQL so that the messages of `archive_wal`
  are written to the logfile of PostgreSQL, otherwise they would be
  lost.

* `ARCHIVE_ENCRYPT` can be set to "yes" to encrypt the WAL file using
  GnuPG. `GPG_ENCRYPT_KEYS` must be configured to give the list of
  recipients for encryption

If archiving is set up to a remote host, this host must be reachable
using SSH in batch mode, meaning that passphraseless access using keys
is to be configured for the system user running PostgreSQL to the
remote host.


PostgreSQL configuration
------------------------

Once `archive_wal` is configured, PostgreSQL must be setup to use it by
modifying the `archive_command` parameter in postgresql.conf and
dependent parameters:

    # If using PostgreSQL >= 9.0, wal_level must be set to archive or hot_standby
    # If using PostgreSQL >= 9.6, wal_level must be set to replica
    # Changing this requires a restart
    wal_level = archive

    # If using PostgreSQL >= 8.3, archiving must be enabled
    # Changing this requires a restart
    archive_mode = on

    # The archive command using the defaults from pitrery.conf
    archive_command = '/usr/local/bin/archive_wal %p'

    # The archive command with parameters
    #archive_command = '/usr/local/bin/archive_wal -C /path/to/myconf.conf %p'
    # or to search /usr/local/etc/pitrery for the configuration:
    #archive_command = '/usr/local/bin/archive_wal -C myconf %p'


Depending on the version of PostgreSQL, restart the server if
`wal_level` or `archive_mode` were changed, otherwise reload it.


Base backups
------------

Since the WAL archiving is done by PostgreSQL, it is done by the
system user running the instance. This means that the configuration
file should be readable by this user if we want archive_wal to use
it. To keep things simple, it is advised to run pitrery as this user
too for backups and restores.

The first parameters configure how to connect to the PostgreSQL server
to backup.  It is needed to run `pg_start_backup()` and
`pg_stop_backup()` to let us tell PostgreSQL a backup is being
run. `pitrery` uses the client tools of PostgreSQL, so the usual
environment varibles are used to:

* `PGDATA` is the path to the directory storing the cluster

* `PGPSQL` is the path to the psql program

* PostgreSQL access configuration: `PGUSER`, `PGPORT`, `PGHOST` and
  `PGDATABASE` are the well known variables to reach the server.

If `psql` is in the PATH, the variable `PGPSQL` can be commented out
to use the one found in the PATH. If other variables are defined in
the environment, they can be commented out in the file to have pitrery
use them. Please note that it is usually safer to configure them in
the configuration file as environment variables may not be set when
running commands using cron.

The following parameters control the different actions accessible
through pitrery:

* `PGOWNER` is the system user which owns the files of the cluster, it
  is useful when restoring as root if the user want to restore as
  another user.

* `PGWAL` is a path where transaction logs can be stored on restore,
  pg_wal would then be a symbolic link to this path, like `initdb -X`
  would do.

* `BACKUP_DIR` is the path to the directory where to store the backups.

* `BACKUP_HOST` is the name or IP address of the host where backups
  shall be stored. If left empty, backups are local.

* `BACKUP_USER` is the username to use for SSH login, if empty, the
  username is the one running pitrery.

* `RESTORE_COMMAND` can be used to define the command run by PostgreSQL
  when it needs to retrieve a WAL file before applying it in recovery
  mode. It is useful when WAL archiving is not performed by
  pitrery. When archive_wal is used, e.g. `RESTORE_COMMAND` is left
  empty, it defaults to a call to `restore_wal` and it is not necessary
  to set it up here.

* `PURGE_KEEP_COUNT` controls how many backups must be kept when purging
  old backups.

* `PURGE_OLDER_THAN` controls how many __days__ backups are kept when
  purging. If `PURGE_KEEP_COUNT` is also set, age based purge will
  always leave at least `PURGE_KEEP_COUNT` backups.

* `LOG_TIMESTAMP` can be set to "yes" to prefix the messages with the
  date for backup, restore and purge actions.

* `USE_ISO8601_TIMESTAMPS`, when set to "yes", names the backup
  directories using ISO 8601 format. Defaults to "no" to keep the
  backward compatibility, as mixing formats of backup names would
  break the sorting of backups on restore.

* `RSYNC_WHOLEFILE`, when set to "yes", disable the rsync on the fly
  comparison algorithm by adding `--whole-file` to the `rsync`
  commandline. This may improve performance over NFS. Default is "no".

* `RSYNC_BWLIMIT`, limit the bandwidth usage for rsync. This is the
  value of --bwlimit of rsync. With no unit, it is in kB/s. Leave
  empty for no limit, there is no limit by default.



Backup storage
--------------

pitrery offers two storage techniques for the base backup.

The first, and historical, is `tar`, where it creates one compressed
tarball (with `gzip` by default) for `PGDATA` and one for each
tablespace. The `tar` method is quite slow and can become difficult to
use with bigger database clusters, however the compression saves a lot
of space.

The second is `rsync`. It synchronises PGDATA and each tablespace to a
directory inside the backup, and try to optimise data transfer by
hardlinking the files of the previous backup (provided it was done
with the "rsync" method). This method should offer the best speed for
the base backup, and is recommended for bigger databases clusters (more
than several hundreds of gigabytes).

The default method is `tar`. It can be configured by setting the
`STORAGE` variable to either `tar` or `rsync` in the configuration
file.


Tuning compression of archived WAL files
----------------------------------------

By default, `archive_wal` uses `gzip -4` to compress the WAL files
when configured to do so (`ARCHIVE_COMPRESS="yes"`). It is possible to
compress more and/or faster by using other compression tools, like
`bzip2`, `pigz`, the prerequisites are that the compression program
must accept the `-c` option to output on stdout and the data to
compress from stdin. The compression program can be configured by
setting `ARCHIVE_COMPRESS_BIN` in the configuration file. The output
filename has a suffix depending on the program used (e.g. "gz" or
"bz2", etc), it must be configured using `ARCHIVE_COMPRESS_SUFFIX`
(without the leading dot), this suffix is most of the time mandatory
for decompression. The decompression program is then configured using
`ARCHIVE_UNCOMPRESS_BIN`, this command must accept a compressed file
as its first argument.

For example, the fastest compression is archived with `pigz`, a
multithreaded implementation of gzip:

    ARCHIVE_COMPRESS_BIN="pigz"
    ARCHIVE_UNCOMPRESS_BIN="pigz -d"

Or maximum, but slow, compression with the standard `bzip2`:

    ARCHIVE_COMPRESS_BIN="bzip2 -9"
    ARCHIVE_COMPRESS_SUFFIX="bz2"
    ARCHIVE_UNCOMPRESS_BIN="bunzip"

When encryption is active, compression is managed by GnuPG. The
compression options listed before do not apply.


Tuning compression of base backups with tar
-------------------------------------------

When using tar for storing backups, PGDATA and the tablespaces are
compressed using `gzip`. This can be changed by configuring:

* `BACKUP_COMPRESS_BIN` to specify the command line to use for
  compression of the tar files. The output of `tar` is piped to this
  command, then the result is redirected to the target file.

* `BACKUP_COMPRESS_SUFFIX` must be used to tell pitrery what is
  the suffix appended by the compression program used in
  `BACKUP_COMPRESS_BIN`. This is mandatory for the restore.

* `BACKUP_UNCOMPRESS_BIN` to specify the command line to uncompress
  files produced by the previous command. It must work with pipes and
  understand that a `-c` switch makes it output on stdout. Widely used
  compression tools such as `gzip`, `bzip2`, `pigz`, `pbzip2`, `xz`
  work this way.

When encryption is active, compression is managed by GnuPG. The
compression options listed before do not apply.


Encryption of base backups and archived WAL files
-------------------------------------------------

**Warning: Encryption of backups and archived WAL files is
experimental and should be used with caution.**

When using tar for storing backups, they can also be encrypted using
GnuPG. For backup and WAL archiving, the public keys of recipients
must be in the keyring of the user running the PostgreSQL instance and running
pitrery.

When restoring, the secret key must be in the keyring of the user
running pitrery and the PostgreSQL instance.

PostgreSQL can decrypt the restored WAL files without prompting for a
passphrase if it started with `pg_ctl` in a session where a GnuPG
Agent is running with the passphrase cached. The simplest way to feed
the passphrase to the agent is to start PostgreSQL right after
restoring intarectively. See [Restoring an encrypted backup] below.

The encryption of tar backups is controlled by the following parameters:

* `BACKUP_ENCRYPT` must be set to "yes" to encrypt base backups.

* `ARCHIVE_ENCRYPT` must be set to "yes" to encrypt archived WAL files.

* `GPG_ENCRYPT_KEYS` is a colon separeted list of USER-ID recognized
  by the --recipient option of `gpg`. The keys must be in the keyring
  of the user running PostgreSQL in order encrypt WAL files at
  archiving time.

It is advised to encrypt with a local public key *and* another key that has its
private counterpart stored on another machine: if the private keys are lost,
the backups become unusable.

Hooks
-----

Some user defined commands can be executed, they are given in the
following configuration variables:

* `PRE_BACKUP_COMMAND` is run before the backup is started.

* `POST_BACKUP_COMMAND` is run after the backup is finished. The
  command is run even if the backup fails, but not if the backup fails
  because of the `PRE_BACKUP_COMMAND` or earlier (e.g. the order "pre
  -- base backup -- post" is ensured).

The following variables are then available, to access the PostgreSQL
or the current backup:

* `PITRERY_HOOK` is the name of the hook being run

* `PITRERY_PSQL` is the psql command line to run SQL statement on the
  saved PostgreSQL server

* `PITRERY_DATABASE` is the name of the connection database

* `PITRERY_BACKUP_DIR` is the full path to the directory of the backup

* `PITRERY_BACKUP_LOCAL` can be used to know if SSH is required to access the backup directory

* `PITRERY_SSH_TARGET` the user@host part needed to access the backup server

* `PITRERY_EXIT_CODE` is the exit code of the backup. 0 for success, 1 for failure




Using pitrery from the command line
===================================

Choosing a configuration file
-----------------------------

By running pitrery without action, we can use the `-l` option to list
the configuration files in the default configuration directory.

    $ pitrery -l
    INFO: listing configuration files in /etc/pitrery
    prod
    pitrery

`pitrery` being the default configuration file, it is not mandatory to
specify it on the command line. If using another one, use the `-f`
option in every call to pitrery before the action to perform:

    $ pitrery -f prod check
    $ pitrery -f prod list -v


Configuring pitrery from the command line
-----------------------------------------

The `configure` action can create a configuration file. It needs a
destination of the form `[[user@]host:]/path` to know where backups
shall be stored. If a host is not provided, the backup is considered
local.  Some options are available to create a configuration :

    $ pitrery configure -?
    pitrery configure - Create a configuration file from the command line

    usage: pitrery configure [options] [[user@]host:]/path/to/backups

    options:
        -o config_file         Output configuration file
        -f                     Overwrite the destination file
        -C                     Do not connect to PostgreSQL

        -s mode                Storage method, tar or rsync
        -m count               Number of backups to keep when purging
        -g days                Remove backups older than this number of days
        -D dir                 Path to $PGDATA
        -a [[user@]host:]/dir  Place to store WAL archives
        -E                     Encrypt tar backups with GPG
        -r keys:...            Colon separated list of recipients for GPG encryption

        -P psql                Path to the psql command
        -h hostname            Database server host or socket directory
        -p port                Database server port number
        -U name                Connect as specified database user
        -d database            Database to use for connection

        -?                     Print help


Not all possible configuration options are provided, the purpose is to
quickly set pitrery up, then a edit the configuration file created for
further tuning.  It is worth noting that `-C` avoids making pitrery
connect to PostgreSQL so that the correct parameters for WAL archiving
are output. `-o` writes the configuration files if it does not exists,
if only a keyword is given, the file is created in the default
configuration directory.


Checking the configuration file
-------------------------------

The `check` action can check if a configuration file is correct.  The
action tests if the backup directory is reachable, if WAL archiving
can be done with `archive_wal`, if PostgreSQL is up and properly
configured for PITR and if the current user can actually backup the
files.

For example, the following commands checks the `prod.conf`
configuration file:

    $ pitrery -f prod check
    INFO: the configuration file contains:
    PGDATA="/var/lib/postgresql/12/main"
    PGPORT=5433
    BACKUP_DIR="/var/backups/postgresql"
    PURGE_KEEP_COUNT=2
    USE_ISO8601_TIMESTAMPS="no"

    INFO: ==> checking the configuration for inconsistencies
    INFO: configuration seems correct
    INFO: ==> checking backup configuration
    INFO: backups are local, not checking SSH
    INFO: target directory '/var/backups/postgresql' exists
    INFO: target directory '/var/backups/postgresql' is writable
    INFO: ==> checking WAL files archiving configuration
    INFO: WAL archiving is local, not checking SSH
    INFO: checking WAL archiving directory: /var/backups/postgresql/archived_wal
    ERROR: target directory '/var/backups/postgresql/archived_wal' does NOT exist or is NOT reachable
    INFO: ==> checking access to PostgreSQL
    INFO: psql command and connection options are: psql -X -p 5433
    INFO: connection database is: postgres
    INFO: environment variables (maybe overwritten by the configuration file):
    INFO: PostgreSQL version is: 12.1
    INFO: connection role can run backup functions
    INFO: current configuration:
    INFO:   wal_level = minimal
    INFO:   archive_mode = off
    INFO:   archive_command = '(disabled)'
    ERROR: wal_level must be set at least to replica
    ERROR: archive_mode must be set to on
    INFO: ==> checking access to PGDATA
    INFO: PostgreSQL and the configuration reports the same PGDATA
    INFO: permissions of PGDATA ok
    INFO: owner of PGDATA is the current user
    INFO: access to the contents of PGDATA ok

Here the `check` action reports that PostgreSQL is not properly
configured for archiving WAL files and that a directory is
missing. Fixing those error is mandatory to make the backups work:

    $ pitrery -f prod check
    INFO: the configuration file contains:
    PGDATA="/var/lib/postgresql/12/main"
    PGPORT=5433
    BACKUP_DIR="/var/backups/postgresql"
    PURGE_KEEP_COUNT=2
    USE_ISO8601_TIMESTAMPS="no"

    INFO: ==> checking the configuration for inconsistencies
    INFO: configuration seems correct
    INFO: ==> checking backup configuration
    INFO: backups are local, not checking SSH
    INFO: target directory '/var/backups/postgresql' exists
    INFO: target directory '/var/backups/postgresql' is writable
    INFO: ==> checking WAL files archiving configuration
    INFO: WAL archiving is local, not checking SSH
    INFO: checking WAL archiving directory: /var/backups/postgresql/archived_wal
    INFO: target directory '/var/backups/postgresql/archived_wal' exists
    INFO: target directory '/var/backups/postgresql/archived_wal' is writable
    INFO: ==> checking access to PostgreSQL
    INFO: psql command and connection options are: psql -X -p 5433
    INFO: connection database is: postgres
    INFO: environment variables (maybe overwritten by the configuration file):
    INFO: PostgreSQL version is: 12.1
    INFO: connection role can run backup functions
    INFO: current configuration:
    INFO:   wal_level = replica
    INFO:   archive_mode = on
    INFO:   archive_command = 'archive_wal -C prod %p'
    INFO: ==> checking access to PGDATA
    INFO: PostgreSQL and the configuration reports the same PGDATA
    INFO: permissions of PGDATA ok
    INFO: owner of PGDATA is the current user
    INFO: access to the contents of PGDATA ok


Backup
------

**Beware that the backup must run on the PostgreSQL server host**,
SSH login is used to __push__ data to a backup server, and PostgreSQL
connection options to run SQL __locally__.

To run a backup with pitrery, either a configuration file is needed
or the options must be put on the commandline. The usage of the backup
action is:

    $ pitrery backup -?
    pitrery backup - Perform a base backup

    usage: pitrery backup [options] [[[user@]host:]/path/to/backups]

    options:
        -D dir               Path to $PGDATA
        -s mode              Storage method, tar or rsync
        -c compress_bin      Compression command for tar method
        -e compress_suffix   Suffix added by the compression program
            -E                   Encrypt tar backups with GPG
        -r keys:...          Colon separated list of recipients for GPG encryption
        -t                   Use ISO 8601 format to name backups
        -T                   Timestamp log messages

        -P PSQL              path to the psql command
        -h HOSTNAME          database server host or socket directory
        -p PORT              database server port number
        -U NAME              connect as specified database user
        -d DATABASE          database to use for connection

        -?                   Print help



For example:

    $ pitrery -f prod backup
    INFO: preparing directories in /var/backups/postgresql/
    INFO: listing tablespaces
    INFO: starting the backup process
    INFO: performing a non-exclusive backup
    INFO: backing up PGDATA with tar
    INFO: archiving /var/lib/postgresql/12/main
    INFO: stopping the backup process
    INFO: saving /etc/postgresql/12/main/postgresql.conf
    INFO: saving /etc/postgresql/12/main/pg_hba.conf
    INFO: saving /etc/postgresql/12/main/pg_ident.conf
    INFO: copying the backup history file
    INFO: copying the tablespace_map file
    INFO: copying the tablespaces list
    INFO: copying PG_VERSION
    INFO: backup directory is /var/backups/postgresql//2019.11.15_09.56.43
    INFO: done

If we have a look at the contents of the `/var/backups/postgresql`
directory on the backup host:

    $ tree /var/backups/postgresql
    /var/backups/postgresql
    ├── 2019.11.15_09.56.43
    │   ├── backup_label
    │   ├── backup_timestamp
    │   ├── conf
    │   │   ├── pg_hba.conf
    │   │   ├── pg_ident.conf
    │   │   └── postgresql.conf
    │   ├── pgdata.tar.gz
    │   ├── PG_VERSION
    │   ├── tablespace_map
    │   ├── tblspc
    │   └── tblspc_list
    └── archived_wal
        ├── 00000001000000000000002E.gz
        ├── 00000001000000000000002F.gz
        ├── 000000010000000000000030.gz
        ├── 000000010000000000000031.00000028.backup.gz
        └── 000000010000000000000031.gz



The backup directory is named with the stop date and time of the
backup. The `backup_timestamp` file contains the timestamp value of
the stop time of the backup, which is used by the restore action to
find the best candidate when restoring to a specific date and time and
by the purge action. The directory stores the backup label file of
PostgreSQL, a tarball of the PGDATA directory, tarballs for each
tablespace and the tablespace list with their path. Finally, shown in
the example but not always present, a `conf` directory can be created
to store configuration files of the database cluster
(`postgresql.conf`, `pg_hba.conf` and `pg_ident.conf`) when they are
not located inside `PGDATA`.

Notes:
* Here we have left the default configuration for `archive_wal` to
  store the WAL files in `archived_wal`. This keep them close to
  the base backups.
* When using the `rsync` storage method, tarballs are replaced with
  directories with the same base name.


Listing backups
---------------

The list action allow to find the backups the backup host or the
localhost depending on the configuration. By default, it prints a
parsable list of backups, with one backups on each line:

    $ pitrery -f prod list
    List of local backups
    /var/backups/postgresql/2019.11.15_09.56.43	5.8M	  2019-11-15 09:56:43 CEST
    /var/backups/postgresql/2019.11.15_10.13.30	5.8M	  2019-11-15 10:13:30 CEST

The `-v` switch display more information on each backups, like needed space
for each tablespace :

* The "space used" value is the size of the backup,

* The disk usage for PGDATA and tablespaces is recorded at backup
  time, it is the space one need to restore

For example :

    $ pitrery -f prod list -v
    List of local backups
    ----------------------------------------------------------------------
    Directory:
      /var/backups/postgresql/2019.11.15_10.13.20
      space used: 5.8M
      storage: tar with gz compression
      encryption: false
    Minimum recovery target time:
      2019-11-15 10:13:30 CEST
    PGDATA:
      pg_default 47 MB
      pg_global 505 kB
    Tablespaces:

    ----------------------------------------------------------------------
    Directory:
      /var/backups/postgresql/2019.11.15_09.56.43
      space used: 5.8M
      storage: tar with gpg compression
      encryption: true
    Minimum recovery target time:
      2019-11-15 09:56:43 CEST
    PGDATA:
      pg_default 47 MB
      pg_global 505 kB
    Tablespaces:
      "ts1" /var/lib/postgresql/tblspc/12/main/ts1 (18768) 0 bytes


Like the other commands, the options of the list action can be display
by adding the -? option after the action:

    $ pitrery list -?
    pitrery list - Display information about backups

    usage: pitrery list [options] [[user@]host:]/path/to/backups

    options:
        -v              Display details of the backup

        -?              Print help



Restore
-------

The restore action selects a backup and prepares the recovery to restore
to a particular point in time. The target date must be given on the
command line using the `-d` option.

The best format is the one expected by PostgreSQL: `YYYY-mm-DD HH:MM:SS [+-]TZTZ`.
The `'[+-]TZTZ'` is the timezone offset, it must given as `HHMM`, .e.g
+2h30 would be +0230 and -7h would be -0700. This work best with the
`date` command found on most Unix systems.

Depending on the local `date` command, the target date can be
anything it can parse, for example, offsets like `1 day ago` work with
GNU date.

This action perform the following steps:

* Find the newest possible backup from the store.

* Retrieve and extract the contents of PGDATA and the tablespaces.

* Create a `recovery.signal` or `standby.signal` file depending on
  _RESTORE_MODE_ configuration. Add recovery keys at the end of the
  `postgresql.conf` file. Or, for PostgreSQL in version 11 or less, create a
  `recovery.conf` file.

* Optionally, restore the saved configuration files in
  `PGDATA/restored_config_files` if they were outside PGDATA at the time
  of the backup.

* Create a script which can be used to optionally restore any replication
  slots that were active (or inactive) at the time of the base backup.

* Optionally, create a script to update the catalogue when paths to
  tablespaces have changed, for PostgreSQL <= 9.1.

The restore will only work if the target destination directory (PGDATA
in the configuration file of pitrery) and the directories used by
tablespaces exist or can be created, are writable and empty. It is
important to prepare those directories before running the restore. It
is possible to overwrite contents of target directories with the `-R`
option.

When specifying a target date, it will be used in the configuration file as
value for the `recovery_target_time` parameter (in `postgresql.conf` from
versions 12 onward and in `$PGDATA/recovery.conf` for versions 11 and less).

Unless `RESTORE_COMMAND` is defined to something else, the `restore_wal`
script will be used by PostgreSQL to retrieve archived WAL files. The
purpose of this script is to find, copy on PostgreSQL server, and
uncompress the archived WAL file asked by PostgreSQL.

The restore actions uses options values from the configuration, which
is passed by the restore action to `restore_wal`, using the `-C`
option. If options, different from the configuration, must be given to
`restore_wal`, the complete command must be provided to the restore
action with `-r`.

The command line for the restore action can be tested using the `-n`
(dry run) option:

    $ pitrery -f prod restore -n
    INFO: searching backup directory
    INFO: searching for tablespaces information
    INFO:
    INFO: backup directory:
    INFO:   /var/backups/postgresql/2019.11.15_10.13.30
    INFO:
    INFO: destinations directories:
    INFO:   PGDATA -> /var/lib/postgresql/12/main
    INFO:   tablespace "ts1" (18768) -> /var/lib/postgresql/tblspc/12/main/ts1 (relocated: no)
    INFO:
    INFO: recovery configuration:
    INFO:   target owner of the restored files: postgres
    INFO:   restore_command = 'restore_wal -C /usr/local/etc/pitrery/prod.conf %f %p'
    INFO:

Let's say the target directories are ready for a restore run by the
`postgres` user, the restore can be started with pitrery on an example
production server, ensure the date (or other arguments that need it)
are properly quoted:

    $ pitrery -f prod restore -d '2019-11-15 11:04:30 +0200'
    INFO: searching backup directory
    INFO: searching for tablespaces information
    INFO:
    INFO: backup directory:
    INFO:   /var/backups/postgresql/2019.11.15_10.13.30
    INFO:
    INFO: destinations directories:
    INFO:   PGDATA -> /var/lib/postgresql/12/main
    INFO:
    INFO: recovery configuration:
    INFO:   target owner of the restored files: postgres
    INFO:   restore_command = 'restore_wal -C /usr/local/etc/pitrery/prod.conf %f %p'
    INFO:   recovery_target_time = '2019-11-15 11:04:30 +0200'
    INFO:
    INFO: creating /var/lib/postgresql/12/main with permission 0700
    INFO: extracting PGDATA to /var/lib/postgresql/12/main
    INFO: extraction of PGDATA successful
    INFO: restoring configuration files to /var/lib/postgresql/12/main/restored_config_files
    INFO: preparing pg_wal directory
    INFO: preparing recovery.conf file
    INFO: done
    INFO:
    INFO: saved configuration files have been restored to:
    INFO:   /var/lib/postgresql/12/main/restored_config_files
    INFO:
    INFO: please check directories and recovery.conf before starting the cluster
    INFO: and do not forget to update the configuration of pitrery if needed
    INFO:



The restore script finds that the backup to be restored is located in
`/var/backups/postgresql/2019.11.15_10.13.30` on our backup server. It then
extracts everything, including the tablespaces if some exists and create the
signal file at the root of `$PGDATA`. It adds the configuration keys in the
`postgresql.conf` file located either in `$PGDATA` or in the restored config
files folder. The script asks the user to check everything before starting the
PostgreSQL cluster: this behaviour is intentional, it allows the user to modify
parameters of PostgreSQL or change how the recovery is configured in
`postgresql.conf`.

In version 11 and less, there is no signal file created and the configuration
keys are stored in the file `recovery.conf` into the root of `$PGDATA`.

When everything is fine, the PostgreSQL can be started, and it will apply
the archived WAL files until the target date is reached or until all
archived WAL files are consumed if no target date was specified.

If unsure about the options to give for a restore, use the `-n` switch
of the restore action to make it stop after showing the information.

Furthermore, it possible choose the target directories when restoring,
use `-D` switch to set the target directory for PGDATA, and one to many
`-t` switches to relocate the tablespaces to other directories. The
format of the value of a `-t` option is `tablespace_name_or_oid:new_directory`.

One `-t` option apply to one tablespace. For example:

    $ pitrery -f prod restore -D /var/lib/postgresql/12/main2 \
    > -t ts1:/var/lib/postgresql/tblspc/12/main/ts1_2
    INFO: searching backup directory
    INFO: searching for tablespaces information
    INFO:
    INFO: backup directory:
    INFO:   /var/backups/postgresql/2019.11.15_10.13.30
    INFO:
    INFO: destinations directories:
    INFO:   PGDATA -> /var/lib/postgresql/12/main2
    INFO:   tablespace "ts1" (18768) -> /var/lib/postgresql/tblspc/12/main/ts1_2 (relocated: yes)
    INFO:
    INFO: recovery configuration:
    INFO:   target owner of the restored files: postgres
    INFO:   restore_command = 'restore_wal -C /usr/local/etc/pitrery/prod.conf %f %p'
    INFO:
    INFO: creating /var/lib/postgresql/12/main2 with permission 0700
    INFO: creating /var/lib/postgresql/tblspc/12/main/ts1_2 with permission 0700
    INFO: extracting PGDATA to /var/lib/postgresql/12/main2
    INFO: extraction of PGDATA successful
    INFO: restoring configuration files to /var/lib/postgresql/12/main2/restored_config_files
    INFO: extracting tablespace "ts1" to /var/lib/postgresql/tblspc/12/main/ts1_2
    INFO: extraction of tablespace "ts1" successful
    INFO: preparing pg_wal directory
    INFO: preparing recovery.conf file
    INFO: done
    INFO:
    INFO: saved configuration files have been restored to:
    INFO:   /var/lib/postgresql/12/main2/restored_config_files
    INFO:
    INFO: please check directories and recovery.conf before starting the cluster
    INFO: and do not forget to update the configuration of pitrery if needed
    INFO:


In the above example, the PGDATA has been changed along with the path
of the ts1 tablespace.


With version of PostgreSQL 9.1 or older, pitrery creates a SQL file
with the `UPDATE` statements needed to change the `spclocation`
column of `pg_tablespace` (this columns has been removed as of
9.2). This script must be run as a superuser role on the restored
cluster after the recovery.

Again, if unsure, run the restore action with the `-n` switch to display
what would be done.

The options of restore are:

    $ pitrery restore -?
    pitrery restore - Restore a base backup and prepare PITR

    usage: pitrery restore [options] [[[user@]host:]/path/to/backups]

     options:
        -D dir               Path to target $PGDATA
        -x dir               Path to the wal directory (only if outside $PGDATA)
        -d date              Restore until this date
        -O user              If run by root, owner of the files
        -t tblspc:dir        Change the target directory of tablespace "tblspc"
                               this switch can be used many times
        -n                   Dry run: show restore information only
        -R                   Overwrite destination directories
        -c compress_bin      Uncompression command for tar method
        -e compress_suffix   Suffix added by the compression program
        -r command           Command line to use in restore_command
        -C config            Configuration file for restore_wal in restore_command
        -m restore_mode      restore either in "standby" or "recovery" mode
        -T                   Timestamp log messages

        -?                   Print help


Restoring an encrypted backup
----------------------------

**Warning: Encryption of backups and archived WAL files is
experimental and should be used with caution.**

When the backup is encrypted, decryption is transparent. The user
running the restore action must have the secret key required to
decrypt the data in its keyring. Since a restore can take quite a long
time, it is recommended to start a gpg-agent explicitely for the
operation with longer cache TTL values (7 days in the example):

    eval $(/usr/bin/gpg-agent --daemon --allow-preset-passphrase \
      --default-cache-ttl 604800 --max-cache-ttl 604800)

If the restore fails on GnuPG complaining there are no tty for prompting
the passphrase, get one using `script`:

    script /dev/null
    export GPG_TTY=$(tty)

This will allow pinentry to prompt for the passphrase.

Since those information are in the shell environment, PostgreSQL can
use the agent when started using `pg_ctl`. To make the recovery
process successfully decrypt the archived WAL files, start the
PostgreSQL instance with `pg_ctl` after the restore in the same
console session, the restart it using the regular init script/systemd
unit if needed.


Removing old backups
--------------------

The purge action removes old backups according to a policy based on
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

For example, we have three backups on the store and we want to keep only
one, while `PURGE_KEEP_COUNT=2`:

    $ pitrery -f prod purge -m 1
    INFO: searching backups
    INFO: Would be purging the following backups:
    INFO:  /var/backups/postgresql/2019.11.15_09.56.43
    INFO:  /var/backups/postgresql/2019.11.15_10.13.30
    INFO: listing WAL files older than 000000010000000000000035
    INFO: 9 old WAL file(s) to remove
    INFO: purging old WAL files
    INFO: done

Note that if there are no backups but archived WAL files, the purge
action will not remove those WAL files.

The options of purge are:

    $ pitrery purge -?
    pitrery purge - Clean old base backups and archived WAL files

    usage: pitrery purge [options] [[user@]host:]/path/to/backups

    options:
        -m count               Keep this number of backups
        -d days                Purge backups older than this number of days

        -a [[user@]host:]/dir  Path to WAL archives

        -N                     Dry run: show what would be purged only

        -T                     Timestamp log messages
        -?                     Print help


If unsure about the configuration of the purge, the `-N` switch can be
used to display what would be done.

Checking the backups and archived WAL files
-------------------------------------------

The check action can check if there are enough backups and their
against thresholds. This mode must be selected with the `-B` option of
the check action.

The check is successful if the number of backups is greater or equal
than the number provided to the `-m` option or `PURGE_KEEP_COUNT` if
not specified.  It is also successful if the age of the newest backup
is less than the interval provided to the `-g` option or
`PURGE_OLDER_THAN` if not specified.  The age limit is a number of
days or less if a time unit is specified, the supported units being
"s" (seconds), "min" (minutes), "h" (hours) and "d" (days), like ine
the PostgreSQL configuration.

This check mode can behave like a Nagios plugin with the `-n` option.

For example:

    $ pitrery check -B -g 1d -m 2 /home/pgsql/pitrery/r10
    INFO: checking local backups in: /home/pgsql/pitrery/r10
    INFO: newest backup age: 16d 20h 31min 30s
    INFO: number of backups: 3
    ERROR: backups are too old

With the nagios output:

    $ pitrery check -B -m 3 -g 30d -n localhost:/home/pgsql/pitrery/r10
    PITRERY BACKUPS OK - count: 3, newest: 16d 20h 40min 15s | count=3;3;3 newest=1456815s;2592000;2592000


The check action can check if there are no missing WAL files in the
archives. Archived WAL files are in a sequence: missing files could
make a backup impossible to restore or a make a point in time
unreachable.

To check the archives, use the `-A` option of the check action. The
path to the directory of the WAL archives can be specified with
`-a`. Access to the backups is mandatory to find the version of
PostgreSQL and the number of segments per log (the last segment was
skipped before PostgreSQL 9.3).

Like the check backups mode, it can behave like a Nagios plugin with
the `-n` option.  Currently, backups and archives cannot be checked at
the same time when Nagios plugin output is selected.

For example:

    $ pitrery check -A -a /home/pgsql/pitrery/r10/archived_wal /home/pgsql/pitrery/r10/
    INFO: checking local archives in /home/pgsql/pitrery/r10/archived_wal
    INFO: oldest backup is: /home/pgsql/pitrery/r10/2019.11.15_09.56.43
    INFO: start wal file is: 000000010000000000000017
    INFO: listing WAL files
    INFO: first WAL file checked is: 00000001000000000000000F.gz
    INFO: start WAL file found
    ERROR: missing WAL file: 00000001000000000000001C
    INFO: next found is: 0000000100000001000000F9
    INFO: last WAL file checked is: 000000010000000200000003.gz
    INFO: missing count is: 477

With the Nagios output:

    $ pitrery check -A -a /home/pgsql/pitrery/r10/archived_wal -n /home/pgsql/pitrery/r10/
    PITRERY WAL ARCHIVES CRITICAL - total: 32, missing: 477 | total=32;; missing=477;;

The options are:

    $ pitrery check -?
    pitrery check - Verify configuration and backups integrity

    usage: pitrery check [options] [[[user@]host:]/path/to/backups]

    options:
        -C conf                Configuration file

        -B                     Check backups
        -m count               Fail when the number of backups is less than count
        -g age                 Fail when the newest backup is older than age

        -A                     Check WAL archives
        -a [[user@]host:]/dir  Path to WAL archives
        -c command             Uncompression command

        -n                     Nagios compatible output for -b and -A

        -?                     Print help
