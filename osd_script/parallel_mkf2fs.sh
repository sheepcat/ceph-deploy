#!/bin/bash
base_dir="/etc/ceph/scripts"

echo "paramnumber:$#"
if [ $# -ne 1 ]; then
	echo "./parallel_mkf2fs.sh indexnumber[1]."
	exit 1
fi

index=$1
total_num=$(cat /opt/ceph/f2fs/conf/osddisk | wc -l)
if [ "$index" -gt "$total_num" ] || [ "$index" -le 0 ]; then
	echo "input index error:(index)$index > (total)$total_num || (index)$index <= (total)$total_num"
	exit 0
fi

#exit 0

tmpfifo=/tmp/f2fs.fifo

#pipe fd
fileid=110

#trap
trap "exec 110<&-;exec 110>&-;exit 0" 2

#create read write pipe
mkfifo $tmpfifo
exec 110<>$tmpfifo
rm -f $tmpfifo

#set parallel
parallel_num=36
for ((i=1;i<=$parallel_num;i++))
do
	echo >&110
done

#expand_disks=$(sed -n "$index,\$p" /opt/ceph/f2fs/conf/osddisk)
expand_file=/opt/ceph/f2fs/conf/osddisk-tmp
sed -n "$index,\$p" /opt/ceph/f2fs/conf/osddisk > $expand_file
while read line
do
	read -u110
	{
	echo "LINIE[$line]"
	name=$(echo $line |awk '{print $1}')
	mkfs_log="/opt/ceph/f2fs/conf/${name}-mkf2fs.log"
	sh $base_dir/prepareOsd_new.sh $line >> $mkfs_log
	echo >&110
	}&
done < $expand_file
wait

rm -f $expand_file

#close file handle
exec 110<&-
exec 110>&-

#serial mount f2fs
sh $base_dir/serial_mount.sh $index

exit 0
