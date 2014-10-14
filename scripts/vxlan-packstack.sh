#!/bin/bash

PRIMARY_PUBIP=192.168.95.1
PRIMARY_PRIVIP=10.0.0.1
MASTER=10.0.0.251
NTP_SERVER=${MASTER}

packstack --gen-answer-file /root/packstack_answers.txt

cat > /tmp/sed.script << EOF
s/\(CONFIG_KEYSTONE_ADMIN_PW=\).*/\1openstack/g
s/\(CONFIG_HEAT_INSTALL=\).*/\1y/g
s/\(CONFIG_NTP_SERVERS=\).*/\1${NTP_SERVER}/g
s/\(CONFIG_HEAT_CFN_INSTALL=\).*/\1y/g

s/\(CONFIG_COMPUTE_HOSTS=\).*/\110.0.0.4,10.0.0.5,10.0.0.6,10.0.0.7,10.0.0.8,10.0.0.9/g

s/\(CONFIG_USE_EPEL=\).*/\1n/g
s/\(CONFIG_NEUTRON_OVS_BRIDGE_MAPPINGS=\).*/\1physnet_mgmt:br-mgmt/g
s/\(CONFIG_NEUTRON_OVS_BRIDGE_IFACES=\).*/\1br-mgmt:enp2s1f0/g
s/\(CONFIG_PROVISION_DEMO=\).*/\1n/g
EOF

sed -i -f /tmp/sed.script /root/packstack_answers.txt

packstack --answer-file /root/packstack_answers.txt

crudini --set --existing /etc/heat/heat.conf DEFAULT heat_metadata_server_url http://${PRIMARY_PUBIP}:8000
crudini --set --existing /etc/heat/heat.conf DEFAULT heat_waitcondition_server_url http://${PRIMARY_PUBIP}:8000/v1/waitcondition

sed -i -e '/^osapi_compute_extension/d' /etc/nova/nova.conf
crudini --set /etc/nova/nova.conf DEFAULT osapi_compute_ext_list nova.api.openstack.compute.contrib.select_extensions
crudini --set /etc/nova/nova.conf DEFAULT osapi_compute_extension nova.api.openstack.compute.contrib.standard_extensions
sed -i -e 's/^\(osapi_compute_extension.*\)/\1\nosapi_compute_extension = nova.api.openstack.compute.contrib.extended_server_attributes/g' /etc/nova/nova.conf

openstack-service restart

#
# Begin -- Do this on xCAT MN
#
cat > /tmp/sed.script << EOF
/^osapi_compute_extension/d
EOF
xdcp nova /tmp/sed.script /tmp/
xdsh nova sed -i -f /tmp/sed.script /etc/nova/nova.conf

xdsh nova crudini --set /etc/nova/nova.conf DEFAULT osapi_compute_ext_list nova.api.openstack.compute.contrib.select_extensions
xdsh nova crudini --set /etc/nova/nova.conf DEFAULT osapi_compute_extension nova.api.openstack.compute.contrib.standard_extensions

cat > /tmp/sed.script << EOF
s/^\(osapi_compute_extension.*\)/\1\nosapi_compute_extension = nova.api.openstack.compute.contrib.extended_server_attributes/g
EOF
xdcp nova /tmp/sed.script /tmp/
xdsh nova sed -i -f /tmp/sed.script /etc/nova/nova.conf

xdsh nova openstack-service restart
#
# End -- Do this on xCAT MN
#

. /root/keystonerc_admin
neutron net-create ext_net --router:external=True
neutron subnet-create --name ext_subnet --disable-dhcp ext_net 192.168.80.0/20 \
   --gateway 192.168.95.254 --allocation-pool start=192.168.81.1,end=192.168.94.255

wget http://${MASTER}/install/data/openstack/images/cirros-0.3.3-x86_64-disk.img

glance image-create --name cirros --is-public=True --disk-format=qcow2 \
   --container-format=bare --disk-format=qcow2 --file /root/cirros-0.3.3-x86_64-disk.img

keystone tenant-create --name demo
keystone user-create --name demo --pass demo
keystone user-role-add --user demo --role _member_ --tenant demo
keystone user-role-add --user demo --role heat_stack_owner --tenant demo

tenant=$(keystone tenant-list | awk '/demo/ {print $2}')

nova quota-update --instances 500 --cores 500 $tenant
neutron quota-update --floatingip 500 --security-group 500 --security-group-rule 500 --port 500 --router 50 --subnet 50 --net 50  --tenant-id=$tenant

nova flavor-create hpc_node auto 2048 10 1

cat > /root/keystonerc_demo << EOF
export OS_USERNAME=demo
export OS_TENANT_NAME=demo
export OS_PASSWORD=demo
export OS_AUTH_URL=http://${PRIMARY_PRIVIP}:5000/v2.0/
export PS1='[\u@\h \W(keystone_demo)]\$ '
EOF

. /root/keystonerc_demo

ssh-keygen -t rsa -b 4096 -N '' -f /root/id_rsa_demo
nova keypair-add --pub-key /root/id_rsa_demo.pub demo_key

neutron net-create stack_net_priv
neutron subnet-create --name stack_subnet_priv --dns-nameserver 8.8.8.8 stack_net_priv 10.0.8.0/24

neutron router-create extnet_stackrouter
neutron router-gateway-set extnet_stackrouter ext_net
neutron router-interface-add extnet_stackrouter stack_subnet_priv

neutron security-group-rule-create --protocol tcp --port-range-min 22 --port-range-max 22 default
neutron security-group-rule-create --protocol icmp default

subnet_id=$(neutron subnet-show stack_subnet_priv | grep network_id | awk '{print $4}')

nova boot --poll --flavor m1.tiny --image cirros --nic net-id=${subnet_id} --key-name demo_key --min-count 8 test0

for i in `seq 1 8`
do
   nova floating-ip-create ext_net
done


