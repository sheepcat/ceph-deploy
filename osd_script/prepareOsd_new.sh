#!/bin/bash

# add osd to ceph from all free disks
TOP_DIR=$(cd $(dirname "$0") && pwd)
source $TOP_DIR/ini-config

MEGACLI="/opt/MegaRAID/storcli/storcli64"
f2fs_conf_dir="/opt/ceph/f2fs/conf"
disk_dir="/dev/disk/by-id" 
dev_dir="/dev"
add_osd_log_file="/var/log/deploy_ceph.log"
base_dir=""

#first disk name --- all disk listed are separated by one space
diskname=$1

if [ -z "$diskname" ]; then 
    echo "diskname is empty"
    exit 1 
fi
shift
if [ ! -d "$f2fs_conf_dir" ]; then
    mkdir -p $f2fs_conf_dir
fi
conf_file=$f2fs_conf_dir/f2fs-$diskname.conf
cp $f2fs_conf_dir/f2fs.conf $conf_file

#add by sxw 20170711 for support nvme on centos7 
base_dir=$disk_dir

#modify meta disk name
#sed -i "s/scsi.*$/$diskname/" $f2fs_conf_dir/f2fs-$diskname.conf
iniset $conf_file meta meta_dev $base_dir/$diskname
#modify data disk number
#disk_cnt=$(echo "$#-1"|bc)
#restore old version
disk_cnt=$#
iniset $conf_file data max_disk_cnt $((disk_cnt+1))
iniset $conf_file data disk_cnt     $disk_cnt

#modify by sxw 20170731
echo "11111111--$base_dir/$diskname"
#Modify meta disk disk_type in f2fs.conf 
shortname=$(ls -l /dev/disk/by-id|grep $diskname|head -n 1|awk -F '->' '{print $2}'|awk -F '/' '{print $3}')
is_nvme=$(ls -l $disk_dir | grep -w $shortname | grep -E 'nvme' | awk '{print $9}')

#tmp_disk=$(ls -l /dev/disk/by-id | grep $diskname|awk -F '->' '{print $2}'|awk -F '/' '{print $3}')

#echo "is_nvme:$is_nvme"
if [ -n "${is_nvme}" ]; then
    disk_type=0
else
    disk=${shortname%%[0-9]*}
    jbod_ssd=$(lsscsi | grep $disk | grep 'SSD')
    if [ -n "${jbod_ssd}" ]; then
        disk_type=1
    else
        host_No=$(lsscsi | grep ${disk} | awk '{print $1}' | sed -n 's/\[\(.*\)\]/\1/p' | awk -F ':' '{print $1}')
        if [ -n ${host_No} ]; then
            target_device_No=$(lsscsi | grep ${disk} | awk '{print $1}' | awk -F ':' '{print $3}')
            if [ -n "${target_device_No}" ]; then
                is_ssd=`${MEGACLI} /c${host_No}/v${target_device_No} show all | egrep '\bSSD\b'`
                if [ -n "$is_ssd" ]; then
                    disk_type=1
                else
                    disk_type=2
                fi
            else
                disk_type=2
            fi
        else
            disk_type=2
        fi
    fi
fi

iniset $conf_file meta disk_type $disk_type 
#modify data disk number
#Modify max_disk_size
max_size=$(lsblk $base_dir/$diskname -b -o SIZE |grep -v "SIZE")
if [ $disk_cnt -gt 0 ]
then
    for disk in "$@"
    do
        size=$(lsblk $base_dir/$disk -b -o SIZE |grep -v "SIZE")
        if [ $size -gt $max_size ]
        then
            max_size=$size
        fi
    done
fi
iniset $conf_file data max_disk_size $max_size

#modify meta disk type and data disk name
disk_dir_convert="\/dev\/disk\/by-id\/"
if [ $disk_cnt -ge 1 ]
then
    start=1
    for disk in $*
    do
        disk_abs_name=$disk_dir_convert$disk
        iniset $conf_file data-disk"$start" ssd_type  1
        iniset $conf_file data-disk"$start" disk_type 2
        iniset $conf_file data-disk"$start" data_dev  $disk_abs_name
        ((start++))
    done
fi

# make mount dir
osddir=/Ceph/Data/Osd/osd-$diskname
if [ ! -d "$osddir" ]; then
	mkdir -p $osddir
fi
# mkfs f2fs on disk
mkfs.f2fs $f2fs_conf_dir/f2fs-$diskname.conf

if [ $? -ne 0 ]; then
    echo "mkfs on $disk failed" >> $add_osd_log_file
    #mkfs failed, remove disk id from osddisk file
    sed -i /$diskname/d $f2fs_conf_dir/osddisk
    sed -i /$diskname/d $f2fs_conf_dir/osddisk-vg
    exit 1
fi

exit 0
