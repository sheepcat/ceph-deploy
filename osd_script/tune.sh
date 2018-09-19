#!/bin/sh

osddisk=/opt/ceph/f2fs/conf/osddisk
dev_path=/dev/disk/by-id/

#get ceph node ip list
#ipList=`grep "^public" /etc/ceph/ceph.conf |awk -F "[=:]" '{print $2}' | sed 's/ //g' |sort -k2n |uniq`
#for ip in $ipList
#do
#	echo $ip
#done

#set correct scheduler noop | deadline | cfq
MEGACLI="/opt/MegaRAID/storcli/storcli64"
for line in `cat $osddisk`
do
	for dev in $line
	do
		echo "=========$dev============="
		is_nvme=$(echo $dev |grep nvme)
		if [ -z "$is_nvme" ];then
			#is not nvme
			#judge is sata-ssd
			full_dev=$dev_path$dev
			dev_id=$(ls -l $full_dev |awk -F "[./]" '{print $NF}')
			#echo "dev_id:$dev_id"
			#direct and jbod mode
			primary_dev=$(echo $dev_id | sed 's/[0-9]*$//g')
			jbod_ssd=$(lsscsi | grep $primary_dev | grep 'SSD')
			if [ -n "$jbod_ssd" ]; then
				#is jbod mode sata-ssd
				#TODO: change cfq -> noop 
				disk_type=1
			else
				#judge is raid mode sata-ssd
				host_No=$(lsscsi | grep ${primary_dev} | awk '{print $1}' | sed -n 's/\[\(.*\)\]/\1/p' | awk -F ':' '{print $1}')
				if [ -n "${host_No}" ]; then
					target_device_No=$(lsscsi | grep ${primary_dev} | awk '{print $1}' | awk -F ':' '{print $3}')
					if [ -n "${target_device_No}" ]; then
						is_ssd=`${MEGACLI} /c${host_No}/v${target_device_No} show all | egrep '\bSSD\b'`
						if [ -n "$is_ssd" ]; then
							#ssd
							#ssd_array=("${ssd_array[@]}" ${device_id})
							disk_type=1
						else
							#non_ssd_array=("${non_ssd_array[@]}" ${device_id})
							disk_type=0
						fi
					else
						disk_type=0
					fi
					#avialable_disks=("${avialable_disks[@]}" ${device_id})
				else
					disk_type=0
				fi
			fi

			echo "disk_type=$disk_type"
			#remove partition number, there are two method below
			#primary_dev=$(echo $dev_id | sed 's:[0-9]*$::')
			if [ $disk_type -eq 1 ]; then
				#is ssd maybe raid | jbod | direct
				echo noop > /sys/block/${primary_dev}/queue/scheduler
				echo 2048 > /sys/block/${primary_dev}/queue/nr_requests
			else
				#sata hdd | sas
				echo cfq > /sys/block/${primary_dev}/queue/scheduler
				echo 512 > /sys/block/${primary_dev}/queue/nr_requests
			fi
			cat /sys/block/${primary_dev}/queue/scheduler
			cat /sys/block/${primary_dev}/queue/nr_requests
		fi
	done
done

#check cpu info
#grep -E '^model name|^cpu MHz' /proc/cpuinfo

#set cpu performance
for CPUFREQ in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -f $CPUFREQ ] || continue; echo -n performance > $CPUFREQ; done
