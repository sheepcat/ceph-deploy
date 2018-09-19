import logging
import os.path
import ConfigParser
import commands

from ceph_deploy import exc
from ceph_deploy import conf
from ceph_deploy.cliutil import priority
from ceph_deploy import hosts

LOG = logging.getLogger(__name__)


def config_push(args):
    conf_data = conf.ceph.load_raw(args)

    errors = 0
    for hostname in args.client:
        LOG.debug('Pushing config to %s', hostname)
        try:
            distro = hosts.get(hostname, username=args.username)

            distro.conn.remote_module.write_conf(
                args.cluster,
                conf_data,
                args.overwrite_conf,
            )

            distro.conn.exit()

        except RuntimeError as e:
            LOG.error(e)
            errors += 1

    if errors:
        raise exc.GenericError('Failed to config %d hosts' % errors)
    ''' start osd that sync in verify process '''
    osds = []
    if os.path.exists('/root/osds'):
        with open('/root/osds','r') as f:
            osds = f.readline()
        cmd = '/etc/init.d/ceph -a -c /etc/ceph/ceph.conf start %s' % osds.strip('\n')
        LOG.debug("excute: %s", cmd)
        (ret ,msg) = commands.getstatusoutput(cmd)
        os.unlink('/root/osds')

def merge_conf(remote_conf, local_conf):
    remote_conf_sections = []
    local_conf_sections = []
    diff_sections = []

    remote_conf_hd = ConfigParser.ConfigParser()
    remote_conf_hd.read(remote_conf)

    local_conf_hd = ConfigParser.ConfigParser()
    local_conf_hd.read(local_conf)

    remote_conf_sections = remote_conf_hd.sections()
    local_conf_sections = local_conf_hd.sections()

    for sec in remote_conf_sections:
        if sec not in local_conf_sections:
            diff_sections.append(sec)

    for section in diff_sections:
        if not local_conf_hd.has_section(section):
            local_conf_hd.add_section(section)
            items = remote_conf_hd.items(section)
            for item in items:
                local_conf_hd.set(section, item[0], item[1])
            data = open(local_conf,'w')
            local_conf_hd.write(data)
            data.close()

    return

def verify_conf(conn):
    osd_bfile = '/root/ceph.conf.1'
    local_file = '/etc/ceph/ceph.conf'

    osd_bfile_secs = []
    local_file_secs = []
    diff_secs = []

    if conn.remote_module.exist_file(osd_bfile):
        osd_bfile_content = conn.remote_module.get_file(osd_bfile)
        ''' pull remote file to local ,named ceph.conf.1 '''
        with open(osd_bfile, 'wb') as f:
            f.write(osd_bfile_content)

        local_file_hd = ConfigParser.ConfigParser()
        local_file_hd.read(local_file)
        local_file_secs = local_file_hd.sections()
        osd_bfile_hd = ConfigParser.ConfigParser()
        osd_bfile_hd.read(osd_bfile)
        osd_bfile_secs = osd_bfile_hd.sections()

        for sec in osd_bfile_secs:
            if sec not in local_file_secs:
                diff_secs.append(sec)
        if diff_secs:
            LOG.debug("Start Verify ConfigFile")
            f = open('/root/osds', 'wa')
            for secs in diff_secs:
                f.write(secs+' ')
                if not local_file_hd.has_section(secs):
                    local_file_hd.add_section(secs)
                    items = osd_bfile_hd.items(secs)
                    for item in items:
                        local_file_hd.set(secs, item[0], item[1])
                    data = open(local_file, 'w')
                    local_file_hd.write(data)
                    data.close()
            f.close()
    return

def config_pull(args):

    topath = '{cluster}.conf.tmp'.format(cluster=args.cluster)
    frompath = '/etc/ceph/{cluster}.conf'.format(cluster=args.cluster)

    errors = 0
    for hostname in args.client:
        try:
            LOG.debug('Checking %s for %s', hostname, frompath)
            distro = hosts.get(hostname, username=args.username)
            conf_file_contents = distro.conn.remote_module.get_file(frompath)

            if conf_file_contents is not None:
                LOG.debug('Got %s from %s', frompath, hostname)
                if os.path.exists(topath):
                    with open(topath, 'rb') as f:
                        existing = f.read()
                        if existing != conf_file_contents and not args.overwrite_conf:
                            LOG.error('local config file %s exists with different content; use --overwrite-conf to overwrite' % topath)
                            raise

                with open(topath, 'wb') as f:
                    f.write(conf_file_contents)
                merge_conf(topath, frompath)
                ''' 
                   verify osd config data,
                   that`s needed when ceph-deploy tools run in each ceph-hosts 
                '''
                #verify_conf(distro.conn)
                return
            distro.conn.exit()
            LOG.debug('Empty or missing %s on %s', frompath, hostname)
        except:
            LOG.error('Unable to pull %s from %s', frompath, hostname)
        finally:
            errors += 1

    raise exc.GenericError('Failed to fetch config from %d hosts' % errors)


def config(args):
    if args.subcommand == 'push':
        config_push(args)
    elif args.subcommand == 'pull':
        config_pull(args)
    else:
        LOG.error('subcommand %s not implemented', args.subcommand)


@priority(70)
def make(parser):
    """
    Copy ceph.conf to/from remote host(s)
    """
    config_parser = parser.add_subparsers(dest='subcommand')
    config_parser.required = True

    config_push = config_parser.add_parser(
        'push',
        help='push Ceph config file to one or more remote hosts'
        )
    config_push.add_argument(
        'client',
        metavar='HOST',
        nargs='+',
        help='host(s) to push the config file to',
        )

    config_pull = config_parser.add_parser(
        'pull',
        help='pull Ceph config file from one or more remote hosts'
        )
    config_pull.add_argument(
        'client',
        metavar='HOST',
        nargs='+',
        help='host(s) to pull the config file from',
        )
    parser.set_defaults(
        func=config,
        )
