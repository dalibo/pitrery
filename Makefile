# See COPYRIGHT file for copyright and license details.

include config.mk

SRCS = archive_xlog.bash \
	pitrery.bash \
	restore_xlog.bash
HELPERS = backup_pitr.bash \
	list_pitr.bash \
	purge_pitr.bash \
	restore_pitr.bash
SRCCONFS = pitr.conf.sample
DOCS = COPYRIGHT INSTALL.md UPGRADE.md CHANGELOG
SRCMANPAGES = pitrery.1.man archive_xlog.1.man restore_xlog.1.man

BINS = $(basename $(SRCS))
LIBS = $(basename $(HELPERS))
CONFS = $(basename $(SRCCONFS))
MANPAGES = $(basename $(SRCMANPAGES))

all: options $(BINS) $(LIBS) $(CONFS) $(MANPAGES)

options:
	@echo ${NAME} ${VERSION} install options:
	@echo "PREFIX     = ${PREFIX}"
	@echo "BINDIR     = ${BINDIR}"
	@echo "LIBDIR     = ${LIBDIR}/${NAME}"
	@echo "SYSCONFDIR = ${SYSCONFDIR}"
	@echo "DOCDIR     = ${DOCDIR}"
	@echo

$(BINS) $(LIBS): $(SRCS) $(HELPERS)
	@echo translating paths in bash scripts: $@
	@sed -e "s%@BASH@%${BASH}%" \
		-e "s%@VERSION@%${VERSION}%" \
		-e "s%@BINDIR@%${BINDIR}%" \
		-e "s%@SYSCONFDIR@%${SYSCONFDIR}%" \
		-e "s%@LIBDIR@%${LIBDIR}/${NAME}%" $(addsuffix .bash,$@) > $@

$(CONFS): $(SRCCONFS)
	@echo translating paths in configuration files: $@
	@sed -e "s%@SYSCONFDIR@%${SYSCONFDIR}%" \
		-e "s%@LIBDIR@%${LIBDIR}/${NAME}%" $(addsuffix .sample,$@) > $@

$(MANPAGES): $(SRCMANPAGES)
	@echo translating paths in manual pages: $@
	@sed -e "s%@SYSCONFDIR@%${SYSCONFDIR}%" $(addsuffix .man,$@) > $@

clean:
	@echo cleaning
	@-rm -f $(BINS)
	@-rm -f $(LIBS)
	@-rm -f $(CONFS)
	@-rm -f $(MANPAGES)

install: all
	@echo installing executable files to ${DESTDIR}${BINDIR}
	@mkdir -p ${DESTDIR}${BINDIR}
	@cp -f $(BINS) ${DESTDIR}${BINDIR}
	@chmod 755 $(addprefix ${DESTDIR}${BINDIR}/,$(BINS))
	@echo installing helpers to ${DESTDIR}${LIBDIR}/${NAME}
	@mkdir -p ${DESTDIR}${LIBDIR}/${NAME}
	@cp -f $(LIBS) ${DESTDIR}${LIBDIR}/${NAME}
	@chmod 755 $(addprefix ${DESTDIR}${LIBDIR}/${NAME}/,$(LIBS))
	@echo installing configuration to ${DESTDIR}${SYSCONFDIR}
	@mkdir -p ${DESTDIR}${SYSCONFDIR}
	@-cp -i $(CONFS) ${DESTDIR}${SYSCONFDIR} < /dev/null >/dev/null 2>&1
	@echo installing docs to ${DESTDIR}${DOCDIR}
	@mkdir -p ${DESTDIR}${DOCDIR}
	@cp -f $(CONFS) $(DOCS) ${DESTDIR}${DOCDIR}
	@echo installing man pages to ${DESTDIR}${MANDIR}
	@mkdir -p ${DESTDIR}${MANDIR}/man1
	@cp -f $(MANPAGES) ${DESTDIR}${MANDIR}/man1

uninstall:
	@echo removing executable files from ${DESTDIR}${BINDIR}
	@rm -f $(addprefix ${DESTDIR}${BINDIR}/,$(BINS))
	@rm -f ${DESTDIR}${BINDIR}/pitr_mgr
	@echo removing helpers from ${DESTDIR}${LIBDIR}/${NAME}
	@rm -f $(addprefix ${DESTDIR}${LIBDIR}/${NAME}/,$(LIBS))
	@-rmdir ${DESTDIR}${LIBDIR}/${NAME}
	@echo removing docs from ${DESTDIR}${DOCDIR}
	@rm -f $(addprefix ${DESTDIR}${DOCDIR}/,$(CONFS))
	@rm -f $(addprefix ${DESTDIR}${DOCDIR}/,$(DOCS))
	@-rmdir ${DESTDIR}${DOCDIR}
	@echo removing man pages from ${DESTDIR}${MANDIR}
	@rm -f $(addprefix ${DESTDIR}${MANDIR}/man1/,$(MANPAGES))

.PHONY: all options clean install uninstall
