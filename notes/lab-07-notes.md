## Lab 07 support path
Probed on 2026-10-12T08:56:37Z
PATH A  - use aws eks throughout

## Step 3 Answer: EKS vs ECS
One thing that makes the statement false is that EKS retains a fully exposed, distinct control plane and data plane architecture. In EKS, worker nodes run actual EC2 instances in your account running kubelet and container runtimes that require explicit registration via a node IAM role, whereas ECS (especially with Fargate) abstracts away control plane nodes, etcd, and worker node management entirely.

One thing that makes the statement nearly true is that both serve as container orchestration platforms managing multi-container deployments across an AWS infrastructure with integrated IAM authentication, network interfaces (ENIs), load balancer target registration, and autoscaling capabilities.

## Step 9 Answer: OIDC Issuer Purpose
The EKS OIDC issuer URL is used to establish trust between AWS IAM and Kubernetes ServiceAccounts (IRSA), allowing pods to assume specific IAM roles directly without storing AWS credentials inside the pod or falling back to node credentials.

## Step 17 Answer: Replacement Pod Creator
The replacement pod was created by the `usms-enrolment` ReplicaSet, which continuously monitors the cluster state and automatically spins up a new pod whenever the active count falls below the desired replica count of 2.

## Step 17 Answer: Honest Account of Kubernetes Secrets
1. **Base64 is Encoding, Not Encryption**: Native Kubernetes Secrets are stored as Base64 encoded strings, which provides zero confidentiality or security on its own. Anyone with read access to the Secret object or `etcd` can instantly decode the values.
2. **Security Requirements for Production**: To make Secrets truly secure, a cluster must enable Encryption at Rest in `etcd` (using AWS KMS or a local KMS key), restrict access via RBAC (preventing unauthorized `get`/`list` operations on secrets), and ideally integrate external secret management solutions like AWS Secrets Manager or HashiCorp Vault.

## Step 20 - ECS and Kubernetes, compared with both running

| Question | ECS answer | Kubernetes answer |
| --- | --- | --- |
| What holds the container spec? | | |
| What keeps N copies alive? | | |
| What gives it a stable name? | | |
| How does another service find it? | | |
| What does a rolling update create? | | |
| Where does rollback state live? | | |
| Which IAM role does the app code use? | | |
| What would I have to change to move to another cloud? | | |

Two sentences: which one would I choose for USMS, and why.

## Step 20 - ECS and Kubernetes, compared with both running

| Question | ECS answer | Kubernetes answer |
| --- | --- | --- |
| What holds the container spec? | Task definition (numbered revision) | Pod template inside a Deployment |
| What keeps N copies alive? | ECS service (desiredCount) | ReplicaSet owned by the Deployment |
| What gives it a stable name? | Target group / ALB DNS name | Service (ClusterIP and DNS name) |
| How does another service find it? | Via the ALB or Cloud Map | CoreDNS: usms-enrolment.usms.svc.cluster.local |
| What does a rolling update create? | A new deployment on a new task definition revision | A new ReplicaSet; the old one scaled to zero |
| Where does rollback state live? | Earlier task definition revisions | Old ReplicaSets, up to revisionHistoryLimit |
| Which IAM role does the app code use? | The task role | Node role here; an IRSA ServiceAccount role on real EKS |
| What changes to move to another cloud? | Nearly everything | Manifests mostly portable; IAM, VPC, node groups, load balancers change |

For USMS (quiet most of the year, very busy twice) I would choose ECS on Fargate: a small team avoids running nodes, a control plane and a CNI, and the scaling need is simple. Kubernetes earns its extra cost only if portability or its ecosystem matters.
