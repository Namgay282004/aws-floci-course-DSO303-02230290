#!/usr/bin/env bash
set -uo pipefail
# Option '-e' is omitted intentionally so that individual query evaluation 
# failures on absent fields (e.g., missing public IPs or SG rules) do not cause 
# the script to terminate abruptly before processing all instances.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Get all running USMS instances
INSTANCES_JSON=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=USMS" "Name=instance-state-name,Values=running" \
  --output json)

echo "$INSTANCES_JSON" | python3 -c '
import sys, json, subprocess

data = json.load(sys.stdin)

# Fetch internet gateways
igw_cmd = subprocess.run(["aws", "ec2", "describe-internet-gateways", "--output", "json"], capture_output=True, text=True)
igws = json.loads(igw_cmd.stdout).get("InternetGateways", [])
attached_vpcs = set()
for igw in igws:
    for att in igw.get("Attachments", []):
        if att.get("State") == "available":
            attached_vpcs.add(att.get("VpcId"))

# Fetch route tables
rt_cmd = subprocess.run(["aws", "ec2", "describe-route-tables", "--output", "json"], capture_output=True, text=True)
route_tables = json.loads(rt_cmd.stdout).get("RouteTables", [])

def subnet_has_igw(subnet_id, vpc_id):
    if vpc_id not in attached_vpcs:
        return False
    # Check explicitly associated route tables or main route table
    for rt in route_tables:
        if rt.get("VpcId") != vpc_id:
            continue
        assoc_subnets = [a.get("SubnetId") for a in rt.get("Associations", []) if a.get("SubnetId")]
        is_main = any(a.get("Main") for a in rt.get("Associations", []))
        if subnet_id in assoc_subnets or is_main:
            for r in rt.get("Routes", []):
                if r.get("DestinationCidrBlock") == "0.0.0.0/0" and r.get("GatewayId", "").startswith("igw-"):
                    return True
    return False

# Fetch SGs
sg_cmd = subprocess.run(["aws", "ec2", "describe-security-groups", "--output", "json"], capture_output=True, text=True)
security_groups = {sg["GroupId"]: sg for sg in json.loads(sg_cmd.stdout).get("SecurityGroups", [])}

def sg_allows_http(sg_ids):
    for sg_id in sg_ids:
        sg = security_groups.get(sg_id, {})
        for perm in sg.get("IpPermissions", []):
            from_port = perm.get("FromPort")
            to_port = perm.get("ToPort")
            protocol = perm.get("IpProtocol")
            
            # Port 80 or all ports
            port_match = (protocol == "-1") or (from_port is not None and to_port is not None and from_port <= 80 <= to_port)
            cidr_match = any(ip_range.get("CidrIp") == "0.0.0.0/0" for ip_range in perm.get("IpRanges", []))
            
            if port_match and cidr_match:
                return True
    return False

for res in data.get("Reservations", []):
    for inst in res.get("Instances", []):
        name = "-"
        for tag in inst.get("Tags", []):
            if tag.get("Key") == "Name":
                name = tag.get("Value")
        
        priv_ip = inst.get("PrivateIpAddress", "-") or "-"
        pub_ip = inst.get("PublicIpAddress", "-") or "-"
        subnet_id = inst.get("SubnetId", "")
        vpc_id = inst.get("VpcId", "")
        sg_ids = [sg.get("GroupId") for sg in inst.get("SecurityGroups", [])]
        
        has_igw = subnet_has_igw(subnet_id, vpc_id)
        allows_80 = sg_allows_http(sg_ids)
        
        if pub_ip != "-" and has_igw and allows_80:
            verdict = "REACHABLE"
            reason = "igw route + sg allows 80/tcp from 0.0.0.0/0"
        elif pub_ip == "-" and has_igw:
            verdict = "NO-ADDRESS"
            reason = "igw route present but no public address"
        else:
            verdict = "UNREACHABLE"
            reason = "no igw route on subnet or SG blocks http"
            
        print(f"{name:<15} {priv_ip:<15} {pub_ip:<15} {verdict:<12} {reason}")
'
