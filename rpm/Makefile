include ../config.mk
YUM_LABS?=../../yum-labs/

default:

speccheck:
	grep -Eq "Version: +$(VERSION)" pitrery.spec
	grep -Eq "> - $(VERSION)-[1-9]" pitrery.spec

release: speccheck
	$(MAKE) rhel7 push-rhel7
	$(MAKE) rhel8 push-rhel8

rhel%:
	docker-compose run --rm $@
	$(MAKE) -C $(YUM_LABS) clean
	mkdir -p $(YUM_LABS)/rpms/RHEL$*-x86_64
	cp -fl $$(readlink -e pitrery-last.rpm) $(YUM_LABS)/rpms/RHEL$*-x86_64/

push-rhel%:
	make -C $(YUM_LABS) push createrepos clean
