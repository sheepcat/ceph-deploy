import commands
import os
import time
import ConfigParser
from os.path import join
from ceph_deploy.util import paths
from ceph_deploy import conf
from ceph_deploy.lib import remoto
from ceph_deploy.util import constants
from ceph_deploy.util import system

ceph_conf_file = '/root/ceph.conf'
conf_hd = ConfigParser.ConfigParser()
conf_hd.read(ceph_conf_file)

osddisk_path = '/opt/ceph/f2fs/conf/osddisk'
scripts_path = '/etc/ceph/scripts'
osd_path = '/Ceph/Data/Osd/'

def ceph_version(conn):
    """
    Log the remote ceph-version by calling `ceph --version`
    """
    return remoto.process.run(conn, ['ceph', '--version'])


def mon_create(distro, args, monitor_keyring, mon_index):
    logger = distro.conn.logger
    hostname = distro.conn.remote_module.shortname()
    logger.debug('remote hostname: %s' % hostname)

    ceph_dir = '/Ceph'
    mon_dir = '/Ceph/Data/Mon/mon.' + mon_index
    meta_dir = '/Ceph/Meta/Keyring'

    uid = 167
    gid = 167
    done_path = join(mon_dir, 'done')
    init_path = join(mon_dir, 'init')

    conf_data = conf.ceph.load_raw(args)

    # write the configuration file
    distro.conn.remote_module.write_conf(
        args.cluster,
        conf_data,
        args.overwrite_conf,
    )

    keyring = paths.mon.keyring(args.cluster, mon_index)
    # if the mon path does not exist, create it
    if not distro.conn.remote_module.path_exists(ceph_dir):
        distro.conn.remote_module.create_ceph_path(ceph_dir, uid, gid)
        distro.conn.remote_module.create_meta_path(meta_dir, uid, gid)
    distro.conn.remote_module.create_mon_path(mon_dir, uid, gid)

    logger.debug('checking for done path: %s' % done_path)
    if not distro.conn.remote_module.path_exists(done_path):
        logger.debug('done path does not exist: %s' % done_path)
        if not distro.conn.remote_module.path_exists(paths.mon.constants.tmp_path):
            logger.info('creating tmp path: %s' % paths.mon.constants.tmp_path)
            distro.conn.remote_module.makedir(paths.mon.constants.tmp_path)

        logger.info('creating keyring file: %s' % keyring)
        distro.conn.remote_module.write_monitor_keyring(
            keyring,
            monitor_keyring,
            uid, gid,
        )

        user_args = []
        if uid != 0:
            user_args = user_args + [ '--setuser', str(uid) ]
        if gid != 0:
            user_args = user_args + [ '--setgroup', str(gid) ]

        remoto.process.run(
            distro.conn,
            [
                'ceph-mon',
                '--cluster', args.cluster,
                '--mkfs',
                '-i', mon_index,
                '--keyring', keyring,
            ] + user_args
        )
    # create the done file
    distro.conn.remote_module.create_done_path(done_path, uid, gid)

    # create init path
    distro.conn.remote_module.create_init_path(init_path, uid, gid)

    # start mon service
    start_mon_service(distro, args.cluster, mon_index)
    time.sleep(2)

    # create client.admin.keyring file
    logger.info('create client.admin keyring file in : %s' % keyring)
    distro.conn.remote_module.create_client_admin_keyring(keyring, uid, gid)

    logger.info('unlinking keyring file %s' % keyring)
    distro.conn.remote_module.unlink(keyring)

def mon_add(distro, args, monitor_keyring, mon_index):
    mon_dir = '/Ceph/Data/Mon/mon.' + mon_index
    mk_mon_dir = 'mkdir -p %s' % mon_dir
    commands.getstatusoutput(mk_mon_dir)

    done_path = join(mon_dir, 'done')
    init_path = join(mon_dir, 'init')

    hostname = distro.conn.remote_module.shortname()
    logger = distro.conn.logger
    uid = distro.conn.remote_module.path_getuid(constants.base_path)
    gid = distro.conn.remote_module.path_getgid(constants.base_path)
    monmap_path = paths.mon.monmap(args.cluster, mon_index)

    conf_data = conf.ceph.load_raw(args)

    # write the configuration file
    distro.conn.remote_module.write_conf(
        args.cluster,
        conf_data,
        args.overwrite_conf,
    )

    # if the mon path does not exist, create it
    distro.conn.remote_module.create_mon_path(mon_dir, uid, gid)

    logger.debug('checking for done path: %s' % done_path)
    if not distro.conn.remote_module.path_exists(done_path):
        logger.debug('done path does not exist: %s' % done_path)
        if not distro.conn.remote_module.path_exists(paths.mon.constants.tmp_path):
            logger.info('creating tmp path: %s' % paths.mon.constants.tmp_path)
            distro.conn.remote_module.makedir(paths.mon.constants.tmp_path)
        keyring = paths.mon.keyring(args.cluster, hostname)

        logger.info('creating keyring file: %s' % keyring)
        distro.conn.remote_module.write_monitor_keyring(
            keyring,
            monitor_keyring,
            uid, gid,
        )

        # get the monmap
        remoto.process.run(
            distro.conn,
            [
                'ceph',
                '--cluster', args.cluster,
                'mon',
                'getmap',
                '-o',
                monmap_path,
            ],
        )

        # now use it to prepare the monitor's data dir
        user_args = []
        if uid != 0:
            user_args = user_args + [ '--setuser', str(uid) ]
        if gid != 0:
            user_args = user_args + [ '--setgroup', str(gid) ]

        remoto.process.run(
            distro.conn,
            [
                'ceph-mon',
                '--cluster', args.cluster,
                '--mkfs',
                '-i', mon_index,
                '--monmap',
                monmap_path,
                '--keyring', keyring,
            ] + user_args
        )

        logger.info('unlinking keyring file %s' % keyring)
        distro.conn.remote_module.unlink(keyring)

    # create the done file
    distro.conn.remote_module.create_done_path(done_path, uid, gid)

    # create init path
    distro.conn.remote_module.create_init_path(init_path, uid, gid)

    # start mon service
    start_mon_service(distro, args.cluster, mon_index)


def map_components(notsplit_packages, components):
    """
    Returns a list of packages to install based on component names

    This is done by checking if a component is in notsplit_packages,
    if it is, we know we need to install 'ceph' instead of the
    raw component name.  Essentially, this component hasn't been
    'split' from the master 'ceph' package yet.
    """
    packages = set()

    for c in components:
        if c in notsplit_packages:
            packages.add('ceph')
        else:
            packages.add(c)

    return list(packages)


def start_mon_service(distro, cluster, hostname):
    """
    start mon service depending on distro init
    """
    if distro.init == 'sysvinit':
        service = distro.conn.remote_module.which_service()
        remoto.process.run(
            distro.conn,
            [
                service,
                'ceph',
                '-c',
                '/etc/ceph/{cluster}.conf'.format(cluster=cluster),
                'start',
                'mon.{hostname}'.format(hostname=hostname)
            ],
            timeout=7,
        )
        system.enable_service(distro.conn)

    elif distro.init == 'upstart':
        remoto.process.run(
             distro.conn,
             [
                 'initctl',
                 'emit',
                 'ceph-mon',
                 'cluster={cluster}'.format(cluster=cluster),
                 'id={hostname}'.format(hostname=hostname),
             ],
             timeout=7,
         )

    elif distro.init == 'systemd':
       # enable ceph target for this host (in case it isn't already enabled)
        remoto.process.run(
            distro.conn,
            [
                'systemctl',
                'enable',
                'ceph.target'
            ],
            timeout=7,
        )

        # enable and start this mon instance
        remoto.process.run(
            distro.conn,
            [
                'systemctl',
                'enable',
                'ceph-mon@{hostname}'.format(hostname=hostname),
            ],
            timeout=7,
        )
        remoto.process.run(
            distro.conn,
            [
                'systemctl',
                'start',
                'ceph-mon@{hostname}'.format(hostname=hostname),
            ],
            timeout=7,
        )

def write_osd_data(hostname, public_ip, cluster_ip, disk, osd_no):
    '''write to local manager host where deph-deploy run ,default /root/ceph.conf'''
    osd_sec_name = 'osd.' + str(osd_no)
    if not conf_hd.has_section(osd_sec_name):
        conf_hd.add_section(osd_sec_name)

        osd_port = 6900 + int(osd_no)
        conf_hd.set(osd_sec_name, 'host', hostname)
        conf_hd.set(osd_sec_name, 'public addr', public_ip + ':' + str(osd_port))
        conf_hd.set(osd_sec_name, 'cluster addr', cluster_ip)

        conf_hd.set(osd_sec_name, 'osd journal size', '10000')

        ceph_osd_path = osd_path + 'osd-' + disk
        conf_hd.set(osd_sec_name, 'osd journal', ceph_osd_path + '/journal')
        conf_hd.set(osd_sec_name, 'osd data', ceph_osd_path)

        conf_write = open(ceph_conf_file, 'w')
        conf_hd.write(conf_write)
        conf_write.close()
    return
# hostname, pIP, cIP, disk, journal, strategy, mode, nvme_def_used, nvme_tt_nums, ssd_def_used,ssd_tt_used, hdd_def_used, hdd_tt_nums, cache_nums, cache_dis_type
def osd_create_all(distro, args, hostname, publicip, clusterip, disk, journal, strategy, mode, nvme_def_used, nvme_tt_nums, ssd_def_used,ssd_tt_used, hdd_def_used, hdd_tt_nums, cache_nums, cache_dis_type):
    logger = distro.conn.logger
    logger.info('start prepare osd on HOST : %s , pIP : %s , cIP : %s' % (hostname, publicip, clusterip))

    distro.conn.remote_module.create_osddisk_path(osddisk_path, scripts_path)
    # tar zxvf /etc/ceph/scripts.tar.gz
    distro.conn.remote_module.tar_scripts()

    # scan  host disks 
    # parted disks 
    # write journal data disk to /opt/ceph/f2fs/conf/osddisk
    distro.conn.remote_module.scan_new_disk(scripts_path, strategy, mode, nvme_def_used, nvme_tt_nums, ssd_def_used, ssd_tt_used,hdd_def_used, hdd_tt_nums, cache_nums, cache_dis_type)
    
    # wait for disk ready
    time.sleep(5)

    # mkf2fs and mount to point
    distro.conn.remote_module.prepare_osd_dir(scripts_path)

    disk_list = distro.conn.remote_module.get_osd_disk(osddisk_path)
    if not disk_list:
        logger.info('No disk ready on HOST : %s' % hostname)
    logger.info('The num of disk ready for osd is : %s' % len(disk_list))
    logger.debug('DISK : %s' % disk_list)

    osds = []
    for disk in disk_list:
        if disk:
            osd_num = distro.conn.remote_module.get_osd_num()
            logger.info('OSD.%s -->DISK: %s' % (osd_num, disk))
            logger.debug('start write local ceph.conf')
            write_osd_data(hostname, publicip, clusterip, disk, osd_num)
            logger.debug('start write /etc/ceph/ceph.conf on %s' % hostname)
            distro.conn.remote_module.add_osd_with_no(hostname, publicip, clusterip, disk, osd_num)
            try:
                logger.debug('start prepare osd')
                distro.conn.remote_module.prepare_osd_one(disk, osd_num, hostname)
                osds.append(osd_num)
            except Exception as e:
                logger.info('prepare osd.%s failed' % osd_num)
    if osds:
        try:
            logger.debug('start run osd')
            distro.conn.remote_module.start_osd(osds)
        except Exception as e:
            logger.info('start osd failed %s' % e)


def mgr_create(distro, mgr_name, path, hostname):
    logger = distro.conn.logger
    logger.info('start prepare mgr on HOST:%s ' % hostname)
    distro.conn.remote_module.make_mgr_key(mgr_name, path)