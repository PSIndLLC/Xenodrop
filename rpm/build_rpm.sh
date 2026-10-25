#!/bin/sh
#dnf install rpm-build rpmdevtools
rpmdev-setuptree

mkdir xenodrop-1.0 && cp -a ../README.md ../xenodrop-config xenodrop.service ../xenodrop.sh ipset.service ../ipset.sh xenodrop-1.0
tar -czvf ~/rpmbuild/SOURCES/xenodrop.tgz xenodrop-1.0
rm -rf xenodrop-1.0

rpmbuild -ba xenodrop.spec
