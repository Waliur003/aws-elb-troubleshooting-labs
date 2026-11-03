# Lab 01 — ALB Target Unhealthy

## Overview

This lab demonstrates how to troubleshoot an unhealthy target registered with an AWS Application Load Balancer (ALB).

We deploy an internet-facing ALB with an Amazon EC2 backend running a Python HTTP application on port 8080. The ALB forwards incoming HTTP requests to the backend through a target group and continuously monitors its health using the `/health` endpoint.

Initially, the application works correctly and the registered target reports `healthy`.

We intentionally stop the backend HTTP service to simulate an application outage. The ALB health checks begin failing, and the target transitions to `unhealthy`.

We investigate the target health status, reason codes, EC2 health, security groups, application process, and listening port.

After identifying the stopped backend service as the root cause, we restart it and verify that the target becomes healthy again.

**Troubleshooting workflow:**

Provision → Healthy Baseline → Fault Injection → Investigation → Root Cause Analysis → Remediation → Verification → Cleanup

---

## 1. Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-ELB-001 |
| Difficulty | Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | Elastic Load Balancing, EC2, VPC, IAM, Systems Manager |
| Load Balancer Type | Application Load Balancer |
| Load Balancer Scheme | Internet-facing |
| Listener | HTTP, port 80 |
| Target Group | HTTP, port 8080 |
| Target Type | Instance |
| Health Check Path | `/health` |
| Expected Health Response | HTTP 200 |
| EC2 Instance | Amazon Linux 2023, `t3.micro` |
| Local Environment | Ubuntu WSL2 |
| Tools | AWS CLI v2, Bash, curl, systemd |
| VPC CIDR | `10.160.0.0/16` |
| Subnet A | `10.160.1.0/24` |
| Subnet B | `10.160.2.0/24` |
| Fault Injection | Stop the backend HTTP service |
| Expected Target Status | `unhealthy` |
| Root Cause | No application process listening on port 8080 |
| Remediation | Restart the backend service |
| Verification | Target `healthy` and ALB HTTP 200 |

---

## 2. Production Incident Scenario

### Incident Description

A company hosts its web application on an EC2 instance behind an AWS Application Load Balancer.

The ALB receives incoming requests on port 80 and forwards them to the backend application on port 8080.

To monitor application availability, the target group performs HTTP health checks against `/health`.

After an application service interruption, the ALB begins reporting the registered target as unhealthy.

The EC2 instance itself is still running, but the web application is not accepting connections.

### Incident Symptoms

- Application requests through the ALB fail.
- The registered EC2 target changes from `healthy` to `unhealthy`.
- ALB health checks cannot connect successfully.
- Target health may report `Target.FailedHealthChecks`.
- EC2 instance and system status checks remain healthy.
- Security group and listener configurations remain correct.
- The application service reports `inactive`.
- Port 8080 is no longer listening.

### Business Impact

- Customers cannot access the application successfully.
- Application availability decreases.
- Incoming requests fail.
- Monitoring systems may report unhealthy backends.
- If no healthy application instances are available, the service may experience an outage.
- Engineers must investigate and restore application availability.

### Incident Objective

Identify the application or infrastructure problem causing the ALB target to become unhealthy and restore successful health checks without making unnecessary networking changes.

---

## 3. AWS Architecture

### Healthy Architecture

```text
                         Internet
                            |
                            v
                +-----------------------+
                | Application Load      |
                | Balancer (ALB)        |
                | HTTP Listener: 80     |
                +-----------+-----------+
                            |
                            v
                +-----------------------+
                | Target Group          |
                | Protocol: HTTP        |
                | Target Port: 8080     |
                | Health Path: /health  |
                +-----------+-----------+
                            |
                            v
                +-----------------------+
                | EC2 Backend           |
                | Amazon Linux 2023     |
                | Python HTTP Server    |
                | Port: 8080            |
                +-----------+-----------+
                            |
                            v
                     HTTP 200 OK
                            |
                            v
                     Target Healthy
```

The ALB is attached to two subnets in different Availability Zones.

The backend EC2 instance is deployed in Subnet A.

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
HTTP Health Check
GET /health : 8080
       |
       X
Backend Service Stopped
       |
       X
Port 8080 Not Listening
       |
       v
Health Checks Fail
       |
       v
Target Unhealthy
```

### Resource Configuration

| Component | Configuration |
|---|---|
| VPC | `10.160.0.0/16` |
| Subnet A | `10.160.1.0/24` |
| Subnet B | `10.160.2.0/24` |
| Internet Gateway | Attached to VPC |
| Public route | `0.0.0.0/0` to Internet Gateway |
| ALB security group | Inbound TCP 80 from internet |
| Backend security group | Inbound TCP 8080 from ALB SG only |
| ALB listener | HTTP 80 |
| Backend port | TCP 8080 |
| Health check path | `/health` |
| HTTP success matcher | 200 |

The backend security group restricts incoming application traffic to the load balancer.

---

## 4. Understanding ALB Target Health

An Application Load Balancer distributes incoming HTTP and HTTPS requests to registered targets.

Targets are organized into target groups.

The ALB periodically checks each registered target to determine whether it is able to accept traffic.

### Target Health States

| State | Meaning |
|---|---|
| `healthy` | Target passes the configured health checks |
| `initial` | Target registration or initial health checks are in progress |
| `unhealthy` | Target fails the required health checks |
| `unused` | Target is not being used by the load balancer |
| `draining` | Target is being deregistered |
| `unavailable` | Health checks are unavailable |

### Important Target Health Reason Codes

| Reason Code | Meaning |
|---|---|
| `Target.FailedHealthChecks` | Health checks failed |
| `Target.Timeout` | Target health check timed out |
| `Target.ResponseCodeMismatch` | Response code did not match configured success codes |
| `Target.NotRegistered` | Target is not registered |
| `Target.NotInUse` | Target group or AZ configuration does not allow target use |
| `Target.InvalidState` | Target is in an invalid instance state |

### Configured Health Check

```text
Protocol: HTTP
Port: 8080
Path: /health
Interval: 15 seconds
Timeout: 5 seconds
Healthy threshold: 2
Unhealthy threshold: 2
Success code: 200
```

The target becomes unhealthy after meeting the configured failure threshold.

When the application recovers and passes the required checks, the target returns to `healthy`.

---

## 5. Prerequisites and Safety

### Prerequisites

- AWS account with appropriate permissions
- AWS CLI v2
- Ubuntu WSL2
- Bash
- EC2 and VPC permissions
- Elastic Load Balancing permissions
- IAM role creation permissions
- Systems Manager access
- Git and GitHub

### Safety Requirements

- Use a dedicated lab VPC.
- Do not stop services in production.
- Do not modify existing production target groups.
- Restrict backend port 8080 to the ALB security group.
- Verify AWS account identity before provisioning.
- Confirm tags before deleting resources.
- Remove temporary infrastructure after the lab.

### Cost Considerations

Resources that can incur charges include:

- Application Load Balancer
- Load Balancer Capacity Units
- EC2 instance
- EBS storage
- Public IPv4 address
- Applicable network traffic

The ALB continues to incur charges while deployed, including when its target is unhealthy.

---

## 6. Prepare the Environment

### Step 1 — Configure Variables

Open Ubuntu WSL2:

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="ELB-Troubleshooting-Lab01"

export VPC_CIDR="10.160.0.0/16"
export SUBNET_A_CIDR="10.160.1.0/24"
export SUBNET_B_CIDR="10.160.2.0/24"

export VPC_NAME="cloud-elb-lab01-vpc"

export ALB_NAME="cloud-elb-lab01-alb"
export TG_NAME="cloud-elb-lab01-tg"

export ROLE_NAME="cloud-elb-lab01-ssm-role"
export PROFILE_NAME="cloud-elb-lab01-ssm-profile"
```

### Step 2 — Verify AWS Identity

```bash
aws sts get-caller-identity
aws --version
```

### Step 3 — Select Two Availability Zones

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Select two supported AZs:

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
```

Check the ALB:

```bash
aws elbv2 describe-load-balancers \
  --names "$ALB_NAME" \
  --region "$AWS_REGION"
```

`LoadBalancerNotFound` is expected when no ALB exists.

Do not create duplicate lab resources.

---

## 7. Create VPC Networking

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=$VPC_NAME},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")

echo "$VPC_ID"
```

### Step 2 — Enable DNS

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

### Step 3 — Create Subnet A

```bash
export SUBNET_A_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_A_CIDR" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-elb-lab01-subnet-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Create Subnet B

```bash
export SUBNET_B_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_B_CIDR" \
  --availability-zone "$AZ_B" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-elb-lab01-subnet-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cloud-elb-lab01-igw},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")
```

Attach:

```bash
aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Create Public Route Table

```bash
export RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-elb-lab01-public-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 7 — Add Internet Route

```bash
aws ec2 create-route \
  --route-table-id "$RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Associate Both Subnets

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

### Step 9 — Verify Routes

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
10.160.0.0/16 → local
0.0.0.0/0     → Internet Gateway
```

---

## 8. Configure Security Groups

### Step 1 — Create ALB Security Group

```bash
export ALB_SG_ID=$(aws ec2 create-security-group \
  --group-name cloud-elb-lab01-alb-sg \
  --description "Lab01 ALB security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=cloud-elb-lab01-alb-sg},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Allow Inbound HTTP

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG_ID" \
  --protocol tcp \
  --port 80 \
  --cidr "0.0.0.0/0" \
  --region "$AWS_REGION"
```

### Step 3 — Create Backend Security Group

```bash
export EC2_SG_ID=$(aws ec2 create-security-group \
  --group-name cloud-elb-lab01-ec2-sg \
  --description "Lab01 ALB backend server SG" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=cloud-elb-lab01-ec2-sg},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Allow ALB to Reach Backend Port 8080

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$EC2_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Verify Security Groups

```bash
aws ec2 describe-security-groups \
  --group-ids "$ALB_SG_ID" "$EC2_SG_ID" \
  --query 'SecurityGroups[].{Name:GroupName,Inbound:IpPermissions,Outbound:IpPermissionsEgress}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

| Security Group | Inbound | Outbound |
|---|---|---|
| ALB SG | TCP 80 from internet | Default allow |
| Backend SG | TCP 8080 from ALB SG | Default allow |

---

## 9. Configure IAM for EC2

### Step 1 — Create EC2 Trust Policy

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

### Step 2 — Create IAM Role

```bash
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"
```

### Step 3 — Attach Systems Manager Permissions

```bash
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

### Step 4 — Create Instance Profile

```bash
aws iam create-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME"
```

Allow IAM changes to propagate before launching EC2.

---

## 10. Create Backend HTTP Application

Create `backend-user-data.sh`:

```bash
#!/bin/bash
set -eux

mkdir -p /opt/lab01

cat > /opt/lab01/index.html <<'HTML'
AWS ELB Troubleshooting Lab 01

Application: Python HTTP Server
Service: Backend EC2
Status: Running
HTML

cat > /opt/lab01/health <<'HEALTH'
OK
HEALTH

cat > /etc/systemd/system/lab01-web.service <<'UNIT'
[Unit]
Description=Lab 01 ALB Backend HTTP Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/lab01
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab01-web.service
```

### Application Endpoints

| Endpoint | Expected Result |
|---|---|
| `/` | HTTP 200, application test page |
| `/health` | HTTP 200, `OK` |
| Invalid path | HTTP 404 |

The service is managed by systemd and starts automatically when enabled.

---

## 11. Launch the Backend EC2 Instance

### Step 1 — Retrieve Amazon Linux 2023 AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Launch Instance

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
  "ResourceType=instance,Tags=[{Key=Name,Value=cloud-elb-lab01-backend},{Key=Project,Value=$PROJECT_TAG}]" \
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

### Step 4 — Verify Instance Health

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{ID:InstanceId,Instance:InstanceStatus.Status,System:SystemStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: instance and system checks are `ok`.

### Step 5 — Verify SSM

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

When `Online`, connect:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Verify Application

Inside EC2:

```bash
sudo systemctl status lab01-web.service --no-pager

curl --noproxy '*' -i \
  http://127.0.0.1:8080/health
```

Expected:

```text
HTTP/1.0 200 OK

OK
```

Exit the instance.

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

### Step 2 — Register EC2 Target

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
```

### Step 4 — Wait for ALB

```bash
aws elbv2 wait load-balancer-available \
  --load-balancer-arns "$ALB_ARN" \
  --region "$AWS_REGION"
```

### Step 5 — Create HTTP Listener

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

### Step 6 — Retrieve ALB DNS

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
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
healthy
```

If necessary, wait until the target passes its initial health checks:

```bash
aws elbv2 wait target-in-service \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

### Step 2 — Test ALB HTTP Response

```bash
curl --noproxy '*' -v \
  --connect-timeout 5 \
  --max-time 15 \
  "http://${ALB_DNS}/"
```

Expected:

```text
HTTP/1.1 200 OK
```

The response body should contain the Lab 01 application text.

### Step 3 — Test Health Endpoint

```bash
curl --noproxy '*' -i \
  "http://${ALB_DNS}/health"
```

Expected: HTTP 200 with `OK`.

### Baseline Summary

| Component | Expected Status |
|---|---|
| ALB | Active |
| Listener | HTTP 80 |
| Target Group | Registered |
| EC2 | Running |
| Backend HTTP Service | Active |
| Target Health | Healthy |
| ALB Request | HTTP 200 |

---

## 14. Reproduce the Target Health Failure

### Step 1 — Verify Baseline Health

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{State:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table \
  --region "$AWS_REGION"
```

Confirm the target is `healthy`.

### Step 2 — Connect to Backend

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 3 — Stop HTTP Service

Inside EC2:

```bash
sudo systemctl stop lab01-web.service
```

### Step 4 — Verify Service Is Stopped

```bash
sudo systemctl is-active lab01-web.service
```

Expected:

```text
inactive
```

### Step 5 — Verify Port 8080

```bash
sudo ss -lntp | grep ':8080' || echo "No service listening on port 8080"
```

Expected: no service is listening.

### Step 6 — Test Failed Health Endpoint

```bash
curl --noproxy '*' -v \
  --connect-timeout 3 \
  http://127.0.0.1:8080/health
```

Expected: connection refused.

Exit the session.

### Step 7 — Inspect Target Health

From WSL2:

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}' \
  --output table \
  --region "$AWS_REGION"
```

Expected after health check failures:

```text
State: unhealthy
Reason: Target.FailedHealthChecks
```

The exact reason code can differ based on the failure.

### Step 8 — Monitor the Health Transition

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

Stop with `Ctrl+C` when the unhealthy result is observed.

### Step 9 — Test ALB During Failure

```bash
curl --noproxy '*' -v \
  --connect-timeout 5 \
  --max-time 15 \
  "http://${ALB_DNS}/"
```

Expected: the application does not respond successfully.

The ALB may return HTTP 502 when the backend refuses connections.

**Important:** ALBs can fail open when all registered targets are unhealthy. Therefore, an unhealthy target does not automatically produce HTTP 503.

---

## 15. Troubleshooting Investigation

### Check 1 — Inspect Target Health and Reason Codes

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --output json \
  --region "$AWS_REGION"
```

Finding: target is unhealthy.

### Check 2 — Verify Target Group Configuration

```bash
aws elbv2 describe-target-groups \
  --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[].{Name:TargetGroupName,Protocol:Protocol,Port:Port,Path:HealthCheckPath,Interval:HealthCheckIntervalSeconds,Timeout:HealthCheckTimeoutSeconds}' \
  --output table \
  --region "$AWS_REGION"
```

Finding: port 8080 and `/health` are configured correctly.

### Check 3 — Verify Registered Target

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].Target' \
  --output json \
  --region "$AWS_REGION"
```

Finding: EC2 instance is registered.

### Check 4 — Verify EC2 Health

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{Instance:InstanceStatus.Status,System:SystemStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

Finding: EC2 system and instance checks remain healthy.

### Check 5 — Inspect Security Groups

```bash
aws ec2 describe-security-groups \
  --group-ids "$ALB_SG_ID" "$EC2_SG_ID" \
  --query 'SecurityGroups[].{Name:GroupName,Inbound:IpPermissions,Outbound:IpPermissionsEgress}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: security groups allow the intended HTTP traffic.

### Check 6 — Verify ALB Listener

```bash
aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[].{Port:Port,Protocol:Protocol,Actions:DefaultActions}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: listener forwards to the correct target group.

### Check 7 — Inspect Backend Service

Connect to EC2:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside:

```bash
sudo systemctl status lab01-web.service --no-pager

sudo journalctl -u lab01-web.service -n 30 --no-pager

sudo ss -lntp | grep ':8080' || echo "Port 8080 not listening"
```

Finding: HTTP service is stopped and no process is listening on port 8080.

### Investigation Summary

| Component | Finding |
|---|---|
| ALB | Active |
| Listener | Correct |
| Target registration | Correct |
| Target group port | Correct |
| Health path | Correct |
| EC2 instance checks | Healthy |
| Security groups | Correct |
| Backend service | Inactive |
| Application port | Not listening |
| Target status | Unhealthy |
| Root cause | Backend service stopped |

---

## 16. Root Cause Analysis

### Root Cause

The backend HTTP application was stopped, leaving no process listening on TCP port 8080.

### Technical Explanation

The ALB performs HTTP health checks against the registered EC2 target.

The expected request is:

```text
GET http://<backend-private-ip>:8080/health
```

The expected response is:

```text
HTTP 200 OK
```

After the application stopped, the ALB could no longer establish a successful connection to the target.

Health checks began failing.

After reaching the configured unhealthy threshold, the target state changed to `unhealthy`.

The issue was not caused by EC2 availability, the target group, listener rules, or security groups.

### Root Cause Flow

```text
Backend HTTP Service Stopped
              |
              v
Port 8080 Not Listening
              |
              v
ALB Health Check Fails
              |
              v
Unhealthy Threshold Reached
              |
              v
Target Becomes Unhealthy
              |
              v
Application Requests Fail
```

### Five Whys

1. **Why was the target unhealthy?** The ALB health checks failed.
2. **Why did health checks fail?** The backend stopped accepting connections on port 8080.
3. **Why was port 8080 unavailable?** The Python HTTP service was stopped.
4. **Why was EC2 still healthy?** EC2 status checks monitor infrastructure conditions, not the health of every application process.
5. **How can the incident be prevented?** Use application monitoring, automatic service recovery, multiple targets, and health-based alerts.

---

## 17. Remediation

### Step 1 — Connect to EC2

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 2 — Restart the Application

```bash
sudo systemctl start lab01-web.service
```

### Step 3 — Verify Service Status

```bash
sudo systemctl is-active lab01-web.service
```

Expected:

```text
active
```

### Step 4 — Verify Port 8080

```bash
sudo ss -lntp | grep ':8080'
```

Expected: Python is listening on port 8080.

### Step 5 — Verify Health Endpoint

```bash
curl --noproxy '*' -i \
  http://127.0.0.1:8080/health
```

Expected: HTTP 200 with `OK`.

Exit Session Manager.

### Step 6 — Verify Target Recovery

```bash
aws elbv2 wait target-in-service \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

### Step 7 — Check Target Health

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
healthy
```

### Step 8 — Verify ALB HTTP Response

```bash
curl --noproxy '*' -v \
  --connect-timeout 5 \
  --max-time 15 \
  "http://${ALB_DNS}/"
```

Expected: HTTP 200 and the application test page.

### Step 9 — Verify ALB Health Endpoint

```bash
curl --noproxy '*' -sS \
  -o /dev/null \
  -w 'HTTP Status: %{http_code}\n' \
  "http://${ALB_DNS}/health"
```

Expected:

```text
HTTP Status: 200
```

### Verification Matrix

| Check | Before Failure | During Failure | After Fix |
|---|---|---|---|
| EC2 | Running | Running | Running |
| ALB | Active | Active | Active |
| Target registered | Yes | Yes | Yes |
| Security groups | Correct | Correct | Correct |
| Backend application | Active | Inactive | Active |
| Port 8080 | Listening | Not listening | Listening |
| Target health | Healthy | Unhealthy | Healthy |
| ALB HTTP response | 200 | Failure | 200 |

### Success Criteria

- Baseline target health is verified.
- Stopping the application causes health checks to fail.
- Target becomes unhealthy.
- Backend service is identified as the root cause.
- Application is restarted.
- Target returns to healthy.
- HTTP requests through the ALB succeed.

---

## 18. Production Best Practices

### ALB Troubleshooting Checklist

1. Verify ALB state.
2. Check listeners and listener rules.
3. Identify the forwarding target group.
4. Inspect registered targets.
5. Check target health reason codes.
6. Verify EC2 instance status.
7. Confirm the backend application is running.
8. Verify the application is listening on the expected port.
9. Check the health check path and success matcher.
10. Inspect ALB and target security groups.
11. Verify VPC routing and network ACLs.
12. Test the backend locally.
13. Apply remediation.
14. Verify target health and actual HTTP responses.

### Common Causes of Unhealthy Targets

| Problem | Possible Reason Code |
|---|---|
| Backend application stopped | `Target.FailedHealthChecks` |
| Backend connection timeout | `Target.Timeout` |
| Incorrect health check path | `Target.ResponseCodeMismatch` |
| Wrong expected status code | `Target.ResponseCodeMismatch` |
| Target in invalid EC2 state | `Target.InvalidState` |
| Incorrect target registration | `Target.NotRegistered` or `Target.NotInUse`, depending on circumstances |
| Backend security group restriction | `Target.Timeout` or failed health checks |

Actual reason codes depend on the failure and the service's observations.

### Prevention

- Use automatic application restart policies.
- Deploy multiple healthy targets across Availability Zones.
- Configure useful application health endpoints.
- Monitor `UnHealthyHostCount`.
- Monitor ALB HTTP 5xx metrics.
- Use CloudWatch alarms for availability problems.
- Keep application logs available for investigation.
- Use least-privilege security group rules.
- Deploy infrastructure through Terraform.
- Test application health after deployments.
- Use rolling deployments to reduce downtime.
- Review EC2 and ALB costs.

### Important Production Note

This lab intentionally uses a single backend target to make the failure easy to observe.

Production applications generally benefit from multiple targets across Availability Zones.

A single target represents a single point of application failure.

---

## 19. Interview Questions and Answers

### Q1. What is an Application Load Balancer?

An ALB is an AWS Layer 7 load balancer used to distribute HTTP and HTTPS requests to registered targets.

### Q2. What is an ALB target group?

A collection of registered backend targets that receive requests from a load balancer.

### Q3. What does `healthy` mean?

The target successfully passes the configured health checks.

### Q4. What does `Target.FailedHealthChecks` indicate?

The target failed health checks, potentially because its service is unavailable or not responding correctly.

### Q5. What is `Target.Timeout`?

A health check failed because the target did not complete the required connection or response within the configured timeout.

### Q6. What is `Target.ResponseCodeMismatch`?

The target returned an HTTP status code outside the configured success matcher.

### Q7. Can EC2 be running while the ALB target is unhealthy?

Yes. EC2 status checks and application-level health checks measure different conditions.

### Q8. Why must the backend security group allow the ALB?

The ALB needs permission to connect to backend application ports and perform health checks.

### Q9. Does an ALB always return 503 when all targets are unhealthy?

No. ALBs can fail open and forward requests to unhealthy registered targets.

### Q10. What should you check first when a target is unhealthy?

Check the target health state, reason code, health check configuration, and backend application status.

### Q11. Why did the target become unhealthy in this lab?

The backend HTTP service stopped, so the ALB could not connect to port 8080.

### Q12. How would you explain this lab in an interview?

I deployed an AWS Application Load Balancer with an EC2 backend running a Python HTTP server on port 8080.

I configured the ALB listener, target group, and HTTP health checks using `/health`.

After confirming the target was healthy, I intentionally stopped the backend service. The ALB health checks began failing, and the target became unhealthy.

I inspected the target health reason codes, EC2 health, security groups, and backend service status. I confirmed that port 8080 was not listening.

I restarted the application, verified that the target became healthy, and confirmed that the ALB successfully returned HTTP 200.

---

## 20. Cleanup

**Warning:** Verify AWS identity, resource names, and ownership tags before deleting anything.

### Step 1 — Verify Ownership

```bash
aws sts get-caller-identity

aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].Tags' \
  --output json \
  --region "$AWS_REGION"

aws elbv2 describe-tags \
  --resource-arns "$ALB_ARN" "$TG_ARN" \
  --output json \
  --region "$AWS_REGION"

aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"
```

Confirm all resources belong to `ELB-Troubleshooting-Lab01`.

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
```

Wait:

```bash
aws elbv2 wait load-balancers-deleted \
  --load-balancer-arns "$ALB_ARN" \
  --region "$AWS_REGION"
```

### Step 4 — Deregister Backend Target

```bash
aws elbv2 deregister-targets \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

### Step 5 — Delete Target Group

```bash
aws elbv2 delete-target-group \
  --target-group-arn "$TG_ARN" \
  --region "$AWS_REGION"
```

### Step 6 — Verify EBS Settings

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the root EBS volume has `DeleteOnTermination=true`.

### Step 7 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Remove Backend SG Reference

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$EC2_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

### Step 9 — Verify ENIs Are Removed

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Wait until the lab's EC2 and ALB network interfaces are removed.

### Step 10 — Delete Security Groups

```bash
aws ec2 delete-security-group \
  --group-id "$EC2_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

### Step 11 — Delete IAM Resources

Verify ownership and usage:

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

### Step 12 — Delete Route Table Associations

```bash
aws ec2 disassociate-route-table \
  --association-id "$RT_ASSOC_A" \
  --region "$AWS_REGION"

aws ec2 disassociate-route-table \
  --association-id "$RT_ASSOC_B" \
  --region "$AWS_REGION"
```

### Step 13 — Delete Custom Route Table

```bash
aws ec2 delete-route-table \
  --route-table-id "$RT_ID" \
  --region "$AWS_REGION"
```

### Step 14 — Delete Subnets

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_A_ID" \
  --region "$AWS_REGION"

aws ec2 delete-subnet \
  --subnet-id "$SUBNET_B_ID" \
  --region "$AWS_REGION"
```

### Step 15 — Delete Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 16 — Delete VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 17 — Final Verification

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

Confirm the target group, ALB, root EBS volume, and dedicated VPC have been removed.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| ALB listener | Deleted |
| Application Load Balancer | Deleted |
| Target group | Deleted |
| Backend EC2 | Terminated |
| Root EBS volume | Deleted |
| ALB security group | Deleted |
| Backend security group | Deleted |
| IAM role | Deleted |
| Instance profile | Deleted |
| Custom route table | Deleted |
| Both subnets | Deleted |
| Internet Gateway | Deleted |
| Dedicated VPC | Deleted |
| Default VPC | Unchanged |

---

## 21. Repository Structure

```text
01-alb-target-unhealthy/
├── README.md
├── ec2-trust-policy.json
└── backend-user-data.sh
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete troubleshooting documentation |
| `ec2-trust-policy.json` | Allows EC2 to assume the Systems Manager IAM role |
| `backend-user-data.sh` | Creates the Python HTTP application and `/health` endpoint |

Do not commit AWS credentials, private keys, or other sensitive data.

---

## 22. Lessons Learned

This lab demonstrates that an EC2 instance can be running and healthy while its application is unavailable.

The ALB continuously monitors the backend using health checks.

When the Python HTTP service stopped, the ALB could no longer connect to port 8080.

The target transitioned to unhealthy even though the infrastructure itself remained operational.

Investigating the target health reason code, application service status, and listening port identified the actual failure.

Restarting the application restored successful health checks and HTTP connectivity.

**Key Lesson:** When an ALB target becomes unhealthy, investigate both the AWS configuration and the backend application. A running EC2 instance does not guarantee that its application is healthy.

---

## 23. Skills Demonstrated

- AWS Application Load Balancer deployment
- Target group configuration
- ALB health checks
- Target health reason code investigation
- EC2 application troubleshooting
- AWS CLI v2
- Linux systemd service management
- HTTP testing with curl
- VPC networking
- Security group configuration
- IAM and Systems Manager
- Root cause analysis
- Fault injection
- Application remediation
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-ELB-001 |
| Problem | ALB target unhealthy |
| Root Cause | Backend HTTP service stopped |
| EC2 Infrastructure | Healthy |
| Target Group | Correctly configured |
| Health Check Path | `/health` |
| Application Port | 8080 |
| Initial Target Health | Healthy |
| During Failure | Unhealthy |
| Remediation | Restart backend service |
| Final Target Health | Healthy |
| Final HTTP Response | 200 OK |
| Cleanup | Temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** ALB target health depends on successful application-level health checks, not simply on EC2 instance status. Proper troubleshooting requires examining target health, backend processes, ports, and networking together.
