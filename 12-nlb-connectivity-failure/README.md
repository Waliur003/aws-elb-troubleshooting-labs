# Lab 12 — NLB Connectivity Failure

## Overview

This lab demonstrates how to troubleshoot an AWS Network Load Balancer (NLB) that cannot communicate with its registered EC2 backend because of an incorrect security group configuration.

We deploy an internet-facing NLB with a TCP listener on port 80 and an Amazon EC2 instance running a Python HTTP application on port 8080.

Initially, the NLB forwards TCP connections successfully, the EC2 target is healthy, and HTTP requests return 200 OK.

We then intentionally remove the inbound TCP 8080 rule from the EC2 security group.

As a result, the NLB cannot establish new TCP connections to the backend. The target fails health checks and becomes unhealthy.

We investigate the NLB listener, target group registration, target health status, security group permissions, EC2 status, and application connectivity.

After identifying the missing security group rule, we restore the required permission and verify that the target becomes healthy and application requests succeed.

**Troubleshooting workflow:**

Provision → Healthy Baseline → Fault Injection → Investigation → Root Cause Analysis → Remediation → Verification → Cleanup

---

## 1. Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-ELB-012 |
| Difficulty | Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | NLB, EC2, VPC, IAM, Systems Manager, CloudWatch |
| Load Balancer Type | Network Load Balancer |
| NLB Scheme | Internet-facing |
| Listener Protocol | TCP |
| Listener Port | 80 |
| Target Group Protocol | TCP |
| Target Group Port | 8080 |
| Target Type | Instance |
| EC2 OS | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Backend Application | Python HTTP Server |
| Health Check Protocol | TCP |
| Health Check Port | 8080 |
| VPC CIDR | `10.171.0.0/16` |
| Fault Injection | Remove backend SG ingress rule |
| Expected Target Health | Unhealthy |
| Possible Client Error | Connection timeout or reset |
| Root Cause | Backend security group blocks NLB |
| Remediation | Restore TCP 8080 from NLB SG |
| Expected Final Result | Healthy target and HTTP 200 |

---

## 2. Production Incident Scenario

### Incident Description

A company runs a web application on an Amazon EC2 instance behind an AWS Network Load Balancer.

The NLB accepts TCP connections on port 80 and forwards them to the application on port 8080.

The EC2 instance is registered with a target group, and the NLB performs TCP health checks.

During a network security update, an engineer accidentally removes the backend security group rule that allows traffic from the NLB.

The NLB remains active, and the EC2 instance continues running.

However, the NLB cannot establish new connections to the backend application.

Health checks begin failing, and the registered target becomes unhealthy.

Customers experience connection timeouts, connection resets, or other TCP connectivity failures.

### Incident Symptoms

- NLB remains active.
- TCP listener remains configured on port 80.
- EC2 instance remains running.
- Backend Python application remains active.
- Application listens on TCP port 8080.
- Local application requests return HTTP 200.
- EC2 target remains registered.
- TCP health checks fail.
- Target becomes unhealthy.
- Client requests through the NLB fail.
- Backend security group has no matching TCP 8080 inbound rule.

### Potential Business Impact

- Customer connectivity failures.
- Application downtime.
- Failed TCP connections.
- API connection errors.
- Increased retries and request latency.
- Unhealthy backend alerts.
- Reduced service reliability.

### Objective

Identify the blocked TCP connection between the NLB and EC2, restore least-privilege network access, and verify successful application connectivity.

---

## 3. AWS Architecture

### Healthy Architecture

```text
                     Internet Client
                            |
                            | TCP 80
                            v
                  +----------------------+
                  | NLB Security Group   |
                  | Allow TCP 80         |
                  +----------+-----------+
                             |
                             v
                  +----------------------+
                  | Network Load         |
                  | Balancer             |
                  | TCP Listener: 80     |
                  +----------+-----------+
                             |
                             | TCP 8080
                             v
                  +----------------------+
                  | Target Group         |
                  | Protocol: TCP        |
                  | Port: 8080           |
                  | Target: Healthy      |
                  +----------+-----------+
                             |
                             v
                  +----------------------+
                  | EC2 Security Group   |
                  | Allow TCP 8080       |
                  | Source: NLB SG       |
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
```

### Broken Architecture

```text
                     Internet Client
                            |
                            v
                  Network Load Balancer
                       TCP Port 80
                            |
                            v
                       Target Group
                       TCP Port 8080
                            |
                            v
                   EC2 Security Group
                            |
                            X
                     TCP 8080 Blocked
                            |
                            v
                    Health Check Fails
                            |
                            v
                     Target Unhealthy


                 EC2 Application Still Running
```

### Infrastructure Configuration

| Resource | Configuration |
|---|---|
| VPC | `10.171.0.0/16` |
| Public Subnet A | `10.171.1.0/24` |
| Public Subnet B | `10.171.2.0/24` |
| Internet Gateway | Attached |
| Public Route | `0.0.0.0/0` through IGW |
| NLB Security Group | TCP 80 from internet |
| EC2 Security Group | TCP 8080 from NLB SG |
| NLB Listener | TCP 80 |
| Target Group | TCP 8080 |
| Health Check | TCP 8080 |

---

## 4. Understanding Network Load Balancers

A Network Load Balancer primarily operates at Layer 4 of the OSI model.

It distributes connections using transport-layer information such as IP addresses, ports, and protocols.

Unlike an Application Load Balancer, an NLB does not provide HTTP path-based routing for ordinary TCP listeners.

### ALB vs. NLB

| Feature | Application Load Balancer | Network Load Balancer |
|---|---|---|
| OSI Layer | Layer 7 | Layer 4 |
| HTTP Path Routing | Yes | No |
| Host-Based Routing | Yes | No |
| TCP Listeners | No | Yes |
| UDP Listeners | No | Yes |
| HTTP-Aware Routing | Yes | No |
| TCP Health Checks | No | Yes |
| Typical Use | Web applications and APIs | TCP services and low-latency workloads |

An NLB can forward HTTP traffic, but with a TCP listener it does not inspect HTTP paths or generate ordinary ALB-style HTTP gateway responses.

### NLB Target Health

A TCP health check attempts to establish a connection to the configured target port.

In this lab:

```text
Health Check Protocol: TCP
Health Check Port: 8080
```

If the security group blocks the connection, the health check fails.

The target may report:

```text
State: unhealthy
Reason: Target.FailedHealthChecks
```

### NLB Fail-Open Behavior

If every registered target becomes unhealthy, an NLB can enter fail-open behavior and continue forwarding traffic to unhealthy registered targets.

Fail-open does not fix a blocked security group rule.

The NLB may continue attempting connections even though the backend is unreachable.

### Security Group Considerations

This lab creates the NLB with an associated security group.

The backend EC2 security group references the NLB security group as its source.

This provides a controlled way to permit connections from the load balancer without exposing the application port to the internet.

---

## 5. Prerequisites and Safety

### Requirements

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- curl
- netcat
- EC2 permissions
- VPC permissions
- ELBv2 permissions
- IAM permissions
- Systems Manager access
- CloudWatch read permissions
- Git and GitHub

### Safety Requirements

- Use dedicated lab infrastructure.
- Never remove production security group permissions for testing.
- Restrict application ingress to the NLB security group.
- Verify AWS account identity before provisioning.
- Use project tags to identify resources.
- Do not commit credentials or private keys.
- Clean up all temporary AWS resources.

### Cost Considerations

Resources that may incur charges include the NLB, EC2 instance, EBS storage, public IPv4 addresses, and applicable data transfer.

---

## 6. Prepare the Environment

### Step 1 — Configure Variables

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="ELB-Troubleshooting-Lab12"

export VPC_CIDR="10.171.0.0/16"
export SUBNET_A_CIDR="10.171.1.0/24"
export SUBNET_B_CIDR="10.171.2.0/24"

export NLB_NAME="cloud-elb-lab12-nlb"
export TG_NAME="cloud-elb-lab12-tg"

export ROLE_NAME="cloud-elb-lab12-ssm-role"
export PROFILE_NAME="cloud-elb-lab12-ssm-profile"
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

Select two supported zones:

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
  --names "$NLB_NAME" \
  --region "$AWS_REGION"
```

A `LoadBalancerNotFound` response is expected for a new NLB.

Avoid creating duplicate infrastructure.

---

## 7. Create VPC Networking

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=cloud-elb-lab12-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
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

### Step 2 — Create Public Subnets

```bash
export SUBNET_A_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_A_CIDR" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-elb-lab12-subnet-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")

export SUBNET_B_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_B_CIDR" \
  --availability-zone "$AZ_B" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-elb-lab12-subnet-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cloud-elb-lab12-igw},{Key=Project,Value=$PROJECT_TAG}]" \
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
  "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-elb-lab12-rt},{Key=Project,Value=$PROJECT_TAG}]" \
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

### Step 6 — Verify Routing

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected routes:

```text
10.171.0.0/16 → local
0.0.0.0/0     → Internet Gateway
```

---

## 8. Configure Security Groups

### Step 1 — Create NLB Security Group

```bash
export NLB_SG_ID=$(aws ec2 create-security-group \
  --group-name cloud-elb-lab12-nlb-sg \
  --description "Lab12 NLB security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=cloud-elb-lab12-nlb-sg},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")

aws ec2 authorize-security-group-ingress \
  --group-id "$NLB_SG_ID" \
  --protocol tcp \
  --port 80 \
  --cidr "0.0.0.0/0" \
  --region "$AWS_REGION"
```

### Step 2 — Create EC2 Security Group

```bash
export EC2_SG_ID=$(aws ec2 create-security-group \
  --group-name cloud-elb-lab12-ec2-sg \
  --description "Lab12 backend security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=cloud-elb-lab12-ec2-sg},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")

aws ec2 authorize-security-group-ingress \
  --group-id "$EC2_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$NLB_SG_ID" \
  --region "$AWS_REGION"
```

### Step 3 — Verify Security Groups

```bash
aws ec2 describe-security-groups \
  --group-ids "$NLB_SG_ID" "$EC2_SG_ID" \
  --query 'SecurityGroups[].{Name:GroupName,Inbound:IpPermissions,Outbound:IpPermissionsEgress}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

| Security Group | Inbound |
|---|---|
| NLB SG | TCP 80 from internet |
| EC2 SG | TCP 8080 from NLB SG |

Default outbound permissions remain enabled for this lab.

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

Verify that the role and instance profile names are unused before creating them.

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

## 10. Deploy the Python Backend

Create `backend-user-data.sh`:

```bash
#!/bin/bash
set -eux

mkdir -p /opt/lab12

cat > /opt/lab12/index.html <<'HTML'
AWS ELB Troubleshooting Lab 12

Application: Network Load Balancer Connectivity
Backend Port: 8080
Status: Healthy
HTML

cat > /opt/lab12/health <<'HEALTH'
OK
HEALTH

cat > /etc/systemd/system/lab12-web.service <<'UNIT'
[Unit]
Description=Lab12 NLB Backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/lab12
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab12-web.service
```

### Backend Endpoints

| Endpoint | Expected Response |
|---|---|
| `/` | HTTP 200 |
| `/health` | HTTP 200 |
| Unknown Path | HTTP 404 |

The NLB uses TCP health checks, so it verifies port connectivity rather than sending HTTP requests to `/health`.

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

### Step 2 — Launch Backend

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
  "ResourceType=instance,Tags=[{Key=Name,Value=cloud-elb-lab12-backend},{Key=Project,Value=$PROJECT_TAG}]" \
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

### Step 4 — Verify Application

Check SSM registration:

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
sudo systemctl is-active lab12-web.service

sudo ss -lntp | grep ':8080'

curl --noproxy '*' -i \
  http://127.0.0.1:8080/

curl --noproxy '*' -i \
  http://127.0.0.1:8080/health
```

Expected: active service, listening port 8080, and HTTP 200 responses.

Exit Session Manager.

---

## 12. Create Target Group and NLB

### Step 1 — Create TCP Target Group

```bash
export TG_ARN=$(aws elbv2 create-target-group \
  --name "$TG_NAME" \
  --protocol TCP \
  --port 8080 \
  --vpc-id "$VPC_ID" \
  --target-type instance \
  --health-check-protocol TCP \
  --health-check-port traffic-port \
  --health-check-interval-seconds 10 \
  --healthy-threshold-count 3 \
  --unhealthy-threshold-count 3 \
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

### Step 3 — Create NLB

```bash
export NLB_ARN=$(aws elbv2 create-load-balancer \
  --name "$NLB_NAME" \
  --type network \
  --scheme internet-facing \
  --ip-address-type ipv4 \
  --subnets "$SUBNET_A_ID" "$SUBNET_B_ID" \
  --security-groups "$NLB_SG_ID" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text \
  --region "$AWS_REGION")
```

The NLB security group is attached during creation.

### Step 4 — Wait for NLB

```bash
aws elbv2 wait load-balancer-available \
  --load-balancer-arns "$NLB_ARN" \
  --region "$AWS_REGION"
```

### Step 5 — Create TCP Listener

```bash
export LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$NLB_ARN" \
  --protocol TCP \
  --port 80 \
  --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
  --query 'Listeners[0].ListenerArn' \
  --output text \
  --region "$AWS_REGION")
```

### Step 6 — Retrieve NLB DNS

```bash
export NLB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$NLB_ARN" \
  --query 'LoadBalancers[0].DNSName' \
  --output text \
  --region "$AWS_REGION")

echo "$NLB_DNS"
```

---

## 13. Establish Healthy Baseline

### Step 1 — Verify Target Health

```bash
aws elbv2 wait target-in-service \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"

aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{Instance:Target.Id,Port:Target.Port,State:TargetHealth.State}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `healthy`.

### Step 2 — Verify TCP Connectivity

```bash
nc -vz -w 5 "$NLB_DNS" 80
```

Expected: TCP connection succeeds.

### Step 3 — Verify HTTP Request

```bash
curl --noproxy '*' -i \
  --connect-timeout 5 \
  --max-time 15 \
  "http://${NLB_DNS}/"
```

Expected: HTTP 200.

### Step 4 — Verify Health Endpoint

```bash
curl --noproxy '*' -i \
  "http://${NLB_DNS}/health"
```

Expected: HTTP 200.

### Baseline Summary

| Component | Expected Result |
|---|---|
| NLB | Active |
| Listener | TCP 80 |
| Target Group | TCP 8080 |
| EC2 | Running |
| Application | Active |
| Target Health | Healthy |
| Backend SG | Allows NLB SG |
| Client TCP Connection | Successful |
| HTTP Response | 200 |

---

## 14. Fault Injection — Block Backend TCP Connections

### Step 1 — Remove Inbound TCP 8080 Permission

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$EC2_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$NLB_SG_ID" \
  --region "$AWS_REGION"
```

This intentionally blocks new NLB-to-EC2 connections.

### Step 2 — Verify the Security Group

```bash
aws ec2 describe-security-groups \
  --group-ids "$EC2_SG_ID" \
  --query 'SecurityGroups[0].IpPermissions' \
  --output json \
  --region "$AWS_REGION"
```

Expected, if no other inbound rules exist:

```json
[]
```

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
Reason: Target.FailedHealthChecks
```

### Step 4 — Test TCP Connectivity

```bash
nc -vz -w 5 "$NLB_DNS" 80
```

A timeout or other connection failure may occur.

A TCP connection probe alone is not always conclusive because an NLB can accept or forward a connection attempt even when the backend cannot process traffic.

### Step 5 — Test HTTP Through the NLB

```bash
curl --noproxy '*' -v \
  --connect-timeout 5 \
  --max-time 15 \
  "http://${NLB_DNS}/"
```

Possible symptoms:

```text
Connection timed out
```

or:

```text
Connection reset by peer
```

or:

```text
curl: (28) Operation timed out
```

The exact result depends on TCP connection behavior.

### Why Not HTTP 503 or 504?

A Network Load Balancer operating with a TCP listener does not normally generate HTTP gateway responses.

Unlike an ALB, it forwards transport-layer connections rather than interpreting HTTP requests.

### Fault Summary

| Component | Finding |
|---|---|
| NLB | Active |
| TCP Listener | 80 |
| Target Group | TCP 8080 |
| Registered Target | Present |
| Target Health | Unhealthy |
| EC2 | Running |
| Application | Active locally |
| Backend SG TCP 8080 | Blocked |
| Client Connection | Fails or times out |
| Root Cause | Missing backend SG inbound permission |

---

## 15. Troubleshooting Investigation

### Check 1 — Verify NLB Status

```bash
aws elbv2 describe-load-balancers \
  --load-balancer-arns "$NLB_ARN" \
  --query 'LoadBalancers[0].{Name:LoadBalancerName,Type:Type,State:State.Code,SecurityGroups:SecurityGroups}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: NLB is active.

### Check 2 — Inspect TCP Listener

```bash
aws elbv2 describe-listeners \
  --listener-arns "$LISTENER_ARN" \
  --query 'Listeners[].{Protocol:Protocol,Port:Port,Actions:DefaultActions}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: TCP listener forwards to the expected target group.

### Check 3 — Inspect Target Group

```bash
aws elbv2 describe-target-groups \
  --target-group-arns "$TG_ARN" \
  --query 'TargetGroups[].{Name:TargetGroupName,Protocol:Protocol,Port:Port,HealthProtocol:HealthCheckProtocol,HealthPort:HealthCheckPort}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: TCP 8080 with TCP health checks.

### Check 4 — Inspect Registered Target

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --output json \
  --region "$AWS_REGION"
```

Finding: target is registered but unhealthy.

### Check 5 — Inspect Security Groups

```bash
aws ec2 describe-security-groups \
  --group-ids "$NLB_SG_ID" "$EC2_SG_ID" \
  --query 'SecurityGroups[].{Name:GroupName,Ingress:IpPermissions,Egress:IpPermissionsEgress}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: the backend security group has no rule allowing TCP 8080 from the NLB security group.

### Check 6 — Verify EC2 Infrastructure

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name,PrivateIP:PrivateIpAddress}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `running`.

Check infrastructure status:

```bash
aws ec2 describe-instance-status \
  --instance-ids "$INSTANCE_ID" \
  --query 'InstanceStatuses[].{System:SystemStatus.Status,Instance:InstanceStatus.Status}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: both checks `ok`.

### Check 7 — Verify Application Locally

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
sudo systemctl is-active lab12-web.service

sudo ss -lntp | grep ':8080'

curl --noproxy '*' -i \
  http://127.0.0.1:8080/health
```

Expected: service active and HTTP 200.

Exit Session Manager.

### Check 8 — Inspect CloudWatch NLB Metrics

Set the correct metric dimensions:

```bash
export NLB_DIMENSION="${NLB_ARN#*loadbalancer/}"

export TG_DIMENSION="targetgroup/${TG_ARN#*targetgroup/}"
```

Query unhealthy host count:

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/NetworkELB \
  --metric-name UnHealthyHostCount \
  --dimensions \
    "Name=LoadBalancer,Value=$NLB_DIMENSION" \
    "Name=TargetGroup,Value=$TG_DIMENSION" \
  --statistics Maximum \
  --period 60 \
  --start-time "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --region "$AWS_REGION"
```

Expected after metrics appear: unhealthy host count increases.

Additional useful NLB metrics:

```text
HealthyHostCount
UnHealthyHostCount
TCP_ELB_Reset_Count
TCP_Target_Reset_Count
```

### Investigation Summary

| Component | Finding |
|---|---|
| NLB | Active |
| Listener | Correct |
| Target Group | Correct |
| Target Registration | Correct |
| Target Health | Unhealthy |
| EC2 | Running |
| Local Application | HTTP 200 |
| NLB SG | Correct |
| EC2 SG | Missing TCP 8080 rule |
| Root Cause | Backend connectivity blocked |

---

## 16. Root Cause Analysis

### Root Cause

The EC2 security group did not permit inbound TCP connections on port 8080 from the NLB security group.

As a result, the NLB could not establish connections to the application backend.

TCP health checks failed, and the registered target became unhealthy.

The EC2 instance and application continued working normally.

### Technical Explanation

The client attempts to connect to the NLB on TCP port 80.

The NLB selects the registered target and forwards the connection to EC2 port 8080.

However, the EC2 security group has no matching inbound permission.

The connection is blocked before reaching the application.

### Root Cause Flow

```text
Client → NLB:80
          |
          v
     TCP Listener
          |
          v
     Target Group
          |
          v
      EC2:8080
          |
          X
  Backend SG Blocks
          |
          v
    TCP Health Fails
          |
          v
   Target Unhealthy
```

### Five Whys

1. **Why did clients lose connectivity?** The NLB could not communicate with the backend.
2. **Why was the backend unreachable?** The EC2 security group blocked port 8080.
3. **Why was the port blocked?** The inbound rule referencing the NLB security group was removed.
4. **Why was the EC2 instance still healthy?** EC2 infrastructure health does not prove NLB network connectivity.
5. **How can the problem be prevented?** Use infrastructure as code, change reviews, least-privilege rules, and target health monitoring.

---

## 17. Remediation and Verification

### Step 1 — Restore TCP 8080 Permission

```bash
aws ec2 authorize-security-group-ingress \
  --group-id "$EC2_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$NLB_SG_ID" \
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

Expected: TCP 8080 allowed from the NLB security group.

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
  --query 'TargetHealthDescriptions[].{Instance:Target.Id,State:TargetHealth.State}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `healthy`.

### Step 5 — Verify TCP Connection

```bash
nc -vz -w 5 "$NLB_DNS" 80
```

Expected: TCP connection successful.

### Step 6 — Verify Application Response

```bash
curl --noproxy '*' -i \
  --connect-timeout 5 \
  --max-time 15 \
  "http://${NLB_DNS}/"
```

Expected: HTTP 200.

### Step 7 — Verify Multiple Requests

```bash
for i in {1..5}; do
  curl --noproxy '*' -sS \
    -o /dev/null \
    -w "Request $i: HTTP %{http_code}\n" \
    --connect-timeout 5 \
    --max-time 15 \
    "http://${NLB_DNS}/"
done
```

Expected: all five requests return HTTP 200.

### Verification Matrix

| Check | Baseline | During Fault | After Fix |
|---|---|---|---|
| NLB | Active | Active | Active |
| TCP Listener | 80 | 80 | 80 |
| Target Group | TCP 8080 | TCP 8080 | TCP 8080 |
| EC2 | Running | Running | Running |
| Application | Active | Active | Active |
| Backend SG TCP 8080 | Allowed | Blocked | Allowed |
| Target Health | Healthy | Unhealthy | Healthy |
| Client Request | HTTP 200 | Connection Failure | HTTP 200 |

### Success Criteria

- NLB deployed successfully.
- TCP listener configured.
- EC2 target registered.
- Healthy baseline established.
- Backend security group rule removed.
- Target becomes unhealthy.
- Client connection failure reproduced.
- Application confirmed working locally.
- Missing security group permission identified.
- TCP 8080 permission restored.
- Target returns to healthy.
- HTTP 200 restored.
- Temporary resources removed.

---

## 18. Production Best Practices

### NLB Troubleshooting Checklist

1. Verify NLB status.
2. Inspect listener protocol and port.
3. Identify the target group.
4. Verify registered targets.
5. Check target health status.
6. Inspect health check protocol.
7. Verify the backend listening port.
8. Inspect NLB security group rules.
9. Inspect backend security group rules.
10. Review network ACLs.
11. Verify subnet routes.
12. Test backend application locally.
13. Review CloudWatch metrics.
14. Restore the required network permissions.
15. Verify successful TCP connections.

### Common NLB Connectivity Problems

| Problem | Possible Symptom | Remediation |
|---|---|---|
| NLB inbound port blocked | Client cannot connect | Correct NLB SG |
| Backend port blocked | Target unhealthy | Correct EC2 SG |
| Incorrect target registration | Backend unreachable | Register correct target |
| Wrong target port | TCP connection failure | Correct target port |
| Application not listening | Failed health checks | Start or repair service |
| Network ACL blocks traffic | TCP timeout | Correct NACL rules |
| Incorrect routing | Network unreachable | Correct route tables |
| All targets unhealthy | Fail-open behavior | Resolve backend health issues |

### Prevention

- Use Terraform or CloudFormation.
- Apply least-privilege security groups.
- Reference the NLB security group in backend rules.
- Review infrastructure changes through pull requests.
- Monitor target health.
- Configure CloudWatch alarms.
- Use multiple healthy targets for production availability.
- Test TCP connectivity after deployments.
- Maintain documentation of application ports.
- Avoid manual security group modifications in production.

### Security Considerations

- Do not expose backend TCP 8080 publicly.
- Restrict application ingress to the NLB security group.
- Use encrypted protocols for sensitive production traffic.
- Use least-privilege IAM permissions.
- Audit network configuration changes using CloudTrail.
- Remove unnecessary inbound permissions.
- Keep security group rules managed through version-controlled infrastructure.

---

## 19. Cleanup

**Warning:** Verify the AWS account, resource IDs, and project tags before deleting infrastructure.

Only delete resources belonging to `ELB-Troubleshooting-Lab12`.

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
  --resource-arns "$NLB_ARN" "$TG_ARN" \
  --region "$AWS_REGION"
```

Confirm the tag:

```text
Project=ELB-Troubleshooting-Lab12
```

### Step 2 — Delete TCP Listener

```bash
aws elbv2 delete-listener \
  --listener-arn "$LISTENER_ARN" \
  --region "$AWS_REGION"
```

### Step 3 — Delete NLB

```bash
aws elbv2 delete-load-balancer \
  --load-balancer-arn "$NLB_ARN" \
  --region "$AWS_REGION"

aws elbv2 wait load-balancers-deleted \
  --load-balancer-arns "$NLB_ARN" \
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

### Step 5 — Verify EBS Volume Settings

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the root volume uses `DeleteOnTermination=true`.

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
  --source-group "$NLB_SG_ID" \
  --region "$AWS_REGION"
```

If the rule has already been removed, verify the current security group permissions before continuing.

### Step 8 — Verify Network Interfaces

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Wait until the NLB and EC2 network interfaces have been removed.

### Step 9 — Delete Security Groups

```bash
aws ec2 delete-security-group \
  --group-id "$EC2_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$NLB_SG_ID" \
  --region "$AWS_REGION"
```

### Step 10 — Delete IAM Resources

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

### Step 11 — Delete Route Table

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

### Step 12 — Delete Subnets

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_A_ID" \
  --region "$AWS_REGION"

aws ec2 delete-subnet \
  --subnet-id "$SUBNET_B_ID" \
  --region "$AWS_REGION"
```

### Step 13 — Delete Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 14 — Delete VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 15 — Verify Cleanup

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

Verify NLB deletion:

```bash
aws elbv2 describe-load-balancers \
  --names "$NLB_NAME" \
  --region "$AWS_REGION"
```

Expected: `LoadBalancerNotFound`.

Also verify that the target group, EC2 instance, EBS root volume, IAM resources, and dedicated network resources are removed.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| NLB Listener | Deleted |
| Network Load Balancer | Deleted |
| Target Group | Deleted |
| EC2 Instance | Terminated |
| Root EBS Volume | Deleted |
| NLB Security Group | Deleted |
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

### Q1. What is a Network Load Balancer?

An AWS load balancer that operates primarily at Layer 4 and distributes TCP, UDP, and other supported transport-layer traffic to registered targets.

### Q2. What is the difference between ALB and NLB?

An ALB supports HTTP-aware routing, including URL paths and hostnames. An NLB primarily forwards transport-layer connections.

### Q3. What caused the connectivity failure in this lab?

The EC2 security group rule permitting TCP 8080 from the NLB security group was removed.

### Q4. Why did the target become unhealthy?

The NLB could not establish TCP connections to the application port during health checks.

### Q5. What does `Target.FailedHealthChecks` mean?

The registered target is failing the configured health checks.

### Q6. Why can EC2 be running while NLB connections fail?

Infrastructure health and network reachability are different. Security groups, routes, NACLs, or application port issues can prevent access.

### Q7. Does an NLB normally return HTTP 503 or 504 for TCP failures?

No. TCP connectivity failures generally appear as timeouts, resets, or failed connections rather than ALB-generated HTTP gateway errors.

### Q8. What is NLB fail-open behavior?

If all registered targets become unhealthy, the NLB may continue forwarding connections to those targets.

### Q9. Can a backend security group reference the NLB security group?

Yes. This allows controlled access from the NLB without exposing the backend port publicly.

### Q10. Which CloudWatch metrics help investigate NLB connectivity?

`HealthyHostCount`, `UnHealthyHostCount`, `TCP_ELB_Reset_Count`, and `TCP_Target_Reset_Count`.

### Q11. How can NLB connectivity failures be prevented?

Use infrastructure as code, least-privilege security groups, change reviews, target health alarms, and automated connectivity tests.

### Q12. How would you explain this lab in an interview?

I deployed an AWS Network Load Balancer with a TCP listener on port 80 and an EC2 backend running a Python application on port 8080.

After establishing a healthy baseline, I intentionally removed the backend security group rule allowing traffic from the NLB.

The target became unhealthy, and client connections failed even though the application continued working locally.

I investigated the NLB listener, target group configuration, health check status, security groups, EC2 health, and local application connectivity.

After restoring the least-privilege inbound rule, the target recovered and application requests successfully returned HTTP 200.

---

## 21. Repository Structure

```text
12-nlb-connectivity-failure/
├── README.md
├── ec2-trust-policy.json
└── backend-user-data.sh
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete NLB connectivity troubleshooting documentation |
| `ec2-trust-policy.json` | EC2 IAM trust policy for Systems Manager |
| `backend-user-data.sh` | Deploys the Python HTTP backend on port 8080 |

Never commit AWS credentials, private keys, or sensitive information.

---

## 22. Lessons Learned

This lab demonstrates how a Network Load Balancer can become unable to reach its backend even when the EC2 instance and application remain operational.

The problem was caused by a missing security group rule that blocked TCP port 8080.

The NLB remained active, but its registered target became unhealthy because TCP health checks could not establish a connection.

The most important troubleshooting steps were checking the target health reason, verifying the application locally, and comparing the NLB and backend security group rules.

Restoring the required inbound permission allowed the target to recover and normal traffic to resume.

**Key Lesson:** When troubleshooting NLB connectivity, verify the complete TCP path between the client, NLB, and registered backend. A running EC2 instance does not guarantee successful network access.

---

## 23. Skills Demonstrated

- AWS Network Load Balancer
- Layer 4 TCP troubleshooting
- TCP listener configuration
- Target group registration
- TCP health check investigation
- NLB fail-open behavior
- Security group troubleshooting
- AWS CLI v2
- EC2 application diagnostics
- Systems Manager
- Linux systemd
- curl and netcat
- CloudWatch NLB metrics
- VPC networking
- Least-privilege security configuration
- Fault injection
- Root cause analysis
- Remediation and verification
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-ELB-012 |
| Problem | NLB connectivity failure |
| Root Cause | Backend security group blocks TCP 8080 |
| NLB | Active |
| EC2 | Running |
| Application | Active |
| Target During Fault | Unhealthy |
| Client During Fault | TCP connection failure |
| Remediation | Restore TCP 8080 from NLB SG |
| Final Target Health | Healthy |
| Final HTTP Response | 200 |
| Cleanup | Temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** Network Load Balancers depend on correct target registration, health checks, and transport-layer connectivity. Even a fully running application can become unreachable when security group rules block required TCP traffic.
