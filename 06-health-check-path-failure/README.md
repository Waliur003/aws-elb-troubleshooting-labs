# Lab 06 — ALB Health Check Path Failure

## Overview

This lab demonstrates how to troubleshoot an unhealthy AWS Application Load Balancer (ALB) target caused by an incorrect health check path.

We deploy an internet-facing ALB with an Amazon EC2 backend running a Python HTTP server on port 8080.

Initially, the ALB uses the correct health check path `/health`, and the target becomes healthy.

We intentionally change the health check path to `/healthcheck`, which does not exist in the application.

The backend returns HTTP 404 instead of the expected HTTP 200. Because of this response code mismatch, the ALB marks the registered target as unhealthy.

We investigate the health check configuration, target health reason codes, EC2 instance, application endpoints, and network settings.

After identifying the incorrect health check path, we restore `/health` and verify that the target becomes healthy again.

**Workflow:** Provision → Healthy Baseline → Fault Injection → Investigation → Root Cause → Remediation → Verification → Cleanup

---

## 1. Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-ELB-006 |
| Difficulty | Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | ALB, EC2, VPC, IAM, Systems Manager |
| Load Balancer | Application Load Balancer |
| ALB Scheme | Internet-facing |
| Listener | HTTP 80 |
| Target Group | HTTP 8080 |
| Target Type | Instance |
| EC2 | Amazon Linux 2023, `t3.micro` |
| Backend Application | Python HTTP Server |
| Correct Health Check | `/health` |
| Incorrect Health Check | `/healthcheck` |
| Expected Status | HTTP 200 |
| Actual Fault Response | HTTP 404 |
| Target Health | `unhealthy` |
| Health Reason | `Target.ResponseCodeMismatch` |
| Root Cause | Incorrect ALB health check path |
| Remediation | Restore `/health` |
| Verification | Target `healthy` and HTTP 200 |

---

## 2. Production Incident Scenario

### Incident Description

A company runs a web application on an EC2 instance behind an AWS Application Load Balancer.

The backend application listens on port 8080 and exposes an endpoint called `/health`.

The ALB uses this endpoint to determine whether the application can receive traffic.

During an infrastructure configuration update, the target group's health check path is accidentally changed to `/healthcheck`.

However, the application does not provide this endpoint.

The ALB starts receiving HTTP 404 responses during its health checks.

Because the target group expects HTTP 200, the health checks fail and the target becomes unhealthy.

### Incident Symptoms

- ALB is active.
- EC2 is running.
- Application service is active.
- Port 8080 is listening.
- Target is correctly registered.
- `/health` returns HTTP 200.
- `/healthcheck` returns HTTP 404.
- ALB health checks fail.
- Target health reports `unhealthy`.
- Reason code reports `Target.ResponseCodeMismatch`.

### Potential Business Impact

- Application availability may decrease.
- Healthy backend instances may be removed from normal traffic selection.
- Monitoring systems generate unhealthy-target alerts.
- Deployments may fail health validation.
- If multiple backends exist, traffic may shift to the remaining healthy targets.
- If all registered targets are unhealthy, the ALB may fail open and still forward requests to them.

### Objective

Identify the cause of the health check failure, correct the target group configuration, and restore the target to a healthy state.

---

## 3. AWS Architecture

### Healthy Architecture

```text
                  Internet Client
                         |
                         v
              +---------------------+
              | Application Load    |
              | Balancer            |
              | HTTP Listener: 80   |
              +----------+----------+
                         |
                         v
              +---------------------+
              | Target Group        |
              | HTTP Port: 8080     |
              | Health: /health     |
              +----------+----------+
                         |
                         v
              +---------------------+
              | EC2 Backend         |
              | Python HTTP Server  |
              | Listening: 8080     |
              +----------+----------+
                         |
                         v
                 GET /health
                         |
                         v
                    HTTP 200
                         |
                         v
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
                   Target Group
                         |
                         v
                GET /healthcheck
                         |
                         v
                    EC2 Backend
                         |
                         v
                HTTP 404 Not Found
                         |
                         v
              Expected HTTP 200
                         |
                         X
               Response Code Mismatch
                         |
                         v
                  Target Unhealthy
```

### Networking

| Resource | Configuration |
|---|---|
| VPC | `10.165.0.0/16` |
| Subnet A | `10.165.1.0/24` |
| Subnet B | `10.165.2.0/24` |
| Internet Gateway | Attached |
| Public Route | `0.0.0.0/0` through IGW |
| ALB Security Group | Inbound TCP 80 |
| Backend Security Group | TCP 8080 from ALB SG |
| Health Check Port | `traffic-port` |
| Health Check Matcher | `200` |

---

## 4. Understanding ALB Health Checks

An Application Load Balancer performs health checks to determine whether registered targets are functioning correctly.

Health checks use a configured protocol, port, path, interval, timeout, and expected response code.

### Health Check Configuration

```text
Protocol: HTTP
Port: traffic-port
Path: /health
Interval: 15 seconds
Timeout: 5 seconds
Healthy Threshold: 2
Unhealthy Threshold: 2
Success Matcher: 200
```

### Important Health States

| State | Meaning |
|---|---|
| `initial` | Initial health checks are in progress |
| `healthy` | Target passes health checks |
| `unhealthy` | Target fails required health checks |
| `unused` | Target is not currently used by the ALB |
| `draining` | Target is being deregistered |
| `unavailable` | Health checks are unavailable |

### Important Reason Codes

| Reason Code | Meaning |
|---|---|
| `Target.ResponseCodeMismatch` | Unexpected HTTP response code |
| `Target.FailedHealthChecks` | Health checks failed |
| `Target.Timeout` | Health check timed out |
| `Target.NotRegistered` | Target is not registered |
| `Target.NotInUse` | Target is not being used |

### Root Cause Example

```text
Configured Health Check: /healthcheck
Actual Application Path: /health

GET /healthcheck → HTTP 404

Expected Matcher: HTTP 200

Result: Target.ResponseCodeMismatch
```

**Important:** An HTTP 404 proves the backend responded to the health check request. This helps distinguish a wrong endpoint from a connection timeout or blocked network port.

---

## 5. Prerequisites and Safety

### Prerequisites

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- EC2 permissions
- VPC permissions
- ELBv2 permissions
- IAM permissions
- Systems Manager access
- Git and GitHub

### Security Requirements

- Use dedicated lab infrastructure.
- Do not change production health checks for testing.
- Restrict backend access to the ALB security group.
- Use least-privilege IAM permissions.
- Verify AWS account identity before provisioning.
- Never commit credentials or private keys.

### AWS Costs

The ALB, EC2 instance, EBS volume, public IPv4 address, and applicable data transfer may incur charges.

Delete temporary resources after completing the experiment.

---

## 6. Prepare the Environment

### Step 1 — Configure Variables

Run in Ubuntu WSL2:

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="ELB-Troubleshooting-Lab06"

export VPC_CIDR="10.165.0.0/16"
export SUBNET_A_CIDR="10.165.1.0/24"
export SUBNET_B_CIDR="10.165.2.0/24"

export ALB_NAME="cloud-elb-lab06-alb"
export TG_NAME="cloud-elb-lab06-tg"

export ROLE_NAME="cloud-elb-lab06-ssm-role"
export PROFILE_NAME="cloud-elb-lab06-ssm-profile"

export CORRECT_PATH="/health"
export WRONG_PATH="/healthcheck"
```

### Step 2 — Verify AWS Identity

```bash
aws sts get-caller-identity
aws --version
```

### Step 3 — Choose Two Availability Zones

Check which AZs support the instance type:

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Select two supported zones:

```bash
export AZ_A="us-east-1a"
export AZ_B="us-east-1b"
```

### Step 4 — Check Existing Resources

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock}' \
  --output table \
  --region "$AWS_REGION"

aws elbv2 describe-load-balancers \
  --names "$ALB_NAME" \
  --region "$AWS_REGION"
```

`LoadBalancerNotFound` is expected if the lab has not yet been deployed.

---

## 7. Create VPC Networking

### Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=cloud-elb-lab06-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
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

### Create Subnets

```bash
export SUBNET_A_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_A_CIDR" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-elb-lab06-subnet-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")

export SUBNET_B_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_B_CIDR" \
  --availability-zone "$AZ_B" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-elb-lab06-subnet-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cloud-elb-lab06-igw},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Create Route Table

```bash
export RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-elb-lab06-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 create-route \
  --route-table-id "$RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Associate Subnets

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

### Verify Routes

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
10.165.0.0/16 → local
0.0.0.0/0     → Internet Gateway
```

---

## 8. Configure Security Groups

### Create ALB Security Group

```bash
export ALB_SG_ID=$(aws ec2 create-security-group \
  --group-name cloud-elb-lab06-alb-sg \
  --description "Lab06 ALB security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=cloud-elb-lab06-alb-sg},{Key=Project,Value=$PROJECT_TAG}]" \
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

### Create Backend Security Group

```bash
export EC2_SG_ID=$(aws ec2 create-security-group \
  --group-name cloud-elb-lab06-ec2-sg \
  --description "Lab06 backend security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=cloud-elb-lab06-ec2-sg},{Key=Project,Value=$PROJECT_TAG}]" \
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

### Verify Security Groups

```bash
aws ec2 describe-security-groups \
  --group-ids "$ALB_SG_ID" "$EC2_SG_ID" \
  --query 'SecurityGroups[].{Name:GroupName,Inbound:IpPermissions,Outbound:IpPermissionsEgress}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

| Security Group | Inbound |
|---|---|
| ALB SG | HTTP 80 from internet |
| EC2 SG | TCP 8080 from ALB SG |

---

## 9. Configure IAM and Systems Manager

### Create EC2 Trust Policy

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

### Create IAM Role

```bash
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

### Create Instance Profile

```bash
aws iam create-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME"
```

Verify that the IAM resources do not already exist before creating them, and allow IAM changes to propagate.

---

## 10. Create the Backend Application

Create `backend-user-data.sh`:

```bash
#!/bin/bash
set -eux

mkdir -p /opt/lab06

cat > /opt/lab06/index.html <<'HTML'
AWS ELB Troubleshooting Lab 06

Application: Python HTTP Server
Application Port: 8080
Health Check: /health
Status: Healthy
HTML

cat > /opt/lab06/health <<'HEALTH'
OK
HEALTH

cat > /etc/systemd/system/lab06-web.service <<'UNIT'
[Unit]
Description=Lab 06 ALB Health Check Backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/lab06
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab06-web.service
```

### Application Endpoints

| Endpoint | HTTP Response |
|---|---|
| `/` | 200 |
| `/health` | 200 |
| `/healthcheck` | 404 |

The Python server returns HTTP 404 for the nonexistent `/healthcheck` path.

---

## 11. Launch and Verify EC2

### Retrieve AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Launch Instance

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
  "ResourceType=instance,Tags=[{Key=Name,Value=cloud-elb-lab06-backend},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Wait for EC2

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Verify Systems Manager

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Once `Online`, connect:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
sudo systemctl is-active lab06-web.service

sudo ss -lntp | grep ':8080'

curl --noproxy '*' -i \
  http://127.0.0.1:8080/health

curl --noproxy '*' -i \
  http://127.0.0.1:8080/healthcheck
```

Expected:

```text
Service: active
Port: 8080 listening

/health      → HTTP 200
/healthcheck → HTTP 404
```

Exit the Session Manager session.

---

## 12. Create ALB and Target Group

### Create Target Group

```bash
export TG_ARN=$(aws elbv2 create-target-group \
  --name "$TG_NAME" \
  --protocol HTTP \
  --port 8080 \
  --vpc-id "$VPC_ID" \
  --target-type instance \
  --health-check-protocol HTTP \
  --health-check-port traffic-port \
  --health-check-path "$CORRECT_PATH" \
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

### Register EC2

```bash
aws elbv2 register-targets \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

### Create ALB

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

### Create Listener

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

### Get ALB DNS

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

Wait for target health:

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

Test the ALB:

```bash
curl --noproxy '*' -i \
  "http://${ALB_DNS}/"

curl --noproxy '*' -i \
  "http://${ALB_DNS}/health"
```

Expected: HTTP 200 for both endpoints.

### Baseline Summary

| Check | Expected Result |
|---|---|
| ALB | Active |
| EC2 | Running |
| Backend Application | Active |
| Health Check Path | `/health` |
| Health Response | HTTP 200 |
| Target Health | Healthy |
| ALB Application Response | HTTP 200 |

---

## 14. Fault Injection — Incorrect Health Check Path

### Step 1 — Modify the Health Check Path

```bash
aws elbv2 modify-target-group \
  --target-group-arn "$TG_ARN" \
  --health-check-path "$WRONG_PATH" \
  --region "$AWS_REGION"
```

The target group now checks `/healthcheck`.

### Step 2 — Verify the New Configuration

```bash
aws elbv2 describe-target-groups \
  --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[].{Path:HealthCheckPath,Matcher:Matcher.HttpCode}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Path: /healthcheck
Matcher: 200
```

### Step 3 — Observe Target Health

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{State:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}' \
  --output table \
  --region "$AWS_REGION"
```

Expected after failed checks:

```text
State: unhealthy
Reason: Target.ResponseCodeMismatch
Description: Health checks failed with these codes: [404]
```

### Step 4 — Monitor the Transition

```bash
for i in {1..12}; do
  aws elbv2 describe-target-health \
    --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[].{State:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}' \
    --output table \
    --region "$AWS_REGION"

  sleep 15
done
```

Stop using `Ctrl+C` after the unhealthy state appears.

### Step 5 — Compare Application Endpoints

```bash
curl --noproxy '*' -i \
  "http://${ALB_DNS}/health"

curl --noproxy '*' -i \
  "http://${ALB_DNS}/healthcheck"
```

Expected:

```text
/health      → HTTP 200
/healthcheck → HTTP 404
```

Because the target group has only one registered target, the ALB may fail open and continue forwarding requests despite the unhealthy target state.

The main incident evidence is `Target.ResponseCodeMismatch`, not a particular ALB response to `/`.

### Fault Summary

| Component | Finding |
|---|---|
| ALB | Active |
| EC2 | Running |
| Application | Active |
| Listening Port | 8080 |
| Actual Health Endpoint | `/health` |
| Configured Health Check | `/healthcheck` |
| Expected HTTP Status | 200 |
| Actual HTTP Status | 404 |
| Target Status | Unhealthy |
| Root Cause | Wrong health check path |

---

## 15. Troubleshooting Investigation

### Check 1 — Target Health

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --output json \
  --region "$AWS_REGION"
```

Finding: `Target.ResponseCodeMismatch`.

### Check 2 — Target Group Settings

```bash
aws elbv2 describe-target-groups \
  --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[].{Protocol:HealthCheckProtocol,Port:HealthCheckPort,Path:HealthCheckPath,Matcher:Matcher.HttpCode}' \
  --output table \
  --region "$AWS_REGION"
```

Finding: health path is `/healthcheck`.

### Check 3 — EC2 Health

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{Instance:InstanceStatus.Status,System:SystemStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

Finding: EC2 infrastructure is healthy.

### Check 4 — ALB Listener

```bash
aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[].{Port:Port,Protocol:Protocol,Actions:DefaultActions}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: listener forwards to the intended target group.

### Check 5 — Security Groups

```bash
aws ec2 describe-security-groups \
  --group-ids "$ALB_SG_ID" "$EC2_SG_ID" \
  --query 'SecurityGroups[].{Name:GroupName,Inbound:IpPermissions}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: ALB communication to port 8080 is permitted.

### Check 6 — Backend Endpoint Testing

Connect to EC2:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
sudo systemctl is-active lab06-web.service

curl --noproxy '*' -sS \
  -o /dev/null \
  -w 'Correct path: HTTP %{http_code}\n' \
  http://127.0.0.1:8080/health

curl --noproxy '*' -sS \
  -o /dev/null \
  -w 'Incorrect path: HTTP %{http_code}\n' \
  http://127.0.0.1:8080/healthcheck
```

Expected:

```text
Correct path: HTTP 200
Incorrect path: HTTP 404
```

### Investigation Summary

| Component | Finding |
|---|---|
| ALB | Active |
| Listener | Correct |
| Target Group | Registered |
| EC2 | Healthy |
| Backend Service | Running |
| Port 8080 | Listening |
| Security Group | Correct |
| Health Check Path | Incorrect |
| Expected Code | 200 |
| Actual Code | 404 |
| Root Cause | Health check path mismatch |

---

## 16. Root Cause Analysis

### Root Cause

The ALB target group was configured to check `/healthcheck`, while the backend application only supported `/health`.

The incorrect endpoint returned HTTP 404.

Because the target group's success matcher expected HTTP 200, the ALB marked the target unhealthy with `Target.ResponseCodeMismatch`.

### Technical Explanation

The ALB sent:

```http
GET /healthcheck HTTP/1.1
```

The application responded:

```http
HTTP/1.0 404 File not found
```

The configured matcher expected:

```text
HTTP 200
```

The response was outside the accepted range.

After the configured unhealthy threshold was reached, the target changed to `unhealthy`.

### Root Cause Flow

```text
Incorrect Health Check Path
             |
             v
GET /healthcheck
             |
             v
HTTP 404 Not Found
             |
             v
Expected HTTP 200
             |
             v
Target.ResponseCodeMismatch
             |
             v
Target Unhealthy
```

### Five Whys

1. **Why was the target unhealthy?** Health checks returned an unexpected HTTP response code.
2. **Why did the response code mismatch?** The application returned HTTP 404.
3. **Why did it return 404?** The configured `/healthcheck` endpoint did not exist.
4. **Why was the wrong endpoint configured?** The health check path was changed incorrectly.
5. **How can this be prevented?** Validate health check endpoints during deployment and manage ALB configuration through infrastructure as code.

---

## 17. Remediation and Verification

### Step 1 — Restore Correct Health Check Path

```bash
aws elbv2 modify-target-group \
  --target-group-arn "$TG_ARN" \
  --health-check-path "$CORRECT_PATH" \
  --region "$AWS_REGION"
```

### Step 2 — Verify Configuration

```bash
aws elbv2 describe-target-groups \
  --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[].{HealthPath:HealthCheckPath,Matcher:Matcher.HttpCode}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
HealthPath: /health
Matcher: 200
```

### Step 3 — Wait for Recovery

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
  --query 'TargetHealthDescriptions[].{ID:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `healthy`.

### Step 5 — Verify HTTP 200

```bash
curl --noproxy '*' -i \
  "http://${ALB_DNS}/"

curl --noproxy '*' -i \
  "http://${ALB_DNS}/health"
```

Expected: HTTP 200.

### Step 6 — Verify Multiple Requests

```bash
for i in {1..5}; do
  curl --noproxy '*' -sS \
    -o /dev/null \
    -w "Request $i: HTTP %{http_code}\n" \
    "http://${ALB_DNS}/health"
done
```

Expected: all five requests return HTTP 200.

### Verification Matrix

| Check | Baseline | During Failure | After Fix |
|---|---|---|---|
| EC2 | Running | Running | Running |
| Application | Active | Active | Active |
| Health Check Path | `/health` | `/healthcheck` | `/health` |
| Health Check Status | 200 | 404 | 200 |
| Target Health | Healthy | Unhealthy | Healthy |
| Reason Code | None | ResponseCodeMismatch | None |
| Application Response | 200 | May still be 200 | 200 |

### Success Criteria

- The initial target is healthy.
- Changing the path causes health check failures.
- `Target.ResponseCodeMismatch` is identified.
- Backend testing confirms HTTP 404 for the incorrect path.
- The health check configuration is corrected.
- Target health returns to healthy.
- HTTP 200 responses are verified.

---

## 18. Production Best Practices

### ALB Health Check Troubleshooting Checklist

1. Verify ALB status.
2. Check the target group.
3. Inspect target health reason codes.
4. Confirm registered target ports.
5. Review health check protocol.
6. Verify health check path.
7. Check the success-code matcher.
8. Verify application endpoints.
9. Inspect backend application logs.
10. Test the health endpoint directly.
11. Check security groups and network connectivity.
12. Correct configuration.
13. Verify target recovery.
14. Test application traffic.

### Common Health Check Problems

| Problem | Possible Result | Solution |
|---|---|---|
| Wrong path | HTTP 404 | Correct health check path |
| Application authentication required | HTTP 401 or 403 | Provide an appropriate health endpoint |
| Redirected endpoint | HTTP 301 or 302 | Use the intended health endpoint |
| Backend unavailable | Failed health checks | Restore application |
| Wrong target port | Connection failure | Correct target registration |
| Slow endpoint | Health check timeout | Optimize endpoint |
| Wrong matcher | Response code mismatch | Set appropriate success codes |
| Security group restriction | Connection timeout | Allow required ALB traffic |

### Prevention

- Use a dedicated application health endpoint.
- Keep health check paths consistent across environments.
- Avoid authentication requirements on internal health checks.
- Ensure health endpoints respond quickly.
- Validate the health path before deployment.
- Use Terraform or CloudFormation for target group configuration.
- Monitor unhealthy target counts.
- Configure CloudWatch alarms.
- Test application endpoints during CI/CD.
- Review infrastructure changes through pull requests.

### Security Considerations

- Restrict backend traffic to the ALB security group.
- Avoid using sensitive application endpoints for health checks.
- Apply least-privilege IAM permissions.
- Protect logs and application data.
- Keep production health checks stable during changes.

---

## 19. Cleanup

**Warning:** Before executing destructive commands, verify that all resources belong to `ELB-Troubleshooting-Lab06`.

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

### Step 4 — Check EBS Settings

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

Verify root EBS volume `DeleteOnTermination=true`.

### Step 5 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Remove Security Group Dependency

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

Wait until the lab's ALB and EC2 network interfaces have been removed.

### Step 7 — Delete Security Groups

```bash
aws ec2 delete-security-group \
  --group-id "$EC2_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Delete IAM Resources

Verify ownership and instance profile usage:

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

### Step 9 — Delete Route Table Associations

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

### Step 10 — Delete Subnets

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_A_ID" \
  --region "$AWS_REGION"

aws ec2 delete-subnet \
  --subnet-id "$SUBNET_B_ID" \
  --region "$AWS_REGION"
```

### Step 11 — Delete Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 12 — Delete VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 13 — Verify Cleanup

```bash
aws ec2 describe-instances \
  --filters \
    "Name=tag:Project,Values=$PROJECT_TAG" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' \
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

Also confirm the target group, EBS volume, IAM resources, and dedicated VPC have been removed.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| ALB Listener | Deleted |
| ALB | Deleted |
| Target Group | Deleted |
| EC2 | Terminated |
| EBS Root Volume | Deleted |
| ALB Security Group | Deleted |
| EC2 Security Group | Deleted |
| IAM Role | Deleted |
| Instance Profile | Deleted |
| Route Table | Deleted |
| Both Subnets | Deleted |
| Internet Gateway | Deleted |
| Lab VPC | Deleted |
| Default VPC | Unchanged |

---

## 20. Interview Questions and Answers

### Q1. What does `Target.ResponseCodeMismatch` mean?

The target returned an HTTP response code outside the configured health check success codes.

### Q2. What caused the problem in this lab?

The ALB checked `/healthcheck`, but the application only supported `/health`.

### Q3. Why did the backend return HTTP 404?

The `/healthcheck` endpoint did not exist.

### Q4. Was the EC2 instance unhealthy?

No. EC2 was running and the application responded correctly on its actual endpoints.

### Q5. What is the default successful HTTP health check code for an ALB?

HTTP 200.

### Q6. Can a target be unhealthy when the application is working?

Yes. Incorrect health check configuration can mark a functioning application as unhealthy.

### Q7. Which AWS CLI command modifies the health check path?

`aws elbv2 modify-target-group --health-check-path`.

### Q8. How do you inspect target health errors?

Use `aws elbv2 describe-target-health`.

### Q9. What is the difference between `Target.Timeout` and `Target.ResponseCodeMismatch`?

A timeout occurs when the health check cannot complete in time. A response code mismatch occurs when the target responds with an unexpected HTTP status code.

### Q10. Should HTTP 404 be added to the success matcher?

Not for this incident. That would hide the incorrect endpoint instead of fixing the real problem.

### Q11. How can this issue be prevented?

Validate health check paths, use infrastructure as code, review configuration changes, and monitor target health.

### Q12. How would you explain this lab in an interview?

I deployed an AWS Application Load Balancer with an EC2 backend running a Python HTTP server.

After establishing a healthy baseline, I intentionally changed the target group's health check path from `/health` to `/healthcheck`.

The application returned HTTP 404 because the new endpoint did not exist.

The ALB marked the target unhealthy with `Target.ResponseCodeMismatch`.

I inspected the target group configuration, target health reason code, EC2 status, and application responses.

After restoring `/health`, I verified that the target became healthy and HTTP requests succeeded.

---

## 21. Repository Structure

```text
06-health-check-path-failure/
├── README.md
├── ec2-trust-policy.json
└── backend-user-data.sh
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete production-style troubleshooting documentation |
| `ec2-trust-policy.json` | IAM trust policy for EC2 Systems Manager access |
| `backend-user-data.sh` | Creates the Python HTTP backend and health endpoint |

Do not commit AWS credentials, private keys, or sensitive application information.

---

## 22. Lessons Learned

This lab demonstrates that an ALB target can become unhealthy even when the EC2 instance and application are functioning correctly.

The issue was caused by an incorrect health check path rather than an application failure or network restriction.

The ALB expected HTTP 200, but the incorrectly configured endpoint returned HTTP 404.

The most important troubleshooting evidence was the `Target.ResponseCodeMismatch` reason code and direct testing of the health check endpoints.

Restoring the correct health check path allowed the target to pass health checks again.

**Key Lesson:** Always check the configured health check path and expected response code before assuming that an unhealthy ALB target has an application or networking problem.

---

## 23. Skills Demonstrated

- AWS Application Load Balancer
- Target group health checks
- Target health reason codes
- `Target.ResponseCodeMismatch` troubleshooting
- HTTP 200 and HTTP 404 diagnostics
- AWS CLI v2
- Linux systemd
- curl
- EC2 application troubleshooting
- AWS Systems Manager
- VPC networking
- Security group verification
- Fault injection
- Root cause analysis
- Remediation and verification
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-ELB-006 |
| Problem | ALB health check path failure |
| Root Cause | Wrong health check endpoint |
| EC2 | Running |
| Backend Application | Active |
| Correct Endpoint | `/health` |
| Incorrect Endpoint | `/healthcheck` |
| Fault Response | HTTP 404 |
| Target Health During Fault | Unhealthy |
| Reason | `Target.ResponseCodeMismatch` |
| Remediation | Restore `/health` |
| Final Target Health | Healthy |
| Final HTTP Response | HTTP 200 |
| Cleanup | Temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** ALB health checks depend on the configured application endpoint and expected HTTP response code. An incorrect health check path can make a healthy application appear unhealthy.
