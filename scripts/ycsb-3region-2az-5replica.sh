export f=robert-ycsb-3d2z5r
export ver=v19.1.1
export branch=master
export _crdb_replicas=5
export _ycsb_replicas=5
export _ycsb_insertcount=100000
export COCKROACH_DEV_ORG='Cockroach Labs Training'
export COCKROACH_DEV_LICENSE='crl-0-EIDA4OgGGAEiF0NvY2tyb2FjaCBMYWJzIFRyYWluaW5n'

# 3 DC - 3 AZ per DC 5 way replicas
roachprod create $f --geo --gce-zones \
europe-west1-b,europe-west2-a,europe-west3-a,europe-west1-c,europe-west2-c,europe-west3-b \
-n 6 --local-ssd-no-ext4-barrier 

# use ycsb-roachprod.sh from here on down
