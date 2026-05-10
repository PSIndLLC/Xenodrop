The iptables-cb service suppresses incoming traffic from a given country
by automatically generating and adding rules to the firewall using iptables.
This service requires the presence of iptables for ipv4 and is not currently 
implemented for ipv6.

Country specific network addresses are downloaded from one of several
internet reporitories listing the network CIDRs that apply to each country.
After download, these ranges are added to a tree of rules generated in such
a way as to minimize packet checks by grouping on the first octet in the
CIDR. Country specific log messages are written to the log file for each 
blocked packet as part of the action taken by the generated rules.

Configuration settings may be supplied in the /etc/sysconfig/iptables-cb
file to influence behavior. In general, only the ISO values need be modified

############################################################################

Set the country using the ISO environment variable to list the country
codes that should be blocked from initiating connections:

    ISO="af cn kr"


Limit the filter / iptable to apply to a certain device - important for
systems configured with multiple network interfaces

    IPTCBDEVICE=eth0

Sometimes we need to allow traffic from blocked countries. This is critical
to get driver or software updates if the manufacturer of a networked device
is located in a blocked country

    ALLOWPORTS=80,443

There are two download sources available - the GeoLite website and the IPDeny
website. The IPDeny website had empty zone files at one point so we changed 
the default to GeoLite.

    DLSOURCE="geolite2"


The IPDeny zone listings had some private IP address ranges erroneously 
associated with certain countries. We allow an override to suppress the 
filter for one subnet to work around such data quality issues

    ALLOWSUBNET=192.168.0.0/255.255.0.0

Set the number of days permitted between updates to the zone files. This
reduces network traffic to the sites providing the zone files that seed the
firewall configuration with country based subnets

    MAXZONEAGE=30

Set the IPSET parameter as blank to suppress automatic creation of ipsets
as opposed to creating more verbose firewall rules. As near as we can tell
there is no significant performance gain from using ipset, it seems to be
a syntactic optimization to the firewall to make the rules more intelligible

    IPSET=
