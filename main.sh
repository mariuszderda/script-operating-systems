#!/usr/bin/bash

if [[ $UID -ne 0 ]]; then
    echo "Skrypt musi być uruchomiony jako root."
    exit 1
fi

echo "$(tput setaf 2)Aktualizacja systemu$(tput sgr 0)"
dnf update -y || { echo "Aktualizacja systemu nie powiodła się."; exit 1; }

echo "$(tput setaf 2)Instalowanie pakietów httpd mariadb php php-mysqlnd php-fpm php-common firewalld$(tput sgr 0)"
dnf install -y httpd mariadb-server php php-mysqlnd php-fpm php-common firewalld || { echo "Instalacja pakietów nie powiodła się."; exit 1; }

echo "$(tput setaf 2)Konfiguracja MariaDB$(tput sgr 0)"
systemctl start mariadb || { echo "Uruchomienie MariaDB nie powiodło się."; exit 1; }
systemctl enable mariadb || { echo "Automatyczne uruchamianie MariaDB nie powiodło się."; exit 1; }
mysql_secure_installation || { echo "Konfiguracja MariaDB nie powiodła się."; exit 1; }

read -p "Podaj nazwę użytkownika bazy danych: " DB_USER
read -s -p "Podaj hasło dla użytkownika bazy danych: " DB_PASSWORD
echo ""
read -p "Podaj nazwę bazy danych: " DB_NAME

mysql -e "CREATE DATABASE ${DB_NAME};" || { echo "Utworzenie bazy danych nie powiodło się."; exit 1; }
mysql -e "CREATE USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';" || { echo "Utworzenie użytkownika bazy danych nie powiodło się."; exit 1; }
mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';" || { echo "Nadanie uprawnień użytkownikowi bazy danych nie powiodło się."; exit 1; }

read -e -p "Podaj nazwę domeny (domyślnie: localhost): " -i "localhost" DOMAIN

echo "$(tput setaf 2)Konfiguracja serwera$(tput sgr 0)"
WEB_ROOT="/var/www/html/${DOMAIN}"
mkdir -p "${WEB_ROOT}" || { echo "Utworzenie katalogu dla strony nie powiodło się."; exit 1; }
chown -R apache:apache "${WEB_ROOT}"
chmod 755 "${WEB_ROOT}"

cat > /etc/httpd/conf.d/virtualhost.conf <<EOF
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN}
    DocumentRoot "${WEB_ROOT}"
    ErrorLog /var/log/httpd/${DOMAIN}-error.log
    CustomLog /var/log/httpd/${DOMAIN}-access.log combined

    <Directory "${WEB_ROOT}">
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF

echo "$(tput setaf 2)Uruchomienie i włączenie usługi httpd$(tput sgr 0)"
systemctl restart httpd || { echo "Uruchomienie Apache nie powiodło się."; exit 1; }
systemctl enable httpd || { echo "Automatyczne uruchamianie Apache nie powiodło się."; exit 1; }

echo "$(tput setaf 2)Tworzenie prostej strony www$(tput sgr 0)"
cat > /var/www/html/${DOMAIN}/index.php << EOF
<?php
echo nl2br("Witaj na Twoim serwerze! \n");
echo nl2br("Adres strony: http://${DOMAIN}\n");
echo nl2br("Aby pokazać, że php zaintalowało się poprawnie wyświetlono komunikat phpinfo()\n");
phpinfo();
?>
EOF

echo "$(tput setaf 2)Konfiguracja firewall$(tput sgr 0)"
firewall-cmd --permanent --zone=public --add-service=http || { echo "Konfiguracja firewalla nie powiodła się."; exit 1; }
firewall-cmd --permanent --zone=public --add-service=https || { echo "Konfiguracja firewalla nie powiodła się."; exit 1; }
firewall-cmd --reload || { echo "Ponowne załadowanie firewalla nie powiodło się."; exit 1; }

echo "Serwer WWW został skonfigurowany.
Aby uzyskać dostęp do strony, przejdź do http://www.${DOMAIN}"

echo "$(tput setaf 2)Tunnig systemu$(tput sgr 0)"
DISABLE_SERVICES=(
  avahi-daemon
  cups
  postfix
)
for service in "${DISABLE_SERVICES[@]}"; do
  if systemctl list-unit-files | grep -q "^${service}\\.service"; then
    systemctl disable --now "${service}"
  fi
done

echo -e "* soft nofile 65536\n* hard nofile 65536" >> /etc/security/limits.conf

sysctl -w vm.swappiness=10
sysctl -w vm.vfs_cache_pressure=50
sysctl -w net.ipv4.tcp_keepalive_probes=3
sysctl -w net.ipv4.tcp_congestion_control=cubic
sysctl -w net.ipv4.tcp_slow_start_after_idle=0

echo '
vm.swappiness=10
vm.vfs_cache_pressure=50
net.ipv4.tcp_keepalive_probes=3
net.ipv4.tcp_congestion_control=cubic
net.ipv4.tcp_slow_start_after_idle=0
vm.min_free_kbytes=1024
' >> /etc/sysctl.conf

sysctl -p /etc/sysctl.conf

sysctl -w net.ipv4.tcp_fin_timeout=30
sysctl -w net.ipv4.tcp_keepalive_time=1200

cp /etc/httpd/conf/httpd.conf /etc/httpd/conf/httpd.conf.bak
cp /etc/my.cnf /etc/my.cnf.bak

sed -i '/<IfModule prefork.c>/,/<\/IfModule>/c\
<IfModule prefork.c>\
    StartServers        4\
    MinSpareServers     2\
    MaxSpareServers     8\
    ServerLimit         256\
    MaxClients          256\
    MaxRequestsPerChild 4000\
</IfModule>' /etc/httpd/conf.modules.d/00-mpm.conf

cat > /etc/my.cnf.d/custom.cnf <<EOF
[mysqld]
key_buffer_size = 128M
query_cache_size = 64M
innodb_buffer_pool_size = 1G
innodb_flush_log_at_trx_commit = 2
EOF

sed -i 's/^;date.timezone =/date.timezone = Europe\/Warsaw/' /etc/php.ini

echo "$(tput setaf 2)Ponowne uruchonienie httpd oraz mariaDB$(tput sgr 0)"
systemctl restart httpd || { echo "Ponowne uruchomienie Apache nie powiodło się."; exit 1; }
systemctl restart mysqld || { echo "Ponowne uruchomienie MariaDB nie powiodło się."; exit 1; }
echo ""
echo "$(tput setaf 2)****************************************$(tput sgr 0)"
echo "$(tput setaf 2)***** Skrypt wykonał się poprawnie *****$(tput sgr 0)"
echo "$(tput setaf 2)*****   Możesz przejść na stronę   *****$(tput sgr 0)"
echo "$(tput setaf 2)*****       https://${DOMAIN}      *****$(tput sgr 0)"
echo "$(tput setaf 2)****************************************$(tput sgr 0)"
