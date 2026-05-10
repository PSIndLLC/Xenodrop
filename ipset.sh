#!/bin/sh
#
# ipset	Start ipset firewall
#
# chkconfig: 2345 08 92
# description:	Starts, stops and saves ipset firewall
#
# config: /etc/sysconfig/ipset
# config: /etc/sysconfig/ipset-config
#
### BEGIN INIT INFO
# Provides: ipset
# Required-Start:
# Required-Stop:
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: start and stop ipset firewall
# Description: Start, stop and save ipset firewall
### END INIT INFO

# Source function library.
. /etc/init.d/functions

IPSET=ipset
IPSET_DATA=/etc/sysconfig/$IPSET
IPSET_CONFIG=/etc/sysconfig/${IPSET}-config
VAR_SUBSYS_IPSET=/var/lock/subsys/$IPSET

if [ ! -x /usr/sbin/$IPSET ]; then
    echo -n $"${IPSET}: /usr/sbin/$IPSET does not exist."; warning; echo
    exit 5
fi

# Default firewall configuration:
IPSET_SAVE_ON_STOP="no"
IPSET_SAVE_ON_RESTART="no"

# Load firewall configuration.
[ -f "$IPSET_CONFIG" ] && . "$IPSET_CONFIG"

# Get active tables
NF_IPSETS=$(ipset list -terse | grep Name | cut -f 2 -d ' ')


flush_n_delete() {
    # Check if ipsets are configured (has ipsets)
    [ -z "$NF_IPSETS" ] && return 1

    echo -n $"${IPSET}: Flushing ipsets: "
    ret=0
    # For all sets
    for i in $NF_IPSETS; do
        # Flush ipset content.
	$IPSET flush $i;
	let ret+=$?;

        # Delete firewall chains.
	$IPSET destroy $i;
	let ret+=$?;
    done

    [ $ret -eq 0 ] && success || failure
    echo
    return $ret
}

start() {
    # Do not start if there is no config file.
    [ ! -f "$IPSET_DATA" ] && return 6

    echo -n $"${IPSET}: Applying ipsets: "

    $IPSET restore -f $IPSET_DATA
    if [ $? -eq 0 ]; then
	success; echo
    else
	failure; echo; return 1
    fi
    
    touch $VAR_SUBSYS_IPSET
    return $ret
}

stop() {
    flush_n_delete
    
    rm -f $VAR_SUBSYS_IPSET
    return $ret
}

save() {
    # Check if ipsets are configured (has ipsets)
    [ -z "$NF_IPSETS" ] && return 6

    echo -n $"${IPSET}: Saving ipsets to $IPSET_DATA: "

    ret=0
    TMP_FILE=$(/bin/mktemp -q /tmp/$IPSET.XXXXXX) \
	&& chmod 600 "$TMP_FILE" \
	&& $IPSET save -f $TMP_FILE 2>/dev/null \
	&& size=$(stat -c '%s' $TMP_FILE) && [ $size -gt 0 ] \
	|| ret=1
    if [ $ret -eq 0 ]; then
	if [ -e $IPSET_DATA ]; then
	    cp -f $IPSET_DATA $IPSET_DATA.save \
		&& chmod 600 $IPSET_DATA.save \
		|| ret=1
	fi
	if [ $ret -eq 0 ]; then
	    cp -f $TMP_FILE $IPSET_DATA \
		&& chmod 600 $IPSET_DATA \
	        || ret=1
	fi
    fi
    [ $ret -eq 0 ] && success || failure
    echo
    rm -f $TMP_FILE
    return $ret
}

status() {
    if [ ! -f "$VAR_SUBSYS_IPSET" -a -z "$NF_IPSETS" ]; then
	echo $"${IPSET}: IPSets are not enabled."
	return 3
    fi

    # Do not print status if lockfile is missing and ipset modules are not 
    # loaded.

    # Check if ipsets are configured (has ipsets)
    if [ -z "$NF_IPSETS" ]; then
	echo $"${IPSET}: ipsets are not configured. "
	return 3
    fi

    for i in $NF_IPSETS; do
	echo $"ipset: $i"
	$IPSET list $i && echo
    done

    return 0
}

restart() {
    [ "x$IPSET_SAVE_ON_RESTART" = "xyes" ] && save
    stop
    start
}


case "$1" in
    start)
	[ -f "$VAR_SUBSYS_IPSET" ] && exit 0
	start
	RETVAL=$?
	;;
    stop)
	[ "x$IPSET_SAVE_ON_STOP" = "xyes" ] && save
	stop
	RETVAL=$?
	;;
    restart|force-reload)
	restart
	RETVAL=$?
	;;
    condrestart|try-restart)
	[ ! -e "$VAR_SUBSYS_IPSET" ] && exit 0
	restart
	RETVAL=$?
	;;
    status)
	status
	RETVAL=$?
	;;
    save)
	save
	RETVAL=$?
	;;
    *)
	echo $"Usage: ${IPSET} {start|stop|restart|condrestart|status|save}"
	RETVAL=2
	;;
esac

exit $RETVAL
