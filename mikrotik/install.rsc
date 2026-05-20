# MikroTik install script for Traffic Monitor container
# Import with: /import file-name=install.rsc
# Adjust variables below before import.

:local mtmVeth "veth-tdb"
:local mtmBridge "dockers"
:local mtmSubnet "172.18.0"
:local mtmMask "16"
:local mtmRouterIp ($mtmSubnet . ".1")
:local mtmContainerIp ($mtmSubnet . ".2")
:local mtmDataPath "/usb1/trafficdb-data"
:local mtmDataDir "usb1/trafficdb-data"
:local mtmRootDir "/usb1/containers/trafficdb"
:local mtmPullDir "/usb1/pull"
:local mtmImage "ghcr.io/ovikiss/mikrotik-traffic-monitor:latest"
:local mtmContainerName "trafficdb"
:local mtmIfIndex "auto"
:local mtmIfNamePattern "pppoe"
:local mtmPollInterval "1h"
:local mtmSnmpCommunity "trafficdb"
:local mtmHttpLanPort "8088"
:local mtmLanCidr "192.168.88.0/24"

# Ensure support directories on disk
:if ([:len [/file find where name="usb1/containers"]] = 0) do={ /file add name="usb1/containers" type=directory }
:if ([:len [/file find where name="usb1/pull"]] = 0) do={ /file add name="usb1/pull" type=directory }

# Configure container extraction path
/container/config/set tmpdir=$mtmPullDir

# Stop and remove the old container before touching mounted paths.
:if ([:len [/container/find where name=$mtmContainerName]] > 0) do={
  /container/stop [find where name=$mtmContainerName]
  /delay 2
  /container/remove [find where name=$mtmContainerName]
}

# Ensure persistent data directory exists.
:if ([:len [/file find where name=$mtmDataDir]] = 0) do={ /file add name=$mtmDataDir type=directory }

# Ensure veth exists and is linked to the container bridge
:if ([:len [/interface/veth/find where name=$mtmVeth]] = 0) do={
  /interface/veth/add name=$mtmVeth address=($mtmContainerIp . "/" . $mtmMask) gateway=$mtmRouterIp
} else={
  /interface/veth/set [find where name=$mtmVeth] address=($mtmContainerIp . "/" . $mtmMask) gateway=$mtmRouterIp
}

:local mtmContainerAddress ([/interface/veth/get [find where name=$mtmVeth] address] . "")
:local mtmDetectedContainerIp $mtmContainerAddress
:local mtmSlashPos [:find $mtmContainerAddress "/"]
:if ([:typeof $mtmSlashPos] != "nil") do={ :set mtmDetectedContainerIp [:pick $mtmContainerAddress 0 $mtmSlashPos] }

# Enable SNMP and create readonly community scoped to the actual container IP.
/snmp/set enabled=yes
:if ([:len [/snmp/community/find where name=$mtmSnmpCommunity]] = 0) do={
  /snmp/community/add name=$mtmSnmpCommunity addresses=($mtmDetectedContainerIp . "/32") security=none read-access=yes write-access=no
} else={
  /snmp/community/set [find where name=$mtmSnmpCommunity] addresses=($mtmDetectedContainerIp . "/32") security=none read-access=yes write-access=no
}

:if ([:len [/interface/bridge/find where name=$mtmBridge]] = 0) do={
  /interface/bridge/add name=$mtmBridge
}

:if ([:len [/interface/bridge/port/find where interface=$mtmVeth and bridge=$mtmBridge]] = 0) do={
  /interface/bridge/port/add interface=$mtmVeth bridge=$mtmBridge
}

:if ([:len [/ip/address/find where interface=$mtmBridge and address=($mtmRouterIp . "/" . $mtmMask)]] = 0) do={
  /ip/address/add interface=$mtmBridge address=($mtmRouterIp . "/" . $mtmMask)
}

# Prepare env list
:foreach e in=[/container/envs/find where list="trafficdb"] do={ /container/envs/remove $e }
/container/envs/add list="trafficdb" key="MT_COMMUNITY" value=$mtmSnmpCommunity
/container/envs/add list="trafficdb" key="IFINDEX" value=$mtmIfIndex
/container/envs/add list="trafficdb" key="IFNAME_PATTERN" value=$mtmIfNamePattern
/container/envs/add list="trafficdb" key="POLL_INTERVAL" value=$mtmPollInterval
/container/envs/add list="trafficdb" key="HTTP_PORT" value=$mtmHttpLanPort
/container/envs/add list="trafficdb" key="TZ" value="Europe/Bucharest"
/container/envs/add list="trafficdb" key="DATA_DIR" value="/data"

# Prepare mount list
:foreach m in=[/container/mounts/find where list="trafficdb"] do={ /container/mounts/remove $m }
/container/mounts/add list="trafficdb" src=$mtmDataPath dst="/data"

# Pull and run container
/container/add name=$mtmContainerName remote-image=$mtmImage interface=$mtmVeth root-dir=$mtmRootDir mountlists="trafficdb" envlists="trafficdb" start-on-boot=yes logging=yes dns="192.168.88.1,1.1.1.1"
/container/start [find where name=$mtmContainerName]

# LAN port-forward to UI/API
:if ([:len [/ip/firewall/nat/find where comment="trafficdb-gui"]] = 0) do={
  /ip/firewall/nat/add chain=dstnat action=dst-nat protocol=tcp src-address=$mtmLanCidr dst-address=192.168.88.1 dst-port=$mtmHttpLanPort to-addresses=$mtmDetectedContainerIp to-ports=$mtmHttpLanPort comment="trafficdb-gui"
} else={
  /ip/firewall/nat/set [find where comment="trafficdb-gui"] chain=dstnat action=dst-nat protocol=tcp src-address=$mtmLanCidr dst-address=192.168.88.1 dst-port=$mtmHttpLanPort to-addresses=$mtmDetectedContainerIp to-ports=$mtmHttpLanPort
}

:put ("Traffic Monitor installed. Open http://192.168.88.1:" . $mtmHttpLanPort . "/")
