import logging
import os

from ceph_deploy import conf
from ceph_deploy import exc
from ceph_deploy import hosts
from ceph_deploy.util import system
from ceph_deploy.lib import remoto
from ceph_deploy.cliutil import priority
# try:
#     import configparser
# except ImportError:
#     import ConfigParser as configparser
import ConfigParser

LOG = logging.getLogger(__name__)

ceph_conf_file = '/root/ceph.conf'
conf_hd = ConfigParser.ConfigParser()
conf_hd.read(ceph_conf_file)

def get_bootstrap_mgr_key(cluster):
    """
    Read the bootstrap-mgr key for `cluster`.
    """
    path = '{cluster}.bootstrap-mgr.keyring'.format(cluster=cluster)
    try:
        with open(path, 'rb') as f:
            return f.read()
    except IOError:
        raise RuntimeError('bootstrap-mgr keyring not found; run \'gatherkeys\'')


def create_mgr(distro, name, cluster, init):
    conn = distro.conn

    path = '/Ceph/Data/Mgr/{cluster}-{name}'.format(
        cluster=cluster,
        name=name
        )

    conn.remote_module.safe_mkdir(path)

    bootstrap_keyring = '/Ceph/Data/Mgr/{cluster}.keyring'.format(
        cluster=cluster
        )

    keypath = os.path.join(path, 'keyring')

    stdout, stderr, returncode = remoto.process.check(
        conn,
        [
            'ceph',
            '--cluster', cluster,
            '--name', 'client.bootstrap-mgr',
            '--keyring', bootstrap_keyring,
            'auth', 'get-or-create', 'mgr.{name}'.format(name=name),
            'mon', 'allow profile mgr',
            'osd', 'allow *',
            'mds', 'allow *',
            '-o',
            os.path.join(keypath),
        ]
    )
    LOG.info("---stdout:%s, stderr:%s, returncode:%s---", stdout, stderr, returncode)
    if returncode > 0:
        for line in stderr:
            conn.logger.error(line)
        for line in stdout:
            # yes stdout as err because this is an error
            conn.logger.error(line)
        conn.logger.error('exit code from command was: %s' % returncode)
        raise RuntimeError('could not create mgr')

    conn.remote_module.touch_file(os.path.join(path, 'done'))
    conn.remote_module.touch_file(os.path.join(path, init))

    if init == 'upstart':
        remoto.process.run(
            conn,
            [
                'initctl',
                'emit',
                'ceph-mgr',
                'cluster={cluster}'.format(cluster=cluster),
                'id={name}'.format(name=name),
            ],
            timeout=7
        )
    elif init == 'sysvinit':
        remoto.process.run(
            conn,
            [
                'service',
                'ceph',
                'start',
                'mgr.{name}'.format(name=name),
            ],
            timeout=7
        )
        if distro.is_el:
            system.enable_service(distro.conn)
    elif init == 'systemd':
        remoto.process.run(
            conn,
            [
                'systemctl',
                'enable',
                'ceph-mgr@{name}'.format(name=name),
            ],
            timeout=7
        )
        remoto.process.run(
            conn,
            [
                'systemctl',
                'start',
                'ceph-mgr@{name}'.format(name=name),
            ],
            timeout=7
        )
        remoto.process.run(
            conn,
            [
                'systemctl',
                'enable',
                'ceph.target',
            ],
            timeout=7
        )


def mgr_create(args):
    LOG.debug(
        'Deploying mgr, cluster %s hosts %s',
        args.cluster,
        ' '.join(':'.join(x or '' for x in t) for t in args.mgr),
    )
    # add mgr conf to controler's ceph.conf
    sections = conf_hd.sections()
    mgrname_hostname = {}
    for sec in sections:
        if not sec.startswith("mon."):
            continue
        else:
            hostname = conf_hd.get(sec, 'host')
            if not hostname:
                continue
            mgr_sec_name = 'mgr.' + sec.split('.')[1]
            mgrname_hostname[hostname] = mgr_sec_name
            conf_hd.add_section(mgr_sec_name)
            conf_hd.set(mgr_sec_name, 'host', hostname)
            conf_write = open(ceph_conf_file, 'w')
            conf_hd.write(conf_write)
            conf_write.close()
    conf_data = conf.ceph.load_raw(args)
    # key = get_bootstrap_mgr_key(cluster=args.cluster)

    bootstrapped = set()
    errors = 0
    LOG.info("---mgr_create====>args:%s------", args)

    for hostname, name in args.mgr:
        try:
            distro = hosts.get(hostname, username=args.username)
            rlogger = distro.conn.logger
            LOG.info(
                'Distro info: %s %s %s',
                distro.name,
                distro.release,
                distro.codename
            )

            LOG.debug('remote host will use %s', distro.init)

            if hostname not in bootstrapped:
                bootstrapped.add(hostname)
                LOG.debug('deploying mgr bootstrap to %s', hostname)
                distro.conn.remote_module.write_conf(
                    args.cluster,
                    conf_data,
                    args.overwrite_conf,
                )
                mgr_name = None
                LOG.info("-----mgrname_and_hostname:%s-----" % mgrname_hostname)
                for hname in mgrname_hostname:
                    if hostname == hname:
                        mgr_name = mgrname_hostname[hname]

                LOG.info("======================mgr_name:%s=======" % mgr_name)
                path = '/Ceph/Data/Mgr/{mgr_sec_name}'.format(
                    mgr_sec_name=mgr_name,
                )
                LOG.info("++++++++path:%s++++++++++++++" % path)

                # if not distro.conn.remote_module.path_exists(path):
                # rlogger.warning('mgr keyring does not exist yet, creating one')
                # distro.conn.remote_module.write_keyring(path, key)

                distro.mon.create_mgr(distro, mgr_name, path, hostname)
                # distro.conn.remote_module.make_mgr_key(mgr_name, path)
                LOG.info("==============after remote path=============")
                # create_mgr(distro, name, args.cluster, distro.init)
                distro.conn.exit()
        except Exception as e:
            LOG.error(e)
            errors += 1

    if errors:
        raise exc.GenericError('Failed to create %d MGRs' % errors)


def mgr(args):
    if args.subcommand == 'create':
        mgr_create(args)
    else:
        LOG.error('subcommand %s not implemented', args.subcommand)


def colon_separated(s):
    host = s
    name = s
    if s.count(':') == 1:
        (host, name) = s.split(':')
    return (host, name)


@priority(30)
def make(parser):
    """
    Ceph MGR daemon management
    """
    mgr_parser = parser.add_subparsers(dest='subcommand')
    mgr_parser.required = True

    mgr_create = mgr_parser.add_parser(
        'create',
        help='Deploy Ceph MGR on remote host(s)'
    )
    mgr_create.add_argument(
        'mgr',
        metavar='HOST[:NAME]',
        nargs='+',
        type=colon_separated,
        help='host (and optionally the daemon name) to deploy on',
        )
    parser.set_defaults(
        func=mgr,
        )
