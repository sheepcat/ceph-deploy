#
# spec file for package ceph-deploy
#

%if ! (0%{?fedora} > 12 || 0%{?rhel} > 5)
%{!?python_sitelib: %global python_sitelib %(%{__python} -c "from distutils.sysconfig import get_python_lib; print(get_python_lib())")}
%{!?python_sitearch: %global python_sitearch %(%{__python} -c "from distutils.sysconfig import get_python_lib; print(get_python_lib(1))")}
%endif

#################################################################################
# common
#################################################################################
Name:           ceph-deploy
Version:       1.5.39
Release:        0
Summary:        Admin and deploy tool for Ceph
License:        MIT
Group:          System/Filesystems
URL:            http://ceph.com/
Source0:        %{name}-%{version}.tar.bz2
BuildRoot:      %{_tmppath}/%{name}-%{version}-build
BuildRequires:  python-devel
BuildRequires:  python-setuptools
BuildRequires:  python-virtualenv
BuildRequires:  python-mock
BuildRequires:  python-tox
%if 0%{?suse_version}
BuildRequires:  python-pytest
%else
BuildRequires:  pytest
%endif
BuildRequires:  git
Requires:       python-argparse
#Requires:      lsb-release
#Requires:      ceph
%if 0%{?suse_version} && 0%{?suse_version} <= 1110
%{!?python_sitelib: %global python_sitelib %(python -c "from distutils.sysconfig import get_python_lib; print get_python_lib()")}
%else
BuildArch:      noarch
%endif

#################################################################################
# specific
#################################################################################
%if 0%{defined suse_version}
%py_requires
%endif
# _sysconfdir   /etc
# _shelldir /opt/ceph/scripts/
%description
An easy to use admin tool for deploy ceph storage clusters.

%prep
#%%setup -q -n %%{name}
%setup -q

%build
#python setup.py build

%install
python setup.py install --prefix=%{_prefix} --root=%{buildroot}
install -m 0755 -D scripts/ceph-deploy $RPM_BUILD_ROOT/usr/bin
install -m 0755 -D osd_script/ini-config %{buildroot}%{_sysconfdir}/ceph/scripts/ini-config
install -m 0755 -D osd_script/parallel_mkf2fs.sh %{buildroot}%{_sysconfdir}/ceph/scripts/parallel_mkf2fs.sh
install -m 0755 -D osd_script/prepareOsd_new.sh %{buildroot}%{_sysconfdir}/ceph/scripts/prepareOsd_new.sh
install -m 0755 -D osd_script/serial_mount.sh %{buildroot}%{_sysconfdir}/ceph/scripts/serial_mount.sh
install -m 0755 -D osd_script/disk_fs_mgmt.sh %{buildroot}%{_sysconfdir}/ceph/scripts/disk_fs_mgmt.sh
install -m 0755 -D osd_script/mount.sh %{buildroot}%{_sysconfdir}/ceph/scripts/mount.sh
install -m 0755 -D osd_script/tune.sh %{buildroot}%{_sysconfdir}/ceph/scripts/tune.sh

%clean
[ "$RPM_BUILD_ROOT" != "/" ] && rm -rf "$RPM_BUILD_ROOT"

%files
%defattr(-,root,root)
%doc LICENSE README.rst
%{_bindir}/ceph-deploy
%{_sysconfdir}/ceph/scripts/ini-config
%{_sysconfdir}/ceph/scripts/parallel_mkf2fs.sh
%{_sysconfdir}/ceph/scripts/prepareOsd_new.sh
%{_sysconfdir}/ceph/scripts/serial_mount.sh
%{_sysconfdir}/ceph/scripts/disk_fs_mgmt.sh
%{_sysconfdir}/ceph/scripts/mount.sh
%{_sysconfdir}/ceph/scripts/tune.sh
%{_sysconfdir}/ceph/scripts/*
%{python_sitelib}/*


%changelog
