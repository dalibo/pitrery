---
layout: post
title:  "pitrery 3.1 released"
date:   2020-06-03 15:42:00
categories: news release
---

pitrery is a set of Bash scripts to manage PITR backups for PostgreSQL.

### Bugfixes

* Preserve `xlog` scripts as symlinks in debian and rpm packages #97 Please
  update your `archive_command` and `restore_command` parameters to use the new
  scripts `archive_wal` and `restore_wal`.

* Report `qw` update to `archive_wal` and `restore_wal` #94, #110 (thanks pgstef)
  Please update if you are using bash version < 4.2.

* Release process review

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
