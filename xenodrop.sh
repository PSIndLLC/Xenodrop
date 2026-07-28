#!/bin/bash
#
# Xenodrop  Add country blocking rules to iptables firewall or firewalld drop
# zone
#
# chkconfig: 2345 09 91
# description:	Maintains country blocking rules in iptables firewall & firewalld
# drop zone
#
# config: /etc/sysconfig/xenodrop
#
# See http://blog.psind.com/solutions/products/xenodrop/ for detailed
# information
#
# Origin from http://www.cyberciti.biz/faq/block-entier-country-using-iptables
# Modified by David Picard of PSInd, LLC - dpicard [a-t] psind [d-ot] com - to
# include ability to cache the address list, create chains by subnet thus 
# optimizing rule execution, clean up the rules without wiping the existing 
# tables, include port overrides to allow traffic deemed 'safe', and leverage 
# iptables-restore to optimize rules loading. Introduce firewalld management

# Source function library.
[ -f /etc/init.d/functions ] && . /etc/init.d/functions
[ -f /lib/lsb/init-functions ] && . /lib/lsb/init-functions

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

IPTSYSCONFDIR="/etc/iptables"
[ ! -d ${IPTSYSCONFDIR} ] && IPTSYSCONFDIR="/etc/sysconfig"
XENODROPIPSETS="${IPTSYSCONFDIR}/ipsets.xenodrop"
XENODROPIPTBLS="${IPTSYSCONFDIR}/iptables.xenodrop"
XENODROPDEV=`ip route show | grep default | cut -f 5 -d ' '`
ALLOWPORTS=80,443
ALLOWSUBNET=192.168.0.0/255.255.0.0
MAXZONEAGE=30
XENODROP_VERBOSE="no"
XENODROP_STATUS_NUMERIC="yes"
XENODROP_STATUS_VERBOSE="yes"
XENODROP_STATUS_LINENUMBERS="yes"
#XENODROP_LOGUNIT=xenodrop

### Set PATH ###
IPT=/sbin/iptables
WGET=/usr/bin/wget
GREP=/bin/grep\ -E
IPSET=`whereis -b ipset | cut -f 2 -d ' '`
XENODROP_CONFIG=${IPTSYSCONFDIR}/xenodrop
 
### No editing below ###
PROGNAME=`basename $0`
CBLIST="countrydrop"
XENODROPLOG=/var/log/xenodrop.log
TMPIPSETS=`mktemp`
TMPIPTBLS=`mktemp`
TMPIPTRULES=`mktemp`
XENOROOT="/var/xenodrop"
# Identify directory to hold cache of country files for CIDRs
XENOCACHE="/var/cache/xenodrop"
 
# Load country blocking firewall configuration.
[ -f "$XENODROP_CONFIG" ] && . "$XENODROP_CONFIG"

# Ensure existance of zone cache directory
[ ! -d "${XENOCACHE}" ] && mkdir -p "${XENOCACHE}"


cleanFirewalldGeoDrops(){
    # Remove unconfigured geo ipsets from "drop" zone
    _zsrcs=`firewall-cmd --permanent --zone=drop --list-sources`
    for s in $_zsrcs ; do
	printf "Remove %s from drop zone and delete ipset\n" "${s}"
	firewall-cmd -q --zone=drop --remove-source=${s}
	firewall-cmd -q --permanent --zone=drop --remove-source=${s}
	firewall-cmd -q --permanent --delete-ipset=${s}
    done
    firewall-cmd --reload
}

cleanOldRules(){
    $IPT -L $CBLIST > /dev/null 2>&1
    if [ $? = 0 ] ; then
	$IPT -D INPUT ${XENODROPDEV:+-i }${XENODROPDEV} -j $CBLIST
	$IPT -D FORWARD ${XENODROPDEV:+-i }${XENODROPDEV} -j $CBLIST
	$IPT -D OUTPUT ${XENODROPDEV:+-o }${XENODROPDEV} -j $CBLIST
	$IPT -F $CBLIST
	$IPT -X $CBLIST
    fi

    for i  in `$IPT -L -n | grep Chain | cut -f 2 -d ' ' | grep "\-$CBLIST"`
    do
	$IPT -F ${i}
	$IPT -X ${i}
    done

    if [ -z "${IPSET}" ] ; then
	for t in `$IPSET list -terse | grep Name | cut -f 2 -d ' ' | grep _cbnet`
	do
            $IPSET flush ${t}
            $IPSET destroy ${t}
	done
    fi

    if [ -d /etc/firewalld/ipsets ] ; then
	cleanFirewalldGeoDrops
    fi
}

downloadIPDenyZoneData() {
    # IPDeny zone files are simple lists of CIDR records requiring no transformation
    pushd ${XENOCACHE} 
    for c in $ISO ; do
	ZONEFILE=${c}.zone
	if [ ! -f ${ZONEFILE} ] ; then
            printf "Downloading %s IPDeny data from %s\n" ${c} ${IPDENYDLROOT}
 	    if [  "${IPDENYZONETYPE}" = "aggregated" ] ; then
		$WGET -O $XENOCACHE/$c.zone $IPDENYDLROOT/${c}-aggregated.zone
	    else
		$WGET -O $XENOCACHE/$c.zone $IPDENYDLROOT/$c.zone
	    fi
	else
            printf "Using cached zone data for %s from %s\n" ${c} ${XENOCACHE}/${ZONEFILE}
	fi
    done
    popd
}

downloadGeoliteZoneData() {
    # Geolite zone data is represented in CSV files and must be translated into CIDR lists
    WGET=/usr/bin/wget
    TDT=`date "+%Y%m%d"`
    DL_DATAFILE=GeoLite2-Country-CSV.zip
    # DATADL_DIR is path to hold raw download data pending transformation
    DATADL_DIR=${XENOCACHE}/dl
    BKDIR=${XENOROOT}/arch/${TDT}
    [ ! -d ${DATADL_DIR} ] && mkdir -p ${DATADL_DIR}

    # Download data if source file is not present
    pushd ${DATADL_DIR}
    # Backup data file to backup dir if not yet moved - no overwrite
    if  [ -f ${DL_DATAFILE} ] ; then
	if [ ! -f ${BKDIR}/${DL_DATAFILE} ] ; then
	    mv ${DL_DATAFILE} ${BKDIR}/
	else rm -f ${DL_DATAFILE} ; fi
    fi
    printf "Downloading IP data from: %s\n" ${GEOLITEDLROOT}/${DL_DATAFILE}
    $WGET ${GEOLITEDLROOT}/${DL_DATAFILE}
    popd

    pushd ${XENOCACHE} 

    rm -f GeoLite2-Country-Locations.csv GeoLite2-Country-Blocks.csv
    unzip -ju ${DATADL_DIR}/${DL_DATAFILE} */GeoLite2-Country-Locations.csv */GeoLite2-Country-Blocks.csv

    export IFS="," 

    # Save data as IP ranges in geo code files
    printf "Transforming GeoIP data to country files\n"
    while read GEO_IP IP_MASK_LEN IP_RG_CD IP_CN_CD IP_LINE ; do
	declare -i CIDR=$((32-(128-${IP_MASK_LEN})))
	if [ ${CIDR} -lt 0 ] ; then
	    printf "IPv6 support not provided: %s/%s\n" ${GEO_IP} ${IP_MASK_LEN} >&2
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
		printf "Could not identify IP ranges for country %s : %s\n" "${CN_NAME}" "${CN_CD}" >&2
		rm ${CN_CD}.zone
            fi
	fi
    done < "GeoLite2-Country-Locations.csv" 
    unset IFS

    printf "Removing unmatched geo zone files:\n"
    ugz_count=`find . -maxdepth 1 -mindepth 1 -name \*.geo.zone -print | wc -l`
    [ $ugz_count -gt 0 ] && rm -f *.geo.zone

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
    XENOARCH=${XENOROOT}/arch/${TDT}
    mkdir -p ${XENOARCH}

    # Remove stale cached downloaded zone files
    find ${XENOCACHE} -maxdepth 1 -mindepth 1 -name \*.zone -type f -ctime +${MAXZONEAGE} -exec rm -f {} \;
    # Archive stale zone files in XENOROOT directory
    printf "Moving outdated zone files from %s to %s\n" ${XENOROOT} ${XENOARCH}
    find ${XENOROOT} -maxdepth 1 -mindepth 1 -name \*.zone -type f -ctime +${MAXZONEAGE} -exec mv {} ${XENOARCH} \;

    # Download missing zones to cache
    downloadZoneData

    # Add s "custom" country code to hold customizations
    ISO=${ISO}\ custom

    # Archive zones removed from block list 
    oldzones=`find ${XENOROOT} -mindepth 1 -maxdepth 1 -name \*.zone -type f -exec basename {} \; | cut -f 1 -d '.'`
    for z in $oldzones ; do
	if [[ ! "$ISO" =~ ${z} ]] ; then
	    printf "Archiving unblocked zone: %s\n" ${z}
	    mv ${XENOROOT}/${z}.zone ${XENOARCH}
	fi
    done

    od_count=0
    for c in $ISO ; do
	cf=${XENOCACHE}/${c}.zone
	zf=${XENOROOT}/${c}.zone
	if [[ -f "${cf}" ]] ; then
	    if [[ ! -f "${zf}" || "${cf}" -nt "${zf}" ]] ; then
		# Copy from local cache of CIDR files by country if present
		printf "Updating zone file %s from download cache\n" "${zf}"
		cp "${cf}" "${zf}" && od_count=$(($od_count + 1))
	    fi
	fi
    done

    # Determine if CB Load file is outdated
    CBL_REGEN=0
    if [[ -z "$IPSET" ]] ; then
	CBL_REGEN=`find $XENODROPIPTBLS -maxdepth 0 -mindepth 0 -type f -ctime +$MAXZONEAGE -print | wc -l`
    else
	CBL_REGEN=`find $XENODROPIPSETS -maxdepth 0 -mindepth 0 -type f -ctime +$MAXZONEAGE -print | wc -l`
    fi
    
    # Return count of archived or regenerated zones
    return $((od_count + CBL_REGEN))
}

reuseIPTLoadFile() {
    cp -a ${XENODROPIPSETS} ${TMPIPSETS}
    cp -a ${XENODROPIPTBLS} ${TMPIPTBLS}
    printf "Skipping country block file generation - using old file\n" >&2
}

addCountryIPRanges() {
    c=${1}

    # local zone file
    tDB=$XENOROOT/$c.zone
	
    # country specific log message
    SPAMDROPMSG="iptables: ${c}-Country-Drop: "
	
    # Create drop chain for identified packets
    CBLISTDROP=${c}-${CBLIST}-DROP
    printf ":${CBLISTDROP} - [0:0]\n" >> ${TMPIPTBLS}
    printf "%s ${CBLISTDROP} -j LOG --log-prefix \"$SPAMDROPMSG\"\n" "-A" >> ${TMPIPTRULES}
    printf "%s ${CBLISTDROP} -j DROP\n" "-A" >> ${TMPIPTRULES}
    
    # Load IP ranges from zone file into chains correlating to first octet
    while IFS= read -r line || [[ -n "$line" ]]; do
	# Remove everything after the first #
	ipbloack="${line%%#*}"
	
	# Trim whitespace and skip if the result is empty or begins with a $
	ipblock=$(echo "$ipblock" | xargs)
	[[ -z "$ipblock" ]] && continue
	
        topip=`echo $ipblock | cut -f 1 -d '.'`
        chainExists=`grep -c :${topip}-${CBLIST} ${TMPIPTBLS}`
        if [ $chainExists = 0 ] ; then
            printf "Creating chain for octet %s\n" ${topip} >&5
	    printf ":$topip-$CBLIST - [0:0]\n" >> ${TMPIPTBLS}
	    sip=${topip}.0.0.0/8
	    printf "%s $CBLIST -s ${sip} -j $topip-$CBLIST\n" "-A" >> ${TMPIPTRULES}
	fi
	printf "  Adding rule for %s to chain for octet %s\n" ${ipblock} ${topip} >&5
	printf "%s $topip-$CBLIST -s $ipblock -j ${CBLISTDROP}\n" "-A" >> ${TMPIPTRULES}
    done < "$tDB"
}

genCountryIPSet() {
    c=${1}
    _ipset_file=${2}
    countryset=geo_${c}

    # local zone file
    tDB=$XENOROOT/$c.zone
    [ ! -f ${tDB} ] && printf "Skipping drop on country %s - zone file %s not found\n" ${c} ${tDB} >&2 && return

    _ipset_dt=`stat -c '%y' ${_ipset_file}`
    [ $tDB -nt $_ipset_file ] && _ipset_dt=`stat -c '%y' $tDB`
    netCount=`wc -l ${tDB} | cut -f 1 -d ' '`
    
    # Create ipset for country network segments
    hashTblCnt=$((${netCount}*13/10))
    printf "create %s hash:net family inet hashsize %s maxelem 65536\n" ${countryset} ${hashTblCnt} >> ${_ipset_file}
    
    # Load IP ranges from zone file into chains correlating to first octet
    while IFS= read -r line || [[ -n "$line" ]]; do
	# Remove everything after the first #
	ipblock="${line%%#*}"
	
	# Trim whitespace and skip if the result is empty or begins with a $
	ipblock=$(echo "$ipblock" | xargs)
	[[ -z "$ipblock" ]] && continue
	
	printf "  Adding net %s to ipset %s\n" ${ipblock} ${countryset} >&5
        printf "add %s %s\n" ${countryset} ${ipblock} >> ${_ipset_file}
    done < "$tDB"
    touch --date="${_ipset_dt}" ${_ipset_file}
    printf "%s" "${countryset}"
}

addCountryIPSet() {
    c=${1}
    _cset=`genCountryIPSet ${c} ${TMPIPSETS}`

    # country specific log message
    SPAMDROPMSG="iptables: ${c}-Country-Drop: "
    
    # Create drop chain for identified packets
    CBLISTDROP=${c}-${CBLIST}-DROP
    printf ":${CBLISTDROP} - [0:0]\n" >> ${TMPIPTBLS}
    printf "%s ${CBLISTDROP} -j LOG --log-prefix \"$SPAMDROPMSG\"\n" "-A" >> ${TMPIPTRULES}
    printf "%s ${CBLISTDROP} -j DROP\n" "-A" >> ${TMPIPTRULES}

    # Create iptables filter on country set
    printf "Adding drop chain %s for country %s\n" ${CBLISTDROP} ${c}
    printf "%s $CBLIST -m set --match-set ${_cset} src -j ${CBLISTDROP}\n" "-A" >> ${TMPIPTRULES}
}

generateIPTLoadFile() {
    if [ -z "${IPSET}" ] ; then
        printf "Generating load file using verbose chains for rules"
    else
        printf "Generating load file using ipset for rules"
    fi

    printf "# Generated by %s on %s %s %s %s %s %s %s\n*filter\n" $0 `date` > ${TMPIPTBLS}
    # Create CBLIST chain
    printf ":$CBLIST - [0:0]\n" >> ${TMPIPTBLS}
    printf "%s INPUT ${XENODROPDEV:+-i }${XENODROPDEV} -j $CBLIST\n" "-I" > ${TMPIPTRULES}
    printf "%s OUTPUT ${XENODROPDEV:+-o }${XENODROPDEV} -j $CBLIST\n" "-I"  >> ${TMPIPTRULES}
    printf "%s FORWARD ${XENODROPDEV:+-i }${XENODROPDEV} -j $CBLIST\n" "-I" >> ${TMPIPTRULES}

    printf "%s $CBLIST -m state --state RELATED,ESTABLISHED -j ACCEPT\n" "-I">> ${TMPIPTRULES}
    if [ -z "${ALLOWPORTS}" ] ; then
	printf "Blocking all traffic from country - no ports allowed\n"
    else
	printf "%s $CBLIST -p tcp -m multiport --dports ${ALLOWPORTS} -j RETURN\n" "-I">> ${TMPIPTRULES}
    fi

    if [ -z "${ALLOWSUBNET}" ] ; then
	printf "Blocking all traffic from country - no subnets excluded\n"
    else
	printf "%s $CBLIST -s ${ALLOWSUBNET} -j RETURN\n" "-I">> ${TMPIPTRULES}
    fi

    [ ! -z "${IPSET}" ] && printf "# ipsets for country blocking rules\n" > ${TMPIPSETS}

    for c in $ISO ; do
	printf "Blocking country %s in iptables country block rules\n" "$c"
	if [ -z "${IPSET}" ] ; then
	    addCountryIPRanges $c
	else
	    addCountryIPSet $c
	fi
    done
    mv -f ${TMPIPSETS} $XENODROPIPSETS
    cat ${TMPIPTRULES} >> ${TMPIPTBLS} && rm -f ${TMPIPTRULES}
    printf "COMMIT\n# Completed on %s %s %s %s %s %s %s\n" `date` >> ${TMPIPTBLS}

    TDT=`date "+%Y%m%d"`
    [ ! -f ${XENODROPIPTBLS}.${TDT}.bak ] && mv ${XENODROPIPTBLS} ${XENODROPIPTBLS}.${TDT}.bak
    mv ${TMPIPTBLS} ${XENODROPIPTBLS}

    NUM=
    [[ "$XENODROP_STATUS_NUMERIC" == "yes" ]] && NUM="-n"
    VERBOSE= 
    [[ "$XENODROP_STATUS_VERBOSE" == "yes" ]] && VERBOSE="--verbose"
    COUNT=
    [[ "$XENODROP_STATUS_LINENUMBERS" == "yes" ]] && COUNT="--line-numbers"

    for table in "filter" ; do
	echo $"Table: $table"
	$IPT -t $table --list $CBLIST $NUM $VERBOSE $COUNT
    done

    return 0
}

loadTables() {
    reuseIPTLoadFile
    generateIPTLoadFile
    [ ! "Z${IPSET}" = "Z" ] && $IPSET restore -f ${XENODROPIPSETS}
    ${IPT}-restore -n ${XENODROPIPTBLS}
    printf "Country block instituted for: %s\n" "$ISO"
}

ipsetToFirewalldXML() {
    _ipset_file=${1}
    _xml_dir=${2}
    _xml_file=
    _setname=
    _settype=
    _hashsz=
    _maxel=
    _setentry=

    [ ! -d $_xml_dir ] && mkdir -p $_xml_dir
    printf "Translating ipset definitions %s to firewalld ipset xml in %s\n" "${_ipset_file}" "$_xml_dir"
    while IFS= read -r _ln ; do
	_lntype=`echo $_ln | cut -f 1 -d ' '`
	_wtype=
	for _w in $_ln ; do
	    [[ "$_wtype" == "create" ]] && _setname=$_w
	    [[ "$_wtype" == "hashsize" ]] && _hashsz=$_w
	    [[ "$_wtype" == "maxelem" ]] && _maxel=$_w
	    if [[ "$_wtype" =~ geo_.* ]] ; then
		[[ "$_lntype" == "create" ]] && _settype=$_w
		[[ "$_lntype" == "add" ]] && _setentry=$_w
	    fi
	    _wtype=$_w
	done
	if [[ "$_lntype" == "create" ]] ; then
	    [ ! -z "$_xml_file" ] && printf "</ipset>\n" >> ${_xml_file}
	    _xml_file=${_xml_dir}/${_setname}.xml
	    printf "<?xml version='1.0' encoding='utf-8'?>\n<ipset type='%s'>\n  <option name='hashsize' value='%s'/>\n  <option name='maxelem' value='%s'/>\n  <short>%s</short>\n  <description>%s</description>\n" "${_settype}" "${_hashsz}" "${_maxel}" "${_setname}" "Xenodrop list of country IP ranges" > ${_xml_file}
	    printf "...creating firewalld ipset xml config %s\n" "${_xml_file}"
	fi
	[ "$_lntype" == "add" ] && printf "  <entry>%s</entry>\n" "${_setentry}" >> ${_xml_file}
    done < "${_ipset_file}"
    [ ! -z "$_xml_file" ] && printf "</ipset>\n" >> ${_xml_file}
}

firewalldDropZone() {
    # Import ipsets for countries to firewalld
    for c in $ISO ; do
	printf "Add country %s IP ranges to linux ipset definition\n" "$c"
	_cset=`genCountryIPSet ${c} ${TMPIPSETS}`
    done
    if [ ${TMPIPSETS} -nt ${XENODROPIPSETS} ] ; then
	mv ${TMPIPSETS} ${XENODROPIPSETS}
    else
	printf "Zone cache predates last Linux ipsets generation\n"
    fi
    ipsetToFirewalldXML ${XENODROPIPSETS} /etc/firewalld/ipsets
    /usr/bin/restorecon -R /etc/firewalld
    firewall-cmd --reload

    # Apply defined subnet exceptions to drop zone

    # Apply defined port exceptions to drop zone

    # Identify currently bound geo sets in drop zone
    _zsrcs=`firewall-cmd --zone=drop --list-sources | sed -e 's/ipset:geo_//'`

    # Apply country ipsets to drop zone
    for c in $ISO ; do
	# Skip addition if ipset XML is missing or ipset is already bound
	[[ ! -f /etc/firewalld/ipsets/geo_${c}.xml ]] || [[ "$_zsrcs" =~ ${c} ]] && continue
	firewall-cmd -q --zone=drop --add-source=ipset:geo_${c}
	[ $? -eq 0 ] && printf "Activate ipset drop of geo_%s via firewalld\n" "$c"
	firewall-cmd -q --permanent --zone=drop --add-source=ipset:geo_${c}
    done

    # Remove unconfigured geo ipsets from "drop" zone
    for _cn in $_zsrcs ; do
	if [[ ! "$ISO" =~ ${_cn} ]] ; then
	    firewall-cmd -q --zone=drop --remove-source=ipset:geo_${_cn}
	    [ $? -eq 0 ] && printf "Removed ipset geo_%s from firewalld drop zone\n" "${_cn}"
	    firewall-cmd -q --permanent --zone=drop --remove-source=ipset:geo_${_cn}
	fi
    done
}

stop() {
    echo -n $"${PROGNAME}: Removing xenodrop firewall rules: "

    # clean old rules
    cleanOldRules

    if [ $? -eq 0 ]; then
	success; echo
    else
	failure; echo; return 1
    fi
}

start() {
    echo -n $"${PROGNAME}: Applying xenodrop firewall rules: "
    
    # create a dir
    [ ! -d $XENOROOT ] && /bin/mkdir -p $XENOROOT
 
    # update zone files as needed
    updateZoneFiles

    if [ -d /etc/firewalld/ipsets ] ; then
	# add country set to firewalld drop zone
	firewalldDropZone
    else
	# Add a new iptables list
	loadTables
    fi


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

if [[ ! -z $XENODROP_LOGUNIT ]] ; then
    #[ ! "x$XENODROP_VERBOSE" = "xyes" ] && exec 1>/dev/null
    # Redirect stdout / stderr to syslog / journald
    exec 1> >(logger -p info --id=$$ -t ${XENODROP_LOGUNIT}) && exec 2> >(logger -p err --id=$$ -t ${XENODROP_LOGUNIT})
    # Create file descriptor 5 for debug output...
    exec 5> >(logger -p debug --id=$$ -t ${XENODROP_LOGUNIT})
else
    exec 5> /dev/null
fi

case "$1" in
    start)
	[ -f "$VAR_SUBSYS_IPTABLES" ] && exit 0
	start
	RETVAL=$?
	;;
    stop)
	[ "x$XENODROP_SAVE_ON_STOP" = "xyes" ] && save
	stop
	RETVAL=$?
	;;
    force-regenerate)
        export MAXZONEAGE=0
        updateZoneFiles
 	RETVAL=$?
	[ $RETVAL -gt 0 ] && generateIPTLoadFile && RETVAL=$?
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
	echo $"Usage: ${PROGNAME} {start|stop|force-regenerate|restart|force-reload|status}"
	echo "$1 not a supported option"
	RETVAL=2
	;;
esac

exit $RETVAL
