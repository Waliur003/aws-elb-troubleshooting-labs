# Lab 10 — ALB Target Registration Failure

## Overview

This lab demonstrates how to troubleshoot an AWS Application Load Balancer (ALB) that returns HTTP 503 because its target group contains no registered EC2 instances.

We deploy an internet-facing ALB with an Amazon EC2 instance running a Python HTTP server on port 8080.

Initially, the EC2 instance is registered with the target group, passes its health checks, and serves HTTP 200 responses through the ALB.

We then intentionally deregister the EC2 instance from the target group.

The EC2 instance continues running and the application remains healthy. However, the target group becomes empty, so the ALB has no backend target to receive requests.

The ALB returns HTTP 503 Service Unavailable.

We investigate the ALB listener, target group configuration, registered target count, EC2 status, and backend application.

After identifying the missing registration, we register the instance again and verify successful application connectivity.

**Troubleshooting workflow:**

Provision → Healthy Baseline → Fault Injection → Investigation → Root Cause Analysis → Remediation → Verification → Cleanup

---

## 1. Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-ELB-010 |
| Difficulty | Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | ALB, EC2, VPC, IAM, Systems Manager, CloudWatch |
| Load Balancer | Application Load Balancer |
| ALB Scheme | Internet-facing |
| Listener | HTTP 80 |
| Target Group | HTTP 8080 |
| Target Type | Instance |
| EC2 OS | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Backend Application | Python HTTP server |
| Application Port | 8080 |
| Health Check Path | `/health` |
| VPC CIDR | `10.169.0.0/16` |
| Subnet A | `10.169.1.0/24` |
| Subnet B | `10.169.2.0/24` |
| Fault Injection | Deregister the only EC2 target |
| Expected Error | HTTP 503 Service Unavailable |
| Root Cause | No registered targets |
| Remediation | Register the EC2 instance again |
| Expected Final Result | Healthy target and HTTP 200 |

---

## 2. Production Incident Scenario

### Incident Description

A company hosts a web application on Amazon EC2 behind an Application Load Balancer.

The application runs on port 8080 and exposes a health check endpoint at `/health`.

The ALB receives HTTP requests on port 80 and forwards them to an EC2 target group.

During an infrastructure deployment, an engineer accidentally deregisters the application's EC2 instance from the target group.

The instance continues running, and the application remains available locally.

However, the target group contains zero registered targets.

Customers begin receiving HTTP 503 Service Unavailable.

### Incident Symptoms

- ALB remains active.
- HTTP listener remains correctly configured.
- EC2 instance is running.
- EC2 status checks pass.
- Python application remains active.
- Application listens on TCP port 8080.
- Local `/health` endpoint returns HTTP 200.
- Target group configuration is correct.
- Target group contains zero registered targets.
- ALB returns HTTP 503.

### Potential Business Impact

- Application downtime.
- Failed customer requests.
- Increased HTTP 503 errors.
- Application unavailability despite healthy EC2 infrastructure.
- Failed API requests.
- Deployment incidents.
- Reduced service reliability.

### Objective

Identify the missing target registration, restore the instance to the correct target group, and verify HTTP 200 responses without restarting the backend application.

---

## 3. AWS Architecture

### Healthy Architecture

```text
                  Internet Client
                         |
                         | HTTP 80
                         v
              +----------------------+
              | Application Load     |
              | Balancer             |
              | Listener: HTTP 80    |
              +----------+-----------+
                         |
                         v
              +----------------------+
              | Target Group         |
              | Protocol: HTTP       |
              | Port: 8080           |
              | Registered Targets: 1|
              +----------+-----------+
                         |
                         v
              +----------------------+
              | EC2 Backend          |
              | Python HTTP Server   |
              | Port: 8080           |
              +----------+-----------+
                         |
                         v
                    HTTP 200 OK
                    Target Healthy
```

### Broken Architecture

```text
                  Internet Client
                         |
                         v
              Application Load Balancer
                         |
                         v
                   HTTP Listener
                         |
                         v
                    Target Group
                         |
                         v
                Registered Targets: 0
                         |
                         X
                  No Backend Target
                         |
                         v
               HTTP 503 Service Unavailable


              EC2 Application Still Running
```

### Infrastructure Configuration

| Component | Configuration |
|---|---|
| VPC | `10.169.0.0/16` |
| Subnet A | `10.169.1.0/24` |
| Subnet B | `10.169.2.0/24` |
| Internet Gateway | Attached |
| Public Route | `0.0.0.0/0` through IGW |
| ALB Security Group | TCP 80 from internet |
| Backend Security Group | TCP 8080 from ALB SG |
| Listener | HTTP 80 |
| Target Group | HTTP 8080 |
| Health Check | `/health` |

---

## 4. Understanding ALB Target Registration

An Application Load Balancer forwards requests to registered targets through a target group.

Targets can be EC2 instances, IP addresses, Lambda functions, or other supported target types.

In this lab, the target type is `instance`.

### Registered Target

An EC2 instance is associated with a target group and can receive requests when eligible.

Example:

```bash
aws elbv2 register-targets \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

### Unregistered Target

The EC2 instance is not associated with the target group.

It cannot receive traffic through that group even if its application is running correctly.

### Registered Unhealthy vs. Unregistered

| State | Description |
|---|---|
| Registered Healthy | Target exists and passes health checks |
| Registered Unhealthy | Target exists but fails health checks |
| Unregistered | Target is not associated with the group |
| Draining | Target is being deregistered |

### Important Difference

An ALB may fail open and forward requests when all registered targets are unhealthy.

However, an empty target group contains no backend targets at all.

When an ALB forwards to an empty target group, it generates HTTP 503 Service Unavailable.

### `Target.NotRegistered`

When querying a particular target that is not registered, AWS may return:

```text
State: unused
Reason: Target.NotRegistered
```

A normal query that lists every registered target in an empty target group instead returns:

```json
{
  "TargetHealthDescriptions": []
}
```

These two results are different and both are useful for troubleshooting.

---

## 5. Prerequisites and Safety

### Requirements

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- EC2 permissions
- VPC permissions
- ELBv2 permissions
- IAM permissions
- Systems Manager access
- CloudWatch read permissions
- Git and GitHub

### Safety Requirements

- Use dedicated lab resources.
- Do not deregister production targets for testing.
- Verify AWS account identity.
- Use project tags to identify resources.
- Avoid committing credentials or private keys.
- Delete temporary infrastructure after the experiment.

### Cost Considerations

The ALB, EC2 instance, EBS volume, public IPv4 address, and network usage may incur charges.

---

## 6. Prepare the Environment

### Step 1 — Configure Variables

Run in Ubuntu WSL2:

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="ELB-Troubleshooting-Lab10"

export VPC_CIDR="10.169.0.0/16"
export SUBNET_A_CIDR="10.169.1.0/24"
export SUBNET_B_CIDR="10.169.2.0/24"

export ALB_NAME="cloud-elb-lab10-alb"
export TG_NAME="cloud-elb-lab10-tg"

export ROLE_NAME="cloud-elb-lab10-ssm-role"
export PROFILE_NAME="cloud-elb-lab10-ssm-profile"
```

### Step 2 — Verify Credentials

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

Choose two supported zones:

```bash
export AZ_A="us-east-1a"
export AZ_B="us-east-1b"
```

### Step 4 — Check Existing Resources

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

Avoid provisioning duplicate resources.

---

## 7. Create VPC Networking

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=cloud-elb-lab10-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")
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

### Step 2 — Create Two Subnets

```bash
export SUBNET_A_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_A_CIDR" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-elb-lab10-subnet-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")

export SUBNET_B_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_B_CIDR" \
  --availability-zone "$AZ_B" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-elb-lab10-subnet-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cloud-elb-lab10-igw},{Key=Project,Value=$PROJECT_TAG}]" \
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
  "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-elb-lab10-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 create-route \
  --route-table-id "$RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Associate Subnets

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

Verify:

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
10.169.0.0/16 → local
0.0.0.0/0     → Internet Gateway
```

---

## 8. Configure Security Groups

### Step 1 — Create ALB Security Group

```bash
export ALB_SG_ID=$(aws ec2 create-security-group \
  --group-name cloud-elb-lab10-alb-sg \
  --description "Lab10 ALB SG" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=cloud-elb-lab10-alb-sg},{Key=Project,Value=$PROJECT_TAG}]" \
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
  --group-name cloud-elb-lab10-ec2-sg \
  --description "Lab10 backend SG" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=cloud-elb-lab10-ec2-sg},{Key=Project,Value=$PROJECT_TAG}]" \
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
  --query 'SecurityGroups[].{Name:GroupName,Inbound:IpPermissions}' \
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

Check whether the IAM role and instance profile already exist.

For new resources, create:

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

Allow IAM changes to propagate before launching EC2.

---

## 10. Create Python Backend Application

Create `backend-user-data.sh`:

```bash
#!/bin/bash
set -eux

mkdir -p /opt/lab10

cat > /opt/lab10/index.html <<'HTML'
AWS ELB Troubleshooting Lab 10

Application: Target Registration Troubleshooting
Backend Port: 8080
Status: Healthy
HTML

cat > /opt/lab10/health <<'HEALTH'
OK
HEALTH

cat > /etc/systemd/system/lab10-web.service <<'UNIT'
[Unit]
Description=Lab 10 ALB Target Registration Backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/lab10
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab10-web.service
```

### Application Endpoints

| Endpoint | Expected Response |
|---|---|
| `/` | HTTP 200 |
| `/health` | HTTP 200 |
| Unknown path | HTTP 404 |

---

## 11. Launch EC2

### Step 1 — Retrieve Amazon Linux 2023 AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Check Existing Instances

```bash
aws ec2 describe-instances \
  --filters \
    "Name=tag:Project,Values=$PROJECT_TAG" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}' \
  --output table \
  --region "$AWS_REGION"
```

### Step 3 — Launch Instance

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
  "ResourceType=instance,Tags=[{Key=Name,Value=cloud-elb-lab10-backend},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Wait for EC2

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Verify Application

Check Systems Manager:

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Once the instance reports `Online`, connect:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
sudo systemctl is-active lab10-web.service

sudo ss -lntp | grep ':8080'

curl --noproxy '*' -i \
  http://127.0.0.1:8080/

curl --noproxy '*' -i \
  http://127.0.0.1:8080/health
```

Expected: active service and HTTP 200 responses.

Exit Session Manager.

---

## 12. Create Target Group and ALB

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

### Step 3 — Verify Registration

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{Instance:Target.Id,Port:Target.Port,State:TargetHealth.State}' \
  --output table \
  --region "$AWS_REGION"
```

The target should appear in the result.

Before the target group is attached to an ALB listener, its state may be `unused`.

### Step 4 — Create ALB

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

### Step 5 — Create Listener

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

### Step 6 — Get ALB DNS

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

### Step 1 — Wait for Target Health

```bash
aws elbv2 wait target-in-service \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

Verify:

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{Instance:Target.Id,Port:Target.Port,State:TargetHealth.State}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Port: 8080
State: healthy
```

### Step 2 — Verify Application Access

```bash
curl --noproxy '*' -i \
  --connect-timeout 5 \
  --max-time 15 \
  "http://${ALB_DNS}/"
```

Expected: HTTP 200.

### Step 3 — Verify Health Endpoint

```bash
curl --noproxy '*' -i \
  "http://${ALB_DNS}/health"
```

Expected: HTTP 200.

### Baseline Summary

| Component | Expected Result |
|---|---|
| ALB | Active |
| EC2 | Running |
| Backend Application | Active |
| Registered Target Count | 1 |
| Target Health | Healthy |
| HTTP Response | 200 |

---

## 14. Fault Injection — Deregister the Target

### Step 1 — Configure Lab Deregistration Delay

```bash
aws elbv2 modify-target-group-attributes \
  --target-group-arn "$TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=0 \
  --region "$AWS_REGION"
```

The zero-second delay is appropriate only for this disposable experiment.

Production systems usually require a suitable connection-draining period.

### Step 2 — Deregister EC2

```bash
aws elbv2 deregister-targets \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

This intentionally removes the only backend target.

The EC2 instance continues running.

### Step 3 — Verify Deregistration

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --output json \
  --region "$AWS_REGION"
```

During deregistration, the target may temporarily show `draining`.

Once deregistration completes:

```json
{
  "TargetHealthDescriptions": []
}
```

### Step 4 — Monitor Target Group

```bash
for i in {1..12}; do
  aws elbv2 describe-target-health \
    --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[].{Instance:Target.Id,State:TargetHealth.State}' \
    --output json \
    --region "$AWS_REGION"

  sleep 10
done
```

Stop after the output becomes `[]`.

### Step 5 — Query the Missing Target Explicitly

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
State: unused
Reason: Target.NotRegistered
```

### Step 6 — Reproduce HTTP 503

```bash
curl --noproxy '*' -i \
  --connect-timeout 5 \
  --max-time 15 \
  "http://${ALB_DNS}/"
```

Expected:

```http
HTTP/1.1 503 Service Unavailable
Server: awselb/2.0
```

### Step 7 — Verify Multiple Failed Requests

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

Expected: five HTTP 503 responses after deregistration completes.

### Fault Summary

| Component | Finding |
|---|---|
| ALB | Active |
| Listener | Correct |
| Target Group | Exists |
| Registered Targets | 0 |
| EC2 | Running |
| Application | Active |
| Backend Port | 8080 |
| ALB Response | HTTP 503 |
| Root Cause | Missing target registration |

---

## 15. Troubleshooting Investigation

### Check 1 — Verify ALB

```bash
aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].{Name:LoadBalancerName,State:State.Code,DNS:DNSName}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: ALB is active.

### Check 2 — Verify Listener

```bash
aws elbv2 describe-listeners \
  --listener-arns "$LISTENER_ARN" \
  --query 'Listeners[].{Port:Port,Protocol:Protocol,DefaultActions:DefaultActions}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: listener forwards to the expected target group.

### Check 3 — Inspect Target Group Configuration

```bash
aws elbv2 describe-target-groups \
  --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[].{Name:TargetGroupName,Port:Port,Protocol:Protocol,HealthPath:HealthCheckPath}' \
  --output table \
  --region "$AWS_REGION"
```

Finding: target group uses HTTP 8080 and `/health`.

### Check 4 — Count Registered Targets

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'length(TargetHealthDescriptions)' \
  --output text \
  --region "$AWS_REGION"
```

Expected:

```text
0
```

This is the primary evidence that target registration is missing.

### Check 5 — Verify EC2 State

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name,PrivateIP:PrivateIpAddress}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `running`.

### Check 6 — Verify EC2 Infrastructure Health

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{System:SystemStatus.Status,Instance:InstanceStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: both checks `ok`.

### Check 7 — Verify Backend Application

Connect:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
sudo systemctl is-active lab10-web.service

sudo ss -lntp | grep ':8080'

curl --noproxy '*' -i \
  http://127.0.0.1:8080/health
```

Expected: service active and HTTP 200.

Exit the session.

### Check 8 — Verify Security Groups

```bash
aws ec2 describe-security-groups \
  --group-ids "$ALB_SG_ID" "$EC2_SG_ID" \
  --query 'SecurityGroups[].{Name:GroupName,Inbound:IpPermissions}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: required network permissions remain correctly configured.

### Check 9 — Inspect CloudWatch 503 Metric

Retrieve the load balancer dimension:

```bash
export ALB_DIMENSION="${ALB_ARN#*loadbalancer/}"
```

Query:

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name HTTPCode_ELB_503_Count \
  --dimensions "Name=LoadBalancer,Value=$ALB_DIMENSION" \
  --statistics Sum \
  --period 60 \
  --start-time "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --region "$AWS_REGION"
```

After CloudWatch publishes the data, nonzero HTTP 503 datapoints are expected.

### Investigation Summary

| Check | Finding |
|---|---|
| ALB | Active |
| Listener | Correct |
| Target Group | Correct |
| Registered Target Count | 0 |
| EC2 | Running |
| Backend Application | Active |
| Application Health Endpoint | HTTP 200 locally |
| Security Groups | Correct |
| ALB Response | HTTP 503 |
| Root Cause | Missing target registration |

---

## 16. Root Cause Analysis

### Root Cause

The EC2 instance was removed from the ALB target group.

The target group continued to exist, and the ALB listener continued forwarding requests to it.

However, the group no longer contained a registered backend.

The ALB therefore returned HTTP 503 Service Unavailable.

### Technical Explanation

The EC2 application was running and listening on port 8080.

But an ALB does not automatically forward requests to every running EC2 instance in the VPC.

The instance must be registered with the appropriate target group.

After deregistration, the registered target count became zero.

### Root Cause Flow

```text
EC2 Target Deregistered
          |
          v
Target Group Becomes Empty
          |
          v
ALB Receives HTTP Request
          |
          v
No Registered Backend Found
          |
          v
HTTP 503 Service Unavailable
```

### Five Whys

1. **Why did the ALB return HTTP 503?** The target group contained no registered targets.
2. **Why was the target group empty?** The EC2 instance was deregistered.
3. **Why did the ALB not discover the instance automatically?** Manually managed target groups require explicit target registration.
4. **Why did EC2 health checks remain successful?** EC2 infrastructure status is independent of ALB target registration.
5. **How can this be prevented?** Automate target registration, validate target counts, and monitor deployment changes.

---

## 17. Remediation and Verification

### Step 1 — Register EC2 Again

```bash
aws elbv2 register-targets \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

### Step 2 — Verify Registration

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{Instance:Target.Id,Port:Target.Port,State:TargetHealth.State}' \
  --output table \
  --region "$AWS_REGION"
```

Initially, the target may show `initial` while health checks begin.

### Step 3 — Wait for Target Recovery

```bash
aws elbv2 wait target-in-service \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

### Step 4 — Verify Healthy Status

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{Instance:Target.Id,Port:Target.Port,State:TargetHealth.State}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Port: 8080
State: healthy
```

### Step 5 — Test ALB HTTP Response

```bash
curl --noproxy '*' -i \
  --connect-timeout 5 \
  --max-time 15 \
  "http://${ALB_DNS}/"
```

Expected: HTTP 200.

### Step 6 — Test Health Endpoint

```bash
curl --noproxy '*' -i \
  "http://${ALB_DNS}/health"
```

Expected: HTTP 200.

### Step 7 — Test Five Requests

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

Expected: all five requests return HTTP 200.

### Verification Matrix

| Check | Baseline | During Failure | After Fix |
|---|---|---|---|
| ALB | Active | Active | Active |
| EC2 | Running | Running | Running |
| Application | Active | Active | Active |
| Registered Targets | 1 | 0 | 1 |
| Target Health | Healthy | No targets | Healthy |
| ALB Response | 200 | 503 | 200 |
| Incident | None | Active | Resolved |

### Success Criteria

- ALB and EC2 deployed.
- Healthy target registration established.
- Target intentionally deregistered.
- Target group becomes empty.
- HTTP 503 reproduced.
- EC2 and application confirmed healthy.
- Missing registration identified.
- EC2 registered again.
- Target returns to healthy.
- HTTP 200 restored.
- Temporary resources cleaned up.

---

## 18. Production Best Practices

### Target Registration Troubleshooting Checklist

1. Verify ALB status.
2. Inspect listener forwarding actions.
3. Identify the target group.
4. List registered targets.
5. Check target registration count.
6. Inspect target health states.
7. Verify EC2 instance status.
8. Confirm the application is running.
9. Check the backend listening port.
10. Verify health check configuration.
11. Check security groups.
12. Register the correct backend target.
13. Confirm healthy target status.
14. Test application traffic.

### Common Target Registration Problems

| Problem | Possible Effect | Remediation |
|---|---|---|
| No registered targets | HTTP 503 | Register targets |
| Wrong instance ID | Wrong or failed registration | Use correct instance |
| Wrong target port | Health check failure | Correct registered port |
| Wrong target group | Unexpected routing | Register with intended group |
| Target deregistered | Lost backend capacity | Restore registration |
| EC2 terminated | Target unavailable | Replace backend |
| Unsupported target configuration | Registration error | Correct target type or configuration |
| Target not in enabled AZ | Target not used | Review ALB Availability Zones |

### Prevention

- Use Auto Scaling groups integrated with ALB target groups where appropriate.
- Manage target group configuration through Terraform or CloudFormation.
- Validate registered target counts after deployments.
- Configure CloudWatch alerts for ALB-generated HTTP 503 errors.
- Monitor healthy and unhealthy host counts.
- Use more than one backend instance for production availability.
- Avoid manual deregistration during active traffic.
- Implement deployment health checks.
- Review target registration changes through change management.

### Security Considerations

- Use least-privilege permissions for target registration APIs.
- Restrict backend traffic to the ALB security group.
- Avoid exposing backend application ports to the internet.
- Audit target group changes using CloudTrail.
- Do not permit unnecessary manual infrastructure changes in production.

---

## 19. Cleanup

**Warning:** Confirm the AWS account, resource identifiers, and project tags before running destructive commands.

Only delete resources belonging to `ELB-Troubleshooting-Lab10`.

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

### Step 2 — Delete ALB Listener

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

Deregister the target:

```bash
aws elbv2 deregister-targets \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

Delete:

```bash
aws elbv2 delete-target-group \
  --target-group-arn "$TG_ARN" \
  --region "$AWS_REGION"
```

### Step 5 — Check EBS Volume

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the root EBS volume has `DeleteOnTermination=true`.

### Step 6 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Remove Security Group Reference

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$EC2_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

Check remaining network interfaces:

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Wait until the ALB and EC2 interfaces have been removed.

### Step 8 — Delete Security Groups

```bash
aws ec2 delete-security-group \
  --group-id "$EC2_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

### Step 9 — Delete IAM Resources

Confirm that the IAM role and instance profile belong to this lab and are not shared.

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

### Step 10 — Delete Route Table

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
```

### Step 11 — Delete Subnets

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_A_ID" \
  --region "$AWS_REGION"

aws ec2 delete-subnet \
  --subnet-id "$SUBNET_B_ID" \
  --region "$AWS_REGION"
```

### Step 12 — Delete Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 13 — Delete VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 14 — Verify Cleanup

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

Also confirm that the target group, EC2 instance, EBS root volume, IAM resources, and dedicated network resources are removed.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| ALB Listener | Deleted |
| ALB | Deleted |
| Target Group | Deleted |
| EC2 Instance | Terminated |
| Root EBS Volume | Deleted |
| ALB Security Group | Deleted |
| EC2 Security Group | Deleted |
| IAM Role | Deleted |
| Instance Profile | Deleted |
| Custom Route Table | Deleted |
| Both Subnets | Deleted |
| Internet Gateway | Deleted |
| Lab VPC | Deleted |
| Default VPC | Unchanged |

---

## 20. Interview Questions and Answers

### Q1. What is target registration in AWS ALB?

Target registration associates a backend resource with a target group so the ALB can forward requests to it.

### Q2. What happens if an ALB target group contains zero registered targets?

The ALB typically returns HTTP 503 when forwarding requests to the empty target group.

### Q3. What is the difference between an unhealthy target and an unregistered target?

An unhealthy target is registered but fails its health checks. An unregistered target is not associated with the target group.

### Q4. What command shows registered targets?

`aws elbv2 describe-target-health`.

### Q5. What command registers an EC2 target?

`aws elbv2 register-targets`.

### Q6. What command deregisters a target?

`aws elbv2 deregister-targets`.

### Q7. Does deregistering EC2 terminate the instance?

No. Deregistration removes the target group association without terminating the instance.

### Q8. What does `Target.NotRegistered` mean?

The specified target is not registered with the target group.

### Q9. Can an EC2 instance be running but unavailable through an ALB?

Yes. It may be unregistered, unhealthy, unreachable, or incorrectly routed.

### Q10. Which CloudWatch metric counts ALB-generated HTTP 503 errors?

`HTTPCode_ELB_503_Count`.

### Q11. How can registration failures be prevented?

Use Auto Scaling group integration, infrastructure as code, target registration validation, and monitoring.

### Q12. How would you explain this lab in an interview?

I deployed an AWS Application Load Balancer with an EC2 backend running a Python HTTP server on port 8080.

After establishing a healthy target group and confirming successful application access, I intentionally deregistered the only EC2 target.

The EC2 instance continued running, but the ALB returned HTTP 503 because the target group was empty.

I inspected the ALB listener, target group, registered target count, EC2 status, security groups, and backend application.

After identifying the missing registration, I registered the instance again, verified that the target became healthy, and confirmed HTTP 200 responses.

---

## 21. Repository Structure

```text
10-target-registration-failure/
├── README.md
├── ec2-trust-policy.json
└── backend-user-data.sh
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete target registration incident documentation |
| `ec2-trust-policy.json` | IAM trust policy for Systems Manager access |
| `backend-user-data.sh` | Creates and starts the Python HTTP backend |

Do not commit AWS credentials, private keys, or sensitive information.

---

## 22. Lessons Learned

This lab demonstrates that an Application Load Balancer can return HTTP 503 even when its backend EC2 instance and application are running correctly.

The problem was not caused by an EC2 infrastructure failure, application crash, security group restriction, or incorrect health check path.

Instead, the registered target was missing.

The most important troubleshooting step was checking the target group registration count.

After registering the EC2 instance again, the ALB could resume forwarding requests.

**Key Lesson:** Always check registered target counts before assuming an HTTP 503 error is caused by a backend application failure.

---

## 23. Skills Demonstrated

- AWS Application Load Balancer troubleshooting
- Target group registration
- Target deregistration
- HTTP 503 diagnosis
- `Target.NotRegistered` investigation
- AWS CLI v2
- EC2 application verification
- Systems Manager
- Linux systemd
- curl
- Target health monitoring
- CloudWatch metrics
- VPC networking
- Security group verification
- Fault injection
- Root cause analysis
- Remediation and verification
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-ELB-010 |
| Problem | ALB target registration failure |
| Root Cause | Empty target group |
| EC2 | Running |
| Application | Active |
| Baseline Target Count | 1 |
| Fault Target Count | 0 |
| Final Target Count | 1 |
| HTTP Response During Fault | 503 |
| Remediation | Register EC2 target again |
| Final Target Health | Healthy |
| Final HTTP Response | 200 |
| Cleanup | Temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** A running EC2 instance cannot automatically receive traffic through an ALB unless it is correctly registered with the intended target group.
