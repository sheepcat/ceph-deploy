#!/bin/bash

# add osd to ceph from all free disks

f2fs_conf_dir="/opt/ceph/f2fs/conf"
disk_dir="/dev/disk/by-id"
add_osd_log_file="/var/log/deploy_ceph.log"

# find free disk add prepare f2fs conf files
mount_osd()
{
	while read line
	do
		osd=$(echo $line |awk '{print $1}')
		mount -t f2fs $disk_dir/$osd -o f2fsconfig=$f2fs_conf_dir/f2fs-$osd.conf /Ceph/Data/Osd/osd-$osd
		date=`date "+%Y-%m-%d %H:%M:%S"`
		if [[ 0 -ne $? ]]; then
			echo "$date: mount f2fs on $osd failed" >> $add_osd_log_file
			continue
		else
			echo "$date: mount f2fs on $line success" >> $add_osd_log_file
		fi
	done < $f2fs_conf_dir/osddisk
}

stop_udev()
{
	systemctl stop systemd-udevd-control.socket
	systemctl stop systemd-udevd-kernel.socket
	systemctl stop systemd-udevd.service
}

start_udev()
{
	systemctl start systemd-udevd-control.socket
	systemctl start systemd-udevd-kernel.socket
	systemctl start systemd-udevd.service
}

#add by sxw for avoid super block lock, AB -> BA 20171018
stop_udev
mount_osd
start_udev

#start current server mon
for m in `ls -l /Ceph/Data/Mon/ |grep "^d" |awk '{print $NF}'|grep "^mon.[a-z]$"`; do
	date=`date "+%Y-%m-%d %H:%M:%S"`
	echo "$date start $m" >> $add_osd_log_file
	/etc/init.d/ceph -a -c /etc/ceph/ceph.conf start $m >> $add_osd_log_file
done

#start current server osd
for f in `find /Ceph/Data/Osd/ -maxdepth 2 -type f -name whoami`; do
	id=$(cat $f)
	date=`date "+%Y-%m-%d %H:%M:%S"`
	echo "$date start osd.$id" >> $add_osd_log_file
	/etc/init.d/ceph -a -c /etc/ceph/ceph.conf start osd.$id >> $add_osd_log_file
done

#start current server mds
conffile=/etc/ceph/ceph.conf

tail_pos=$(cat $conffile |wc -l)
mdsinfo=$(grep "^\[" $conffile -n |grep -E "\[mds|\[osd" |grep "\[mds" |sed "/--/d")

ip_list=$(ip a |grep inet |sed '/inet6/d' |awk '{print $2}' |awk -F "[/]" '{print $1}')
hostname=$(hostname)
#echo "[$hostname] [$ip_list]"

find="false"
for line in `echo $mdsinfo`; do
	pos=$(echo $line |awk -F "[:]" '{print $1}')
	mds=$(echo $line |awk -F "[:]" '{print $2}' |sed 's/\[//g' |sed 's/\]//g')

	#echo "pos=[$pos] mds = [$mds]"
	cur_ip=$(sed -n "${pos},${tail_pos}p" $conffile |grep "^host = " |head -n 1 |awk -F "[=]" '{print $2}' |sed 's/ //g')

	#echo "$cur_ip"
	if [ "$cur_ip" = "$hostname" ]; then
		echo "find hostname[$hostname] [$mds]"
		find="true"
	else
		for ip in $ip_list; do
			echo "compare:[$cur_ip]-[$ip]"
			if [ "$cur_ip" = "$ip" ]; then
				echo "find it [$ip] [$mds]"
				find="true"
				break
			fi
		done
	fi
	if [ "$find" = "true" ]; then
		break
	fi
done
if [ "$find" = "true" ] && [ -n "$mds" ]; then
	/etc/init.d/ceph -a -c /etc/ceph/ceph.conf start $mds >> $add_osd_log_file
fi

basepath=$(cd `dirname $0`; pwd)
#sh $basepath/tune.sh
