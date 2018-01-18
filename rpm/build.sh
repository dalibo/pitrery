#!/bin/bash -eux

SPEC=pitrery.spec
VERSION=${1-${VERSION-$(rpmspec --query --queryformat '%{VERSION}' ${SPEC})}}
yum-builddep -y ${SPEC}
rpmbuild \
    --define "pkgversion ${VERSION}" \
    --undefine _disable_source_fetch \
    -ba ${SPEC}
