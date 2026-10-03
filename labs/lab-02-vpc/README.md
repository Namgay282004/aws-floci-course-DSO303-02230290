# Lab 2 : Building a Virtual Private Cloud (VPC)

## 1. Aim / Objective

The objective of this practical laboratory was to design, implement, and verify a custom multi-tier Virtual Private Cloud (VPC) architecture on AWS using the AWS CLI within a local Floci environment. Hands-on tasks included provisioning custom network boundaries, multi-AZ subnets, custom route tables, Internet/NAT Gateways, stateless Network Access Control Lists (NACLs), stateful security groups with group-referencing rules, VPC S3 endpoints, and automated verification scripting.

## 2. Introduction

AWS Virtual Private Cloud (VPC) gives administrators complete control over a logically isolated virtual network. This includes selecting IP address ranges, creating subnets, configuring route tables, and managing network gateways.

#### Key Features

- Custom IPv4 CIDR Block Allocation
- Public and Private Subnets across Multiple Availability Zones
- Internet Gateways (IGW) and Network Address Translation (NAT) Gateways
- Custom Route Tables and Explicit Subnet Associations
- Network Access Control Lists (NACLs) for stateless subnet-level security
- Security Groups for stateful instance-level firewalls
- VPC Gateway Endpoints for direct, secure S3 connectivity

## 3. Use Case

The University Student Management System (USMS) required an enterprise-grade cloud network topology:

- Public Tier: Hosted web applications accessible from the public internet.
- Application Tier: Executed business logic and required outbound internet access for patching without allowing direct public ingress.
- Database Tier: Protected sensitive student records in an isolated private subnet, permitting ingress traffic exclusively from application compute nodes over database ports (e.g., PostgreSQL TCP 5432).

## 4. System Architecture / Design
![](../../screenshots/lab-02-vpc/architecture.png)

![](../../screenshots/lab-02-vpc/architecture1.png)


## 5. Implementation Overview

The implementation process involved initializing the environment variables and provisioning core infrastructure components step-by-step using the AWS CLI. The network isolation parameters, security group dependencies, route tables, and NACL associations were verified using CLI query parameters and automated verification scripts.


## 6. Results and Evidence

### 6.1 CLI Output

#### Step 1: Resume the environment
Resumed local services and checked container readiness.
![](../../screenshots/lab-02-vpc/1.png)

#### Step 2: Load previous lab environment & confirm identity
Sourced Lab 01 variables and confirmed identity (`aws sts get-caller-identity`).
![](../../screenshots/lab-02-vpc/2.png)

#### Step 3: Assume developer role and create the VPC
Assumed `usms-developer-role` and provisioned `usms-vpc` with CIDR `10.0.0.0/16`.
![](../../screenshots/lab-02-vpc/3.png)

![](../../screenshots/lab-02-vpc/3.1.png)

![](../../screenshots/lab-02-vpc/3.2.png)

#### Step 4: Restore normal identity
Unset temporary STS session credentials to adhere to least-privilege principles.
![](../../screenshots/lab-02-vpc/4.png)

#### Step 5: Enable DNS support and DNS hostnames
Configured `enableDnsHostnames` and `enableDnsSupport` attributes on `usms-vpc`.
![](../../screenshots/lab-02-vpc/5.png)

#### Step 6: Create and attach the Internet Gateway
Created `usms-igw` and attached it directly to `usms-vpc`.
![](../../screenshots/lab-02-vpc/6.png)

![](../../screenshots/lab-02-vpc/6.1.png)

#### Step 7: Create the public subnet in us-east-1a
Created `usms-public-subnet-a` with CIDR `10.0.1.0/24` in `us-east-1a`.
![](../../screenshots/lab-02-vpc/7.png)

![](../../screenshots/lab-02-vpc/7.1.png)

#### Step 8: Turn on auto-assign public IPv4 for the public subnet
Modified `usms-public-subnet-a` to automatically assign public IPv4 addresses on launch.
![](../../screenshots/lab-02-vpc/8.png)

#### Step 9: Create the private subnet in us-east-1a
Created `usms-private-subnet-a` with CIDR `10.0.3.0/24` without public IP auto-assignment.
![](../../screenshots/lab-02-vpc/9.png)

![](../../screenshots/lab-02-vpc/9.1.png)

#### Step 10: Create the public route table and default route
Created `usms-public-rt` and added default route `0.0.0.0/0` pointing to `usms-igw`.
![](../../screenshots/lab-02-vpc/10.png)

![](../../screenshots/lab-02-vpc/10.1.png)

#### Step 11: Associate the public subnet with the public route table
Associated `usms-public-subnet-a` explicitly with `usms-public-rt`.

![](../../screenshots/lab-02-vpc/11.png)

**Individual Activity**: Create usms-public-subnet-b with CIDR 10.0.2.0/24 in us-east-1b, turn on auto-assign public IPv4 for it, associate it with usms-public-rt, and capture its ID into PUBLIC_SUBNET_B_ID. Tag it consistently with the others.

![](../../screenshots/lab-02-vpc/11.1.png)

![](../../screenshots/lab-02-vpc/11.2.png)

#### Step 12: Create the private route table and associate the private subnet
Created `usms-private-rt` with local-only routes and associated `usms-private-subnet-a`.
![](../../screenshots/lab-02-vpc/12.png)

#### Step 13: Prove the two subnets are actually different
Queried route attributes to demonstrate that Subnet A reaches IGW while Subnet B remains isolated.
![](../../screenshots/lab-02-vpc/13.png)

#### Step 14: Create the application security group
Provisioned `usms-app-sg` and authorized inbound HTTP (TCP 80) from `0.0.0.0/0`.
![](../../screenshots/lab-02-vpc/14.png)

**Individual Activity**: Add an inbound rule to usms-app-sg allowing TCP 443 from 0.0.0.0/0, and give the rule a description so that a future reader knows why it is there

![](../../screenshots/lab-02-vpc/14.1.png)

![](../../screenshots/lab-02-vpc/14.2.png)

#### Step 15: Create database security group, sourced from application group
Created `usms-db-sg` allowing PostgreSQL (TCP 5432) sourced dynamically from `usms-app-sg`.
![](../../screenshots/lab-02-vpc/15.png)

![](../../screenshots/lab-02-vpc/15.1.png)

![](../../screenshots/lab-02-vpc/15.2.png)

#### Step 16: Read groups back, and understand what stateful means
Inspected rules via `describe-security-groups` to verify return traffic is automatically allowed.
![](../../screenshots/lab-02-vpc/16.png)

#### Step 17: Explore default network ACL, then create a private one
Inspected the default VPC NACL and created a custom stateless `usms-private-nacl`.
![](../../screenshots/lab-02-vpc/17.png)

![](../../screenshots/lab-02-vpc/17.1.png)

![](../../screenshots/lab-02-vpc/17.2.png)

#### Step 18: Associate the private NACL with the private subnet
Replaced the default NACL association on `usms-private-subnet-a` with `usms-private-nacl`.
![](../../screenshots/lab-02-vpc/18.png)

#### Step 19: Give private subnet outbound internet access with a NAT Gateway
Evaluated NAT Gateway configuration for private subnet outbound patching.
![](../../screenshots/lab-02-vpc/19.png)

![](../../screenshots/lab-02-vpc/19.1.png)

#### Step 20: Point the private route table at the NAT Gateway
Configured outbound routing paths for private subnets.
![](../../screenshots/lab-02-vpc/20.png)

#### Step 21: Create the S3 Gateway Endpoint
Provisioned a free Gateway VPC Endpoint for S3 and attached it to `usms-private-rt`.
![](../../screenshots/lab-02-vpc/21.png)

#### Step 22: Audit your tags
Ran tagging queries to ensure every resource carries `Project=USMS`.
![](../../screenshots/lab-02-vpc/22.png)

#### Step 23: Prove the network survives a restart
Verified configuration persistence across environment reloads.
![](../../screenshots/lab-02-vpc/23.png)

![](../../screenshots/lab-02-vpc/23.1.png)

![](../../screenshots/lab-02-vpc/23.2.png)

#### Step 24: Write configs/lab-02.env
Saved all resource IDs into `configs/lab-02.env` and confirmed no empty variables remained.
![](../../screenshots/lab-02-vpc/24.png)

#### Step 25: Commit your work
Committed configuration files, policies, scripts, and documentation to Git.
![](../../screenshots/lab-02-vpc/24.png)

### 6.2 AWS Console Verification

#### VPC Workflow Resource Creation

![](../../screenshots/lab-02-vpc/vpc1.png)

- VPC Provisioning
- Subnets & Gateways
- Routing & NAT Components

#### Route Tables & Subnet Associations

![](../../screenshots/lab-02-vpc/vpc2.png)

- Private Route Table Details
- Subnet Associations
- Route Architecture

#### Instances & Compute Placement

![](../../screenshots/lab-02-vpc/vpc3.png)

- Instance Status
- Multi-AZ Deployment
- Public IP Allocation

## 7. Verifications

#### Build scripts/utilities/verify-lab-02.sh
Executed `verify-lab-02.sh` to validate all 33 assertion checks.

![](../../screenshots/lab-02-vpc/verification.png)


## 8. Analysis and Discussion

**Group-Referenced Security Rules**: Sourcing usms-db-sg from usms-app-sg provided dynamic access control that automatically scales as instances are added to the application group without exposing fixed IP addresses.

**Stateless vs. Stateful Boundaries**: Combining stateful Security Groups with stateless NACLs provided layered defense-in-depth protection across network tiers.

## 9. Reflection

After doing this lab, I gained experience in the construction of a VPC by using low-level CLI operations in AWS. 

- I have come to learn how subnets, route tables, and gateways relate to classify a tier as either public, private or isolated.
- I have learned the importance of relying on Security Group IDs instead of hard-coded CIDR blocks in a cloud environment.

## Conclusion

A custom, multi-tier VPC topology featuring public and private subnets across multiple Availability Zones, custom route tables, security group referencing, NACLs, and S3 VPC endpoints was successfully deployed and verified via the CLI test suite with `PASS=33 FAIL=0`.

## 10. Appendix

**Additional Files**

- `configs/lab-02.env`

- `policies/usms-db-sg-ingress.json`

- `scripts/utilities/lab-02-network-report.sh`

- `labs/lab-02-vpc/exercises.md`