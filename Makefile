# See COPYRIGHT file for copyright and license details.

# The install can be customized by modifying config.mk
include config.mk

# The place where we store the files processed by sed.  Do not set
# that to the same directory as the source files, or you would destroy
# them
BUILDDIR = _build

# Files to install
SRCS = archive_wal restore_wal pitrery
CONFS = pitrery.conf
DOCS = COPYRIGHT INSTALL.md UPGRADE.md CHANGELOG
SRCMANPAGES = pitrery.1 archive_wal.1 restore_wal.1

# Files that we temporary store into BUILDDIR before copying them to
# their target destination
MANPAGES = $(addprefix ${BUILDDIR}/, $(SRCMANPAGES))
BINS = $(addprefix ${BUILDDIR}/, $(SRCS))

DIST=pitrery-$(VERSION).tar.gz
DISTREMOTE=git@github.com:dalibo/pitrery.git

all: options $(BINS) $(CONFS) $(DOCS) $(MANPAGES)

checkversion:
	grep -q 'VERSION = $(VERSION)$$' config.mk
	! grep ^version= $(SRCS) | grep -v '"$(VERSION)"'
	grep -q 'pitrery $(VERSION)$$' CHANGELOG
	grep -q -E 'BRANCH = (master|pitrery_$(shell echo $(VERSION)|cut -d'.' -f1))$$' config.mk

dist: $(DIST)
$(DIST):
	git archive --prefix=pitrery-$(VERSION)/ -o $@ v$(VERSION)

distsign: $(DIST)
	gpg --detach-sign --armor $^

disttag: checkversion
	git fetch $(DISTREMOTE) $(BRANCH)
	git diff --quiet FETCH_HEAD..HEAD
	git commit -m "Version $(VERSION)" config.mk $(SRCS) CHANGELOG
	git diff --quiet  # Require clean worktree.
	git tag --sign v$(VERSION) --message="Version $(VERSION)"
	git push --tags $(DISTREMOTE)

options:
	@echo ${NAME} ${VERSION} install options:
	@echo "PREFIX     = ${PREFIX}"
	@echo "BINDIR     = ${BINDIR}"
	@echo "SYSCONFDIR = ${SYSCONFDIR}"
	@echo "DOCDIR     = ${DOCDIR}"
	@echo "MANDIR     = ${MANDIR}"
	@echo

$(BINS): $(SRCS)
	@mkdir -p ${BUILDDIR}
	@echo translating paths in bash scripts: $(@:${BUILDDIR}/%=%)
	@sed -e "s%#!/bin/bash%#!${BASH}%" \
		-e "s%/etc/pitrery%${SYSCONFDIR}%" $(@:${BUILDDIR}/%=%) > $@

$(MANPAGES): $(SRCMANPAGES)
	@mkdir -p ${BUILDDIR}
	@echo translating paths in manual pages: $(@:${BUILDDIR}/%=%)
	@sed -e "s%/etc/pitrery%${SYSCONFDIR}%" $(@:${BUILDDIR}/%=%) > $@

clean:
	@echo cleaning
	@-rm -f $(BINS) $(MANPAGES)
	@-rmdir ${BUILDDIR}

install: all
	@echo installing executable files to ${DESTDIR}${BINDIR}
	@mkdir -p ${DESTDIR}${BINDIR}
	@cp -f $(BINS) ${DESTDIR}${BINDIR}
	@chmod 755 $(addprefix ${DESTDIR}${BINDIR}/, $(BINS:${BUILDDIR}/%=%))
	@echo create symlinks to ${DESTDIR}${BINDIR}
	@ln -s -f archive_wal ${DESTDIR}${BINDIR}/archive_xlog
	@ln -s -f restore_wal ${DESTDIR}${BINDIR}/restore_xlog
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
	@rm $(addprefix ${DESTDIR}${BINDIR}/, $(BINS:${BUILDDIR}/%=%))
	@echo removing docs from ${DESTDIR}${DOCDIR}
	@rm -f $(addprefix ${DESTDIR}${DOCDIR}/, $(CONFS))
	@rm -f $(addprefix ${DESTDIR}${DOCDIR}/, $(DOCS))
	@-rmdir ${DESTDIR}${DOCDIR}
	@echo removing man pages from ${DESTDIR}${MANDIR}
	@rm $(addprefix ${DESTDIR}${MANDIR}/man1/, $(MANPAGES:${BUILDDIR}/%=%))

.PHONY: all checkversion dist distsign disttag options clean install uninstall
