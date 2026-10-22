## Step 3 - Ten times the traffic on usms-enrolment

I would start with dimension 1 (horizontal workload): raise replicas, ideally by letting the HPA do it, and check that the new pods become Ready and that the endpoints list grows. Before going further I would check `kubectl top pods` and the pod requests, because if pods are throttled or OOMKilled then dimension 2 (vertical workload, bigger requests/limits) is the next lever, and I would check that a pod still fits on a node. Next I would check for Pending pods with `kubectl describe pod` (Insufficient cpu); if there are any, the cluster is out of room and I need dimension 3 (more nodes, by raising the node group's desiredSize or running a Cluster Autoscaler/Karpenter), then confirm the nodes are Ready and the pods have scheduled. I would only reach for dimension 4 (bigger instance types) if a single pod needs more than any current node can offer, and since that cannot be changed in place I would create a new node group, cordon and drain the old one, and delete it, which needs planning rather than a last-minute change.
## Step 6 - Making usms-gateway Guaranteed

QoS class before: Burstable (requests 50m/32Mi, limits 200m/128Mi)
QoS class after setting requests = limits (200m/128Mi): Guaranteed
QoS class after putting it back: Burstable

The pod was REPLACED, not adjusted, each time. Resources live in the pod template, so changing them triggers a rollout, and a pod's QoS class is fixed for its lifetime. This is dimension 2 (vertical workload scaling) from Step 3. Changing a pod's size means restarting it, which is why the VerticalPodAutoscaler is used far less than the HPA, which adds pods without disturbing running ones.

I would want Guaranteed for latency-critical or stateful workloads (a database, a payment path) that must be evicted last under node pressure and never be throttled below what they reserved, accepting that the reserved capacity is paid for even when idle.
## Step 7 - metrics-server
metrics.k8s.io was not available on this kind cluster, so I installed metrics-server from the upstream manifest. The pod never became ready (x509: kind kubelets use self-signed certificates), so I added --kubelet-insecure-tls. This flag is laboratory-only: it skips verification of the kubelet certificate, so something impersonating a kubelet could feed the autoscaler invented metrics. Real EKS never needs it.
## Step 8 - HPA arithmetic
Two pods at 40m with a 50m request: utilisation = 40/50 = 80%.
desiredReplicas = ceil(2 * 80 / 50) = ceil(3.2) = 4.
Lab 06 mapping: RegisterScalableTarget -> scaleTargetRef; MinCapacity/MaxCapacity -> minReplicas/maxReplicas; TargetTrackingScaling on ECSServiceAverageCPUUtilization -> metrics[].resource cpu averageUtilization; ScaleInCooldown 300 -> behavior.scaleDown.stabilizationWindowSeconds 300; ScaleOutCooldown -> behavior.scaleUp stabilizationWindowSeconds + policies.
## Step 11 - Autoscalers and nodeSelector
Cluster Autoscaler watches Pending pods and raises an Auto Scaling group's desired capacity, from node groups I pre-declared, then waits for EKS to add a node.
Karpenter watches the same Pending pods but launches right-sized EC2 instances directly, from a NodePool of acceptable instance families.
Neither is installed here (both need IRSA and a real ASG).
The node group's labels did not reach the kind nodes, so I applied workload=usms tier=app by hand. A nodeSelector workload=usms was applied to usms-enrolment; with workload=nonexistent the new pod stayed Pending while the two running pods kept serving (maxUnavailable: 0), proving the selector is enforced.

## Step 17 - Practical 2 and Practical 4, compared with both running

### Scaling

| Question | ECS + Application Auto Scaling | Kubernetes + HPA |
| --- | --- | --- |
| What integer is written? | | |
| Who writes it? | | |
| Where does that thing run? | | |
| Where does the metric come from? | | |
| What does "50% CPU" mean - 50% of what? | | |
| How is scale-in slowed down? | | |
| What happens if there is no capacity for the new instance/pod? | | |
| What creates the alarms, if anything? | | |

### Exposure

| Question | ECS + ALB (Lab 05) | Kubernetes + Ingress (Step 16) |
| --- | --- | --- |
| How many AWS objects did I create by hand? | | |
| What is the target type, and why? | | |
| How are targets registered and deregistered? | | |
| How are competing routing rules disambiguated? | | |
| What would I change to move this to another cloud? | | |
| What is the cost of exposing ten services? | | |

### Two paragraphs, in prose

1. If the AWS control plane has a bad afternoon, what happens to each of the two
   scaling arrangements, and which of them can I still debug?

2. For USMS specifically - one small team, one region, quiet for eight months and
   very busy for two - which would I choose, and what is the strongest argument
   AGAINST my own choice?
