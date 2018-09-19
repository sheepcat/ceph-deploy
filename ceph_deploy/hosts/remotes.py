try:
    import configparser
except ImportError:
    import ConfigParser as configparser
import errno
import socket
import os
import shutil
import tempfile
import platform
import commands

disk_conf = '/opt/ceph/f2fs/conf/osddisk'
ceph_conf_file = '/etc/ceph/ceph.conf'
conf_hd = configparser.ConfigParser()
conf_hd.read(ceph_conf_file)
osd_path = '/Ceph/Data/Osd/'

def platform_information(_linux_distribution=None):
    """ detect platform information from remote host """
    linux_distribution = _linux_distribution or platform.linux_distribution
    distro, release, codename = linux_distribution()
    if not codename and 'debian' in distro.lower():  # this could be an empty string in Debian
        debian_codenames = {
            '10': 'buster',
            '9': 'stretch',
            '8': 'jessie',
            '7': 'wheezy',
            '6': 'squeeze',
        }
        major_version = release.split('.')[0]
        codename = debian_codenames.get(major_version, '')

        # In order to support newer jessie/sid or wheezy/sid strings we test this
        # if sid is buried in the minor, we should use sid anyway.
        if not codename and '/' in release:
            major, minor = release.split('/')
            if minor == 'sid':
                codename = minor
            else:
                codename = major
    if not codename and 'oracle' in distro.lower(): # this could be an empty string in Oracle linux
        codename = 'oracle'
    if not codename and 'virtuozzo linux' in distro.lower(): # this could be an empty string in Virtuozzo linux
        codename = 'virtuozzo'

    return (
        str(distro).rstrip(),
        str(release).rstrip(),
        str(codename).rstrip()
    )


def machine_type():
    """ detect machine type """
    return platform.machine()

def make_mgr_key(mgr_name, path):
    # try:
    uid = 167
    gid = 167
    if not os.path.exists(path):
        os.makedirs(path)
        os.chown(path, uid, gid)
    # create mgr key
    auth_add = 'ceph auth get-or-create %s mon \'allow *\' osd \'allow *\' mds \'allow *\' -o %s/%s/keyring' % \
               (mgr_name, "/Ceph/Data/Mgr", mgr_name)
    (ret, out) = commands.getstatusoutput(auth_add)
    # if 0 != ret:
    #     raise RuntimeError('create mgr key failed! --->ret:%s  out:%s' % (ret, out))
    # start mgr
    start_cmd = '/etc/init.d/ceph -a -c /etc/ceph/ceph.conf start %s' % mgr_name
    (ret, out) = commands.getstatusoutput(start_cmd)

def write_sources_list(url, codename, filename='ceph.list', mode=0o644):
    """add deb repo to /etc/apt/sources.list.d/"""
    repo_path = os.path.join('/etc/apt/sources.list.d', filename)
    content = 'deb {url} {codename} main\n'.format(
        url=url,
        codename=codename,
    )
    write_file(repo_path, content.encode('utf-8'), mode)


def write_sources_list_content(content, filename='ceph.list', mode=0o644):
    """add deb repo to /etc/apt/sources.list.d/ from content"""
    repo_path = os.path.join('/etc/apt/sources.list.d', filename)
    if not isinstance(content, str):
        content = content.decode('utf-8')
    write_file(repo_path, content.encode('utf-8'), mode)


def write_yum_repo(content, filename='ceph.repo'):
    """add yum repo file in /etc/yum.repos.d/"""
    repo_path = os.path.join('/etc/yum.repos.d', filename)
    if not isinstance(content, str):
        content = content.decode('utf-8')
    write_file(repo_path, content.encode('utf-8'))


def set_apt_priority(fqdn, path='/etc/apt/preferences.d/ceph.pref'):
    template = "Package: *\nPin: origin {fqdn}\nPin-Priority: 999\n"
    content = template.format(fqdn=fqdn)
    with open(path, 'w') as fout:
        fout.write(content)


def set_repo_priority(sections, path='/etc/yum.repos.d/ceph.repo', priority='1'):
    Config = configparser.ConfigParser()
    Config.read(path)
    Config.sections()
    for section in sections:
        try:
            Config.set(section, 'priority', priority)
        except configparser.NoSectionError:
            # Emperor versions of Ceph used all lowercase sections
            # so lets just try again for the section that failed, maybe
            # we are able to find it if it is lower
            Config.set(section.lower(), 'priority', priority)

    with open(path, 'w') as fout:
        Config.write(fout)

    # And now, because ConfigParser is super duper, we need to remove the
    # assignments so this looks like it was before
    def remove_whitespace_from_assignments():
        separator = "="
        lines = open(path).readlines()
        fp = open(path, "w")
        for line in lines:
            line = line.strip()
            if not line.startswith("#") and separator in line:
                assignment = line.split(separator, 1)
                assignment = tuple(map(str.strip, assignment))
                fp.write("%s%s%s\n" % (assignment[0], separator, assignment[1]))
            else:
                fp.write(line + "\n")

    remove_whitespace_from_assignments()


def write_conf(cluster, conf, overwrite):
    """ write cluster configuration to /etc/ceph/{cluster}.conf """
    path = '/etc/ceph/{cluster}.conf'.format(cluster=cluster)
    tmp_file = tempfile.NamedTemporaryFile('w', dir='/etc/ceph', delete=False)
    err_msg = 'config file %s exists with different content; use --overwrite-conf to overwrite' % path

    if os.path.exists(path):
        with open(path, 'r') as f:
            old = f.read()
            if old != conf and not overwrite:
                raise RuntimeError(err_msg)
        tmp_file.write(conf)
        tmp_file.close()
        shutil.move(tmp_file.name, path)
        os.chmod(path, 0o644)
        return
    if os.path.exists('/etc/ceph'):
        with open(path, 'w') as f:
            f.write(conf)
        os.chmod(path, 0o644)
    else:
        err_msg = '/etc/ceph/ does not exist - could not write config'
        raise RuntimeError(err_msg)


def write_keyring(path, key, uid=-1, gid=-1):
    """ create a keyring file """
    # Note that we *require* to avoid deletion of the temp file
    # otherwise we risk not being able to copy the contents from
    # one file system to the other, hence the `delete=False`
    tmp_file = tempfile.NamedTemporaryFile('wb', delete=False)
    tmp_file.write(key)
    tmp_file.close()
    keyring_dir = os.path.dirname(path)
    if not path_exists(keyring_dir):
        makedir(keyring_dir, uid, gid)
    shutil.move(tmp_file.name, path)

def create_ceph_path(path, uid=-1, gid=-1):
    """create the ceph path if it does not exist"""
    if not os.path.exists(path):
        os.makedirs(path)
        os.chown(path, uid, gid);

def create_mon_path(path, uid=-1, gid=-1):
    """create the mon path if it does not exist"""
    if not os.path.exists(path):
        os.makedirs(path)
        os.chown(path, uid, gid);

def create_meta_path(path, uid=-1, gid=-1):
    """create the meta path if it does not exist"""
    if not os.path.exists(path):
        os.makedirs(path)
        os.chown(path, uid, gid);

def create_done_path(done_path, uid=-1, gid=-1):
    """create a done file to avoid re-doing the mon deployment"""
    with open(done_path, 'wb'):
        pass
    os.chown(done_path, uid, gid);


def create_init_path(init_path, uid=-1, gid=-1):
    """create the init path if it does not exist"""
    if not os.path.exists(init_path):
        with open(init_path, 'wb'):
            pass
        os.chown(init_path, uid, gid);


def append_to_file(file_path, contents):
    """append contents to file"""
    with open(file_path, 'a') as f:
        f.write(contents)

def path_getuid(path):
    return os.stat(path).st_uid

def path_getgid(path):
    return os.stat(path).st_gid

def readline(path):
    with open(path) as _file:
        return _file.readline().strip('\n')


def path_exists(path):
    return os.path.exists(path)


def get_realpath(path):
    return os.path.realpath(path)


def listdir(path):
    return os.listdir(path)


def makedir(path, ignored=None, uid=-1, gid=-1):
    ignored = ignored or []
    try:
        os.makedirs(path)
    except OSError as error:
        if error.errno in ignored:
            pass
        else:
            # re-raise the original exception
            raise
    else:
        os.chown(path, uid, gid);


def unlink(_file):
    os.unlink(_file)

''' define fuc for osd '''
def create_client_admin_keyring(key_path, uid, gid):
    key_file = '/Ceph/Meta/Keyring/client.admin.keyring'
    if not os.path.exists(key_file):
        get_key = 'ceph --cluster=ceph --name=mon. --keyring=%s auth get-or-create client.admin mon \'allow *\' osd \'allow *\' mgr \'allow *\' mds \'allow *\'' % key_path
        (ret,out) = commands.getstatusoutput(get_key)
        with open(key_file,'w') as f:
            f.write(out)
            f.write('\n')

def tar_scripts():
    cmd = "tar xvzf /etc/ceph/scripts.tar.gz --directory=/etc/ceph/"
    (ret, out) = commands.getstatusoutput(cmd)
    return

def prepare_osd(hostname, publicip):
    cmd = "python2.7 /etc/ceph/scripts/prepare_all.py %s %s %s" % (hostname, publicip, publicip)
    (ret,out) = commands.getstatusoutput(cmd)
    return [ret, out]

def create_osddisk_path(osddisk_path, scripts_path):
    if os.path.exists(osddisk_path):
        clear_dir = 'rm -rf /opt/ceph/f2fs/conf/*'
        (ret,out) = commands.getstatusoutput(clear_dir)

    if not os.path.exists(osddisk_path):
        create_dir = 'mkdir -p /opt/ceph/f2fs/conf'
        (ret,out) = commands.getstatusoutput(create_dir)
        create_file = 'touch %s' % osddisk_path
        (ret,out) = commands.getstatusoutput(create_file)

    if not os.path.exists(scripts_path):
        mk_dir = 'mkdir -p %s' % scripts_path
        (ret,out) = commands.getstatusoutput(mk_dir)

def scan_new_disk(scripts_path, strategy, mode, nvme_def_used, nvme_tt_nums, ssd_def_used, ssd_tt_used,hdd_def_used, hdd_tt_nums, cache_nums, cache_dis_type):
    if strategy == 'parted':
        option = "deploy"
        scan_disk = 'sh /etc/ceph/scripts/disk_fs_mgmt.sh -M%s -O%s -a%s -b%s -c%s -d%s -e%s -f%s -g%s -t%s' % (
            mode, option, nvme_def_used, nvme_tt_nums, ssd_def_used, ssd_tt_used,
            hdd_def_used, hdd_tt_nums, cache_nums, cache_dis_type)
    else:
        scan_disk = 'sh %s/disk_fs_mgmt.sh -Odeploy -Mauto -tnone' % scripts_path
    (ret, out) = commands.getstatusoutput(scan_disk)
    return [ret,out]

def prepare_osd_dir(scripts_path):
    mkf2fs_cmd='sh %s/parallel_mkf2fs.sh 1' % scripts_path
    (ret, out) = commands.getstatusoutput(mkf2fs_cmd)
    return [ret,out]

def get_osd_disk(osddisk_path):
    new_disk_index = 1
    # get new disk list
    # ata-INTEL_SSDSC2BB600G4L_PHWL536400VM600TGN-part2 scsi-3600062b200c8e5b021b78b502a088287
    get_avail_disks = 'sed -n \'%s,$p\' %s' % (str(new_disk_index), disk_conf)
    (ret, avail_disk_msg) = commands.getstatusoutput(get_avail_disks)
    if (0 != ret):
        return ret

    avail_disk_list = avail_disk_msg.split('\n')

    osd_disk = []
    for i in range(0, len(avail_disk_list)):
        meta_disk = avail_disk_list[i].split(" ")[0]
        osd_disk.append(meta_disk)

        if (not os.path.exists('/Ceph/Meta/Keyring')):
            mk_meta_dir = 'mkdir -p /Ceph/Meta/Keyring'
            (ret, msg) = commands.getstatusoutput(mk_meta_dir)

        mk_osd_dir = 'mkdir -p /Ceph/Data/Osd/osd-%s' % meta_disk
        (ret, msg) = commands.getstatusoutput(mk_osd_dir)
    return osd_disk

def get_osd_num():
    create_osd_cmd = 'ceph osd create > /tmp/osd_no'
    (ret, msg) = commands.getstatusoutput(create_osd_cmd)
    if (0 != ret):
        return ret

    get_osd_no = 'cat /tmp/osd_no'
    (ret, osd_no) = commands.getstatusoutput(get_osd_no)
    return osd_no

def get_osd_weight(disk):
    #ata-INTEL_SSDSC2BB600G4L_PHWL536400VM600TGN-part1 
    get_disk_name = "ls -l /dev/disk/by-id | grep -w %s | awk '{print $11}'|awk -F'/' '{print $3}'" % disk
    (ret, disk_name) = commands.getstatusoutput(get_disk_name)

    get_osd_size = 'df | grep -w %s| awk \'{print $2}\'' % disk_name
    (ret, osd_size) = commands.getstatusoutput(get_osd_size)

    weight = int(osd_size)/1024.00/1024.00/1024.00
    return weight

def prepare_osd_one(disk, osd, hostname):
    mkfs_osd = 'ceph-osd -i %s --mkfs --mkjournal --mkkey' % osd
    (ret, msg) = commands.getstatusoutput(mkfs_osd)
    if(0 != ret):
        return ret

    # add auth
    auth_add = 'ceph auth get-or-create osd.%s osd \'allow *\' mgr \'allow profile osd\' mon \'allow rwx\' -o %s/osd.%s.keyring' % \
                    (osd, "/Ceph/Meta/Keyring", osd)
    (ret, msg) = commands.getstatusoutput(auth_add)
    if(0 != ret):
        return ret

    # modify crush map
    weight = get_osd_weight(disk)

    # modify cluster crush
    modify_crush = 'ceph osd crush create-or-move %s %s  host=%s rack=unknownrack root=default' \
                    % (osd, weight, hostname)
    (ret, msg) = commands.getstatusoutput(modify_crush)
    if(0 != ret):
        return ret


def start_osd(osds):
    for osd in osds:
        start_osd_cmd = '/etc/init.d/ceph -a -c /etc/ceph/ceph.conf start osd.%s' % osd
        (ret, msg) = commands.getstatusoutput(start_osd_cmd)
        if (0 != ret):
           return ret
    return

def add_osd_with_no(hostname, public_ip, cluster_ip, dev_id, osd_no):
    osd_sec_name = 'osd.' + str(osd_no)
    if not conf_hd.has_section(osd_sec_name):
        conf_hd.add_section(osd_sec_name)

        osd_port = 6900 + int(osd_no)
        conf_hd.set(osd_sec_name, 'host', hostname)
        conf_hd.set(osd_sec_name, 'public addr', public_ip + ':' + str(osd_port))
        conf_hd.set(osd_sec_name, 'cluster addr', cluster_ip)

        conf_hd.set(osd_sec_name, 'osd journal size', '10000')

        ceph_osd_path = osd_path + 'osd-' + dev_id
        conf_hd.set(osd_sec_name, 'osd journal', ceph_osd_path + '/journal')
        conf_hd.set(osd_sec_name, 'osd data', ceph_osd_path)

        conf_write = open(ceph_conf_file, 'w')
        conf_hd.write(conf_write)
        conf_write.close()
    return

'''end osd fuc define'''

def write_monitor_keyring(keyring, monitor_keyring, uid=-1, gid=-1):
    """create the monitor keyring file"""
    write_file(keyring, monitor_keyring, 0o600, None, uid, gid)


def write_file(path, content, mode=0o644, directory=None, uid=-1, gid=-1):
    if directory:
        if path.startswith("/"):
            path = path[1:]
        path = os.path.join(directory, path)
    if os.path.exists(path):
        # Delete file in case we are changing its mode
        os.unlink(path)
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT, mode), 'wb') as f:
        f.write(content)
    os.chown(path, uid, gid)


def touch_file(path):
    with open(path, 'wb') as f:  # noqa
        pass

def exist_file(path):
    if os.path.exists(path):
        return True
    else:
        return False

def get_file(path):
    """ fetch remote file """
    try:
        with open(path, 'rb') as f:
            return f.read()
    except IOError:
        pass


def object_grep(term, file_object):
    for line in file_object.readlines():
        if term in line:
            return True
    return False


def grep(term, file_path):
    # A small grep-like function that will search for a word in a file and
    # return True if it does and False if it does not.

    # Implemented initially to have a similar behavior as the init system
    # detection in Ceph's init scripts::

    #     # detect systemd
    #     # SYSTEMD=0
    #     grep -qs systemd /proc/1/comm && SYSTEMD=1

    # .. note:: Because we intent to be operating in silent mode, we explicitly
    # return ``False`` if the file does not exist.
    if not os.path.isfile(file_path):
        return False

    with open(file_path) as _file:
        return object_grep(term, _file)


def shortname():
    """get remote short hostname"""
    return socket.gethostname().split('.', 1)[0]


def which_service():
    """ locating the `service` executable... """
    # XXX This should get deprecated at some point. For now
    # it just bypasses and uses the new helper.
    return which('service')


def which(executable):
    """find the location of an executable"""
    locations = (
        '/usr/local/bin',
        '/bin',
        '/usr/bin',
        '/usr/local/sbin',
        '/usr/sbin',
        '/sbin',
    )

    for location in locations:
        executable_path = os.path.join(location, executable)
        if os.path.exists(executable_path):
            return executable_path


def make_mon_removed_dir(path, file_name):
    """ move old monitor data """
    try:
        os.makedirs('/var/lib/ceph/mon-removed')
    except OSError as e:
        if e.errno != errno.EEXIST:
            raise
    shutil.move(path, os.path.join('/var/lib/ceph/mon-removed/', file_name))


def safe_mkdir(path, uid=-1, gid=-1):
    """ create path if it doesn't exist """
    try:
        os.mkdir(path)
    except OSError as e:
        if e.errno == errno.EEXIST:
            pass
        else:
            raise
    else:
        os.chown(path, uid, gid)

def safe_makedirs(path, uid=-1, gid=-1):
    """ create path recursively if it doesn't exist """
    try:
        os.makedirs(path)
    except OSError as e:
        if e.errno == errno.EEXIST:
            pass
        else:
            raise
    else:
        os.chown(path, uid, gid)


def zeroing(dev):
    """ zeroing last few blocks of device """
    # this kills the crab
    #
    # sgdisk will wipe out the main copy of the GPT partition
    # table (sorry), but it doesn't remove the backup copies, and
    # subsequent commands will continue to complain and fail when
    # they see those.  zeroing the last few blocks of the device
    # appears to do the trick.
    lba_size = 4096
    size = 33 * lba_size
    return True
    with open(dev, 'wb') as f:
        f.seek(-size, os.SEEK_END)
        f.write(size*b'\0')


def enable_yum_priority_obsoletes(path="/etc/yum/pluginconf.d/priorities.conf"):
    """Configure Yum priorities to include obsoletes"""
    config = configparser.ConfigParser()
    config.read(path)
    config.set('main', 'check_obsoletes', '1')
    with open(path, 'w') as fout:
        config.write(fout)


# remoto magic, needed to execute these functions remotely
if __name__ == '__channelexec__':
    for item in channel:  # noqa
        channel.send(eval(item))  # noqa
