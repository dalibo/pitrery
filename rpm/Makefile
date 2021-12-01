include ../config.mk
YUM_LABS?=../../yum-labs/

default: build

speccheck:
	grep -Eq "Version: +$(VERSION)" pitrery.spec
	grep -Eq "> - $(VERSION)-[1-9]" pitrery.spec

release: speccheck
	$(MAKE) centos7 push-centos7
	$(MAKE) centos8 push-centos8

centos%:
	docker run --rm \
		--volume $${PWD}/..:/src \
		dalibo/buildpack-pkg:$@ \
		/src/rpm/mkrpm
	$(MAKE) -C $(YUM_LABS) clean
	mkdir -p $(YUM_LABS)/rpms/CentOS$*-x86_64
	cp -fl $$(readlink -e pitrery-last.rpm) $(YUM_LABS)/rpms/CentOS$*-x86_64/

push-centos%:
	make -C $(YUM_LABS) push createrepos clean
