## Step 32: Policy Simulator Predictions for usms-audit-01

### 1. Action: `ec2:CreateVpc`
* **Predicted Decision:** `implicitDeny`
* **Justification:** The `usms-auditors` group has the `usms-readonly-policy` attached. This policy only allows read actions (e.g., `ec2:Describe*`). There is no statement granting `ec2:CreateVpc`, nor is there an explicit `Deny` statement for it. Because AWS defaults to denying any action not explicitly allowed, this results in an **implicitDeny**.

### 2. Action: `ec2:DescribeVpcs`
* **Predicted Decision:** `allowed`
* **Justification:** The `usms-readonly-policy` attached to `usms-auditors` includes `"ec2:Describe*"` under its `Action` array inside statement `ReadOnlyEverything` with `"Effect": "Allow"`. Because `ec2:DescribeVpcs` matches the wildcard `ec2:Describe*`, the request is **allowed**.
