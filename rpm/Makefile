include ../config.mk
YUM_LABS?=../../yum-labs/

default: build

speccheck:
	grep -Eq "Version: +$(VERSION)" pitrery.spec
	grep -Eq "> - $(VERSION)-[1-9]" pitrery.spec

build: speccheck
	$(MAKE) -C $(YUM_LABS) clean
	docker-compose run --rm centos7
	mkdir -p $(YUM_LABS)/rpms/CentOS7-x86_64
	cp -fl $$(readlink -e last-build.rpm) $(YUM_LABS)/rpms/CentOS7-x86_64/

push:
	@make -C $(YUM_LABS) push createrepos clean
