%define debug_package %{nil}

Name:           documentdb-gateway
Version:        DOCUMENTDB_VERSION
Release:        1%{?dist}
Summary:        DocumentDB Gateway - MongoDB wire protocol proxy

License:        MIT
URL:            https://github.com/microsoft/documentdb

%description
DocumentDB Gateway provides a MongoDB wire protocol proxy for DocumentDB,
enabling MongoDB-compatible connections to a PostgreSQL-backed DocumentDB instance.

%prep
# No source tarball; binary is pre-built in the Docker build environment.

%build
# Binary is already built.

%install
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/etc/documentdb
mkdir -p %{buildroot}/usr/lib/systemd/system
cp /home/documentdb/code/pg_documentdb_gw/target/release-with-symbols/documentdb_gateway %{buildroot}/usr/bin/documentdb_gateway
cp /home/documentdb/code/pg_documentdb_gw/SetupConfiguration.json %{buildroot}/etc/documentdb/SetupConfiguration.json
cp /home/documentdb/code/pg_documentdb_gw/documentdb_gateway/documentdb-gateway.service %{buildroot}/usr/lib/systemd/system/documentdb-gateway.service

%pre
getent group documentdb >/dev/null || groupadd -r documentdb
getent passwd documentdb >/dev/null || useradd -r -g documentdb -d /var/lib/documentdb -s /sbin/nologin -c "DocumentDB Gateway" documentdb
exit 0

%files
%defattr(-,root,root,-)
/usr/bin/documentdb_gateway
%config(noreplace) /etc/documentdb/SetupConfiguration.json
/usr/lib/systemd/system/documentdb-gateway.service

%changelog
