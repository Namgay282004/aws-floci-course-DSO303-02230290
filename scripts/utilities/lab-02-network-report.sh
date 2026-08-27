#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if [ -f "${PROJECT_ROOT}/configs/lab-02.env" ]; then
  source "${PROJECT_ROOT}/configs/lab-02.env"
fi

SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${USMS_VPC_ID}" --query 'Subnets[*].SubnetId' --output text)

for SUBNET_ID in $SUBNET_IDS; do
  SUBNET_NAME=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --query 'Subnets[0].Tags[?Key==`Name`].Value' --output text)
  CIDR=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --query 'Subnets[0].CidrBlock' --output text)
  AZ=$(aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --query 'Subnets[0].AvailabilityZone' --output text)

  RT_ID=$(aws ec2 describe-route-tables --filters "Name=association.subnet-id,Values=${SUBNET_ID}" --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null || true)
  if [ -z "$RT_ID" ] || [ "$RT_ID" == "None" ]; then
    RT_ID=$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=${USMS_VPC_ID}" "Name=association.main,Values=true" --query 'RouteTables[0].RouteTableId' --output text)
  fi

  IGW_ROUTE=$(aws ec2 describe-route-tables --route-table-ids "$RT_ID" --query 'RouteTables[0].Routes[?starts_with(GatewayId, `igw-`)].GatewayId' --output text)
  NAT_ROUTE=$(aws ec2 describe-route-tables --route-table-ids "$RT_ID" --query 'RouteTables[0].Routes[?starts_with(NatGatewayId, `nat-`)].NatGatewayId' --output text)

  if [ -n "$IGW_ROUTE" ] && [ "$IGW_ROUTE" != "None" ]; then
    TYPE="PUBLIC"
    VIA="via ${IGW_ROUTE}"
  elif [ -n "$NAT_ROUTE" ] && [ "$NAT_ROUTE" != "None" ]; then
    TYPE="PRIVATE"
    VIA="via ${NAT_ROUTE}"
  else
    TYPE="ISOLATED"
    VIA="no default route"
  fi

  printf "%-22s %-14s %-12s %-8s %s\n" "$SUBNET_NAME" "$CIDR" "$AZ" "$TYPE" "$VIA"
done
