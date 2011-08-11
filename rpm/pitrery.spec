Name:           pitrery
Version:        1.0
Release:        1%{?dist}
Summary:        Point-In-Time Recovery tools for PostgreSQL
License:        BSD
Group:          Applications/Databases
URL:            https://github.com/dalibo/pitrery
Source0:        pitrery-1.0.tar.gz
Patch1:         pitrery.config.patch
BuildArch:      noarch
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)

%description
pitrery is set of tools to ease to management of PITR backups and
restores.

- Management of WAL segments archiving with compression to hosts
reachable with SSH
- Automation of the base backup procedure
- Restore to a particular date
- Management of backup retention

%prep
%setup -q
%patch1 -p0

%build
make

%install
make install DESTDIR=%{buildroot}

%files
%config(noreplace) /etc/sysconfig/pgsql/archive_nodes.conf
%config(noreplace) /etc/sysconfig/pgsql/archive_xlog.conf
%config(noreplace) /etc/sysconfig/pgsql/pitr.conf
/usr/bin/archive_xlog
/usr/bin/pitr_mgr
/usr/bin/restore_xlog
/usr/lib/pitrery/backup_pitr
/usr/lib/pitrery/list_pitr
/usr/lib/pitrery/purge_pitr
/usr/lib/pitrery/restore_pitr

%changelog
* Thu Aug 11 2011 Nicolas Thauvin <nicolas.thauvin@dalibo.com> - 1.0-1
- Update to 1.0

* Mon Aug  8 2011 Nicolas Thauvin <nicolas.thauvin@dalibo.com> - 1.0rc2-1
- New package

