
# AWS Networking and Infrastructure Validation

## Question 1: What Makes a Subnet Truly Public?
The missing component is an **Internet Gateway (IGW)** explicitly attached to the VPC, combined with a **route entry** in the subnet's route table that maps default external traffic (`0.0.0.0/0`) to that IGW target.

Names, tags, and auto-assign IP settings fail to make a subnet public because they are purely operational metadata and local interface behaviors:
*   **Names and Tags (Tier=public):** These are human-readable metadata labels used for organization and filtering; AWS networking components completely ignore tags when making routing decisions.
*   **Auto-assign Public IP:** This setting only instructs AWS to assign a public IPv4 address to an interface upon creation. Having a public IP address is useless if the underlying network routing engine does not know how to forward packets destined for outside the VPC. Without an explicit route to an attached Internet Gateway, external packets have no path out of the VPC, leaving the subnet functionally private.

---

## Question 2: Stateful vs. Stateless Firewalls in a USMS Request Path
Consider an incoming web request from an external student client targeting a web server on port `80/tcp` (HTTP), which subsequently queries the database server on port `5432/tcp` (PostgreSQL).

### Security Groups (Stateful)
Because Security Groups are stateful, return traffic is automatically tracked and allowed. You only write **2 ingress rules**:
1.  Ingress on the application group allowing `80/tcp` from `0.0.0.0/0`.
2.  Ingress on the database group allowing `5432/tcp` sourced from the application security group.
*   **Note:** No egress rules are required for return traffic.

### Network ACLs (Stateless)
Because Network ACLs are stateless, they evaluate traffic entering and exiting the subnet boundary independently. To support the exact same flow, you must write **4 distinct rules**:
1.  **Ingress on the public NACL:** Allowing inbound `80/tcp`.
2.  **Egress on the public NACL:** Allowing outbound ephemeral ports (`1024–65535/tcp`) for the HTTP response back to the client.
3.  **Ingress on the private NACL:** Allowing inbound `5432/tcp` from the public subnet.
4.  **Egress on the private NACL:** Allowing outbound ephemeral ports (`1024–65535/tcp`) for the database response back to the app server.

**First Choice for New Requirements:** I would reach for **Security Groups** first. They operate at the instance level, handle return state automatically (drastically reducing operational error), and allow rule definitions based on logical security group references rather than fixed IP ranges. NACLs are best reserved as a coarse subnet-wide safety net.

---

## Question 3: Group-Referenced vs. CIDR-Based Security Group Rules
Two structural changes to the USMS network architecture would silently break a CIDR-based rule (`10.0.1.0/24`) while keeping the group-referenced rule intact:

1.  **Adding a Second Public Subnet in Another AZ:** If web instances are deployed into a new public subnet in `us-east-1b` (e.g., using CIDR `10.0.2.0/24`) for high availability, a hardcoded CIDR rule on the database tier (`10.0.1.0/24`) will drop PostgreSQL traffic coming from the new AZ. A group-referenced rule dynamically permits any instance attached to `usms-app-sg`, regardless of its subnet or IP address.
2.  **Subnet Re-IPing / CIDR Expansion:** If network administrators renumber the public tier subnet range (for instance, changing `10.0.1.0/24` to `10.0.10.0/23` to accommodate growth), hardcoded CIDR references in the database security group silently stale out, blocking legitimate connection attempts. Group referencing resolves dynamically via resource identity, insulating security policies from underlying IP scheme changes.

---

## Question 4: NAT Gateway Placement and Availability Boundaries
The NAT Gateway must sit inside a **public subnet** because it requires a public IPv4 address and a route table configured with an Internet Gateway as its default route (`0.0.0.0/0 -> igw`). Its purpose is to perform Network Address Translation, taking private traffic and translating it into its own public identity before forwarding it out to the internet.

**Impact of AZ Failure:**
If `us-east-1a` fails, the private subnet in `us-east-1b` loses all outbound internet connectivity. This is because a NAT Gateway is a localized resource bound to a single Availability Zone. Even though private subnets across different AZs can point their route tables to it, the routing path relies on underlying infrastructure physically located in `us-east-1a`.

This dependency proves that the **availability boundary sits at the Availability Zone level**, not the VPC level. Achieving true high availability requires provisioning redundant NAT Gateways in each public subnet per AZ and pointing each private subnet's route table to its local AZ's NAT Gateway.

---

## Question 5: S3 Gateway Endpoints: Traffic Paths, Costs, and Risks

*   **Path WITH a Gateway Endpoint:** 
    `Private Instance` $\rightarrow$ `Private Route Table (matches S3 Prefix List)` $\rightarrow$ `usms-s3-endpoint` $\rightarrow$ `AWS Internal Network` $\rightarrow$ `usms-student-data S3 Bucket`.
*   **Path WITHOUT an Endpoint:** 
    `Private Instance` $\rightarrow$ `Private Route Table` $\rightarrow$ `NAT Gateway (in public subnet)` $\rightarrow$ `Internet Gateway` $\rightarrow$ `Public Internet` $\rightarrow$ `AWS S3 Public Regional Endpoint` $\rightarrow$ `usms-student-data S3 Bucket`.

### Comparison of Public Internet Path Risks:
*   **Money / Cost:** Routing S3 traffic through a NAT Gateway incurs hourly NAT Gateway provision fees plus per-gigabyte NAT data processing charges. Gateway Endpoints for S3 are completely free of charge.
*   **Exposure / Security:** The path without an endpoint routes data over public network pathways, requiring public IPs and exposure through an Internet Gateway. The Gateway Endpoint keeps all data strictly within the private AWS network backbone, reducing internet intercept vectors and eliminating public route exposure.

---

## Question 6: Testing State Persistence vs. Variable Reliance
If Step 23 had looked up the VPC using the existing `$VPC_ID` shell environment variable, it would have only proven that the variable remained set in local memory. It would **not** have proven that the infrastructure state had actually been successfully written to and reloaded from disk persistence by the local Floci container across a process restart.

This relates directly to the failure in Lab 1 Step 14, where restarting an unpersisted or in-memory emulation layer clears all previously created infrastructure. Re-querying resources by **Tag (Project=USMS)** forces the client to make a fresh API call against the backend engine, proving that the infrastructure state survived the service restart and exists independently of local shell memory.

---

## Question 7: Validating Security Group Logic in Emulation Environments
Because Floci does not enforce network filtering, confidence in rule correctness relies on validating the **declared configuration schema** via API call responses and structured verification logic rather than active traffic interception.

*   **Mistake caught by verification:** Declaring an incorrect protocol, entering a malformed JSON rule body, omitting mandatory tags, or hardcoding a static CIDR block (`10.0.1.0/24`) instead of specifying the source security group ID (`usms-app-sg`). The script inspects the object schema directly and fails if non-group sourcing is detected.
*   **Mistake NOT caught by verification:** A functional logic error within allowed traffic rules :such as accidentally permitting TCP port `8080` instead of port `80` inside the application security group policy, assuming the verification script only asserts the general existence of rule objects rather than matching every individual port constraint.
