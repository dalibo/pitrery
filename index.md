---
layout: default
title: pitrery - Home
---

Welcome
=======

Introduction
------------

pitrery is a set of Bash scripts to manage Point In Time Recovery (PITR) backups for PostgreSQL.

pitrery automates [Continuous Archiving and Point-in-Time Recovery (PITR)](http://www.postgresql.org/docs/current/static/continuous-archiving.html) as much as possible with the following goals:

* Do only PITR, log-shipping and replication is outside of the scope
* Be the least possible intrusive about archiving

Pitrery has been tested and works with all currently supported versions of PostgreSQL.

It is free software licensed under the PostgreSQL License.

Quick start
-----------

1. Get the source, edit the `config.mk`, run `make` and `make install`

2. Run `pitrery configure -o pitrery -f [[user@]host:]/path/to/backups` (user@host being optional)

3. Configure WAL archiving (`archive_command = 'archive_xlog %p'` and friends) in PostgreSQL

4. Run `pitrery` to perform your backups and restores


News
----

<ul class="posts">
  {% for post in site.posts %}
  <li><span>{{ post.date | date_to_string }}</span> &raquo; <a href="{{ site.baseurl }}{{ post.url }}">{{ post.title }}</a></li>
  {% endfor %}
</ul>

