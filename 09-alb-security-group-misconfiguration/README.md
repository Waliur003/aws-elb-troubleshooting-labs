# Lab 09 — ALB Security Group Misconfiguration

## Overview

This lab demonstrates how to troubleshoot Application Load Balancer (ALB) connectivity problems caused by incorrect AWS security group rules.

We deploy an internet-facing Application Load Balancer with an Amazon EC2 backend running a Python HTTP server on port 8080.

The ALB listens for incoming HTTP requests on port 80 and forwards them to an EC2 target group on port 8080.

Initially, the application is accessible and the registered target is healthy.

We intentionally introduce two different security group failures:

**Scenario A — ALB Security Group Blocks Clients**

We remove the inbound HTTP rule from the ALB security group. Clients can no longer establish new connections to the ALB, but the EC2 target remains healthy.

**Scenario B — Backend Security Group Blocks ALB**

We restore the ALB inbound rule and remove the backend security group rule allowing traffic from the ALB to port 8080. The ALB remains accessible, but it cannot communicate with the backend application. Health checks fail, and the target becomes unhealthy.

We investigate the security group rules, target health status, ALB listener, EC2 status, and application connectivity.

After restoring the correct security group permissions, we verify that the target returns to a healthy state and the application responds with HTTP 200.

**Troubleshooting Workflow:**

Provision → Healthy Baseline → Fault Injection → Investigation → Root Cause Analysis → Remediation → Verification → Cleanup

---

## 1. Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-ELB-009 |
| Difficulty | Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | ALB, EC2, VPC, IAM, Systems Manager |
| Load Balancer | Application Load Balancer |
| Scheme | Internet-facing |
| Listener | HTTP 80 |
| Backend Target Group | HTTP 8080 |
| Backend Instance | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Application | Python HTTP Server |
| Application Port | 8080 |
| Health Check Path | `/health` |
| VPC CIDR | `10.168.0.0/16` |
| Public Subnet A | `10.168.1.0/24` |
| Public Subnet B | `10.168.2.0/24` |
| Fault A | ALB inbound HTTP rule removed |
| Fault B | EC2 inbound port 8080 rule removed |
| Root Cause | Missing security group permissions |
| Remediation | Restore least-privilege network rules |
| Final Verification | Target healthy and HTTP 200 |

---

## 2. Production Incident Scenario

### Incident Description

A company hosts a web application on an Amazon EC2 instance behind an AWS Application Load Balancer.

The ALB receives HTTP requests from customers on port 80 and forwards them to the backend application on port 8080.

During a security configuration update, an engineer accidentally changes security group permissions.

After the change, users report that the application is unavailable.

The cloud engineering team must determine whether the problem is caused by client-to-ALB connectivity or ALB-to-backend connectivity.

The application itself remains running.

### Scenario A — ALB Security Group Failure

The ALB security group no longer allows incoming connections on TCP port 80.

As a result, clients cannot establish new HTTP connections to the ALB.

However, the ALB can still communicate with the EC2 backend, so target health remains healthy.

### Scenario B — EC2 Security Group Failure

The ALB security group allows incoming HTTP requests, but the EC2 security group does not permit connections from the ALB to TCP port 8080.

As a result, ALB health checks fail and the registered target becomes unhealthy.

### Potential Business Impact

- Application downtime.
- Failed customer connections.
- Increased request latency.
- API request failures.
- Unhealthy target alerts.
- Reduced application availability.
- Increased troubleshooting effort.

### Incident Objective

Identify the blocked traffic path, restore the correct security group permissions, and verify successful application connectivity without opening unnecessary network ports.

---

## 3. AWS Architecture

### Healthy Architecture

```text
                     Internet Client
                            |
                            | HTTP 80
                            v
                  +---------------------+
                  | ALB Security Group  |
                  | Allow TCP 80        |
                  +----------+----------+
                             |
                             v
                  +---------------------+
                  | Application Load    |
                  | Balancer            |
                  | HTTP Listener: 80   |
                  +----------+----------+
                             |
                             | HTTP 8080
                             v
                  +---------------------+
                  | EC2 Security Group  |
                  | Allow TCP 8080      |
                  | Source: ALB SG      |
                  +----------+----------+
                             |
                             v
                  +---------------------+
                  | EC2 Backend         |
                  | Python HTTP Server  |
                  | Port: 8080          |
                  +----------+----------+
                             |
                             v
                         HTTP 200
                         Healthy
```

### Scenario A — Client Traffic Blocked

```text
                 Internet Client
                        |
                        | HTTP 80
                        v
                ALB Security Group
                        |
                        X
                 Inbound 80 Denied
                        |
                        v
                Connection Timeout


                EC2 Target: Healthy
```

### Scenario B — Backend Traffic Blocked

```text
                 Internet Client
                        |
                        v
                 ALB HTTP :80
                        |
                        v
                  Target Group
                        |
                        | TCP 8080
                        v
                EC2 Security Group
                        |
                        X
                Missing Inbound Rule
                        |
                        v
                 Target Unhealthy


           EC2 Application Still Running
```

### Resource Configuration

| Resource | Configuration |
|---|---|
| VPC | `10.168.0.0/16` |
| Subnet A | `10.168.1.0/24` |
| Subnet B | `10.168.2.0/24` |
| Internet Gateway | Attached |
| ALB Security Group | TCP 80 from internet |
| EC2 Security Group | TCP 8080 from ALB SG |
| ALB Listener | HTTP 80 |
| Target Group | HTTP 8080 |
| Health Check | `/health` |
| Application | Python HTTP Server |

---

## 4. Understanding AWS Security Groups

Security groups act as stateful virtual firewalls for AWS resources.

They control which network connections are allowed to reach or leave a resource.

Security groups contain allow rules. They do not support explicit deny rules.

If no rule permits the required traffic, that traffic is blocked.

### Security Groups Are Stateful

When a connection is allowed, the corresponding response traffic is automatically permitted.

For example:

```text
Client → ALB:80
ALB → Client response automatically allowed
```

### Security Group vs. Network ACL

| Feature | Security Group | Network ACL |
|---|---|---|
| Scope | Resource or network interface | Subnet |
| Stateful | Yes | No |
| Allow Rules | Yes | Yes |
| Deny Rules | No | Yes |
| Rule Processing | All applicable rules | Ordered rules |
| Return Traffic | Automatically permitted | Requires appropriate rules |

### Required ALB Security Group Rules

| Component | Direction | Protocol | Port | Source or Destination |
|---|---|---|---|---|
| ALB SG | Inbound | TCP | 80 | Internet clients |
| ALB SG | Outbound | TCP | 8080 | Backend targets |
| EC2 SG | Inbound | TCP | 8080 | ALB SG |

For this lab, default outbound allow rules remain enabled.

### Important Concept

An ALB can be active while clients cannot connect to it.

Likewise, an EC2 instance can be running while the ALB cannot communicate with its application.

Troubleshooting must identify which part of the network path is blocked.

---

## 5. Prerequisites and Safety

### Requirements

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- EC2 permissions
- VPC permissions
- Elastic Load Balancing permissions
- IAM permissions
- Systems Manager access
- Git and GitHub

### Safety Requirements

- Use dedicated lab infrastructure.
- Do not change production security groups for testing.
- Use unique project tags.
- Restrict backend access to the ALB.
- Verify ownership before cleanup.
- Avoid committing sensitive information.

### AWS Costs

Temporary resources may incur charges, including the ALB, EC2 instance, EBS storage, public IPv4 address, and network usage.

Delete all lab resources after completing the exercises.

---

## 6. Prepare the Environment

### Step 1 — Configure Variables

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="ELB-Troubleshooting-Lab09"

export VPC_CIDR="10.168.0.0/16"
export SUBNET_A_CIDR="10.168.1.0/24"
export SUBNET_B_CIDR="10.168.2.0/24"

export ALB_NAME="cloud-elb-lab09-alb"
export TG_NAME="cloud-elb-lab09-tg"

export ROLE_NAME="cloud-elb-lab09-ssm-role"
export PROFILE_NAME="cloud-elb-lab09-ssm-profile"
```

### Step 2 — Verify AWS Credentials

```bash
aws sts get-caller-identity
aws --version
```

### Step 3 — Select Availability Zones

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Select two supported Availability Zones:

```bash
export AZ_A="us-east-1a"
export AZ_B="us-east-1b"
```

### Step 4 — Check Existing Lab Resources

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].VpcId' \
  --output table \
  --region "$AWS_REGION"

aws elbv2 describe-load-balancers \
  --names "$ALB_NAME" \
  --region "$AWS_REGION"
```

For a new ALB, `LoadBalancerNotFound` is expected.

Avoid provisioning duplicate infrastructure.

---

## 7. Create VPC Networking

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=cloud-elb-lab09-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")

echo "$VPC_ID"
```

Enable DNS:

```bash
aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-support \
  --region "$AWS_REGION"

aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-hostnames \
  --region "$AWS_REGION"
```

### Step 2 — Create Subnets

```bash
export SUBNET_A_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_A_CIDR" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-elb-lab09-subnet-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")

export SUBNET_B_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_B_CIDR" \
  --availability-zone "$AZ_B" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-elb-lab09-subnet-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cloud-elb-lab09-igw},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Create Public Route Table

```bash
export RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-elb-lab09-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 create-route \
  --route-table-id "$RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Associate Both Subnets

```bash
export RT_ASSOC_A=$(aws ec2 associate-route-table \
  --route-table-id "$RT_ID" \
  --subnet-id "$SUBNET_A_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")

export RT_ASSOC_B=$(aws ec2 associate-route-table \
  --route-table-id "$RT_ID" \
  --subnet-id "$SUBNET_B_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

### Step 6 — Verify Routing

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
10.168.0.0/16 → local
0.0.0.0/0     → Internet Gateway
```

---

## 8. Configure Security Groups

### Step 1 — Create ALB Security Group

```bash
export ALB_SG_ID=$(aws ec2 create-security-group \
  --group-name cloud-elb-lab09-alb-sg \
  --description "Lab09 ALB security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=cloud-elb-lab09-alb-sg},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")

aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG_ID" \
  --protocol tcp \
  --port 80 \
  --cidr "0.0.0.0/0" \
  --region "$AWS_REGION"
```

### Step 2 — Create EC2 Security Group

```bash
export EC2_SG_ID=$(aws ec2 create-security-group \
  --group-name cloud-elb-lab09-ec2-sg \
  --description "Lab09 backend security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=cloud-elb-lab09-ec2-sg},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")

aws ec2 authorize-security-group-ingress \
  --group-id "$EC2_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

### Step 3 — Verify Rules

```bash
aws ec2 describe-security-groups \
  --group-ids "$ALB_SG_ID" "$EC2_SG_ID" \
  --query 'SecurityGroups[].{Name:GroupName,Ingress:IpPermissions,Egress:IpPermissionsEgress}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

| Security Group | Inbound |
|---|---|
| ALB SG | TCP 80 from internet |
| EC2 SG | TCP 8080 from ALB SG |

---

## 9. Configure IAM and Systems Manager

Create `ec2-trust-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

Verify that the IAM role and instance profile names are not already in use.

Create:

```bash
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam create-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME"
```

Allow IAM propagation before launching EC2.

---

## 10. Create the Python Backend Application

Create `backend-user-data.sh`:

```bash
#!/bin/bash
set -eux

mkdir -p /opt/lab09

cat > /opt/lab09/index.html <<'HTML'
AWS ELB Troubleshooting Lab 09

Application: Security Group Troubleshooting
Backend Port: 8080
Status: Healthy
HTML

cat > /opt/lab09/health <<'HEALTH'
OK
HEALTH

cat > /etc/systemd/system/lab09-web.service <<'UNIT'
[Unit]
Description=Lab 09 ALB Security Group Backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/lab09
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab09-web.service
```

### Application Endpoints

| Endpoint | Expected Response |
|---|---|
| `/` | HTTP 200 |
| `/health` | HTTP 200 |
| Unknown path | HTTP 404 |

The application remains active during both fault injections.

---

## 11. Launch EC2

### Step 1 — Retrieve Amazon Linux AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Launch Backend Instance

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --network-interfaces \
    "DeviceIndex=0,SubnetId=$SUBNET_A_ID,Groups=$EC2_SG_ID,AssociatePublicIpAddress=true" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --user-data file://backend-user-data.sh \
  --count 1 \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=cloud-elb-lab09-backend},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Wait for EC2

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Verify Backend

Check Systems Manager:

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Once the instance is online:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
sudo systemctl is-active lab09-web.service

sudo ss -lntp | grep ':8080'

curl --noproxy '*' -i http://127.0.0.1:8080/

curl --noproxy '*' -i http://127.0.0.1:8080/health
```

Expected: service active and HTTP 200.

Exit Session Manager.

---

## 12. Create ALB and Target Group

### Step 1 — Create Target Group

```bash
export TG_ARN=$(aws elbv2 create-target-group \
  --name "$TG_NAME" \
  --protocol HTTP \
  --port 8080 \
  --vpc-id "$VPC_ID" \
  --target-type instance \
  --health-check-protocol HTTP \
  --health-check-port traffic-port \
  --health-check-path "/health" \
  --health-check-interval-seconds 15 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 2 \
  --matcher HttpCode=200 \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Register EC2

```bash
aws elbv2 register-targets \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

### Step 3 — Create ALB

```bash
export ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "$ALB_NAME" \
  --type application \
  --scheme internet-facing \
  --ip-address-type ipv4 \
  --subnets "$SUBNET_A_ID" "$SUBNET_B_ID" \
  --security-groups "$ALB_SG_ID" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text \
  --region "$AWS_REGION")

aws elbv2 wait load-balancer-available \
  --load-balancer-arns "$ALB_ARN" \
  --region "$AWS_REGION"
```

### Step 4 — Create HTTP Listener

```bash
export LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
  --query 'Listeners[0].ListenerArn' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Retrieve ALB DNS

```bash
export ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' \
  --output text \
  --region "$AWS_REGION")

echo "$ALB_DNS"
```

---

## 13. Establish Healthy Baseline

### Step 1 — Verify Target Health

```bash
aws elbv2 wait target-in-service \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

Inspect:

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{ID:Target.Id,State:TargetHealth.State}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `healthy`.

### Step 2 — Test Application

```bash
curl --noproxy '*' -i \
  --connect-timeout 5 \
  --max-time 15 \
  "http://${ALB_DNS}/"
```

Expected: HTTP 200.

### Step 3 — Test Health Endpoint

```bash
curl --noproxy '*' -i \
  "http://${ALB_DNS}/health"
```

Expected: HTTP 200.

### Healthy Baseline Summary

| Component | Expected Result |
|---|---|
| ALB | Active |
| EC2 | Running |
| Application | Active |
| ALB SG Port 80 | Allowed |
| EC2 SG Port 8080 | Allowed from ALB |
| Target Health | Healthy |
| HTTP Response | 200 |

---

## 14. Fault Injection A — ALB Security Group Blocks Clients

### Step 1 — Remove ALB Inbound Rule

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$ALB_SG_ID" \
  --protocol tcp \
  --port 80 \
  --cidr "0.0.0.0/0" \
  --region "$AWS_REGION"
```

This removes the rule allowing clients to establish new HTTP connections to the ALB.

### Step 2 — Verify Security Group

```bash
aws ec2 describe-security-groups \
  --group-ids "$ALB_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
[]
```

### Step 3 — Test Client Connectivity

```bash
curl --noproxy '*' -v \
  --connect-timeout 5 \
  --max-time 10 \
  "http://${ALB_DNS}/"
```

Expected: a new connection times out.

Example:

```text
curl: (28) Failed to connect: Connection timed out
```

The exact message can vary by client and network conditions.

### Step 4 — Verify Target Health

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{State:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `healthy`.

### Why Does Target Health Remain Healthy?

The ALB security group blocks incoming client requests on port 80.

However, the ALB's connections to its backend use port 8080.

Because the backend security group still permits this communication, health checks continue working.

### Fault A Findings

| Component | Finding |
|---|---|
| ALB | Active |
| HTTP Listener | Exists |
| ALB Inbound TCP 80 | Missing |
| Backend Application | Active |
| Target Health | Healthy |
| Client Connection | Times out |
| Root Cause | ALB security group ingress |

---

## 15. Remediation A — Restore Client Access

### Step 1 — Reauthorize HTTP

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG_ID" \
  --protocol tcp \
  --port 80 \
  --cidr "0.0.0.0/0" \
  --region "$AWS_REGION"
```

### Step 2 — Verify Connection

```bash
curl --noproxy '*' -i \
  --connect-timeout 5 \
  --max-time 15 \
  "http://${ALB_DNS}/"
```

Expected: HTTP 200.

This completes the first incident.

---

## 16. Fault Injection B — EC2 Security Group Blocks the ALB

### Step 1 — Remove Backend Port 8080 Rule

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$EC2_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

The EC2 security group no longer permits the ALB to communicate with the backend application.

### Step 2 — Verify Backend Security Group

```bash
aws ec2 describe-security-groups \
  --group-ids "$EC2_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected: the inbound TCP 8080 permission is missing.

### Step 3 — Monitor Target Health

```bash
for i in {1..12}; do
  date -u +"%Y-%m-%dT%H:%M:%SZ"

  aws elbv2 describe-target-health \
    --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[].{State:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}' \
    --output table \
    --region "$AWS_REGION"

  sleep 15
done
```

Expected after failed health checks:

```text
State: unhealthy
Reason: Target.Timeout
```

The exact health reason may vary depending on the observed failure.

### Step 4 — Test ALB Request

```bash
curl --noproxy '*' -v \
  --connect-timeout 5 \
  --max-time 20 \
  "http://${ALB_DNS}/"
```

A possible result is HTTP 504 Gateway Timeout because the ALB cannot connect to its backend.

The actual response may vary. Use target health and security group evidence as the primary diagnosis.

### Step 5 — Verify Application Is Running

Connect through Systems Manager:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
sudo systemctl is-active lab09-web.service

sudo ss -lntp | grep ':8080'

curl --noproxy '*' -i \
  http://127.0.0.1:8080/health
```

Expected:

```text
Service: active
Port: 8080 listening
Health Endpoint: HTTP 200
```

Exit Session Manager.

### Why Does This Matter?

The application itself works.

The failure occurs because network traffic from the ALB is blocked by the EC2 security group.

### Fault B Findings

| Component | Finding |
|---|---|
| ALB | Active |
| Client Access to ALB | Allowed |
| Backend EC2 | Running |
| Application Service | Active |
| Local Health Endpoint | HTTP 200 |
| EC2 SG Inbound 8080 | Missing |
| Target Health | Unhealthy |
| Root Cause | Backend security group ingress |

---

## 17. Troubleshooting Investigation

### Check 1 — ALB State

```bash
aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].{Name:LoadBalancerName,State:State.Code,SecurityGroups:SecurityGroups}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: ALB is active.

### Check 2 — Listener Configuration

```bash
aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[].{Port:Port,Protocol:Protocol,Actions:DefaultActions}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: listener is configured correctly.

### Check 3 — Target Group Configuration

```bash
aws elbv2 describe-target-groups \
  --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[].{Protocol:Protocol,Port:Port,HealthPort:HealthCheckPort,HealthPath:HealthCheckPath}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: HTTP 8080 and `/health`.

### Check 4 — Security Group Rules

```bash
aws ec2 describe-security-groups \
  --group-ids "$ALB_SG_ID" "$EC2_SG_ID" \
  --query 'SecurityGroups[].{Name:GroupName,ID:GroupId,Inbound:IpPermissions,Outbound:IpPermissionsEgress}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: the backend security group is missing the inbound TCP 8080 rule from the ALB security group.

### Check 5 — EC2 Infrastructure Health

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{System:SystemStatus.Status,Instance:InstanceStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: both status checks `ok`.

### Investigation Summary

| Component | Finding |
|---|---|
| ALB | Active |
| Listener | Correct |
| Target Group | Correct |
| EC2 | Running |
| Application | Active |
| Application Port | 8080 |
| ALB SG | Correct during Fault B |
| EC2 SG | Missing inbound rule |
| Target Health | Unhealthy |
| Root Cause | Security group blocks ALB-to-backend traffic |

---

## 18. Root Cause Analysis

### Scenario A — Root Cause

The ALB security group did not permit inbound TCP port 80 from clients.

Although the ALB listener existed and the backend was healthy, clients could not establish new HTTP connections.

### Scenario B — Root Cause

The EC2 backend security group did not permit inbound TCP port 8080 from the ALB security group.

As a result, ALB-to-target connections and health checks failed.

The EC2 application remained active and responded successfully to local requests.

### Root Cause Comparison

| Item | Scenario A | Scenario B |
|---|---|---|
| Blocked Traffic | Client → ALB | ALB → EC2 |
| Security Group | ALB SG | EC2 SG |
| Missing Port | 80 | 8080 |
| ALB Listener | Active | Active |
| EC2 Application | Active | Active |
| Target Health | Healthy | Unhealthy |
| Client Symptom | Connection timeout | Backend timeout/error |

### Five Whys

1. **Why was the application unavailable?** Required network traffic was blocked.
2. **Why was traffic blocked?** The corresponding inbound security group permission was missing.
3. **Why did the security group rule disappear?** It was intentionally removed to simulate a configuration error.
4. **Why did EC2 remain running?** EC2 infrastructure health is separate from application network reachability.
5. **How can this be prevented?** Use least-privilege security group rules, infrastructure as code, configuration reviews, and automated connectivity checks.

---

## 19. Remediation B — Restore Backend Connectivity

### Step 1 — Restore EC2 Inbound Rule

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$EC2_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

### Step 2 — Verify Security Group

```bash
aws ec2 describe-security-groups \
  --group-ids "$EC2_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected: TCP 8080 allowed from ALB SG.

### Step 3 — Wait for Target Recovery

```bash
aws elbv2 wait target-in-service \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

### Step 4 — Verify Target Health

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{State:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `healthy`.

### Step 5 — Verify Application

```bash
curl --noproxy '*' -i \
  --connect-timeout 5 \
  --max-time 15 \
  "http://${ALB_DNS}/"
```

Expected: HTTP 200.

### Step 6 — Verify Health Endpoint

```bash
curl --noproxy '*' -i \
  "http://${ALB_DNS}/health"
```

Expected: HTTP 200.

### Step 7 — Run Repeated Requests

```bash
for i in {1..5}; do
  curl --noproxy '*' -sS \
    -o /dev/null \
    -w "Request $i: HTTP %{http_code}\n" \
    --connect-timeout 5 \
    --max-time 15 \
    "http://${ALB_DNS}/"
done
```

Expected: all requests return HTTP 200.

### Verification Matrix

| Check | Healthy Baseline | Fault A | Fault B | After Fix |
|---|---|---|---|---|
| ALB SG Inbound 80 | Allowed | Blocked | Allowed | Allowed |
| EC2 SG Inbound 8080 | Allowed | Allowed | Blocked | Allowed |
| Target Health | Healthy | Healthy | Unhealthy | Healthy |
| ALB Reachable | Yes | No | Yes | Yes |
| Application Accessible | Yes | No | No | Yes |
| EC2 Application | Active | Active | Active | Active |

### Success Criteria

- Healthy ALB baseline established.
- Client access blocked by ALB security group.
- Connection failure reproduced.
- Target health remains healthy during Fault A.
- Client access restored.
- Backend access blocked by EC2 security group.
- Target becomes unhealthy.
- Application confirmed working locally.
- Backend security group corrected.
- Target returns to healthy.
- HTTP 200 verified.

---

## 20. Production Best Practices

### Security Group Troubleshooting Checklist

1. Verify ALB status.
2. Inspect listener port and protocol.
3. Check ALB security group inbound rules.
4. Check ALB security group outbound rules.
5. Confirm registered target port.
6. Inspect EC2 security group inbound rules.
7. Verify health check settings.
8. Check target health reason codes.
9. Verify EC2 instance health.
10. Test backend application locally.
11. Inspect subnet routing and network ACLs if necessary.
12. Apply least-privilege remediation.
13. Verify target recovery and application response.

### Common Security Group Misconfigurations

| Problem | Effect | Remediation |
|---|---|---|
| ALB inbound port blocked | Clients cannot connect | Allow intended listener traffic |
| EC2 backend port blocked | Target health fails | Allow ALB SG on backend port |
| ALB outbound port blocked | ALB cannot reach target | Permit required outbound traffic |
| Wrong source CIDR | Authorized clients blocked | Correct approved source |
| Wrong security group reference | ALB-to-target blocked | Reference correct SG |
| Incorrect target port | Connection failure | Correct target registration |
| Overly broad ingress | Unnecessary exposure | Restrict to approved sources |

### Prevention

- Use Terraform or CloudFormation.
- Apply least-privilege network access.
- Review security group changes through pull requests.
- Monitor target health with CloudWatch.
- Enable CloudTrail for configuration auditing.
- Keep application ports documented.
- Use automated connectivity tests.
- Validate changes in staging before production.
- Avoid unnecessary public access to backend instances.

### Security Considerations

- Do not open backend port 8080 to the entire internet.
- Use the ALB security group as the backend source.
- Use HTTPS for production client connections.
- Restrict IAM permissions.
- Avoid disabling security controls to solve connectivity issues.
- Remove temporary permissions after testing.

---

## 21. Cleanup

**Warning:** Verify ownership of all resources before running destructive commands. Delete only resources tagged `ELB-Troubleshooting-Lab09`.

### Step 1 — Verify Ownership

```bash
aws sts get-caller-identity

aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].Tags' \
  --output json \
  --region "$AWS_REGION"

aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"

aws elbv2 describe-tags \
  --resource-arns "$ALB_ARN" "$TG_ARN" \
  --region "$AWS_REGION"
```

### Step 2 — Delete Listener

```bash
aws elbv2 delete-listener \
  --listener-arn "$LISTENER_ARN" \
  --region "$AWS_REGION"
```

### Step 3 — Delete ALB

```bash
aws elbv2 delete-load-balancer \
  --load-balancer-arn "$ALB_ARN" \
  --region "$AWS_REGION"

aws elbv2 wait load-balancers-deleted \
  --load-balancer-arns "$ALB_ARN" \
  --region "$AWS_REGION"
```

### Step 4 — Delete Target Group

```bash
aws elbv2 deregister-targets \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"

aws elbv2 delete-target-group \
  --target-group-arn "$TG_ARN" \
  --region "$AWS_REGION"
```

### Step 5 — Verify EBS Volume Configuration

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the root volume has `DeleteOnTermination=true`.

### Step 6 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Remove Security Group Dependencies

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$EC2_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

Check network interfaces:

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

When lab ENIs have been deleted:

```bash
aws ec2 delete-security-group \
  --group-id "$EC2_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Delete IAM Resources

First verify that the IAM role and instance profile belong to the lab and are not shared:

```bash
aws iam list-role-tags \
  --role-name "$ROLE_NAME"

aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

Delete:

```bash
aws iam detach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam remove-role-from-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME"

aws iam delete-instance-profile \
  --instance-profile-name "$PROFILE_NAME"

aws iam delete-role \
  --role-name "$ROLE_NAME"
```

### Step 9 — Delete Networking

```bash
aws ec2 disassociate-route-table \
  --association-id "$RT_ASSOC_A" \
  --region "$AWS_REGION"

aws ec2 disassociate-route-table \
  --association-id "$RT_ASSOC_B" \
  --region "$AWS_REGION"

aws ec2 delete-route-table \
  --route-table-id "$RT_ID" \
  --region "$AWS_REGION"

aws ec2 delete-subnet \
  --subnet-id "$SUBNET_A_ID" \
  --region "$AWS_REGION"

aws ec2 delete-subnet \
  --subnet-id "$SUBNET_B_ID" \
  --region "$AWS_REGION"

aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"

aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 10 — Verify Cleanup

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].VpcId' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
[]
```

Verify ALB deletion:

```bash
aws elbv2 describe-load-balancers \
  --names "$ALB_NAME" \
  --region "$AWS_REGION"
```

Expected: `LoadBalancerNotFound`.

Also verify that the target group, EC2 instance, root EBS volume, IAM resources, and dedicated network resources have been removed.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| ALB Listener | Deleted |
| ALB | Deleted |
| Target Group | Deleted |
| EC2 Instance | Terminated |
| Root EBS Volume | Deleted |
| ALB SG | Deleted |
| Backend SG | Deleted |
| IAM Role | Deleted |
| Instance Profile | Deleted |
| Route Table | Deleted |
| Both Subnets | Deleted |
| Internet Gateway | Deleted |
| Lab VPC | Deleted |
| Default VPC | Unchanged |

---

## 22. Interview Questions and Answers

### Q1. What is an AWS security group?

A stateful virtual firewall that controls allowed inbound and outbound network traffic.

### Q2. What happens if an ALB security group blocks inbound port 80?

Clients cannot establish new HTTP connections to the ALB, even when the backend is healthy.

### Q3. What happens if an EC2 security group blocks ALB traffic?

Health checks and forwarded requests can fail because the ALB cannot reach the backend application.

### Q4. Why can the ALB return HTTP 504?

One possible cause is a timeout while establishing a connection to the backend target.

### Q5. Can the target remain healthy while clients cannot access the ALB?

Yes. Client-to-ALB connectivity and ALB-to-backend health checks are separate.

### Q6. How should backend security groups be configured?

Allow the required application and health check ports from the ALB security group rather than the public internet.

### Q7. Are AWS security groups stateful?

Yes. Return traffic for allowed connections is automatically permitted.

### Q8. What is the difference between a security group and a network ACL?

Security groups are stateful resource-level controls. Network ACLs are stateless subnet-level controls.

### Q9. Which AWS CLI command displays security group rules?

`aws ec2 describe-security-groups`.

### Q10. Why does the ALB need outbound permissions?

The ALB must be able to connect to backend targets for request forwarding and health checks.

### Q11. How can security group incidents be prevented?

Use infrastructure as code, least-privilege permissions, change reviews, monitoring, and automated connectivity tests.

### Q12. How would you explain this lab in an interview?

I deployed an AWS Application Load Balancer with an EC2 backend running a Python HTTP server on port 8080.

After establishing a healthy baseline, I simulated two security group failures.

First, I removed the ALB inbound HTTP rule, which blocked client access while target health remained healthy.

Then I restored client access and removed the backend security group permission allowing traffic from the ALB on port 8080.

The target became unhealthy even though the application remained active.

I investigated the ALB listener, target group, security group rules, EC2 health, and local application connectivity.

After restoring the least-privilege permissions, I verified healthy target status and successful HTTP 200 responses.

---

## 23. Repository Structure

```text
09-alb-security-group-misconfiguration/
├── README.md
├── ec2-trust-policy.json
└── backend-user-data.sh
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete troubleshooting documentation for both security group failures |
| `ec2-trust-policy.json` | IAM trust policy for EC2 Systems Manager |
| `backend-user-data.sh` | Deploys and starts the Python HTTP backend |

Never commit AWS credentials, private keys, or sensitive information.

---

## 24. Lessons Learned

This lab demonstrates how incorrect security group rules can cause application connectivity failures even when the ALB and EC2 infrastructure are running.

The first incident blocked incoming client traffic to the ALB. The backend remained healthy because health check communication was unaffected.

The second incident blocked communication between the ALB and the EC2 backend. The application remained active, but the ALB health checks failed.

The most important troubleshooting lesson was identifying which network connection was blocked instead of assuming the application itself had failed.

Restoring the correct security group permissions resolved both incidents.

**Key Lesson:** When troubleshooting an ALB, separately investigate client-to-ALB connectivity and ALB-to-backend connectivity. These paths have different security group requirements and produce different symptoms.

---

## 25. Skills Demonstrated

- AWS Application Load Balancer
- Security group troubleshooting
- Client-to-ALB connectivity
- ALB-to-backend connectivity
- Target health investigation
- HTTP connection timeout analysis
- AWS CLI v2
- EC2 diagnostics
- Systems Manager
- Linux systemd
- curl
- VPC networking
- Least-privilege security configuration
- Fault injection
- Root cause analysis
- Remediation and verification
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-ELB-009 |
| Problem | ALB security group misconfiguration |
| Fault A | ALB inbound port 80 removed |
| Fault B | Backend inbound port 8080 removed |
| EC2 Application | Running |
| ALB | Active |
| Target Health During Fault A | Healthy |
| Target Health During Fault B | Unhealthy |
| Root Cause | Missing security group permissions |
| Remediation | Restore least-privilege rules |
| Final Target Health | Healthy |
| Final HTTP Response | 200 |
| Cleanup | Temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** A healthy application does not guarantee successful network access. AWS security groups must permit both client-to-ALB traffic and ALB-to-backend traffic for an application to operate correctly.
