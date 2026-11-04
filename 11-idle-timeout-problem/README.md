# Lab 11 — ALB Idle Timeout Problem

## Overview

This lab demonstrates how to troubleshoot an AWS Application Load Balancer (ALB) that returns HTTP 504 Gateway Timeout because its idle timeout is shorter than the backend application's response time.

We deploy an internet-facing ALB with an Amazon EC2 instance running a Python HTTP server on port 8080.

The application provides three endpoints:

- `/` — Returns HTTP 200 immediately.
- `/health` — Returns HTTP 200 immediately.
- `/slow` — Waits 12 seconds before returning HTTP 200.

Initially, the ALB uses its default idle timeout of 60 seconds, so all endpoints work correctly.

We intentionally reduce the ALB idle timeout to 5 seconds.

Because `/slow` takes 12 seconds without sending response data, the ALB times out and returns HTTP 504 Gateway Timeout.

We investigate ALB attributes, target group health, backend response times, application logs, and CloudWatch metrics.

After identifying the timeout mismatch, we increase the idle timeout to 30 seconds and verify successful application requests.

**Workflow:** Provision → Healthy Baseline → Fault Injection → Investigation → Root Cause Analysis → Remediation → Verification → Cleanup

---

## 1. Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-ELB-011 |
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
| Application | Python HTTP Server |
| Backend Port | 8080 |
| Health Check Path | `/health` |
| Slow Endpoint | `/slow` |
| Backend Processing Delay | 12 seconds |
| Default ALB Idle Timeout | 60 seconds |
| Fault Injection | Reduce idle timeout to 5 seconds |
| Expected Error | HTTP 504 Gateway Timeout |
| Root Cause | Idle timeout shorter than response delay |
| Remediation | Increase idle timeout to 30 seconds |
| Expected Final Result | HTTP 200 after approximately 12 seconds |

---

## 2. Production Incident Scenario

### Incident Description

A company hosts a web application on Amazon EC2 behind an AWS Application Load Balancer.

The application supports normal web requests and longer-running operations such as report generation or data processing.

Most requests finish quickly, but some operations require approximately 12 seconds.

During an infrastructure configuration update, the ALB idle timeout is changed from 60 seconds to 5 seconds.

After the deployment, users report that normal pages work but longer-running requests return HTTP 504 Gateway Timeout.

The backend instance is running, the application service is active, and ALB health checks continue passing.

The cloud engineering team must determine why only slow requests fail.

### Incident Symptoms

- ALB remains active.
- EC2 instance remains running.
- Backend application remains active.
- Target group reports healthy.
- `/` returns HTTP 200.
- `/health` returns HTTP 200.
- `/slow` takes 12 seconds when tested directly.
- `/slow` through the ALB returns HTTP 504.
- ALB idle timeout is configured to 5 seconds.
- Increasing the idle timeout restores successful requests.

### Potential Business Impact

- Failed API requests.
- Report generation failures.
- Interrupted long-running operations.
- Increased HTTP 504 errors.
- Poor customer experience.
- Unnecessary retries.
- Increased application troubleshooting time.

### Objective

Identify the timeout configuration mismatch, adjust the ALB idle timeout appropriately, and verify successful requests without changing the healthy backend application.

---

## 3. AWS Architecture

### Healthy Architecture

```text
                     Internet Client
                            |
                            | HTTP 80
                            v
                 +-----------------------+
                 | Application Load      |
                 | Balancer              |
                 | Idle Timeout: 60s     |
                 +-----------+-----------+
                             |
                             v
                 +-----------------------+
                 | Target Group          |
                 | HTTP Port: 8080       |
                 | Health: /health       |
                 +-----------+-----------+
                             |
                             v
                 +-----------------------+
                 | EC2 Python Backend    |
                 | /      → Immediate    |
                 | /health → Immediate   |
                 | /slow  → 12 seconds   |
                 +-----------+-----------+
                             |
                             v
                         HTTP 200
```

### Broken Architecture

```text
                     Internet Client
                            |
                            v
                 Application Load Balancer
                    Idle Timeout: 5s
                            |
                            v
                      GET /slow
                            |
                            v
                   EC2 Python Backend
                            |
                            v
                  Processing for 12s
                            |
                            |
                       5s passes
                            |
                            X
                    ALB Idle Timeout
                            |
                            v
                  HTTP 504 Gateway Timeout
```

### Infrastructure Configuration

| Component | Configuration |
|---|---|
| VPC | `10.170.0.0/16` |
| Public Subnet A | `10.170.1.0/24` |
| Public Subnet B | `10.170.2.0/24` |
| Internet Gateway | Attached |
| ALB Security Group | TCP 80 from internet |
| EC2 Security Group | TCP 8080 from ALB SG |
| ALB Listener | HTTP 80 |
| Target Group | HTTP 8080 |
| Health Check | `/health` |

---

## 4. Understanding ALB Idle Timeout

An Application Load Balancer maintains connections between clients and backend targets.

The ALB idle timeout defines how long a connection can remain inactive before it is closed.

### Default and Supported Values

| Configuration | Value |
|---|---|
| Default Idle Timeout | 60 seconds |
| Minimum | 1 second |
| Maximum | 4,000 seconds |
| Configuration Attribute | `idle_timeout.timeout_seconds` |

### Example

```text
Backend Processing Time: 12 seconds
ALB Idle Timeout: 5 seconds

12 seconds > 5 seconds

Result: HTTP 504 Gateway Timeout
```

The backend does not send any response data during the 12-second processing period.

The ALB therefore reaches its idle timeout before receiving the response.

### Idle Timeout vs. Health Check Timeout

| Feature | ALB Idle Timeout | Health Check Timeout |
|---|---|---|
| Purpose | Controls connection inactivity | Limits health check response time |
| Configuration Level | Load Balancer | Target Group |
| Lab Value During Fault | 5 seconds | 5 seconds |
| Applies to `/slow` request | Yes | No |
| Applies to `/health` probe | Not the primary health check limit | Yes |

These are separate settings.

The target can remain healthy while some user requests fail due to the ALB idle timeout.

### Important Concept

Increasing the ALB idle timeout does not make the backend application faster.

It only allows the ALB to keep waiting for the application to respond.

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
- CloudWatch read permissions
- Git and GitHub

### Safety Requirements

- Use dedicated lab resources.
- Do not modify production ALB timeouts for testing.
- Verify AWS account identity.
- Use project tags.
- Restrict backend traffic to the ALB security group.
- Never commit AWS credentials or private keys.
- Delete temporary infrastructure after testing.

### Cost Considerations

Temporary ALB, EC2, EBS, public IPv4, and networking resources may incur charges.

---

## 6. Prepare the Environment

### Step 1 — Configure Variables

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="ELB-Troubleshooting-Lab11"

export VPC_CIDR="10.170.0.0/16"
export SUBNET_A_CIDR="10.170.1.0/24"
export SUBNET_B_CIDR="10.170.2.0/24"

export ALB_NAME="cloud-elb-lab11-alb"
export TG_NAME="cloud-elb-lab11-tg"

export ROLE_NAME="cloud-elb-lab11-ssm-role"
export PROFILE_NAME="cloud-elb-lab11-ssm-profile"
```

### Step 2 — Verify AWS Credentials

```bash
aws sts get-caller-identity
aws --version
```

### Step 3 — Choose Availability Zones

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Choose two supported Availability Zones:

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
  "ResourceType=vpc,Tags=[{Key=Name,Value=cloud-elb-lab11-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
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

### Step 2 — Create Subnets

```bash
export SUBNET_A_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_A_CIDR" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-elb-lab11-subnet-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")

export SUBNET_B_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_B_CIDR" \
  --availability-zone "$AZ_B" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-elb-lab11-subnet-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cloud-elb-lab11-igw},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Create Route Table

```bash
export RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-elb-lab11-rt},{Key=Project,Value=$PROJECT_TAG}]" \
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
10.170.0.0/16 → local
0.0.0.0/0     → Internet Gateway
```

---

## 8. Configure Security Groups

### Step 1 — Create ALB Security Group

```bash
export ALB_SG_ID=$(aws ec2 create-security-group \
  --group-name cloud-elb-lab11-alb-sg \
  --description "Lab11 ALB security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=cloud-elb-lab11-alb-sg},{Key=Project,Value=$PROJECT_TAG}]" \
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
  --group-name cloud-elb-lab11-ec2-sg \
  --description "Lab11 EC2 backend security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=cloud-elb-lab11-ec2-sg},{Key=Project,Value=$PROJECT_TAG}]" \
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

Create the resources:

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

## 10. Create the Python Backend Application

Create `backend-user-data.sh`:

```bash
#!/bin/bash
set -eux

mkdir -p /opt/lab11

cat > /opt/lab11/app.py <<'PY'
#!/usr/bin/env python3

import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):

    def do_GET(self):

        if self.path == "/health":
            status = 200
            body = b"OK\n"

        elif self.path == "/":
            status = 200
            body = b"AWS ELB Lab 11 - Application Healthy\n"

        elif self.path == "/slow":
            time.sleep(12)
            status = 200
            body = b"Slow operation completed after 12 seconds\n"

        else:
            status = 404
            body = b"Not Found\n"

        try:
            self.send_response(status)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        except (BrokenPipeError, ConnectionResetError):
            self.log_message(
                "Client disconnected before response completed"
            )


if __name__ == "__main__":

    server = ThreadingHTTPServer(
        ("0.0.0.0", 8080),
        Handler
    )

    server.serve_forever()
PY

cat > /etc/systemd/system/lab11-web.service <<'UNIT'
[Unit]
Description=Lab 11 ALB Idle Timeout Backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/lab11/app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab11-web.service
```

### Application Endpoints

| Endpoint | Behavior | Expected HTTP Code |
|---|---|---|
| `/` | Responds immediately | 200 |
| `/health` | Responds immediately | 200 |
| `/slow` | Waits 12 seconds | 200 |
| Unknown path | Returns Not Found | 404 |

The application uses `ThreadingHTTPServer`, allowing health checks to succeed while a slow request is processing.

---

## 11. Launch and Verify EC2

### Step 1 — Retrieve Amazon Linux 2023 AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Launch EC2

Verify that no active instance already exists with the lab tag.

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
  "ResourceType=instance,Tags=[{Key=Name,Value=cloud-elb-lab11-backend},{Key=Project,Value=$PROJECT_TAG}]" \
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

### Step 4 — Check Systems Manager

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Once the instance reports `Online`:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
sudo systemctl is-active lab11-web.service

sudo ss -lntp | grep ':8080'

curl --noproxy '*' -i \
  http://127.0.0.1:8080/health

time curl --noproxy '*' -i \
  http://127.0.0.1:8080/slow
```

Expected:

```text
Service: active
Port: 8080
Health: HTTP 200
Slow endpoint: HTTP 200 after approximately 12 seconds
```

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

### Step 6 — Verify Target Health

```bash
aws elbv2 wait target-in-service \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"

aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{Instance:Target.Id,State:TargetHealth.State}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `healthy`.

---

## 13. Establish Healthy Baseline

### Step 1 — Inspect Default Idle Timeout

```bash
aws elbv2 describe-load-balancer-attributes \
  --load-balancer-arn "$ALB_ARN" \
  --query "Attributes[?Key=='idle_timeout.timeout_seconds']" \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
idle_timeout.timeout_seconds = 60
```

### Step 2 — Test Fast Endpoint

```bash
curl --noproxy '*' -i \
  --connect-timeout 5 \
  --max-time 20 \
  "http://${ALB_DNS}/"
```

Expected: HTTP 200.

### Step 3 — Test Slow Endpoint

```bash
curl --noproxy '*' -sS \
  -o /dev/null \
  -w 'HTTP: %{http_code}\nTime: %{time_total} seconds\n' \
  --connect-timeout 5 \
  --max-time 25 \
  "http://${ALB_DNS}/slow"
```

Expected:

```text
HTTP: 200
Time: approximately 12 seconds
```

### Baseline Summary

| Check | Expected Result |
|---|---|
| ALB | Active |
| EC2 | Running |
| Application | Active |
| Target Health | Healthy |
| Idle Timeout | 60 seconds |
| `/` | HTTP 200 |
| `/health` | HTTP 200 |
| `/slow` | HTTP 200 after 12 seconds |

---

## 14. Fault Injection — Reduce ALB Idle Timeout

### Step 1 — Configure Idle Timeout to 5 Seconds

```bash
aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn "$ALB_ARN" \
  --attributes Key=idle_timeout.timeout_seconds,Value=5 \
  --region "$AWS_REGION"
```

This is the intentional fault injection.

### Step 2 — Verify the Configuration

```bash
aws elbv2 describe-load-balancer-attributes \
  --load-balancer-arn "$ALB_ARN" \
  --query "Attributes[?Key=='idle_timeout.timeout_seconds']" \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
idle_timeout.timeout_seconds = 5
```

### Step 3 — Test Fast Endpoint

```bash
curl --noproxy '*' -i \
  --connect-timeout 5 \
  --max-time 15 \
  "http://${ALB_DNS}/"
```

Expected: HTTP 200.

### Step 4 — Reproduce Slow Request Failure

```bash
curl --noproxy '*' -v \
  --connect-timeout 5 \
  --max-time 25 \
  -w '\nHTTP: %{http_code}\nTime: %{time_total} seconds\n' \
  "http://${ALB_DNS}/slow"
```

Expected after the setting propagates:

```text
HTTP/1.1 504 Gateway Timeout

HTTP: 504
Time: approximately 5 seconds
```

### Step 5 — Verify Target Health

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{State:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `healthy`.

### Step 6 — Compare Endpoints

```bash
for path in / /health /slow; do
  curl --noproxy '*' -sS \
    -o /dev/null \
    -w "$path → HTTP %{http_code}, %{time_total}s\n" \
    --connect-timeout 5 \
    --max-time 25 \
    "http://${ALB_DNS}${path}"
done
```

Expected:

```text
/       → HTTP 200, fast
/health → HTTP 200, fast
/slow   → HTTP 504, approximately 5 seconds
```

### Fault Summary

| Component | Finding |
|---|---|
| ALB | Active |
| EC2 | Running |
| Backend Application | Active |
| Target Health | Healthy |
| Fast Endpoint | HTTP 200 |
| Slow Endpoint | HTTP 504 |
| ALB Idle Timeout | 5 seconds |
| Backend Processing Time | 12 seconds |
| Root Cause | Timeout mismatch |

---

## 15. Troubleshooting Investigation

### Check 1 — Verify ALB Status

```bash
aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].{Name:LoadBalancerName,State:State.Code,DNS:DNSName}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: ALB is active.

### Check 2 — Inspect Listener

```bash
aws elbv2 describe-listeners \
  --listener-arns "$LISTENER_ARN" \
  --query 'Listeners[].{Port:Port,Protocol:Protocol,Actions:DefaultActions}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: listener forwards to the correct target group.

### Check 3 — Inspect Health Check Settings

```bash
aws elbv2 describe-target-groups \
  --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[].{Port:Port,HealthPath:HealthCheckPath,HealthTimeout:HealthCheckTimeoutSeconds}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Port: 8080
HealthPath: /health
HealthTimeout: 5
```

The health check timeout is independent of the ALB connection idle timeout.

### Check 4 — Inspect Idle Timeout Attribute

```bash
aws elbv2 describe-load-balancer-attributes \
  --load-balancer-arn "$ALB_ARN" \
  --query "Attributes[?Key=='idle_timeout.timeout_seconds']" \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
[
  {
    "Key": "idle_timeout.timeout_seconds",
    "Value": "5"
  }
]
```

### Check 5 — Verify Slow Endpoint Directly

Connect through Systems Manager:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
sudo systemctl is-active lab11-web.service

sudo ss -lntp | grep ':8080'

time curl --noproxy '*' -i \
  http://127.0.0.1:8080/slow
```

Expected: HTTP 200 after approximately 12 seconds.

This confirms the slow endpoint works when the ALB is bypassed.

### Check 6 — Inspect Application Logs

Inside EC2:

```bash
sudo journalctl -u lab11-web.service \
  --since "15 minutes ago" \
  --no-pager
```

Look for `/slow` requests and possible client disconnection messages.

The backend may finish processing after the ALB has already timed out.

Exit Session Manager.

### Check 7 — Inspect CloudWatch HTTP 504 Errors

```bash
export ALB_DIMENSION="${ALB_ARN#*loadbalancer/}"
```

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name HTTPCode_ELB_504_Count \
  --dimensions "Name=LoadBalancer,Value=$ALB_DIMENSION" \
  --statistics Sum \
  --period 60 \
  --start-time "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --region "$AWS_REGION"
```

Expected after CloudWatch publishes the data: nonzero HTTP 504 datapoints.

### Investigation Summary

| Check | Finding |
|---|---|
| ALB | Active |
| Listener | Correct |
| Target Group | Correct |
| Target Health | Healthy |
| EC2 | Running |
| Backend Service | Active |
| Direct `/slow` Request | HTTP 200 after 12 seconds |
| ALB `/slow` Request | HTTP 504 after about 5 seconds |
| Idle Timeout | 5 seconds |
| Root Cause | Connection idle timeout expires before backend response |

---

## 16. Root Cause Analysis

### Root Cause

The ALB idle timeout was configured to 5 seconds, but the backend application required 12 seconds to respond to `/slow`.

The backend sent no response data during processing.

The ALB therefore reached its configured idle timeout and returned HTTP 504 Gateway Timeout.

### Technical Explanation

The client sends:

```http
GET /slow HTTP/1.1
```

The ALB forwards the request to the EC2 backend.

The backend executes:

```python
time.sleep(12)
```

During this time, the backend sends no response bytes.

The ALB idle timeout expires after approximately 5 seconds.

The client receives HTTP 504 instead of waiting for the application's eventual HTTP 200 response.

### Root Cause Flow

```text
Client Requests /slow
         |
         v
ALB Forwards Request
         |
         v
EC2 Starts Processing
         |
         v
No Response Data
         |
         v
5-Second Idle Timeout Expires
         |
         v
HTTP 504 Gateway Timeout
```

### Five Whys

1. **Why did `/slow` return HTTP 504?** The ALB timed out before receiving response data.
2. **Why did the timeout occur?** The connection was inactive for longer than 5 seconds.
3. **Why was the connection inactive?** The backend required 12 seconds to process the request.
4. **Why did target health remain healthy?** The `/health` endpoint responded immediately.
5. **How can this be prevented?** Configure appropriate timeouts, monitor latency, optimize slow operations, and use asynchronous processing when appropriate.

---

## 17. Remediation and Verification

### Step 1 — Increase Idle Timeout to 30 Seconds

```bash
aws elbv2 modify-load-balancer-attributes \
  --load-balancer-arn "$ALB_ARN" \
  --attributes Key=idle_timeout.timeout_seconds,Value=30 \
  --region "$AWS_REGION"
```

### Step 2 — Verify Timeout

```bash
aws elbv2 describe-load-balancer-attributes \
  --load-balancer-arn "$ALB_ARN" \
  --query "Attributes[?Key=='idle_timeout.timeout_seconds']" \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
idle_timeout.timeout_seconds = 30
```

### Step 3 — Verify Slow Request

```bash
curl --noproxy '*' -sS \
  -o /dev/null \
  -w 'HTTP: %{http_code}\nTime: %{time_total} seconds\n' \
  --connect-timeout 5 \
  --max-time 35 \
  "http://${ALB_DNS}/slow"
```

Expected:

```text
HTTP: 200
Time: approximately 12 seconds
```

### Step 4 — Verify Fast Endpoints

```bash
curl --noproxy '*' -i \
  "http://${ALB_DNS}/"

curl --noproxy '*' -i \
  "http://${ALB_DNS}/health"
```

Expected: HTTP 200.

### Step 5 — Verify Target Health

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `healthy`.

### Step 6 — Run Repeated Slow Requests

```bash
for i in {1..3}; do
  curl --noproxy '*' -sS \
    -o /dev/null \
    -w "Slow request $i: HTTP %{http_code}, %{time_total}s\n" \
    --connect-timeout 5 \
    --max-time 35 \
    "http://${ALB_DNS}/slow"
done
```

Expected: three HTTP 200 responses after approximately 12 seconds each.

### Verification Matrix

| Check | Baseline | During Fault | After Fix |
|---|---|---|---|
| ALB | Active | Active | Active |
| EC2 | Running | Running | Running |
| Target Health | Healthy | Healthy | Healthy |
| Idle Timeout | 60 seconds | 5 seconds | 30 seconds |
| Backend Delay | 12 seconds | 12 seconds | 12 seconds |
| Fast Request | HTTP 200 | HTTP 200 | HTTP 200 |
| Slow Request | HTTP 200 | HTTP 504 | HTTP 200 |
| Incident | None | Active | Resolved |

### Success Criteria

- Healthy ALB baseline established.
- Slow endpoint returns HTTP 200 with default timeout.
- ALB idle timeout reduced to 5 seconds.
- HTTP 504 reproduced.
- Target health remains healthy.
- Direct backend request returns HTTP 200.
- Timeout mismatch identified.
- Idle timeout increased to 30 seconds.
- HTTP 200 restored for slow requests.
- Temporary resources cleaned up.

---

## 18. Production Best Practices

### ALB Timeout Troubleshooting Checklist

1. Verify ALB state.
2. Check listener configuration.
3. Verify target group registration.
4. Inspect target health.
5. Measure backend application response time.
6. Check ALB idle timeout.
7. Compare application latency against timeout settings.
8. Test the backend directly.
9. Inspect application logs.
10. Review CloudWatch HTTP 504 metrics.
11. Correct the configuration.
12. Verify application requests.

### Common Timeout Problems

| Problem | Possible Symptom | Remediation |
|---|---|---|
| Idle timeout too short | HTTP 504 | Increase appropriately |
| Backend processing too slow | Long requests or 504 | Optimize application |
| Backend connection timeout | HTTP 504 | Investigate networking |
| Backend not responding | HTTP 504 | Restore application |
| Connection interrupted | Connection errors | Review infrastructure and logs |
| Blocking application operations | High latency | Use asynchronous processing |
| High backend load | Slow requests | Scale or optimize backend |

### Prevention

- Monitor backend response latency.
- Use CloudWatch alarms for HTTP 504.
- Use ALB access logs when detailed request evidence is needed.
- Tune idle timeout according to workload behavior.
- Avoid unnecessarily high timeout values.
- Optimize expensive application operations.
- Use queues and background workers for long-running tasks.
- Validate timeout settings during deployment.
- Manage ALB configuration with Terraform or CloudFormation.
- Test slow application endpoints before production releases.

### Important Production Consideration

Increasing the ALB idle timeout can resolve legitimate long-running requests, but it is not always the best architectural solution.

For lengthy operations such as report generation, video processing, or bulk imports, asynchronous processing may be more appropriate.

For example:

```text
Client
   |
   v
API Gateway / ALB
   |
   v
Application
   |
   v
SQS Queue
   |
   v
Background Worker
   |
   v
S3 / Database
```

This avoids forcing clients to maintain long-running connections.

---

## 19. Cleanup

**Warning:** Verify the AWS account, resource IDs, and project tags before deleting infrastructure.

Only remove resources belonging to `ELB-Troubleshooting-Lab11`.

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

### Step 2 — Delete Listener and ALB

```bash
aws elbv2 delete-listener \
  --listener-arn "$LISTENER_ARN" \
  --region "$AWS_REGION"

aws elbv2 delete-load-balancer \
  --load-balancer-arn "$ALB_ARN" \
  --region "$AWS_REGION"

aws elbv2 wait load-balancers-deleted \
  --load-balancer-arns "$ALB_ARN" \
  --region "$AWS_REGION"
```

### Step 3 — Delete Target Group

```bash
aws elbv2 deregister-targets \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"

aws elbv2 delete-target-group \
  --target-group-arn "$TG_ARN" \
  --region "$AWS_REGION"
```

### Step 4 — Verify EBS Root Volume

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the root EBS volume is configured with `DeleteOnTermination=true`.

### Step 5 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Remove Security Group Dependencies

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

After the lab's network interfaces are removed:

```bash
aws ec2 delete-security-group \
  --group-id "$EC2_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Delete IAM Resources

Verify the role and instance profile belong to this lab and are not shared:

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

### Step 8 — Delete Route Table

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

### Step 9 — Delete Subnets

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_A_ID" \
  --region "$AWS_REGION"

aws ec2 delete-subnet \
  --subnet-id "$SUBNET_B_ID" \
  --region "$AWS_REGION"
```

### Step 10 — Delete Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 11 — Delete VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 12 — Verify Cleanup

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

Also verify that the target group, EC2 instance, root EBS volume, IAM resources, and dedicated network resources are removed.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| ALB Listener | Deleted |
| ALB | Deleted |
| Target Group | Deleted |
| EC2 | Terminated |
| Root EBS Volume | Deleted |
| ALB Security Group | Deleted |
| EC2 Security Group | Deleted |
| IAM Role | Deleted |
| Instance Profile | Deleted |
| Route Table | Deleted |
| Subnets | Deleted |
| Internet Gateway | Deleted |
| Lab VPC | Deleted |
| Default VPC | Unchanged |

---

## 20. Interview Questions and Answers

### Q1. What is the ALB idle timeout?

It is the maximum time a connection can remain inactive before the ALB closes it.

### Q2. What is the default ALB idle timeout?

60 seconds.

### Q3. What is the supported range?

1 to 4,000 seconds.

### Q4. What caused HTTP 504 in this lab?

The ALB idle timeout was 5 seconds, while the backend needed 12 seconds to respond without sending data.

### Q5. Why did the target remain healthy?

The `/health` endpoint responded immediately, so health checks continued passing.

### Q6. Which command displays the idle timeout?

`aws elbv2 describe-load-balancer-attributes`.

### Q7. How do you modify the ALB idle timeout?

Use `aws elbv2 modify-load-balancer-attributes` with `idle_timeout.timeout_seconds`.

### Q8. What is the difference between idle timeout and health check timeout?

The idle timeout controls connection inactivity. The health check timeout limits the duration of an individual health check.

### Q9. Does increasing the idle timeout improve application performance?

No. It allows requests to wait longer but does not make the backend faster.

### Q10. Should every production ALB use a very high idle timeout?

No. The correct value depends on the application's workload and expected connection behavior.

### Q11. Which CloudWatch metric helps investigate this issue?

`HTTPCode_ELB_504_Count`. ALB access logs and backend latency metrics can provide additional evidence.

### Q12. How would you explain this lab in an interview?

I deployed an AWS Application Load Balancer with an EC2 backend running a Python HTTP server.

The application included a slow endpoint that required 12 seconds to respond.

After establishing a healthy baseline, I intentionally reduced the ALB idle timeout from 60 seconds to 5 seconds.

The normal endpoints continued returning HTTP 200, but the slow endpoint returned HTTP 504 Gateway Timeout.

The registered target remained healthy.

I investigated the ALB attributes, target health, backend response time, and application logs.

After increasing the ALB idle timeout to 30 seconds, I verified that the slow endpoint successfully returned HTTP 200 after approximately 12 seconds.

---

## 21. Repository Structure

```text
11-idle-timeout-problem/
├── README.md
├── ec2-trust-policy.json
└── backend-user-data.sh
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete ALB idle timeout troubleshooting documentation |
| `ec2-trust-policy.json` | IAM trust policy for Systems Manager access |
| `backend-user-data.sh` | Deploys the Python backend with fast and slow endpoints |

Do not commit AWS credentials, private keys, or sensitive information.

---

## 22. Lessons Learned

This lab demonstrates that an Application Load Balancer can return HTTP 504 even when the EC2 instance, application, and target group are healthy.

The problem was caused by an ALB idle timeout configuration that was shorter than the backend application's response time.

The slow endpoint required 12 seconds, but the ALB was configured to close inactive connections after 5 seconds.

As a result, slow requests failed while normal requests and health checks continued working.

The most important troubleshooting steps were comparing the ALB idle timeout with the backend response time and testing the slow endpoint directly.

Increasing the timeout to 30 seconds restored successful slow requests.

**Key Lesson:** When an ALB returns HTTP 504 for slow requests while target health remains healthy, inspect the connection idle timeout and measure the backend response time before assuming the application or network has failed.

---

## 23. Skills Demonstrated

- AWS Application Load Balancer
- ALB idle timeout configuration
- HTTP 504 troubleshooting
- Backend response latency analysis
- AWS CLI v2
- EC2 application diagnostics
- Systems Manager
- Linux systemd
- Python ThreadingHTTPServer
- curl response timing
- CloudWatch metrics
- Target group health monitoring
- VPC networking
- Security group verification
- Fault injection
- Root cause analysis
- Remediation and verification
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-ELB-011 |
| Problem | ALB idle timeout |
| Root Cause | Timeout shorter than backend response time |
| ALB | Active |
| EC2 | Running |
| Application | Active |
| Target Health | Healthy |
| Backend Delay | 12 seconds |
| Fault Idle Timeout | 5 seconds |
| HTTP Response During Fault | 504 |
| Remediation | Increase idle timeout to 30 seconds |
| Final Slow Response | HTTP 200 |
| Final Target Health | Healthy |
| Cleanup | Temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** ALB idle timeout settings should match application traffic patterns. A backend can be healthy while longer-running requests fail because the load balancer closes an inactive connection before the application responds.
