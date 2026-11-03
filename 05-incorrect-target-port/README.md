# Lab 05 — ALB Incorrect Target Port

## Overview

This lab demonstrates how to troubleshoot an unhealthy Application Load Balancer (ALB) target caused by an incorrect registered backend port.

We deploy an internet-facing ALB with an Amazon EC2 backend running a Python HTTP application on TCP port 8080.

Initially, the EC2 instance is registered with the target group on port 8080. Health checks succeed, and the ALB returns HTTP 200.

We then intentionally deregister the healthy target and register the same instance using port 9090.

The target group's default port remains 8080, but the explicit registration overrides that port.

Because no application is listening on port 9090, the ALB cannot complete its health checks. The registered target becomes unhealthy.

We investigate target registration, health check configuration, EC2 instance health, security groups, and Linux listening ports.

After identifying the incorrect target port, we register the instance on port 8080 again, remove the unnecessary security group rule, and verify successful HTTP connectivity.

**Troubleshooting workflow:**

Provision → Healthy Baseline → Fault Injection → Investigation → Root Cause Analysis → Remediation → Verification → Cleanup

---

## 1. Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-ELB-005 |
| Difficulty | Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | ALB, EC2, VPC, IAM, Systems Manager |
| Load Balancer | Application Load Balancer |
| Scheme | Internet-facing |
| ALB Listener | HTTP 80 |
| Target Group | HTTP 8080 |
| Target Type | Instance |
| Health Check Path | `/health` |
| Health Check Port | `traffic-port` |
| Backend Application | Python HTTP server |
| EC2 Instance | Amazon Linux 2023, `t3.micro` |
| VPC CIDR | `10.164.0.0/16` |
| Subnet A | `10.164.1.0/24` |
| Subnet B | `10.164.2.0/24` |
| Correct Application Port | 8080 |
| Incorrect Registered Port | 9090 |
| Fault Injection | Register EC2 with incorrect port |
| Target Status During Fault | Unhealthy |
| Root Cause | Target port differs from application listener |
| Remediation | Correct target registration |
| Verification | Target healthy and HTTP 200 |

---

## 2. Production Incident Scenario

### Incident Description

A company hosts an application on an Amazon EC2 instance behind an Application Load Balancer.

The application listens on TCP port 8080 and exposes an HTTP health check endpoint at `/health`.

The ALB forwards client requests through a target group configured with HTTP port 8080.

During an infrastructure deployment, an engineer accidentally registers the EC2 instance using port 9090.

The target group itself still shows the correct default port of 8080, but the registered instance uses an explicit port override.

The ALB starts checking the instance on port 9090.

No application process is listening on that port, so health checks begin failing.

The target transitions from healthy to unhealthy.

### Incident Symptoms

- ALB remains active.
- EC2 remains running.
- Application service remains active.
- Application responds successfully on port 8080.
- Port 9090 has no listening application.
- Target group default port is 8080.
- Registered target port is 9090.
- Health check port uses `traffic-port`.
- ALB target becomes unhealthy.
- Requests through the ALB fail.

### Business Impact

- Application requests fail.
- Customers cannot reliably access the service.
- Application availability decreases.
- Health checks report failures.
- Monitoring systems may generate unhealthy-target alerts.
- Infrastructure troubleshooting is required before service can be restored.

### Incident Objective

Identify why the ALB target is unhealthy even though the EC2 application is running, correct the port mismatch, and verify successful application access.

---

## 3. AWS Architecture

### Healthy Architecture

```text
                    Internet Client
                           |
                           v
                +----------------------+
                | Application Load     |
                | Balancer             |
                | HTTP Listener: 80    |
                +----------+-----------+
                           |
                           v
                +----------------------+
                | Target Group         |
                | Default Port: 8080   |
                | Health: /health      |
                +----------+-----------+
                           |
                           v
                +----------------------+
                | Registered Target    |
                | EC2 Instance         |
                | Port: 8080           |
                +----------+-----------+
                           |
                           v
                +----------------------+
                | Python HTTP Server   |
                | Listening: 8080      |
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
                Target Group: HTTP 8080
                           |
                           v
                Registered Target: 9090
                           |
                           X
                 No Application Listening
                           |
                           v
                  Health Check Fails
                           |
                           v
                    Target Unhealthy


                EC2 Application Still Runs
                     on Port 8080
```

### Resource Configuration

| Component | Configuration |
|---|---|
| VPC | `10.164.0.0/16` |
| Subnet A | `10.164.1.0/24` |
| Subnet B | `10.164.2.0/24` |
| Internet Gateway | Attached |
| Public Route | `0.0.0.0/0` via IGW |
| ALB Security Group | Inbound TCP 80 |
| Backend Security Group | TCP 8080 and 9090 from ALB SG during testing |
| Listener | HTTP 80 |
| Target Group Default Port | 8080 |
| Registered Target Port During Fault | 9090 |
| Health Check Path | `/health` |
| Health Check Port | `traffic-port` |

---

## 4. Understanding Target Group Ports

An ALB target group defines the protocol and default port used to communicate with registered targets.

When registering an EC2 instance, we can optionally specify a port different from the target group's default.

### Correct Registration

```bash
aws elbv2 register-targets \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

### Incorrect Registration

```bash
aws elbv2 register-targets \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=9090" \
  --region "$AWS_REGION"
```

Even if the target group default port is 8080, explicitly registering the target on port 9090 causes traffic to use that registered port.

### What Does `traffic-port` Mean?

The `traffic-port` setting tells the ALB to perform health checks using the registered target's traffic port.

During the incident:

```text
Target Group Default Port: 8080
Registered Target Port: 9090
Health Check Port: traffic-port

Effective Health Check Port: 9090
```

The ALB attempts:

```text
GET http://<EC2-private-IP>:9090/health
```

No application process is listening on 9090.

The health check fails.

### Common Target Health Reason Codes

| Reason Code | Meaning |
|---|---|
| `Target.FailedHealthChecks` | Target failed health checks |
| `Target.Timeout` | Health check timed out |
| `Target.ResponseCodeMismatch` | HTTP status code did not match the expected success code |
| `Target.NotRegistered` | Target is not registered |
| `Target.NotInUse` | Target is not used by the load balancer |

An incorrect target port commonly produces failed health checks, although the exact reason depends on the network behavior.

---

## 5. Prerequisites and Safety

### Requirements

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- EC2 permissions
- ELBv2 permissions
- VPC permissions
- IAM permissions
- AWS Systems Manager access
- Git and GitHub

### Safety

- Use dedicated lab infrastructure.
- Never change production target ports for testing.
- Verify AWS account and region before provisioning.
- Use unique names and resource tags.
- Avoid committing credentials or private keys.
- Delete temporary infrastructure after finishing.

### AWS Costs

Potential charges include the Application Load Balancer, EC2 instance, EBS storage, public IPv4 address, and applicable network usage.

---

## 6. Prepare the Environment

### Step 1 — Configure Environment Variables

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="ELB-Troubleshooting-Lab05"

export VPC_CIDR="10.164.0.0/16"
export SUBNET_A_CIDR="10.164.1.0/24"
export SUBNET_B_CIDR="10.164.2.0/24"

export ALB_NAME="cloud-elb-lab05-alb"
export TG_NAME="cloud-elb-lab05-tg"

export ROLE_NAME="cloud-elb-lab05-ssm-role"
export PROFILE_NAME="cloud-elb-lab05-ssm-profile"

export APP_PORT=8080
export WRONG_PORT=9090
```

### Step 2 — Verify AWS Identity

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

Choose two supported Availability Zones:

```bash
export AZ_A="us-east-1a"
export AZ_B="us-east-1b"
```

Confirm they are supported by your AWS account.

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

For an unused ALB name, `LoadBalancerNotFound` is expected.

Do not create duplicate resources if the lab has already been started.

---

## 7. Create VPC Networking

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=cloud-elb-lab05-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")
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
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-elb-lab05-subnet-a},{Key=Project,Value=$PROJECT_TAG}]" \
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
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-elb-lab05-subnet-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Create and Attach Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cloud-elb-lab05-igw},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Create Route Table

```bash
export RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-elb-lab05-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")
```

Add the internet route:

```bash
aws ec2 create-route \
  --route-table-id "$RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Associate Both Subnets

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

### Step 8 — Verify Routes

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
10.164.0.0/16 → local
0.0.0.0/0     → Internet Gateway
```

---

## 8. Configure Security Groups

### Step 1 — Create ALB Security Group

```bash
export ALB_SG_ID=$(aws ec2 create-security-group \
  --group-name cloud-elb-lab05-alb-sg \
  --description "Lab05 ALB security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=cloud-elb-lab05-alb-sg},{Key=Project,Value=$PROJECT_TAG}]" \
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

### Step 3 — Create EC2 Security Group

```bash
export EC2_SG_ID=$(aws ec2 create-security-group \
  --group-name cloud-elb-lab05-ec2-sg \
  --description "Lab05 EC2 backend security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=cloud-elb-lab05-ec2-sg},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Allow Correct and Test Ports

Permit the real application port:

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$EC2_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

Temporarily allow the incorrect port:

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$EC2_SG_ID" \
  --protocol tcp \
  --port 9090 \
  --source-group "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

We allow port 9090 during the experiment to isolate the application port mismatch from a security group restriction.

### Step 5 — Verify Security Groups

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
| ALB SG | TCP 80 from internet |
| Backend SG | TCP 8080 and 9090 from ALB SG |

---

## 9. Configure EC2 IAM Role

### Step 1 — Create Trust Policy

Save as `ec2-trust-policy.json`:

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

### Step 2 — Check Existing IAM Resources

```bash
aws iam get-role \
  --role-name "$ROLE_NAME"

aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

A `NoSuchEntity` response is expected if these resources don't exist.

### Step 3 — Create Role and Instance Profile

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

## 10. Create the Backend Application

Create `backend-user-data.sh`:

```bash
#!/bin/bash
set -eux

mkdir -p /opt/lab05

cat > /opt/lab05/index.html <<'HTML'
AWS ELB Troubleshooting Lab 05

Application: Python HTTP Server
Application Port: 8080
Status: Healthy
HTML

cat > /opt/lab05/health <<'HEALTH'
OK
HEALTH

cat > /etc/systemd/system/lab05-web.service <<'UNIT'
[Unit]
Description=Lab 05 ALB Target Port Backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/lab05
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab05-web.service
```

### Application Behavior

| Request | Expected Result |
|---|---|
| `http://127.0.0.1:8080/` | HTTP 200 |
| `http://127.0.0.1:8080/health` | HTTP 200 |
| `http://127.0.0.1:9090/` | Connection refused |
| `http://127.0.0.1:9090/health` | Connection refused |

The application is configured to listen on port 8080 only.

---

## 11. Launch EC2 Backend

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
    "ResourceType=instance,Tags=[{Key=Name,Value=cloud-elb-lab05-backend},{Key=Project,Value=$PROJECT_TAG}]" \
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

### Step 5 — Verify SSM Registration

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Expected after registration: `Online`.

### Step 6 — Connect to EC2

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 7 — Verify Correct Application Port

Inside EC2:

```bash
sudo systemctl is-active lab05-web.service

sudo ss -lntp | grep ':8080'
```

Expected: application active and listening on port 8080.

Test:

```bash
curl --noproxy '*' -i \
  http://127.0.0.1:8080/health
```

Expected: HTTP 200.

### Step 8 — Verify Incorrect Port Is Unused

```bash
curl --noproxy '*' -v \
  --connect-timeout 3 \
  http://127.0.0.1:9090/health
```

Expected: connection refused.

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

### Step 2 — Configure Lab Deregistration Delay

```bash
aws elbv2 modify-target-group-attributes \
  --target-group-arn "$TG_ARN" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=0 \
  --region "$AWS_REGION"
```

This is for the disposable lab only. Production workloads usually require an appropriate draining period.

### Step 3 — Register Correct Target

```bash
aws elbv2 register-targets \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

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
```

### Step 5 — Wait for ALB

```bash
aws elbv2 wait load-balancer-available \
  --load-balancer-arns "$ALB_ARN" \
  --region "$AWS_REGION"
```

### Step 6 — Create HTTP Listener

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

### Step 7 — Retrieve ALB DNS

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

### Step 2 — Inspect Target Registration

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{ID:Target.Id,Port:Target.Port,State:TargetHealth.State}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Port: 8080
State: healthy
```

### Step 3 — Verify ALB HTTP Response

```bash
curl --noproxy '*' -i \
  --connect-timeout 5 \
  --max-time 15 \
  "http://${ALB_DNS}/"
```

Expected: HTTP 200 and the application page.

### Baseline Summary

| Component | Expected Result |
|---|---|
| ALB | Active |
| Target Group | HTTP 8080 |
| Registered Port | 8080 |
| Application Port | 8080 |
| Target Health | Healthy |
| EC2 | Running |
| HTTP Response | 200 |

---

## 14. Reproduce the Incorrect Target Port Failure

### Step 1 — Deregister the Healthy Target

```bash
aws elbv2 deregister-targets \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

Verify that deregistration completes:

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --output json \
  --region "$AWS_REGION"
```

Expected once fully deregistered:

```json
{
  "TargetHealthDescriptions": []
}
```

### Step 2 — Register the Wrong Port

```bash
aws elbv2 register-targets \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=9090" \
  --region "$AWS_REGION"
```

**Fault injected:** the instance is registered on TCP 9090, but the application is listening on TCP 8080.

### Step 3 — Inspect Target Health

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{ID:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}' \
  --output table \
  --region "$AWS_REGION"
```

Expected after repeated health check failures:

```text
Port: 9090
State: unhealthy
Reason: Target.FailedHealthChecks
```

The exact reason may vary.

### Step 4 — Monitor the Failure

```bash
for i in {1..12}; do
  date -u +"%Y-%m-%dT%H:%M:%SZ"

  aws elbv2 describe-target-health \
    --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[].{Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
    --output table \
    --region "$AWS_REGION"

  sleep 15
done
```

Stop the loop after the unhealthy state is confirmed.

### Step 5 — Test ALB

```bash
curl --noproxy '*' -v \
  --connect-timeout 5 \
  --max-time 20 \
  "http://${ALB_DNS}/"
```

Expected: the application request fails, potentially with HTTP 502 because the connection to port 9090 is refused.

The precise client error is not the primary evidence. ALBs may fail open when all registered targets are unhealthy.

### Failure Summary

| Component | Expected Finding |
|---|---|
| EC2 | Running |
| Application | Active |
| Target Group Default Port | 8080 |
| Registered Target Port | 9090 |
| Health Check Port | 9090 |
| Application Listener | 8080 |
| Port 9090 | Not listening |
| Target Health | Unhealthy |
| Root Cause | Incorrect target registration |

---

## 15. Troubleshooting Investigation

### Check 1 — Inspect ALB

```bash
aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].{Name:LoadBalancerName,State:State.Code,DNS:DNSName}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: ALB is active.

### Check 2 — Inspect Target Group

```bash
aws elbv2 describe-target-groups \
  --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[].{Name:TargetGroupName,DefaultPort:Port,Protocol:Protocol,HealthPort:HealthCheckPort,HealthPath:HealthCheckPath}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
DefaultPort: 8080
HealthPort: traffic-port
HealthPath: /health
```

### Check 3 — Inspect Actual Target Port

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,RegisteredPort:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
RegisteredPort: 9090
State: unhealthy
```

Finding: registered target port does not match the application.

### Check 4 — Verify EC2 Health

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{Instance:InstanceStatus.Status,System:SystemStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

Finding: EC2 infrastructure is healthy.

### Check 5 — Verify Listener

```bash
aws elbv2 describe-listeners \
  --load-balancer-arn "$ALB_ARN" \
  --query 'Listeners[].{Port:Port,Protocol:Protocol,Actions:DefaultActions}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: the listener forwards to the intended target group.

### Check 6 — Verify Security Groups

```bash
aws ec2 describe-security-groups \
  --group-ids "$ALB_SG_ID" "$EC2_SG_ID" \
  --query 'SecurityGroups[].{Name:GroupName,Inbound:IpPermissions}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: the test security group allows connections on ports 8080 and 9090 from the ALB.

### Check 7 — Inspect Backend Listening Ports

Connect:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
sudo systemctl is-active lab05-web.service

sudo ss -lntp | grep -E ':(8080|9090)\b'
```

Expected: application is active and only port 8080 is listening.

Test the working port:

```bash
curl --noproxy '*' -i \
  http://127.0.0.1:8080/health
```

Expected: HTTP 200.

Test the incorrect port:

```bash
curl --noproxy '*' -v \
  --connect-timeout 3 \
  http://127.0.0.1:9090/health
```

Expected: connection refused.

Exit Session Manager.

### Investigation Summary

| Component | Finding |
|---|---|
| ALB | Active |
| Listener | Correct |
| Target Group Default Port | 8080 |
| Registered Target Port | 9090 |
| Health Check Port | `traffic-port` |
| EC2 | Running |
| Backend Application | Running |
| Listening TCP Port | 8080 |
| TCP Port 9090 | No listener |
| Security Group | Allows test traffic |
| Target Health | Unhealthy |
| Root Cause | Wrong registered port |

---

## 16. Root Cause Analysis

### Root Cause

The EC2 backend was registered with the ALB target group on port 9090, while the Python HTTP application listened on port 8080.

### Technical Explanation

The target group was configured with a default port of 8080.

However, the EC2 target was explicitly registered with a port override of 9090.

The health check configuration used `traffic-port`, which caused the ALB to perform health checks on port 9090.

No process was listening on that port.

The health checks failed, and the target became unhealthy.

### Root Cause Flow

```text
Application Listening on 8080
              |
              v
EC2 Registered on Port 9090
              |
              v
ALB Health Check Uses 9090
              |
              v
No Application Listener
              |
              v
Connection Failure
              |
              v
Target Becomes Unhealthy
```

### Five Whys

1. **Why was the target unhealthy?** The ALB health checks failed.
2. **Why did the health checks fail?** They used a port where no application was listening.
3. **Why was the ALB checking port 9090?** The target was registered with a port override.
4. **Why didn't the target group's default port 8080 prevent this?** Explicit target registration overrode the default port.
5. **How can this be prevented?** Verify backend listening ports, automate target registration, and validate application connectivity after deployments.

---

## 17. Remediation

### Step 1 — Deregister Incorrect Target Port

```bash
aws elbv2 deregister-targets \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=9090" \
  --region "$AWS_REGION"
```

### Step 2 — Verify Deregistration

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --output json \
  --region "$AWS_REGION"
```

Once complete, the target group should be empty.

### Step 3 — Register Correct Target Port

```bash
aws elbv2 register-targets \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

### Step 4 — Wait for Target Recovery

```bash
aws elbv2 wait target-in-service \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

### Step 5 — Verify Target Health

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{ID:Target.Id,Port:Target.Port,State:TargetHealth.State}' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
Port: 8080
State: healthy
```

### Step 6 — Verify ALB HTTP 200

```bash
curl --noproxy '*' -i \
  --connect-timeout 5 \
  --max-time 15 \
  "http://${ALB_DNS}/"
```

Expected: HTTP 200 and the Lab 05 application page.

### Step 7 — Verify Multiple Requests

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

### Step 8 — Remove Unnecessary Security Group Rule

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$EC2_SG_ID" \
  --protocol tcp \
  --port 9090 \
  --source-group "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

This restores the intended backend security group configuration.

### Verification Matrix

| Check | Healthy Baseline | During Failure | After Fix |
|---|---|---|---|
| ALB | Active | Active | Active |
| EC2 | Running | Running | Running |
| Application Service | Active | Active | Active |
| Target Group Default Port | 8080 | 8080 | 8080 |
| Registered Target Port | 8080 | 9090 | 8080 |
| Application Port | 8080 | 8080 | 8080 |
| Target Health | Healthy | Unhealthy | Healthy |
| ALB Application Request | 200 | Failure | 200 |
| Incorrect SG Rule | Present for testing | Present for testing | Removed |

### Success Criteria

- ALB target initially healthy.
- Application responds on port 8080.
- Target intentionally registered on port 9090.
- Health checks fail.
- Incorrect target port identified.
- Target registration corrected.
- Target returns to healthy.
- ALB returns HTTP 200.
- Unnecessary security group rule removed.

---

## 18. Production Best Practices

### ALB Target Port Troubleshooting Checklist

1. Verify ALB status.
2. Check listener forwarding.
3. Identify the selected target group.
4. Check target group default protocol and port.
5. Inspect the actual registered target port.
6. Review health check port configuration.
7. Verify the EC2 instance is running.
8. Check backend application status.
9. Identify the application's listening TCP port.
10. Test the health endpoint directly.
11. Inspect security group rules.
12. Correct target registration.
13. Verify target health.
14. Test HTTP requests through the ALB.

### Common Port Misconfiguration Problems

| Problem | Possible Effect | Remediation |
|---|---|---|
| Wrong registered target port | Unhealthy target | Register correct port |
| Application listening on another port | Connection failure | Align application and target port |
| Backend SG blocks target port | Health check failures | Allow required ALB traffic |
| Wrong health check port | Target unhealthy | Correct health check configuration |
| Wrong protocol | HTTP or TLS connection problems | Match target group to application |
| Application not listening | Connection refused | Start or repair application |
| Incorrect container port mapping | Backend unreachable | Correct service and port mapping |

### Prevention

- Use Terraform or CloudFormation for target groups.
- Keep application ports documented.
- Validate ports before deployment.
- Use automated health checks.
- Confirm registered target ports after changes.
- Configure suitable CloudWatch alarms.
- Use multiple healthy targets in production.
- Restrict backend security group rules.
- Avoid unnecessary port overrides.
- Test application availability after deployments.

### Security Considerations

- Do not open all backend ports to troubleshoot a single issue.
- Restrict backend access to the ALB security group.
- Remove temporary security group rules after testing.
- Use least-privilege IAM permissions.
- Monitor configuration changes.
- Protect credentials and application logs.

---

## 19. Cleanup

**Warning:** Verify AWS account identity, resource IDs, and project tags before performing destructive operations.

Only delete resources belonging to `ELB-Troubleshooting-Lab05`.

### Step 1 — Verify Resource Ownership

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

### Step 4 — Deregister Target

```bash
aws elbv2 deregister-targets \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

Verify deregistration.

### Step 5 — Delete Target Group

```bash
aws elbv2 delete-target-group \
  --target-group-arn "$TG_ARN" \
  --region "$AWS_REGION"
```

### Step 6 — Verify Root EBS Volume

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the root volume has `DeleteOnTermination=true`.

### Step 7 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Remove Security Group Dependencies

If the test port 9090 rule was not removed during remediation, remove it now:

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$EC2_SG_ID" \
  --protocol tcp \
  --port 9090 \
  --source-group "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

Skip this command if the rule has already been removed.

Remove the port 8080 rule:

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$EC2_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

Check ENIs:

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Wait until the ALB and EC2 network interfaces are removed.

### Step 9 — Delete Security Groups

```bash
aws ec2 delete-security-group \
  --group-id "$EC2_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

### Step 10 — Delete IAM Resources

Verify role ownership and instance profile usage:

```bash
aws iam list-role-tags \
  --role-name "$ROLE_NAME"

aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

Delete the role and profile:

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

### Step 11 — Delete Route Table Associations

```bash
aws ec2 disassociate-route-table \
  --association-id "$RT_ASSOC_A" \
  --region "$AWS_REGION"

aws ec2 disassociate-route-table \
  --association-id "$RT_ASSOC_B" \
  --region "$AWS_REGION"
```

### Step 12 — Delete Custom Route Table

```bash
aws ec2 delete-route-table \
  --route-table-id "$RT_ID" \
  --region "$AWS_REGION"
```

### Step 13 — Delete Subnets

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_A_ID" \
  --region "$AWS_REGION"

aws ec2 delete-subnet \
  --subnet-id "$SUBNET_B_ID" \
  --region "$AWS_REGION"
```

### Step 14 — Delete Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 15 — Delete VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 16 — Verify Cleanup

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

Also confirm the target group, EBS root volume, IAM resources, and dedicated VPC have been removed.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| ALB Listener | Deleted |
| Application Load Balancer | Deleted |
| Target Group | Deleted |
| EC2 Instance | Terminated |
| Root EBS Volume | Deleted |
| ALB Security Group | Deleted |
| Backend Security Group | Deleted |
| IAM Role | Deleted |
| Instance Profile | Deleted |
| Custom Route Table | Deleted |
| Subnet A | Deleted |
| Subnet B | Deleted |
| Internet Gateway | Deleted |
| Lab VPC | Deleted |
| Default VPC | Unchanged |

---

## 20. Interview Questions and Answers

### Q1. What happens when an ALB target uses an incorrect port?

The ALB attempts to connect to the registered port. If no application is listening, health checks and forwarded requests can fail.

### Q2. Can the target group's default port differ from the registered target port?

Yes. An explicit target port can override the default target group port.

### Q3. What does `traffic-port` mean?

It means health checks use the port registered for the target.

### Q4. What command displays the target's registered port?

`aws elbv2 describe-target-health`.

### Q5. How do you identify an application's listening port on Linux?

Use `sudo ss -lntp`.

### Q6. What target health reason code might appear?

`Target.FailedHealthChecks` or `Target.Timeout`, depending on the observed failure.

### Q7. Can EC2 remain healthy while the ALB target is unhealthy?

Yes. EC2 infrastructure checks do not verify that the ALB can reach the application.

### Q8. Does opening all backend security group ports fix this issue?

No. The registered target port must match the actual application listener.

### Q9. Is changing the target group default port always enough?

No. Existing targets can have explicit port overrides that must be corrected.

### Q10. Does an unhealthy target always cause an ALB 503 error?

No. ALBs can fail open and forward traffic to unhealthy registered targets.

### Q11. How can the issue be prevented?

Use infrastructure as code, validate application ports, monitor target health, and review configuration changes.

### Q12. How would you explain this lab in an interview?

I deployed an AWS Application Load Balancer with an EC2 backend running a Python HTTP server on port 8080.

After confirming that the target was healthy, I intentionally deregistered the instance and registered it again on port 9090.

The ALB health checks failed because the application was not listening on port 9090.

I inspected the target group's default port, the actual registered port, security group rules, EC2 status, and Linux listening sockets.

I identified the incorrect registered port as the root cause.

After registering the instance on port 8080 and removing the unnecessary security group rule, I verified that the target became healthy and the ALB returned HTTP 200.

---

## 21. Repository Structure

```text
05-incorrect-target-port/
├── README.md
├── ec2-trust-policy.json
└── backend-user-data.sh
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete incident documentation |
| `ec2-trust-policy.json` | IAM trust policy for EC2 Systems Manager access |
| `backend-user-data.sh` | Installs and starts the Python backend on port 8080 |

Do not commit AWS credentials, private keys, or sensitive application information.

---

## 22. Lessons Learned

This lab demonstrates how an incorrect registered target port can cause ALB health checks to fail even when the backend application is running normally.

The target group had a default port of 8080, but the EC2 instance was registered with an explicit port override of 9090.

Because the application listened on port 8080 only, the ALB could not successfully connect to the registered target.

The most important troubleshooting step was comparing the actual registered port with the backend application's listening port.

Correcting the registration restored target health and successful HTTP requests.

We also removed the unnecessary port 9090 security group permission to maintain least-privilege network access.

**Key Lesson:** Always verify both the target group's default port and the target's actual registered port. A correct target group configuration does not guarantee that every target registration is correct.

---

## 23. Skills Demonstrated

- Application Load Balancer troubleshooting
- Target group configuration
- Target port override investigation
- ALB health checks
- EC2 application diagnostics
- Linux listening port inspection
- AWS CLI v2
- Systems Manager
- VPC networking
- Security group troubleshooting
- Fault injection
- Root cause analysis
- Least-privilege remediation
- Application verification
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-ELB-005 |
| Problem | Incorrect ALB target port |
| Root Cause | EC2 registered on 9090 instead of 8080 |
| EC2 | Running |
| Application | Active |
| Target Group Default Port | 8080 |
| Faulty Registered Port | 9090 |
| Target Health During Fault | Unhealthy |
| Remediation | Register EC2 on port 8080 |
| Final Target Health | Healthy |
| Final HTTP Response | 200 |
| Unnecessary SG Rule | Removed |
| Cleanup | Temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** Incorrect ALB target registration can cause unhealthy targets and application failures without an EC2 outage. Comparing the target registration, health check port, and actual application listener is essential for identifying the root cause.
