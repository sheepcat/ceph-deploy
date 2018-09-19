#!/bin/bash

# add osd to ceph from all free disks

f2fs_conf_dir="/opt/ceph/f2fs/conf"
disk_dir="/dev/disk/by-id"
add_osd_log_file="/var/log/deploy_ceph.log"

echo "paramnumber:$#"
if [ $# -ne 1 ]; then
        echo "./serail_mount.sh indexnumber[1]."
        exit 1
fi

index=$1
total_num=$(cat /opt/ceph/f2fs/conf/osddisk | wc -l)
if [ "$index" -gt "$total_num" ] || [ "$index" -le 0 ]; then
        echo "input index error:(index)$index > (total)$total_num || (index)$index <= (total)$total_num"
        exit 0
fi

# find free disk add prepare f2fs conf files
mount_osd()
{
	#expand_disks=$(sed -n "$index,\$p" /opt/ceph/f2fs/conf/osddisk)
	#for line in $expand_disks
	cur_index=0
	while read line
	do
		((cur_index++))
		if [ "$cur_index" -lt "$index" ]; then
			continue
		fi
		osd=$(echo $line |awk '{print $1}')
		is_mounted=$(df -h|grep $osd)
		if [ -n "$is_mounted" ]; then
			echo "disk[$osd] is mounted"
			continue
		fi
		echo "[$line] -- to mount"
		mount -t f2fs $disk_dir/$osd -o f2fsconfig=$f2fs_conf_dir/f2fs-$osd.conf /Ceph/Data/Osd/osd-$osd
		if [[ 0 -ne $? ]]; then
			date=`date "+%Y-%m-%d %H:%M:%S"`
			echo "$date: mount f2fs on $osd failed" >> $add_osd_log_file
			sed -i /$osd/d $f2fs_conf_dir/osddisk
			sed -i /$osd/d $f2fs_conf_dir/osddisk-vg
			continue
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

