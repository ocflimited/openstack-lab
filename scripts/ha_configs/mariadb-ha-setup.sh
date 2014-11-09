#!/bin/bash

# Tested and confirmed on CentOS 7 x86_64

yum -y install mariadb-galera-server

MYSQL_PWD="password"

systemctl start mariadb
systemctl enable mariadb

mysqladmin password "${MYSQL_PWD}"
mysqladmin -h $HOSTNAME password "${MYSQL_PWD}"

crudini --set /etc/my.cnf.d/galera.cnf mysqld wsrep_sst_auth root:password

mysql --password="${MYSQL_PWD}" -e "SET wsrep_on=OFF; GRANT ALL ON *.* TO wsrep_sst@'%' IDENTIFIED BY 'wspass'";
mysql --password="${MYSQL_PWD}" -e "SET wsrep_on=OFF; DELETE FROM mysql.user WHERE user='';"

crudini --set /etc/my.cnf.d/galera.cnf mysqld query_cache_size 0
crudini --set /etc/my.cnf.d/galera.cnf mysqld binlog_format ROW
crudini --set /etc/my.cnf.d/galera.cnf mysqld default_storage_engine innodb
crudini --set /etc/my.cnf.d/galera.cnf mysqld innodb_autoinc_lock_mode 2
crudini --set /etc/my.cnf.d/galera.cnf mysqld innodb_doublewrite 1

crudini --set /etc/my.cnf.d/galera.cnf mysqld wsrep_provider /usr/lib64/galera/libgalera_smm.so

if [ $HOSTNAME = "stack01" ] then
  # stack01
  crudini --set /etc/my.cnf.d/galera.cnf mysqld wsrep_cluster_address gcomm://
elif [ $HOSTNAME = "stack02" ] then
  # stack02
  # TODO: check once stack01 is finished
  crudini --set /etc/my.cnf.d/galera.cnf mysqld wsrep_cluster_address gcomm://10.0.0.1,10.0.0.3
elif [ $HOSTNAME = "stack03" ] then
  # stack03
  # TODO: check once stack01 is finished
  crudini --set /etc/my.cnf.d/galera.cnf mysqld wsrep_cluster_address gcomm://10.0.0.1,10.0.0.2
fi

# Set the firewall
# mysql
firewall-cmd --permanent --add-service=mysql --zone=public
# galera
firewall-cmd --permanent --add-port=4567/tcp --zone=public
# galera rsync
firewall-cmd --permanent --add-port=4444/tcp --zone=public
# restart the firewall
firewall-cmd --reload

systemctl restart mariadb

if [ $HOSTNAME = "stack01" ] then
  # stack01
  # TODO: need to make sure that at least one of stack01 and stack02 are finished
  crudini --set /etc/my.cnf.d/galera.cnf mysqld wsrep_cluster_address gcomm://10.0.0.2,10.0.0.3
  systemctl restart mariadb
fi


