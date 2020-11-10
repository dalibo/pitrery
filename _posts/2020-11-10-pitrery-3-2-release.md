---
layout: post
title:  "pitrery 3.2 released"
date:   2020-11-10 14:57:00
categories: news release
---

pitrery is a set of Bash scripts to manage PITR backups for PostgreSQL.

### New feature


* Pitrery version 3.2 is compatible with PostgreSQL version 13.

* Add CI for local tests (see CONTRIBUTING.md).

### Bugfixes

* Abort check if backup_timestamp is not available (#130)

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
