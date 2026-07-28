#
# Spec file for xenodrop service...
#
# See example spec on xenodrop from 
#      http://mir01.syntis.net/ART/source/xenodrop.spec
#
Summary: An iptables/firewalld add-on to block net traffic by ISO country code
Name: xenodrop
Version: 1.0
Release: 4
License: GPL
Group: System Environment/Base
#Source: http://psind.com/products/xenodrop/xenodrop.tgz
Source0: xenodrop.tgz
URL: http://psind.com/solutions/products/technology-infrastructure/xenodrop/
BuildArch: noarch
BuildRoot: %(mktemp -ud %{_tmppath}/%{name}-%{version}-%{release}-XXXXXX)
BuildRequires: iptables
Conflicts: kernel < 2.4.20
Requires: iptables
Requires(preun): %{_sbindir}/alternatives chkconfig
Requires(post): %{_sbindir}/alternatives chkconfig
Requires(postun): %{_sbindir}/alternatives
Distribution: Fedora Core Linux
Vendor: PSInd, LLC
Packager: David Picard <dpicard@psind.com>


%description
This service downloads CIDR lists for each country and builds the necessary
artifacts to support implementation of rules to drop traffic matching entries
associated with countries as blocked by configuration

The artifacts are implemented in one of three ways:
* iptables entries organized in a tree structure optimized to minimize checks
* iptables rules referencing country ipsets to implement drop rules
* firewallds ipsets bound to the DROP zone in a firewalld configuration

Each mechanism is intended to allow responses to traffic originating in network
to pass through the firewall

%package systemd
Summary: Systemd support for xenodrop
Group: System Environment/Base
Requires: %{name} = %{version}-%{release}
Requires(post): chkconfig
Requires(preun): chkconfig

%description systemd
The xenodrop package contains support to start and stop country blocking
through the systemd service management mechanisms

%prep
%setup

%build


%install
install -d -m 755 %{buildroot}%{_sysconfdir}/sysconfig
install -m 644 iptables.xenodrop %{buildroot}%{_sysconfdir}/sysconfig
install -m 644 xenodrop-config %{buildroot}%{_sysconfdir}/sysconfig
install -d -m 755 %{buildroot}%{_sysconfdir}/rc.d/init.d
install -c -m 755 ipset.sh %{buildroot}%{_sysconfdir}/rc.d/init.d/ipset
install -c -m 755 xenodrop.sh %{buildroot}%{_sysconfdir}/rc.d/init.d/xenodrop
# % install systemd
install -d -m 755 %{buildroot}%{_libexecdir}/xenodrop
install -d -m 755 %{buildroot}${_libdir}/systemd/system
install -m 755 ipset.sh %{buildroot}%{_libexecdir}/xenodrop
install -m 755 xenodrop.sh %{buildroot}%{_libexecdir}/xenodrop
install -m 644 ipset.service %{buildroot}${_libdir}/systemd/system
install -m 644 xenodrop.service %{buildroot}${_libdir}/systemd/system

%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root,-)
%doc README
%config(noreplace) %attr(0600,root,root) /etc/sysconfig/xenodrop-config
%attr(0644,root,root) %{_sysconfdir}/sysconfig/iptables.xenodrop
%attr(0755,root,root) %{_sysconfdir}/rc.d/init.d/ipset
%attr(0755,root,root) %{_sysconfdir}/rc.d/init.d/xenodrop

%files systemd
%doc README
%config(noreplace) %attr(0600,root,root) %{_sysconfdir}/sysconfig/xenodrop-config
%attr(0644,root,root) %{_sysconfdir}/sysconfig/iptables.xenodrop
%attr(0755,root,root) ${_libdir}/systemd/system/ipset.service
%attr(0755,root,root) ${_libdir}/systemd/system/xenodrop.service
%attr(0644,root,root) %{_libexecdir}/iptables/ipset.init
%attr(0644,root,root) %{_libexecdir}/iptables/xenodrop.init

%post
/sbin/chkconfig --add xenodrop

%preun
if [ "$1" = 0 ]; then
        /sbin/chkconfig --del xenodrop
fi

%changelog
* Mon Jul 27 2026 David Picard <dpicard@psind.com> 1.0.4-1
- Rebrand to xenodrop
- Introduce configuration of firewalld for Fedora Core Linux
- Modifications to use of country zone file cache usage and maintenance
* Mon Apr 07 2015 David Picard <dpicard@psind.com> 1.0.3-1
- Fix to initialization of cache regeneration variable
- Fix to addCountryIPSet function on saveset initialization
- Modifications to flush in old rule cleanup
- Improve duplicate check performance when building iptable and ipset rules
* Fri Dec 25 2014 David Picard <dpicard@psind.com> 1.0.2-1
- Additional fixes to ipset management
* Fri Dec 25 2014 David Picard <dpicard@psind.com> 1.0.1-1
- Fix to ipset optimizations - now correctly generates and starts ipsets
- Allow auto regeneration of /etc/sysconfig/*.cb files if they are deleted
* Mon Dec  8 2014 David Picard <dpicard@psind.com> 1.0.0-1
- Implemented first RPM based release of iptables-cb package as a noarch
  RPM file.
