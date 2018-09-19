#!/bin/bash
f2fs_conf_dir="/opt/ceph/f2fs/conf"
disk_dir="/dev/disk/by-id"
dev_dir="/dev"
add_osd_log_file="/var/log/deploy_ceph.log"

#obtain ssd and non-ssd hard disk number
MEGACLI="/opt/MegaRAID/storcli/storcli64"

function usage()
{
	leftnum=30
	echo "Usage:"
	printf "      %-${leftnum}s : %-20s\n" "-a|--nvme_default_used" "defualt nvme-group use numbers."
	printf "      %-${leftnum}s : %-20s\n" "-b|--nvme_total_nums" "nvme disk total numbers."
	printf "      %-${leftnum}s : %-20s\n" "-c|--ssd_default_used" "default ssd-group use numbers."
	printf "      %-${leftnum}s : %-20s\n" "-d|--ssd_total_nums" "ssd disk total numbers."
	printf "      %-${leftnum}s : %-20s\n" "-e|--hdd_default_used" "default hdd-group use numbers."
	printf "      %-${leftnum}s : %-20s\n" "-f|--hdd_total_nums" "hdd disk total numbers."
	printf "      %-${leftnum}s : %-20s\n" "-g|--hdd_cache_disk_nums" "hdd cache disk numbers, nvme or ssd support."
	printf "      %-${leftnum}s : %-20s\n" "-t|--hdd_cache_disk_type" "hdd cache disk type [nvme | ssd | none]."
	printf "      %-${leftnum}s : %-20s\n" "-O|--option" "[getdisks | deletepartition | deploy | expand]."
	printf "      %-${leftnum}s : %-20s\n" "-M|--mode" "deploy or expand mode: [auto | manual]."
	printf "      %-${leftnum}s : %-20s\n" "" "getdisks: get all kinds of disks, support for py."
	printf "      %-${leftnum}s : %-20s\n" "" "deletepartition: clear all umounted disk partitions."
	printf "      %-${leftnum}s : %-20s\n" "" "deploy: deploy ceph."
	printf "      %-${leftnum}s : %-20s\n" "" "expand: expand ceph."
	printf "      %-${leftnum}s : %-20s\n" "-N|--add_one_disk" "use api add osd."
	echo ""
	echo "example:"
	echo "   deploy | expand"
	echo "     ./disk_fs_mgmt.sh --mode=manual --option=deploy --hdd_default_used=8 --hdd_total_nums=8 --hdd_cache_disk_type=none"
	echo "     or"
	echo "     ./disk_fs_mgmt.sh -Mmanual -Odeploy -e8 -f8 -tnone"
	echo "   deletepartition"
	echo "     ./disk_fs_mgmt.sh -O deletepartition"
	echo "   getdisks"
	echo "     ./disk_fs_mgmt.sh -O getdisks"
	echo "   getdisks with param -N"
	echo "     ./disk_fs_mgmt.sh -Oexpand -Mauto -N"
	exit 1
}

function env_init()
{
	#check conf dir existence
	if [ ! -d "$f2fs_conf_dir" ]; then
	    mkdir -p $f2fs_conf_dir
	fi
	##check osddis file existence
	if [ ! -f "$f2fs_conf_dir/osddisk" ]; then
	    #echo "osddisk file is not exists, so touch it"
	    touch $f2fs_conf_dir/osddisk
	    touch $f2fs_conf_dir/osddisk-vg
	else
		if [ "$option_action" = "deploy" ]; then
			>$f2fs_conf_dir/osddisk
			>$f2fs_conf_dir/osddisk-vg
		fi
	fi
	#check conf file existence
	if [ ! -f "$f2fs_conf_dir/f2fs.conf" ]; then
		if [ -f "/etc/ceph/scripts/f2fs.conf" ]; then
		    cp /etc/ceph/scripts/f2fs.conf $f2fs_conf_dir
		fi
	fi
}

function parse_param()
{
	leftnum=23
	ARGS="`getopt -u -o "a:b:c:d:e:f:g:t:O:M:Nh" -l "nvme_default_used:,nvme_total_nums:,ssd_default_used:,ssd_total_nums:,hdd_default_used:,hdd_total_nums:,hdd_cache_disk_nums:,hdd_cache_disk_type:,option:,mode:,add_one_disk,help" -- "$@"`"

	[ $? -ne 0 ] && usage
	set -- ${ARGS}

	while [ true ] ; do
		case $1 in
			-a|--nvme_default_used)
				nvme_def_nums=$2
				shift
				;;
			-b|--nvme_total_nums)
				nvme_nums=$2
				shift
				;;
			-c|--ssd_default_used)
				ssd_def_nums=$2
				shift
				;;
			-d|--ssd_total_nums)
				ssd_nums=$2
				shift
				;;
			-e|--hdd_default_used)
				hdd_def_nums=$2
				shift
				;;
			-f|--hdd_total_nums)
				hdd_nums=$2
				shift
				;;
			-g|--hdd_cache_disk_nums)
				hdd_cache_nums=$2
				shift
				;;
			-t|--hdd_cache_disk_type)
				hdd_cache_type=$2
				shift
				;;
			-O|--option)
				option_action=$2
				shift
				;;
			-M|--mode)
				mode=$2
				shift
				;;
			-N|--add_one_disk)
				add_one_disk="true"
				;;
			-h|--help)
				usage
				;;
			--)
				shift
				break
				;;
			*)
				usage
				;;
			esac
			shift
	done
	
	return
}

function param_show()
{
	printf "%${leftnum}s : %-20s\n" nvme_default_used $nvme_def_nums
	printf "%${leftnum}s : %-20s\n" nvme_total_nums $nvme_nums
	printf "%${leftnum}s : %-20s\n" ssd_default_used $ssd_def_nums
	printf "%${leftnum}s : %-20s\n" ssd_total_nums $ssd_nums
	printf "%${leftnum}s : %-20s\n" hdd_default_used $hdd_def_nums
	printf "%${leftnum}s : %-20s\n" hdd_total_nums $hdd_nums
	printf "%${leftnum}s : %-20s\n" hdd_cache_disk_nums $hdd_cache_nums
	printf "%${leftnum}s : %-20s\n" hdd_cache_disk_type $hdd_cache_type
	printf "%${leftnum}s : %-20s\n" option $option_action
	printf "%${leftnum}s : %-20s\n" mode $mode
}

#delete partitions, current only support normal disk part delete
function delete_partition()
{
	disks=`cat /proc/partitions | egrep -w "[s,v]d[a-z]*|nvme[0-9]*n[0-9]" | awk '{print $4}'`
	for disk in $disks; do
		is_nvme=$(echo $disk |grep nvme)
		if [ -n "$is_nvme" ];then
			#is nvme
			is_mounted=$(mount -l| grep "^/dev/${disk}")
			if [ -n "$is_mounted" ]; then
				echo "[$disk] is mounted"
				continue
			fi
		else
			#/dev/sda /dev/sdaa /dev/sdab
			is_mounted=$(mount -l |grep "^/dev/${disk}" |awk '{print $1}' |sed 's/[0-9]*//g' |sort |uniq |grep -w "/dev/${disk}")
			if [ -n "$is_mounted" ]; then
				echo "[$disk] is mounted"
				continue
			fi
		fi

		device_id=$(ls -l $disk_dir | grep -w $disk | grep -E 'scsi-3|scsi-0QEMU|virtio|nvme|ata-' | awk '{print $9}')
		if [ -r ${f2fs_conf_dir}/osddisk ]; then
			is_exist=$(cat ${f2fs_conf_dir}/osddisk | grep ${device_id})
			if [ -n "$is_exist" ]; then
				echo "[$disk][$device_id] device is used by ceph"
				continue
			fi
		fi

		cnt=$(ls $disk_dir | grep -c -- "${device_id}-part")
		if [ ${cnt} -gt 0 ]; then
			#have some partition
			dd if=/dev/zero of=/dev/$disk bs=512 count=1 conv=notrunc 2>/dev/null
			parted /dev/$disk --script mktable gpt

			cnt_after=$(ls $disk_dir | grep -c -- "${device_id}-part")
			if [ ${cnt_after} -eq 0 ]; then
				echo "[$disk][$device_id] delete partition success"
			else
				echo "[$disk][$device_id] delete partition failed"
			fi
		else
			parted /dev/$disk --script mktable gpt
			echo "[$disk][$device_id] no partitioin, success"
		fi
	done
}

#0: not exist 1:exist
function is_exist_in_osddisk()
{
	disk=$1
	is_exist=$(cat ${f2fs_conf_dir}/osddisk | grep -- ${disk})
	if [ -z "$is_exist" ]; then
		return 0
	else
		return 1
	fi
}

#step1: filter lvm disk
function remove_lvm_pv()
{
	current_array=()
	lvm_disk=`pvdisplay |grep -w "PV Name" |awk '{print $NF}' |awk -F "[/]" '{print $NF}' |sed s/[0-9]*$//g |sort -k2n |uniq`
	for lvm in $lvm_disk; do
		if [ -n "$lvm_disk" ]; then
			for disk in ${disk_array[@]}; do
				if [ "${lvm}" == "${disk}" ]; then
					lvm_array=("${lvm_array[@]}" ${disk})
				else
					current_array=("${current_array[@]}" ${disk})
				fi
			done
			unset disk_array
			disk_array=${current_array[@]}
			unset current_array
		fi
	done
	#echo ${disk_array[@]}
}

function get_enl_slot_deviceid()
{
	res=`${MEGACLI} -PDlist -aALL |egrep "Enclosure Device ID:|Slot Number:|Device Id:" |awk -F "[:]" '{print $2}'`

	index=0
	for id in $res
	do
		a=$((index%3))
		if [ $a = 0 ]; then
			#echo "00000000000[$a/$index] $id"
			enlid_array=("${enlid_array[@]}" ${id})
		elif [ $a = 1 ]; then
			#echo "11111111111[$a/$index] $id"
			slot_array=("${slot_array[@]}" ${id})
		elif [ $a = 2 ]; then
			#echo "22222222222[$a/$index] $id"
			deviceid_array=("${deviceid_array[@]}" ${id})
		fi
		#echo $id
		((index++))
	done
}

#get jbod mode disk type
function get_disk_type()
{
	index=0
	hostno=$1
	deviceid=$2
	for id in ${deviceid_array[@]}; do
		if [ "$deviceid" = "$id" ]; then
			#echo "get id:$id, index:$index"
			break
		fi
		((index++))
	done
	disk_len=${#deviceid_array[@]}
	if [ "$index" = "$disk_len" ]; then
		#echo "find device id failed,[$deviceid]"
		return 0
	fi

	#echo "hostno:$hostno, deviceid:$deviceid, snlid:${enlid_array[$index]}, slot:${slot_array[$index]}, index:$index"
	res=`${MEGACLI} /c$hostno/e${enlid_array[$index]}/s${slot_array[$index]} show |grep -w "^${enlid_array[$index]}:${slot_array[$index]}" |grep -w SSD`
	if [ -n "$res" ]; then
		#1 is SSD
		#echo "111---SSD"
		return 1
	else
		#echo "000---HDD"
		return 0
	fi
}

#return 1: disk type is ssd 0: disk type is hdd
function is_disk_ssd()
{
	dev=$1
	#lsblk -d -o name,hctl,rota,type,SERIAL,RQ-SIZE,VENDOR,WWN,TRAN,MODEL
	hctl=$(lsblk -d -o name,hctl |grep -w ${dev} |awk '{print $2}')
	if [ -z "$hctl" ]; then
		return 0
	fi

	fullpci=$(find /sys/devices/ -maxdepth 6 -name $hctl |awk -F "[/]" '{print $6}')
	#pci=0000:04:00.0
	pci=$(echo ${fullpci:2})
	pci_begin=$(echo $pci |awk -F "[.]" '{print $1}')
	pci_end=$(echo $pci |awk -F "[.]" '{print $NF}')
	pci_end_2=$(printf "%02d" $pci_end)
	terminal_pci="${pci_begin}:${pci_end_2}"
	#echo "dev:$dev, $hctl, $terminal_pci"

	getctl_status=$(${MEGACLI} show ctrlcount |grep -w "^Status =" |awk '{print $NF}')
	if [ "$getctl_status" = "Success" ]; then
		getctl_cnt=$(${MEGACLI} show ctrlcount |grep -w "^Controller Count" |awk '{print $NF}')
		if [ $getctl_cnt -gt 0 ]; then
			#ctl cnt > 0
			for ((i=0;i<$getctl_cnt;i++))
			do
				getctl_pciaddr=$(${MEGACLI} /c$i show |grep -w "PCI Address" |awk '{print $NF}')
				if [ "$terminal_pci" = "$getctl_pciaddr" ]; then
					host_no=$i
					#try raid mode get disk type
					target_no=$(echo $hctl |awk -F "[:]" '{print $3}')
					is_success=$(${MEGACLI} /c${host_no}/v${target_no} show |grep -w "^Status =" |awk '{print $NF}')
					is_no_vg=$(${MEGACLI} /c${host_no}/v${target_no} show |grep "No VDs have been configured")
					if [ "$is_success" = "Success" ]; then
						if [ -n "$is_no_vg" ]; then
							#echo "BBB-[$dev][h:$host_no][t:$target_no][pci:$terminal_pci] is not raid mode"
							break
						fi
						is_raid_ssd=$(${MEGACLI} /c${host_no}/v${target_no} show all |grep -w "SSD")
						#echo "AAAA---host_no:$host_no, target_no:$target_no, type:$is_raid_ssd"
						if [ -n "$is_raid_ssd" ]; then
							return 1
						else
							return 0
						fi
					else
						#echo "CCC-[$dev][h:$host_no][t:$target_no][pci:$terminal_pci] is not raid mode"
						break
					fi
				fi
			done
		fi
	fi
	#not find raid controller, use rotational[cat /sys/block/sda/queue/rotational]
	rota=$(cat /sys/block/${dev}/queue/rotational)
	#echo "$dev $rota"
	#rotational result 0: ssd, 1: hdd
	if [ $rota -eq 0 ]; then
		return 1
	elif [ $rota -eq 1 ]; then
		return 0
	fi
}

#step2: filter mounted and have multi partition disk
function mark_disk_type()
{
	#get disk type add by sxw 20180124
	get_enl_slot_deviceid
	current_disk_array=()
	for disk in ${disk_array[@]}; do
		is_nvme=$(echo $disk |grep nvme)
		#echo "CURRENT DEV:[$disk]"
		#is_mounted=$(mount -l| grep -w "^/dev/${disk}")
		if [ -n "$is_nvme" ];then
			#is nvme
			is_mounted=$(mount -l| grep -w "^/dev/${disk}")
			if [ -n "$is_mounted" ]; then
				continue
			fi
		else
			is_mounted=$(mount -l |grep -w "^/dev/${disk}" |awk '{print $1}' |sed 's/[0-9]*//g' |sort |uniq |grep -w "/dev/${disk}")
			if [ -n "$is_mounted" ]; then
				#sxw0922
				#echo "AAA dev: [$disk] is mounted"
				continue
			fi
		fi
		#echo "######$disk"
		if [ -n "$is_nvme" ];then
			#is nvme
			cnt=$(lsblk |grep ${disk}p |wc -l)
			if [ ${cnt} -eq 0 ]; then
				device_id=$(ls -l $disk_dir | grep -w $disk | grep -E 'scsi-3|scsi-0QEMU|virtio|nvme|ata-' | awk '{print $9}')
				if [ -n "${device_id}" ]; then
					#judge if exist in osddisk
					is_exist=$(cat ${f2fs_conf_dir}/osddisk | grep -- ${device_id})
					if [ -z "$is_exist" ]; then
						#no partition
						nvme_array=("${nvme_array[@]}" ${device_id})
						current_disk_array=("${current_disk_array[@]}" ${device_id})
					fi
				fi
			else
				#echo "BBB dev: [$disk] have parted... cnt:$cnt"
				#recored resued partition
				get_reused_partition $disk
			fi
		else
			device_id=$(ls -l $disk_dir | grep -w $disk | grep -E 'scsi-3|scsi-0QEMU|virtio|nvme|ata-' | awk '{print $9}')
			if [ -n "${device_id}" ]; then
				# ignore iscsi device
				is_iscsi_dev=$(echo $device_id |grep "^scsi-360000000000000000e")
				if [ -n "${is_iscsi_dev}" ]; then
					continue
				fi
			fi

			cnt=$(ls $disk_dir | grep -c -- "${device_id}-part")
			if [ ${cnt} -eq 0 ]; then
				if [ -n "${device_id}" ]; then
					#judge if exist in osddisk
					is_exist=$(cat ${f2fs_conf_dir}/osddisk | grep -- ${device_id})
					if [ -z "$is_exist" ]; then
						current_disk_array=("${current_disk_array[@]}" ${device_id})
						#echo "AAAA---$disk"
						is_disk_ssd $disk
						is_ssd=$?
						if [ "$is_ssd" = "1" ]; then
							ssd_array=("${ssd_array[@]}" ${device_id})
						else
							hdd_array=("${hdd_array[@]}" ${device_id})
						fi
					fi
				fi
			else
				#echo "CCC deviceid:[$device_id]-[$disk] cnt:$cnt"
				get_reused_partition $disk
			fi
		fi
	done
	unset disk_array
	disk_array=${current_disk_array[@]}
	unset current_disk_array
}

# find reused partition
# param have multipartition dev
function get_reused_partition()
{
	reuse_disk=$1
	# get partition dev
	tmp_part_array=()
	can_reused=0
	for part in `lsblk -ln /dev/${reuse_disk} -o NAME |sed '/\<${reuse_disk}\>/d'`; do
		#input device name get deviceid
		device_id=$(udevadm info --query=symlink -n $part |awk '{print $1}' |awk -F "[/]" '{print $NF}')
		is_exist=$(cat ${f2fs_conf_dir}/osddisk | grep -w ${device_id})
		#echo "deviceid[$device_id]-diskid:[$reuse_disk]"
		if [ -n "$is_exist" ]; then
			can_reused=1
		else
			is_mounted=$(mount -l| grep -w "^/dev/${part}")
			if [ -z "$is_mounted" ]; then
				#unmounted
				tmp_part_array=("${tmp_part_array[@]}" ${device_id})
			fi
		fi
	done
	#echo "can_reused:$can_reused"
	if [ $can_reused -eq 1 ];then
		for p in ${tmp_part_array[@]}; do
			#echo "reused disk: [$p]"
			reused_cache_array=("${reused_cache_array[@]}" ${p})
		done
	fi
}


# parted
function construct_osddisk()
{
	write_nvme_ssd_disk_to_osddisk
	reused_num=${#reused_cache_array[@]}

	if [ $hdd_def_nums -eq 0 ]; then
		#hdd_nums=0
		if [ $hdd_cache_nums -eq 0 ]; then
			#no cache disk
			return
		else
			#have cache disk but no hdd disk
			only_write_cache_disk_to_osddisk ${hdd_cache_type}
		fi
	elif [ $hdd_def_nums -gt 0 ]; then
		if [ $hdd_cache_nums -eq 0 ] && [ $reused_num -eq 0 ]; then
			#no cache disk
			only_write_hdd_disk_to_osddisk
		elif [ $hdd_cache_nums -gt 0 ] || [ $reused_num -gt 0 ] ; then
			#have cache disk, need to make partitions
			#echo "HDD group have cache disk:$hdd_cache_nums"
			write_meta_cache_disk_to_osddisk
		else
			#ERR param
			echo "ERR param hdd_cache_nums=[$hdd_cache_nums] < 0"
		fi
	else
		echo "disk_parted ERR, hdd_def_nums=$hdd_dev_nums <0"
	fi
}

#get cache disk
function get_cache_disk()
{
	if [ "$hdd_cache_type" = "nvme" ]; then
		cache_array=(${nvme_array[@]:${nvme_def_nums}:${hdd_cache_nums}})
	fi
	if [ "$hdd_cache_type" = "ssd" ]; then
		cache_array=(${ssd_array[@]:${ssd_def_nums}:${hdd_cache_nums}})
	fi
}

#make part
function make_partition()
{
	reused_num=${#reused_cache_array[@]}
	remain_def_num=$(echo "$hdd_def_nums-$reused_num"|bc)
	if [ $remain_def_num -eq 0 ] || [ $hdd_cache_nums -eq 0 ]; then
		return 0
	fi
	#echo "AAAA---$remain_def_num"

	first_step=$(echo "($remain_def_num+$hdd_cache_nums-1)/$hdd_cache_nums"|bc)
	first_cnt=$(echo "$remain_def_num+$hdd_cache_nums-$first_step*$hdd_cache_nums"|bc)
	second_step=$(echo "$first_step-1"|bc)
	second_cnt=$(echo "$hdd_cache_nums-$first_cnt"|bc)
	#echo "first_step:$first_step,first_cnt:$first_cnt,second_step:$second_step,second_cnt:$second_cnt"
	calculate_hdd_def_nums=$(echo "$first_step*$first_cnt+$second_step*$second_cnt"|bc)
	#echo "calculate: $calculate_hdd_def_nums , $remain_def_num"

	#if [ "$hdd_cache_type" = "nvme" ]; then
	#	base_dir=$dev_dir
	#	part="p"
	#elif [ "$hdd_cache_type" = "ssd" ]; then
	#	base_dir=$disk_dir
	#	part="-part"
	#fi

	base_dir=$disk_dir
	part="-part"
	wait=0
	#first
	for disk in ${cache_array[@]:0:${first_cnt}}; do
		parted $base_dir/$disk --script mktable gpt
		total_size=$(lsblk -b $base_dir/$disk|grep -v size|awk '{print $4}' |sed -n '2,2p')
		step_gb=$(echo "$total_size/$first_step/1000/1024/1024"|bc)
		for ((i=0;i<$first_step;i++)); do
			begin=$(echo "$i*$step_gb"|bc)
			end=$(echo "($i+1)*$step_gb"|bc)
			parted $base_dir/$disk --script mkpart primary ext4 "$begin"G "$end"G
			partid=$(echo "$i+1"|bc)
			parted_cache_array=("${parted_cache_array[@]}" ${disk}${part}${partid})
			while [ ! -h $disk_dir/${disk}${part}${partid} -a $wait -lt 120 ];do
				cur_date=`date "+%Y-%m-%d %H:%M:%S"`
				echo "$cur_date [$wait/120]==== wait for $disk_dir/${disk}${part}${partid}  ====" >> $add_osd_log_file
				sleep 1
				let wait++
			done
		done
	done
	
	wait=0
	#second
	for disk in ${cache_array[@]:${first_cnt}:${second_cnt}}; do
		parted $base_dir/$disk --script mktable gpt
		total_size=$(lsblk -b $base_dir/$disk|grep -v size|awk '{print $4}' |sed -n '2,2p')
		step_gb=$(echo "$total_size/$second_step/1000/1024/1024"|bc)
		for ((i=0;i<$second_step;i++)); do
			begin=$(echo "$i*$step_gb"|bc)
			end=$(echo "($i+1)*$step_gb"|bc)
			parted $base_dir/$disk --script mkpart primary ext4 "$begin"G "$end"G
			partid=$(echo "$i+1"|bc)
			parted_cache_array=("${parted_cache_array[@]}" ${disk}-part${partid})
			while [ ! -h $disk_dir/${disk}-part${partid} -a $wait -lt 120 ];do
				cur_date=`date "+%Y-%m-%d %H:%M:%S"`
				echo "$cur_date [$wait/120]==== wait for $disk_dir/${disk}-part${partid}  ====" >> $add_osd_log_file
				sleep 1
				let wait++
			done
		done
	done
	return 0
}

#make partition and write to osddisk
function write_meta_cache_disk_to_osddisk()
{
	type="hdd"
	reused_num=${#reused_cache_array[@]}
	remain_def_num=$hdd_def_nums

	#reuse ssd or nvme partition
	if [ "$reused_num" -ge "$hdd_def_nums" ]; then
		#type1: reused num >= hdd_def_num
		for ((i=0;i<$hdd_def_nums;i++));do
			if [ "${add_one_disk}" = "false" ]; then
				echo "${reused_cache_array[$i]} ${hdd_array[$i]}" >> $f2fs_conf_dir/osddisk
				echo "${reused_cache_array[$i]} ${hdd_array[$i]} ${type}" >> $f2fs_conf_dir/osddisk-vg
			else
				echo "${reused_cache_array[$i]} ${hdd_array[$i]} ${type}"
			fi
		done
		return 0
	elif [ "$reused_num" -gt 0 ]; then
		for ((i=0;i<$reused_num;i++));do
			if [ "${add_one_disk}" = "false" ]; then
				echo "${reused_cache_array[$i]} ${hdd_array[$i]}" >> $f2fs_conf_dir/osddisk
				echo "${reused_cache_array[$i]} ${hdd_array[$i]} ${type}" >> $f2fs_conf_dir/osddisk-vg
			else
				echo "${reused_cache_array[$i]} ${hdd_array[$i]} ${type}"
			fi
		done
		remain_def_num=$(echo "$hdd_def_nums-$reused_num"|bc)
	fi

	base_pos=$reused_num
	#set remain cache disk
	if [ "$hdd_cache_nums" -ge "$remain_def_num" ]; then
		#type2: cache num >= hdd_def_num only use hdd note need parted
		for ((i=0;i<$remain_def_num;i++));do
			cur_pos=$(echo "$base_pos+$i"|bc)
			if [ "${add_one_disk}" = "false" ]; then
				echo "${cache_array[$i]} ${hdd_array[$cur_pos]}" >> $f2fs_conf_dir/osddisk
				echo "${cache_array[$i]} ${hdd_array[$cur_pos]} ${type}" >> $f2fs_conf_dir/osddisk-vg
			else
				echo "${cache_array[$i]} ${hdd_array[$cur_pos]} ${type}"
			fi
		done
	else
		make_partition
		
		#write to osddisk
		for ((i=0;i<$remain_def_num;i++));do
			cur_pos=$(echo "$base_pos+$i"|bc)
			if [ "${add_one_disk}" = "false" ]; then
				echo "${parted_cache_array[$i]} ${hdd_array[$cur_pos]}" >> $f2fs_conf_dir/osddisk
				echo "${parted_cache_array[$i]} ${hdd_array[$cur_pos]} ${type}" >> $f2fs_conf_dir/osddisk-vg
			else
				echo "${parted_cache_array[$i]} ${hdd_array[$cur_pos]} ${type}"
			fi
		done
	fi
}

#write nvme | ssd to osddisk
function write_nvme_ssd_disk_to_osddisk()
{
	if [ $nvme_def_nums -gt 0 ]; then
		type="nvme"
		for ((i=0;i<$nvme_def_nums;i++));do
			if [ "${add_one_disk}" = "false" ]; then
				echo "${nvme_array[$i]}" >> $f2fs_conf_dir/osddisk
				echo "${nvme_array[$i]} ${type}" >> $f2fs_conf_dir/osddisk-vg
			else
				echo "${nvme_array[$i]} ${type}"
			fi
		done
	fi
	if [ $ssd_def_nums -gt 0 ]; then
		type="ssd"
		for ((i=0;i<$ssd_def_nums;i++));do
			if [ "${add_one_disk}" = "false" ]; then
				echo "${ssd_array[$i]}" >> $f2fs_conf_dir/osddisk
				echo "${ssd_array[$i]} ${type}" >> $f2fs_conf_dir/osddisk-vg
			else
				echo "${ssd_array[$i]} ${type}"
			fi
		done
	fi
}

#param 1: only have cache disk type: nvme | ssd
function only_write_cache_disk_to_osddisk()
{
	type=$1
	if [ "$type" != "nvme" ] && [ "$type" != "ssd" ]; then
		return
	fi
	for disk in ${cache_array[@]}; do
		if [ "${add_one_disk}" = "false" ]; then
			echo "${disk}" >> $f2fs_conf_dir/osddisk
			echo "${disk} ${type}" >> $f2fs_conf_dir/osddisk-vg
		else
			echo "${disk} ${type}"
		fi
	done
}

#write hdd to osddisk
function only_write_hdd_disk_to_osddisk()
{
	type="hdd"
	hdd_number=${#hdd_array[@]}
	
	if [ "$hdd_def_nums" -gt "$hdd_number" ]; then
		#input param def_nums > current get total disks
		#only use these valid disks
		hdd_def_nums=$hdd_number
	fi
	for disk in ${hdd_array[@]:0:${hdd_def_nums}}; do
		if [ "${add_one_disk}" = "false" ]; then
			echo "${disk}" >> $f2fs_conf_dir/osddisk
			echo "${disk} ${type}" >> $f2fs_conf_dir/osddisk-vg
		else
			echo "${disk} ${type}"
		fi
	done
}

#list all type scaned disks
function list_disk_array()
{
	if [ "${add_one_disk}" = "false" ]; then
		echo "==nvme=="
		nvme_number=${#nvme_array[@]}
		echo ${nvme_array[@]}
		echo "nvme numbers:$nvme_number"

		echo "==ssd=="
		ssd_number=${#ssd_array[@]}
		echo ${ssd_array[@]}
		echo "ssd numbers:$ssd_number"

		echo "==hdd=="
		hdd_number=${#hdd_array[@]}
		echo ${hdd_array[@]:0:${hdd_number}}
		echo "hdd numbers:$hdd_number"
	fi
}

#support user call to get all kinds of disk and number
function option_list_default_disks()
{
        nvme_status=0
        ssd_status=0
        cache_strategy=2
        #modify by sxw 20171010
        if [ $nvme_def_nums -gt 0 ]; then
                nvme_status=1
        fi
        if [ $ssd_def_nums -gt 0 ]; then
                ssd_status=1
        fi
        if [ "$hdd_cache_type" = "nvme" ]; then
                cache_strategy=0
        elif [ "$hdd_cache_type" = "ssd" ]; then
                cache_strategy=1
        fi

	echo "nvme_default_used $nvme_def_nums"
	echo "nvme_total_nums $nvme_nums"
	echo "ssd_default_used $ssd_def_nums"
	echo "ssd_total_nums $ssd_nums"
	echo "hdd_default_used $hdd_def_nums"
	echo "hdd_total_nums $hdd_nums"
	echo "hdd_cache_disk_nums $hdd_cache_nums"
	echo "nvme_group_status $nvme_status"
	echo "ssd_group_status $ssd_status"
	echo "hdd_cache_disk_strategy $cache_strategy"

:<<abc
	echo "==================="
	for p in ${reused_cache_array[@]}; do
		echo "$p"
	done
	echo "==================="
abc
}

function disk_classify()
{
	#get all disk device
	disks=`cat /proc/partitions | egrep -w "[s,v]d[a-z]*|nvme[0-9]*n[0-9]" | awk '{print $4}'`

	disk_array=()
	for disk in $disks; do
		disk_array=("${disk_array[@]}" ${disk})
	done

	#step1: remove lvm pv dev
	remove_lvm_pv
	disk_len=${#disk_array[@]}

	#step2: remove have partition dev && mark type
	mark_disk_type
}

#check all input param
function check_param()
{
	nvme_number=${#nvme_array[@]}
	ssd_number=${#ssd_array[@]}
	hdd_number=${#hdd_array[@]}

	if [ "$nvme_number" -ne "$nvme_nums" ]; then
		nvme_nums=$nvme_number
		if [ "$nvme_def_nums" -gt "$nvme_nums" ]; then
			nvme_def_nums=$nvme_nums
		fi
		if [ "hdd_cache_type" = "nvme" ]; then
			tmp_total=`expr $hdd_cache_nums + $nvme_def_nums`
			if [ "$nvme_nums" -lt "$tmp_total" ]; then
				hdd_cache_nums=`expr $nvme_nums - $nvme_def_nums`
			fi
		fi
	fi
	if [ "$ssd_number" -ne "$ssd_nums" ]; then
		ssd_nums=$ssd_number
		if [ "$ssd_def_nums" -gt "$ssd_nums" ]; then
			ssd_def_nums=$ssd_nums
		fi
		if [ "hdd_cache_type" = "ssd" ]; then
			tmp_total=`expr $hdd_cache_nums + $hdd_def_nums`
			if [ "$ssd_nums" -lt "$tmp_total" ]; then
				hdd_cache_nums=`expr $ssd_nums - $ssd_def_nums`
			fi
		fi
	fi
	if [ "$hdd_number" -ne "$hdd_nums" ]; then
		hdd_nums=$hdd_number
		if [ "$hdd_def_nums" -gt "$hdd_nums" ]; then
			hdd_def_nums=$hdd_nums
		fi
	fi
	if [ "hdd_cache_type" = "none" ]; then
		hdd_cache_nums=0
	fi
}

#set default config
function set_default_conf()
{
	if [ "$mode" != "auto" ]; then
		return
	fi
	
	#auto mode
	nvme_cnt=${#nvme_array[@]}
	ssd_cnt=${#ssd_array[@]}
	hdd_cnt=${#hdd_array[@]}
	hdd_cache_nums=0
	hdd_cache_type="none"

	if [ $hdd_cnt -gt 0 ]; then
		#sequence set default nvme -> ssd -> none
		#determin cache type
		if [ $nvme_cnt -gt 0 ] && [ $ssd_cnt -gt 0 ]; then
			#nvme_cnt > 0 && ssd_cnt > 0
			hdd_cache_type="ssd"
		else
			#nvme_cnt > 0 or ssd > 0
			if [ $nvme_cnt -gt 0 ]; then
				hdd_cache_type="nvme"
			fi
			if [ $ssd_cnt -gt 0 ]; then
				hdd_cache_type="ssd"
			fi
		fi
	fi
	nvme_nums=$nvme_cnt
	ssd_nums=$ssd_cnt
	hdd_nums=$hdd_cnt
	nvme_def_nums=$nvme_cnt
	ssd_def_nums=$ssd_cnt
	hdd_def_nums=$hdd_cnt
	#set cache disk numbers, reset nvme|ssd def nums
	if [ "$hdd_cache_type" = "nvme" ]; then
		nvme_def_nums=0
		hdd_cache_nums=$nvme_cnt
	elif [ "$hdd_cache_type" = "ssd" ]; then
		ssd_def_nums=0
		hdd_cache_nums=$ssd_cnt
	fi
	#param_show
}

#total disk array all kind of disks
disk_array=()
#scaned nvme | ssd | hdd disk
nvme_array=()
ssd_array=()
hdd_array=()
#before parted cache disk
cache_array=()
#after parted cache disk
parted_cache_array=()
#resued parted
reused_cache_array=()

#for get disk type
enlid_array=()
slot_array=()
deviceid_array=()

nvme_def_nums=0
nvme_nums=0
ssd_def_nums=0
ssd_nums=0
hdd_def_nums=0
hdd_nums=0
hdd_cache_nums=0
hdd_cache_type="none"
option_action=""
mode=""
add_one_disk="false"

#parse all param
parse_param "$@"

#delete all disk partitions
if [ "$option_action" = "deletepartition" ]; then
	delete_partition
	exit 0
fi

if [ "$option_action" != "deploy" ] && [ "$option_action" != "expand" ] && [ "$option_action" != "getdisks" ] && [ "$mode" != "auto" ] && [ "$mode" != "manual" ]; then
	echo "param error, need add mode [-M|--mode] [auto | manual] option [-O|--option] [deploy | expand | getdisks | deletepartition]"
	exit 1
fi

#init f2fs conf
env_init

#scrub disk, delete busy | lvm | multi partition
disk_classify

#param show
#param_show

#check param with current host,maybe modify input param
check_param

#set default config
set_default_conf

#get all kinds of disks
if [ "$option_action" = "getdisks" ]; then
	option_list_default_disks
	#param_show
	exit 0
fi

#get cache disk set cache_array
get_cache_disk

#parted all type disk
construct_osddisk

#type group
list_disk_array

exit 0
