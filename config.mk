NAME = pitrery
VERSION = 1.9

# Customize below to fit your system

# Bash is mandatory
BASH = /bin/bash

# Command line to use when duplicating a directory tree using
# hardlinks.
#
# When using GNU cp (e.g. Linux) set this to cp -rl
HARDLINKER = cp -rl
# When using *nix or BSD, set this to pax -rwl
#HARDLINKER = pax -rwl

# paths
PREFIX = /usr/local
BINDIR = ${PREFIX}/bin
LIBDIR = ${PREFIX}/lib
SYSCONFDIR = ${PREFIX}/etc/${NAME}
DOCDIR = ${PREFIX}/share/doc/${NAME}
