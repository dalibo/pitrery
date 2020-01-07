# RPM packaging

pitrery RPM is published on [yum.dalibo.org/labs](https://yum.dalibo.org/labs).
This directory contains required files to build and upload RPM.

- Set version and changelog entry in `pitrery.spec`.
- `make build` generate package.
- `make push` publishes to [yum.dalibo.org.labs](https://yum.dalibo.org/labs).
