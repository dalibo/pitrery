.PHONY: default build
default: build
build: buster

.PHONY: BUSTER
buster:
	docker-compose build $@
	docker-compose run --rm $@
	cd ../dist; grep changes debianfiles | xargs -I % cp % %.orig
	git commit changelog -m "Debianize latest version for $@"

.PHONY: push push-buster push-stretch push-jessie
push: push-buster push-stretch push-jessie
push-%:
	./push $*

.PHONY: reset
reset:
	git checkout -- changelog
