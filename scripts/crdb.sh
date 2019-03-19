# utility function to spin up CRDB with localities
#  pg and admin port numbers will start from 26257 and 26258 
#
# examples to setup one instance per region
#   _crdb_destroy; _crdb cloud=aws,region=us-east-1 cloud=aws,region=ca-central-1 cloud=aws,region=us-west-1
#   _crdb_destroy; _crdb cloud=gcp,region=us-east1 cloud=gcp,region=us-central1 cloud=gcp,region=us-west1
#   _crdb_destroy; _crdb cloud=azure,region=eastus cloud=azure,region=centralus cloud=azure,region=westus
# examples to setup without locality
#   _crdb; _crdb; _crdb
_crdb() {
  _crdb_instance=${_crdb_instance:-1}
  local _crdb_port=${_crdb_port:-26257}
  local _crdb_http_port=${_crdb_http_port:-26258}
  local _crdb_locality
  local _crdb_join
  local _crdb_count
  local _port
  local _http_port
  local _loc

  while [ 1 ]; do
    _loc=$1
    _crdb_count=$(($_crdb_instance-1))
    _port=$(($_crdb_port + $_crdb_count * 2))
    _http_port=$(($_crdb_http_port + $_crdb_count * 2))

    # locality and join command options
    if [ ! -z "$_loc" ]; then _crdb_locality="--locality=$_loc"; fi
    if [ "$_crdb_instance" != "1" ]; then 
      _crdb_join="--join=localhost:$_crdb_port"
    fi

    # start the process
    cockroach start --insecure --port=${_port} --http-port=${_http_port} --store=cockroach-data/${_crdb_instance} --cache=256MiB --background $_crdb_join $_crdb_locality
    echo "${_port} ${_http_port} $_crdb_join $_crdb_locality" > /tmp/_crdb.pid.${_crdb_instance}

    # set the license if available
    if [ "$_crdb_instance" = "1" -a ! -z "$COCKROACH_DEV_ORG" -a ! -z "$COCKROACH_DEV_LICENSE" ]; then 
      sleep 2
      cockroach sql --insecure --port=${_port} -e "set cluster setting cluster.organization='$COCKROACH_DEV_ORG'; set cluster setting enterprise.license='$COCKROACH_DEV_LICENSE';"
    fi

    # next instance number
    ((_crdb_instance=$_crdb_instance+1))
    echo "next instance = $_crdb_instance"
    shift 
    if [ -z "$1" ]; then break; fi
    sleep 1
  done
}

# stop and restart by looking at /_crdb.pid.instance_number
# $1 = instance number (1 - n)
_crdb_stop () {
  cat /tmp/_crdb.pid.$1 | while read _port _http_port _crdb_join _crdb_locality; do
    cockroach quit --insecure --port=${_port}
  done
}

_crdb_restart () {
  cat /tmp/_crdb.pid.$1 | while read _port _http_port _crdb_join _crdb_locality; do
    cockroach start --insecure --port=${_port} --http-port=${_http_port} --store=cockroach-data/${1} --cache=256MiB --background $_crdb_join $_crdb_locality
  done
}

# kill and destroy data files
_crdb_destroy () {
  unset _crdb_instance
  pkill -9 roach
  sleep 5
  rm -rf cockroach-data/
  rm -rf /tmp/_crdb.pid.*
}

# set the number of replicas
_crdb_replica () {
    cockroach sql --insecure -e "ALTER RANGE default CONFIGURE ZONE USING num_replicas=${1:-3};"

    echo "Making sure there are no ranges underreplicated"
    ranges_underreplicated=`curl -s http://localhost:26258/_status/vars | grep "^ranges_underreplicated" | grep -v ".* 0\.0$" | wc -l`
    while [ $ranges_underreplicated -gt 0 ]; do
      echo "$ranges_underreplicated waiting for 10 sec to catch up"
      sleep 10
      ranges_underreplicated=`curl -s http://localhost:26258/_status/vars | grep "^ranges_underreplicated" | grep -v ".* 0$" | wc -l`
    done
}

# show node is and portion of locality
# $1 = user table          
# _crdb_locs region
# 1	region=eu-west-1
# 2	region=eu-west-1
# 3	region=eu-west-1
_crdb_locs() {
  cockroach sql --insecure --format tsv -e "select node_id, concat_ws('','${1:-region}=',locality->>'${1:-region}') loc from crdb_internal.kv_node_status" | tail -n +2 
}

_crdb_show_ranges() {
cockroach sql -u root --insecure --url "postgresql://${_crdb_host:-127.0.0.1}:${_crdb_port:-26257}/${_crdb_db:-defaultdb}" <<-EOF
	select range_id, array_agg(node_id) node_id, array_agg(region) region, array_agg(az) az
	from 
	  ( select range_id,lease_holder,unnest(replicas) as replicas 
	    from [show experimental_ranges from table ${crdbb_db:-defaultdb}.$1]) a, 
	  ( select node_id, locality->>'zone' az, locality->>'region' region
	    from crdb_internal.kv_node_status) b 
	where a.replicas=b.node_id
	group by range_id 
	order by range_id 
	;
	EOF
}

# change replication factor
_crdb_replication() {
  foo_usage() { echo "_crdb_replication: [-t <tablename:-defaultdb>] [-r <replica count:-3]" 1>&2; return; }

  local OPTIND t=usertable r=5
  while getopts ":t:r:" o; do
    case "${o}" in
      t)
        t="${OPTARG}"
        ;;
      r)
        r="${OPTARG}"
        ;;
      *)
        foo_usage
        ;;
    esac
  done
  shift $((OPTIND-1))

  cockroach sql -u root --insecure --url "postgresql://${_crdb_host:-127.0.0.1}:${_crdb_port:-26257}/${_crdb_db:-defaultdb}" -e "alter table ${t} configure zone using num_replicas=${r}"
}
	
# show under replicated or un-available replics
_crdb_show_ranges_regions() {
  foo_usage() { echo "_crdb_show_ranges_regions: [-t <tablename:-defaultdb>] [-r <replica count:-3]" 1>&2; return; }

  local OPTIND t=usertable r=3
  while getopts ":t:r:" o; do
    case "${o}" in
      t)
        t="${OPTARG}"
        ;;
      r)
        r="${OPTARG}"
        ;;
      *)
        foo_usage
        ;;
    esac
  done
  shift $((OPTIND-1))

  cockroach sql -u root --insecure --url "postgresql://${_crdb_host:-127.0.0.1}:${_crdb_port:-26257}/${_crdb_db:-defaultdb}" <<-EOF
	select range_id, array_agg(node_id) node_id, array_agg(region) region
	from 
	  ( select range_id,lease_holder,unnest(replicas) as replicas 
	    from [show experimental_ranges from table ${crdbb_db:-defaultdb}.${t}]) a, 
	  ( select node_id, locality->>'az' az, locality->>'region' region
	    from crdb_internal.kv_node_status) b 
	where a.replicas=b.node_id
	group by range_id 
	having count(distinct(region)) < count(region)
	order by range_id 
	;
	EOF
}

# coordinates from https://www.cockroachlabs.com/docs/stable/enable-node-map.html
_crdb_maps_aws() {
  cat <<-EOF | awk '{print "upsert into system.locations VALUES (" $0" );"}' | cockroach sql --insecure
	'region', 'us-east-1', 37.478397, -76.453077
	'region', 'us-east-2', 40.417287, -76.453077
	'region', 'us-west-1', 38.837522, -120.895824
	'region', 'us-west-2', 43.804133, -120.554201
	'region', 'ca-central-1', 56.130366, -106.346771
	'region', 'eu-central-1', 50.110922, 8.682127
	'region', 'eu-west-1', 53.142367, -7.692054
	'region', 'eu-west-2', 51.507351, -0.127758
	'region', 'eu-west-3', 48.856614, 2.352222
	'region', 'ap-northeast-1', 35.689487, 139.691706
	'region', 'ap-northeast-2', 37.566535, 126.977969
	'region', 'ap-northeast-3', 34.693738, 135.502165
	'region', 'ap-southeast-1', 1.352083, 103.819836
	'region', 'ap-southeast-2', -33.86882, 151.209296
	'region', 'ap-south-1', 19.075984, 72.877656
	'region', 'sa-east-1', -23.55052, -46.633309
	EOF
}

# gcloud compute region list
_crdb_maps_gcp() {
  cat <<-EOF | awk '{print "upsert into system.locations VALUES (" $0" );"}' | cockroach sql --insecure
	'region', 'us-east1', 33.836082, -81.163727
	'region', 'us-east4', 37.478397, -76.453077
	'region', 'us-central1', 42.032974, -93.581543
	'region', 'us-west1', 43.804133, -120.554201
	'region', 'northamerica-northeast1', 56.130366, -106.346771
	'region', 'europe-west1', 50.44816, 3.81886
	'region', 'europe-west3', 50.110922, 8.682127
	'region', 'europe-west4', 53.4386, 6.8355
	'region', 'europe-west2', 51.507351, -0.127758
	'region', 'asia-east1', 24.0717, 120.5624
	'region', 'asia-northeast1', 35.689487, 139.691706
	'region', 'asia-southeast1', 1.352083, 103.819836
	'region', 'australia-southeast1', -33.86882, 151.209296
	'region', 'asia-south1', 19.075984, 72.877656
	'region', 'southamerica-east1', -23.55052, -46.633309
	EOF
}

_crdb_maps_azure() {
  cat <<-EOF | awk '{print "upsert into system.locations VALUES (" $0" );"}' | cockroach sql --insecure
	'region', 'eastasia', 22.267, 114.188
	'region', 'southeastasia', 1.283, 103.833
	'region', 'centralus', 41.5908, -93.6208
	'region', 'eastus', 37.3719, -79.8164
	'region', 'eastus2', 36.6681, -78.3889
	'region', 'westus', 37.783, -122.417
	'region', 'northcentralus', 41.8819, -87.6278
	'region', 'southcentralus', 29.4167, -98.5
	'region', 'northeurope', 53.3478, -6.2597
	'region', 'westeurope', 52.3667, 4.9
	'region', 'japanwest', 34.6939, 135.5022
	'region', 'japaneast', 35.68, 139.77
	'region', 'brazilsouth', -23.55, -46.633
	'region', 'australiaeast', -33.86, 151.2094
	'region', 'australiasoutheast', -37.8136, 144.9631
	'region', 'southindia', 12.9822, 80.1636
	'region', 'centralindia', 18.5822, 73.9197
	'region', 'westindia', 19.088, 72.868
	'region', 'canadacentral', 43.653, -79.383
	'region', 'canadaeast', 46.817, -71.217
	'region', 'uksouth', 50.941, -0.799
	'region', 'ukwest', 53.427, -3.084
	'region', 'westcentralus', 40.890, -110.234
	'region', 'westus2', 47.233, -119.852
	'region', 'koreacentral', 37.5665, 126.9780
	'region', 'koreasouth', 35.1796, 129.0756
	'region', 'francecentral', 46.3772, 2.3730
	'region', 'francesouth', 43.8345, 2.1972
	EOF
}