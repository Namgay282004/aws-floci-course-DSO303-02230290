#!/usr/bin/env bash
# END OF COURSE ONLY. Deletes every Lab 07 resource, dependencies inside-out.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true

cat <<'WARN'
This deletes:
  Kubernetes namespace usms and everything inside it
  EKS node group usms-eks-nodes
  EKS cluster usms-eks-cluster
  IAM roles usms-eks-cluster-role and usms-eks-node-role
  IAM policies USMSEKSClusterPolicy and USMSEKSNodePolicy
  Security group usms-eks-cluster-sg
It does NOT delete USMSStudentDataReadWrite, which Lab 03 and Lab 04 still use.
WARN

printf 'Type exactly DELETE-LAB-07 to proceed: '
read -r CONFIRM
[ "$CONFIRM" = "DELETE-LAB-07" ] || { echo "aborted"; exit 1; }

# 1. Kubernetes objects first
kubectl delete namespace usms --ignore-not-found --timeout=180s 2>/dev/null || true

# 2. Node group before cluster
aws eks delete-nodegroup --cluster-name usms-eks-cluster --nodegroup-name usms-eks-nodes 2>/dev/null || true
aws eks wait nodegroup-deleted --cluster-name usms-eks-cluster --nodegroup-name usms-eks-nodes 2>/dev/null || sleep 10

# 3. Cluster
aws eks delete-cluster --name usms-eks-cluster 2>/dev/null || true
aws eks wait cluster-deleted --name usms-eks-cluster 2>/dev/null || sleep 10

# 4. Detach policies and delete roles
for R in usms-eks-cluster-role usms-eks-node-role; do
  for P in $(aws iam list-attached-role-policies --role-name "$R" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$R" --policy-arn "$P" 2>/dev/null || true
  done
  aws iam delete-role --role-name "$R" 2>/dev/null || true
done

# 5. Local policies
for N in USMSEKSClusterPolicy USMSEKSNodePolicy; do
  A=$(aws iam list-policies --scope Local --query "Policies[?PolicyName=='$N'].Arn | [0]" --output text 2>/dev/null)
  [ -n "$A" ] && [ "$A" != "None" ] && aws iam delete-policy --policy-arn "$A" 2>/dev/null || true
done

# 6. Security group
SG=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=usms-eks-cluster-sg" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
[ -n "$SG" ] && [ "$SG" != "None" ] && aws ec2 delete-security-group --group-id "$SG" 2>/dev/null || true

echo "Lab 07 resources removed."
