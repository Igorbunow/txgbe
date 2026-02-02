#
# spec file for package txgbe (Version 1.3.6)
#
# Copyright (c) 2018 SUSE LINUX Products GmbH, Nuernberg, Germany.
#
# All modifications and additions to the file contributed by third parties
# remain the property of their copyright owners, unless otherwise agreed
# upon. The license for this file, and modifications and additions to the
# file, is the same license as for the pristine package itself (unless the
# license for the pristine package is not an Open Source License, in which
# case the license is the MIT License). An "Open Source License" is a
# license that conforms to the Open Source Definition (Version 1.9)
# published by the Open Source Initiative.

# Please submit bugfixes or comments via http://support.novell.com
#



Name:           txgbe
Summary:        Wangxun 10 Gigabit Ethernet driver
Version:        1.3.6
Release:        1
Source0:        txgbe-%{version}.tar.bz2
Source1:        preamble
License:        GPL-2.0
Group:          System/Kernel
BuildRequires:  %kernel_module_package_buildreqs
BuildRequires:  pciutils-ids
Requires:       pciutils-ids
BuildRoot:      %{_tmppath}/%{name}-%{version}-build

%kernel_module_package -p %_sourcedir/preamble

%description
This driver supports Wangxun 10 gigabit ethernet family of
adapters.  For more information on how to identify your adapter, go
to the Adapter & Driver ID Guide at:

%package KMP  
  
Summary:     Wangxun 10 Gigabit Ethernet driver
Group:       System/Kernel  

%description KMP
This driver supports Wangxun 10 gigabit ethernet family of
adapters.  For more information on how to identify your adapter, go
to the Adapter & Driver ID Guide at:

%prep
%setup -n txgbe-%{version}
set -- *
mv src source
echo "txgbe.ko external" > source/Module.supported
mkdir obj

%build
export EXTRA_CFLAGS+='-DVERSION=\"%version\"'
for flavor in %flavors_to_build; do
    rm -rf obj/$flavor
    cp -r source obj/$flavor
    make -C %{kernel_source $flavor} modules M=$PWD/obj/$flavor
done

%install
export INSTALL_MOD_PATH=$RPM_BUILD_ROOT
export INSTALL_MOD_DIR=%{kernel_module_package_moddir %name}
for flavor in %flavors_to_build; do
    make -C %{kernel_source $flavor} modules_install M=$PWD/obj/$flavor
done

mkdir -p $RPM_BUILD_ROOT/usr/share/pci.ids.d
install -D -m 644 pci.updates $RPM_BUILD_ROOT/usr/share/pci.ids.d/pci.ids.txgbe-%{version}

mkdir -p $RPM_BUILD_ROOT/%{_mandir}/man7
install -m 644 -D txgbe.7 $RPM_BUILD_ROOT/%{_mandir}/man7
gzip -9nf $RPM_BUILD_ROOT/%{_mandir}/man?/*.?

chmod -x COPYING README

%clean
rm -rf %{buildroot}

%files 
%defattr(-,root,root)
%{_mandir}/man7/txgbe.7.gz
/usr/share/pci.ids.d/pci.ids.txgbe-%{version}
%doc COPYING 
%doc README

%post 
if [ -x /usr/bin/merge-pciids -a -x /usr/bin/perl ]; then
  /usr/bin/merge-pciids
else
  echo "ERROR: merge-pciids or perl not found"
fi

%post KMP
modprobe txgbe

%postun
if [ -x /usr/bin/merge-pciids -a -x /usr/bin/perl ]; then
  /usr/bin/merge-pciids
else
  echo "ERROR: merge-pciids or perl not found"
fi

%changelog

