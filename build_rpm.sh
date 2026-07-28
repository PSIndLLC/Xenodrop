#!/bin/sh
#mkdir -p ~/rpm/{BUILD,SOURCES,SRPMS,SPECS,tmp}
#mkdir ~/rpm/RPMS/{i386,i586,i686,noarch}

mkdir -p ~/development/rpm/SOURCES
tar -czvf ~/development/rpm/SOURCES/xenodrop.tgz ipset.service ipset.sh xenodrop-config xenodrop.service xenodrop.sh xenodrop.spec
rpmbuild -ba xenodrop.spec
