#!/usr/bin/env bash
echo "== USMS Security Group Audit =="
aws ec2 describe-security-groups --query 'SecurityGroups[*].[GroupId,GroupName,IpPermissions,IpPermissionsEgress]' --output json
