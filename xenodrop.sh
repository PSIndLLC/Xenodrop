#!/bin/bash
#
# iptables-country-block  Add country blocking rules to iptables firewall
#
# chkconfig: 2345 09 91
# description:	Adds and removes country blocking rules to iptables firewall
#
# config: /etc/sysconfig/iptables-cb-config
#
# See http://blog.psind.com/solutions/products/iptables-cb/ for detailed
# information
#
# Origin from http://www.cyberciti.biz/faq/block-entier-country-using-iptables
# Modified by David Picard of PSInd, LLC - dpicard [a-t] psind [d-ot] com - to
# include ability to cache the address list, create chains by subnet thus 
# optimizing rule execution, clean up the rules without wiping the existing 
# tables, include port overrides to allow traffic deemed 'safe', and leverage 
# iptables-restore to optimize rules loading.

# Source function library.
. /etc/init.d/functions

# The following values may be overridden in the config
### Block all traffic from AFGHANISTAN (af), CHINA (CN) and KOREA(kr).
### Use ISO code ###
ISO="af cn kr" 
# DLSOURCE may be either "geolite2" or "ipdeny"
DLSOURCE="ipdeny"
# IPDeny provides straight ranges for the countries (countries) or 
#   aggregated ranges (aggregated)
# Use aggregated IP ranges to reduce generated rule counts
IPDENYZONETYPE="aggregated"
IPDENYDLROOT="http://www.ipdeny.com/ipblocks/data/${IPDENYZONETYPE}"
GEOLITEDLROOT="http://geolite.maxmind.com/download/geoip/database"
IPSETCBRESTORE="/etc/sysconfig/ipsets.cb"
IPTCBRESTORE="/etc/sysconfig/iptables.cb"
IPTCBSETRESTORE="/etc/sysconfig/iptables.set.cb"
IPTCBDEVICE=eth0
ALLOWPORTS=80,443
ALLOWSUBNET=192.168.0.0/255.255.0.0
MAXZONEAGE=30
IPTABLES_VERBOSE="no"
IPTABLES_STATUS_NUMERIC="yes"
IPTABLES_STATUS_VERBOSE="yes"
IPTABLES_STATUS_LINENUMBERS="yes"

### Set PATH ###
IPT=/sbin/iptables
WGET=/usr/bin/wget
EGREP=/bin/egrep
IPSET=`whereis -b ipset | cut -f 2 -d ' '`
IPTABLES_CB_CONFIG=/etc/sysconfig/iptables-cb-config
 
### No editing below ###
IPTABLESCB=`basename $0`
CBLIST="countrydrop"
IPTCBLOG=/var/log/iptables_cb.log
IPSETCBLOAD=`mktemp`
IPTCBLOAD=`mktemp`
IPTCBTMP=`mktemp`
ZONEROOT="/var/iptables"
# Identify directory to hold cache of country files for CIDRs
CNZONECACHE="/var/cache/country_ips"
 
# Load country blocking firewall configuration.
[ -f "$IPTABLES_CB_CONFIG" ] && . "$IPTABLES_CB_CONFIG"

# Ensure existance of zone cache directory
[ ! -d "${CNZONECACHE}" ] && mkdir -p "${CNZONECACHE}"

cleanOldRules(){
    $IPT -L $CBLIST > /dev/null 2>&1
    if [ $? = 0 ] ; then
	$IPT -D INPUT ${IPTCBDEVICE:+-i }${IPTCBDEVICE} -j $CBLIST
	$IPT -D FORWARD ${IPTCBDEVICE:+-i }${IPTCBDEVICE} -j $CBLIST
	$IPT -D OUTPUT ${IPTCBDEVICE:+-o }${IPTCBDEVICE} -j $CBLIST
    fi
    $IPT -F $CBLIST
    $IPT -X $CBLIST

    for i  in `$IPT -L -n | grep Chain | cut -f 2 -d ' ' | grep "\-$CBLIST"`
    do
	$IPT -F ${i}
	$IPT -X ${i}
    done

    if [ ! "Z${IPSET}" = "Z" ] ; then
    for t in `$IPSET list -terse | grep Name | cut -f 2 -d ' ' | grep _cbnet`
    do
        $IPSET flush ${t}
        $IPSET destroy ${t}
    done
    fi
}

downloadIPDenyZoneData() {
    pushd ${CNZONECACHE} 
    for c in $ISO
    do
        printf "Downloading %s IPDeny data from %s\n" ${c} ${IPDENYDLROOT}
 
	if [  "${IPDENYZONETYPE}" = "aggregated" ] ; then
	    $WGET -O $ZONEROOT/$c.zone $IPDENYDLROOT/${c}-aggregated.zone
	else
	    $WGET -O $ZONEROOT/$c.zone $IPDENYDLROOT/$c.zone
	fi
    done
    popd
}

downloadGeoliteZoneData() {
    TDT=`date "+%Y%m%d"`
    BKDIR=${ZONEROOT}/arch/${TDT}

    pushd ${CNZONECACHE} 

    DL_DATAFILE=GeoLite2-Country-CSV.zip
    WGET=/usr/bin/wget

    DATADL_DIR=${ZONEROOT}/dl
    [ ! -d ${DATADL_DIR} ] && mkdir -p ${DATADL_DIR}

    # Backup data file to backup dir if not yet moved - no overwrite
    [ ! -f ${BKDIR}/${DL_DATAFILE} ] && [ -f ${DATADL_DIR}/${DL_DATAFILE} ] && mv ${DATADL_DIR}/${DL_DATAFILE} ${BKDIR}/${DL_DATAFILE}

    # Download data if source file is not present
    pushd ${DATADL_DIR}
    rm -f ${DL_DATAFILE}

    printf "Downloading IP data from: %s\n" ${GEOLITEDLROOT}/${DL_DATAFILE}
     $WGET ${GEOLITEDLROOT}/${DL_DATAFILE}
    popd
    rm -f ${DL_DATAFILE} GeoLite2-Country-Locations.csv GeoLite2-Country-Blocks.csv
    cp ${DATADL_DIR}/${DL_DATAFILE} .
    unzip -ju ${DL_DATAFILE} */GeoLite2-Country-Locations.csv */GeoLite2-Country-Blocks.csv

    export IFS="," 

    # Save data as IP ranges in geo code files
    printf "Transforming GeoIP data to country files\n"
    while read GEO_IP IP_MASK_LEN IP_RG_CD IP_CN_CD IP_LINE ; do
	declare -i CIDR=$((32-(128-${IP_MASK_LEN})))
	if [ ${CIDR} -lt 0 ] ; then
	    printf "IPv6 support not provided: %s/%s\n" ${GEO_IP} ${IP_MASK_LEN}
	else
            printf "%s/%s\n" ${GEO_IP} ${CIDR} | sed -e 's/::ffff://g' >> ${IP_CN_CD}.geo.zone
	fi
    done < "GeoLite2-Country-Blocks.csv"

    # Read each country from the country file - append IP range by geo code
    # to zone file with matching country code and delete geo coded file
    typeset -l -g CN_CD
    while read GEO_ID RG_CD RG_NAME CN_CD CN_NAME CN_LINE; do
	if [ "Z${CN_CD}" != "Z" ] ; then
            printf "# Zone file for country %s : %s\n" "${CN_NAME}" ${CN_CD} > ${CN_CD}.zone
	    cat ${CN_CD}.zone
            if [ -f ${GEO_ID}.geo.zone ] ; then
		cat ${GEO_ID}.geo.zone >> ${CN_CD}.zone
		rm ${GEO_ID}.geo.zone
            else
		printf "Could not identify IP ranges for country %s : %s\n" "${CN_NAME}" "${CN_CD}"
		rm ${CN_CD}.zone
            fi
	fi
    done < "GeoLite2-Country-Locations.csv" 
    unset IFS

    printf "Removing unmatched geo zone files:\n"
    ugz_count=`find . -maxdepth 1 -mindepth 1 -name \*.geo.zone -print | wc -l`
    [ $ugz_count -gt 0 ] &&     rm -f *.geo.zone

    popd
}

downloadZoneData() {
    if [ "${DLSOURCE}" = "ipdeny" ] ; then
	downloadIPDenyZoneData
    else
	downloadGeoliteZoneData
    fi
}

updateZoneFiles() {
    TDT=`date "+%Y%m%d"`
    ZONEARCH=${ZONEROOT}/arch/${TDT}
    mkdir -p ${ZONEARCH}
    # get fresh zone file if it is newer than MAXZONEAGE days
    od_count=`find ${ZONEROOT} -maxdepth 1 -mindepth 1 -name \*.zone -type f -ctime +${MAXZONEAGE} -print | wc -l`
    z_count=`find ${ZONEROOT} -maxdepth 1 -mindepth 1 -name \*.zone -type f -pr\
int | wc -l`
    b_count=`echo $ISO | wc -l`
    ( [ $od_count -gt 0 ] || [ $z_count -lt $b_count ] ) && downloadZoneData

    # Remove outdated zone files
    printf "Moving outdated zone files from %s to %s\n" ${ZONEROOT} ${ZONEARCH}
    find ${ZONEROOT} -maxdepth 1 -mindepth 1 -name \*.zone -type f -ctime +${MAXZONEAGE} -exec mv {} ${ZONEARCH} \;

    od_count=0
    ISO=${ISO}\ custom
    for c in $ISO
    do
	# local zone file
	tDB=$ZONEROOT/$c.zone
	
	if [ -f $tDB ] ; then
	    printf "Zone file %s is new enough - no update required.\n" $tDB >>${IPTCBLOG}
	else
            # Copy from local cache of CIDR files by country
            cp ${CNZONECACHE}/$c.zone $tDB
	fi
	[ $tDB -nt ${IPTCBRESTORE} ] && od_count=$(($od_count + 1))
    done
    oldzones=`find ${ZONEROOT} -mindepth 1 -maxdepth 1 -name \*.zone -type f -exec basename {} \; | cut -f 1 -d '.'`
    # Archive old zones no longer blocked
    printf "Archiving unblocked zones: %s\n" ${oldzones} 
    for z in $oldzones ; do
	archme=${c}
	for c  in $ISO ; do
	    if [ $c = $z ] ; then archme="X"; fi
	done
	if [ $archme = $z ] ; then
	    mv ${archme} ${ZONEARCH}
	else
	    printf "Working from previous zone file for %s\n" ${z} >>${IPTCBLOG}
	fi
    done

    # Determine if CB Load file is outdated
    CBL_REGEN = 0
    if [ "z$IPSET" = "z" ] ; then
	CBL_REGEN = `find $IPTCBRESTORE -maxdepth 0 -mindepth 0 -type f -ctime +$MAXZONEAGE -print | wc -l`
    else
	CBL_REGEN = `find $IPSETCBRESTORE -maxdepth 0 -mindepth 0 -type f -ctime +$MAXZONEAGE -print | wc -l`
    fi
    # If any zones were archived or restore file are aged - regenerate the CB iptable file
    ( [ $od_count -gt 0 ] || [ $CBL_REGEN -lt 1 ] ) && generateIPTLoadFile
}

reuseIPTLoadFile() {
    cp -a ${IPSETTCBRESTORE} ${IPSETCBLOAD}
    cp -a ${IPTCBRESTORE} ${IPTCBLOAD}
    printf "Skipping country block file generation - using old file"  >>${IPTCBLOG}
}

addCountryIPRanges() {
    c=${1}

    # local zone file
    tDB=$ZONEROOT/$c.zone
	
    # country specific log message
    SPAMDROPMSG="iptables: ${c}-Country-Drop: "
	
    # Create drop chain for identified packets
    CBLISTDROP=${c}-${CBLIST}-DROP
    printf ":${CBLISTDROP} - [0:0]\n" >> ${IPTCBLOAD}
    printf "%s ${CBLISTDROP} -j LOG --log-prefix \"$SPAMDROPMSG\"\n" "-A" >> ${IPTCBTMP}
    printf "%s ${CBLISTDROP} -j DROP\n" "-A" >> ${IPTCBTMP}
    
    # Load IP ranges into chains correlating to first octet
    BADIPS=$(egrep -v "^#|^$" $tDB)
    for ipblock in $BADIPS
    do
        topip=`echo $ipblock | cut -f 1 -d '.'`
        chainExists=`grep -c :${topip}-${CBLIST} ${IPTCBLOAD}`
        if [ $chainExists = 0 ] ; then
            printf "Creating chain for octet %s\n" ${topip} >>${IPTCBLOG}
	    printf ":$topip-$CBLIST - [0:0]\n" >> ${IPTCBLOAD}
	    sip=${topip}.0.0.0/8
	    printf "%s $CBLIST -s ${sip} -j $topip-$CBLIST\n" "-A" >> ${IPTCBTMP}
	fi
	printf "  Adding rule for %s to chain for octet %s\n" ${ipblock} ${topip} >>${IPTCBLOG}
	printf "%s $topip-$CBLIST -s $ipblock -j ${CBLISTDROP}\n" "-A" >> ${IPTCBTMP}
    done
}
 
addCountryIPSet() {
    c=${1}
    savesets=

    # local zone file
    tDB=$ZONEROOT/$c.zone
	
    # country specific log message
    SPAMDROPMSG="iptables: ${c}-Country-Drop: "
	
    # Create drop chain for identified packets
    CBLISTDROP=${c}-${CBLIST}-DROP
    printf ":${CBLISTDROP} - [0:0]\n" >> ${IPTCBLOAD}
    printf "%s ${CBLISTDROP} -j LOG --log-prefix \"$SPAMDROPMSG\"\n" "-A" >> ${IPTCBTMP}
    printf "%s ${CBLISTDROP} -j DROP\n" "-A" >> ${IPTCBTMP}
    
    # Load IP ranges into chains correlating to first octet
    BADIPS=$(egrep -v "^#|^$" $tDB)
    for ipblock in $BADIPS
    do
        # Chain on top IP to reduce ipset sizes - set comparison performance 
        #  degrades linearly as set size increases... this improves by 90+%
        topip=`echo $ipblock | cut -f 1 -d '.'`
        cntopipset=${c}_${topip}_cbnet

        chainExists=`grep -c :${topip}-${CBLIST} ${IPTCBLOAD}`
        if [ $chainExists = 0 ] ; then
            printf "Creating chain for octet %s\n" ${topip} >>${IPTCBLOG}
	    printf ":$topip-$CBLIST - [0:0]\n" >> ${IPTCBLOAD}
	    sip=${topip}.0.0.0/8
	    printf "%s $CBLIST -s ${sip} -j $topip-$CBLIST\n" "-A" >> ${IPTCBTMP}
	fi

        # Test existence of ipset...
        SET_COUNT=`grep -c ${cntopipset} ${IPSETCBLOAD}`
        if [ $SET_COUNT -lt 1 ] ; then
            # Create country ipset - append country drop rule using ipset
            printf "create %s hash:net family inet hashsize 1024 maxelem 65536\n" ${cntopipset} >> ${IPSETCBLOAD}
            printf "%s $topip-$CBLIST -m set --match-set ${cntopipset} src -j ${CBLISTDROP}\n" "-A" >> ${IPTCBTMP}
            savesets=${cntopipset} ${savesets}
        fi
	printf "  Adding net %s to ipset %s\n" ${ipblock} ${cntopipset} >>${IPTCBLOG}
        printf "add %s %s\n" ${cntopipset} ${ipblock} >> ${IPSETCBLOAD}
    done
}

generateIPTLoadFile() {
    if [ "Z${IPSET}" = "Z" ] ; then
        printf "Generating load file using verbose chains for rules" >>${IPTCBLOG}
    else
        printf "Generating load file using ipset for rules" >>${IPTCBLOG}
    fi

    printf "# Generated by %s on %s %s %s %s %s %s %s\n*filter\n" $0 `date` > ${IPTCBLOAD}
    # Create CBLIST chain
    printf ":$CBLIST - [0:0]\n" >> ${IPTCBLOAD}
    printf "%s INPUT ${IPTCBDEVICE:+-i }${IPTCBDEVICE} -j $CBLIST\n" "-I" > ${IPTCBTMP}
    printf "%s OUTPUT ${IPTCBDEVICE:+-o }${IPTCBDEVICE} -j $CBLIST\n" "-I"  >> ${IPTCBTMP}
    printf "%s FORWARD ${IPTCBDEVICE:+-i }${IPTCBDEVICE} -j $CBLIST\n" "-I" >> ${IPTCBTMP}

    printf "%s $CBLIST -m state --state RELATED,ESTABLISHED -j ACCEPT\n" "-I">> ${IPTCBTMP}
    if [ "Z${ALLOWPORTS}" = "Z" ] ; then
	printf "Blocking all traffic from country - no ports allowed\n" >>${IPTCBLOG}
    else
	printf "%s $CBLIST -p tcp -m multiport --dports ${ALLOWPORTS} -j RETURN\n" "-I">> ${IPTCBTMP}
    fi

    if [ "Z${ALLOWSUBNET}" = "Z" ] ; then
	printf "Blocking all traffic from country - no subnets excluded\n" >>${IPTCBLOG}
    else
	printf "%s $CBLIST -s ${ALLOWSUBNET} -j RETURN\n" "-I">> ${IPTCBTMP}
    fi

    [ ! "Z${IPSET}" = "Z" ] && printf "# ipsets for country blocking rules\n" > ${IPSETCBLOAD}

    for c in $ISO ; do
	printf "Blocking country %s in iptables country block rules\n" "$c" >>${IPTCBLOG}
	if [ "Z${IPSET}" = "Z" ] ; then
	    addCountryIPRanges $c
	else
	    addCountryIPSet $c
	fi
    done
    mv -f ${IPSETCBLOAD} $IPSETCBRESTORE
    cat ${IPTCBTMP} >> ${IPTCBLOAD}
    printf "COMMIT\n# Completed on %s %s %s %s %s %s %s\n" `date` >> ${IPTCBLOAD}

    TDT=`date "+%Y%m%d"`
    [ ! -f ${IPTCBRESTORE}.${TDT}.bak ] && mv ${IPTCBRESTORE} ${IPTCBRESTORE}.${TDT}.bak
    mv ${IPTCBLOAD} ${IPTCBRESTORE}
    rm -f ${IPTCBTMP}

    NUM=
    [ "x$IPTABLES_STATUS_NUMERIC" = "xyes" ] && NUM="-n"
    VERBOSE= 
    [ "x$IPTABLES_STATUS_VERBOSE" = "xyes" ] && VERBOSE="--verbose"
    COUNT=
    [ "x$IPTABLES_STATUS_LINENUMBERS" = "xyes" ] && COUNT="--line-numbers"

    for table in "filter" ; do
	echo $"Table: $table"
	$IPT -t $table --list $CBLIST $NUM $VERBOSE $COUNT
    done

    return 0
}

loadTables() {
    reuseIPTLoadFile
    generateIPTLoadFile
    [ ! "Z${IPSET}" = "Z" ] && $IPSET restore -f ${IPSETCBRESTORE}
    ${IPT}-restore -n ${IPTCBRESTORE}
    printf "Country block instituted for: %s\n" "$ISO"
}

stop() {
    echo -n $"${IPTABLESCB}: Removing cb firewall rules: "

    # clean old rules
    cleanOldRules

    if [ $? -eq 0 ]; then
	success; echo
    else
	failure; echo; return 1
    fi
}

start() {
    echo -n $"${IPTABLESCB}: Applying cb firewall rules: "

   # create a dir
    [ ! -d $ZONEROOT ] && /bin/mkdir -p $ZONEROOT
 
    # update zone files as needed
    updateZoneFiles

    # create a new iptables list
    loadTables

    if [ $? -eq 0 ]; then
	success; echo
    else
	failure; echo; return 1
    fi
}

restart() {
    stop
    start
}

reset() {
    for c  in $ISO ; do
	iptables -Z ${c}-countrydrop-DROP -L ${c}-countrydrop-DROP -v
    done
}

status() {
    for c  in $ISO ; do
	iptables -L ${c}-countrydrop-DROP -v
    done
}

#[ ! "x$IPTABLES_VERBOSE" = "xyes" ] && exec 1>/dev/null
case "$1" in
    start)
	[ -f "$VAR_SUBSYS_IPTABLES" ] && exit 0
	start
	RETVAL=$?
	;;
    stop)
	[ "x$IPTABLES_SAVE_ON_STOP" = "xyes" ] && save
	stop
	RETVAL=$?
	;;
    force-regenerate)
        export MAXZONEAGE=0
        updateZoneFiles
 	RETVAL=$?
	;;
    restart|force-reload)
	restart
	RETVAL=$?
	;;
    reset-counters)
	reset
	RETVAL=$?
	;;
    status)
	status
	RETVAL=$?
	;;
    *)
	echo $"Usage: ${IPTABLESCB} {start|stop|force-regenerate|restart|force-reload|status}"
	echo "$1 not a supported option"
	RETVAL=2
	;;
esac

exit $RETVAL
